import asyncio
import base64
import csv
import json
import math
from collections import Counter
from contextlib import AsyncExitStack
from pathlib import Path
from statistics import median
from time import monotonic

from aiohttp import ClientError, ClientSession, ClientTimeout, WSMsgType
from androidtvremote2 import AndroidTVRemote
from androidtvremote2.exceptions import ConnectionClosed, CannotConnect, InvalidAuth

from .lab import DEFAULT_PORTS, Lab
from .web_tvs import SAMSUNG_PATH

KEYS = {"roku": "VolumeUp", "google": "24", "samsung": "KEY_VOLUP", "lg": "VOLUMEUP"}
RECOVERABLE = (ClientError, OSError, TimeoutError, ConnectionClosed, CannotConnect, InvalidAuth)
CHAOS = ("drop", "rebind", "sleep", "revoke", "network")


def url(address, scheme="http"):
    return f"{scheme}://{address[0]}:{address[1]}"


class Controller:
    def __init__(self, base, session):
        self.base, self.session = base, session

    async def status(self, name):
        async with self.session.get(f"{self.base}/tvs/{name}") as response:
            return await response.json()

    async def chaos(self, name, **payload):
        async with self.session.post(f"{self.base}/tvs/{name}/chaos", json=payload) as response:
            return await response.json()


class Probe:
    def __init__(self, session, api, name, directory):
        self.session, self.api, self.name = session, api, name
        self.directory = directory
        self.addresses = None
        self.ws = self.remote = None
        self.credential = None
        self.ready_times = []
        self.pair_times = []
        self.pair_failures = 0

    async def close(self):
        if self.ws:
            await self.ws.close()
            self.ws = None
        if self.remote:
            self.remote.disconnect()
            self.remote = None

    async def connect(self, status):
        await self.close()
        self.addresses = status["addresses"]
        before = monotonic()
        if self.name == "roku":
            async with self.session.get(url(self.addresses["http"]) + "/query/device-info") as response:
                await response.read()
        elif self.name == "google":
            host, port = self.addresses["remote"]
            self.remote = AndroidTVRemote(
                "TestLab soak", str(self.directory / "probe.crt"), str(self.directory / "probe.key"),
                host, port, self.addresses["pair"][1],
            )
            await self.remote.async_generate_cert_if_missing()
            if self.credential:
                try:
                    await self.remote.async_connect()
                except RECOVERABLE:
                    self.credential = None
            if not self.credential:
                started = monotonic()
                try:
                    await self.remote.async_start_pairing()
                    code = (await self.api.status("google"))["pairing_code"]
                    await self.remote.async_finish_pairing(code)
                    self.credential = True
                except RECOVERABLE:
                    self.pair_failures += 1
                    raise
                self.pair_times.append(monotonic() - started)
                await self.remote.async_connect()
        elif self.name == "samsung":
            await self.samsung_connect()
        else:
            await self.lg_connect()
        self.ready_times.append(monotonic() - before)

    async def samsung_connect(self):
        params = {"name": base64.b64encode(b"TestLab soak").decode()}
        if self.credential:
            params["token"] = self.credential
        for _ in range(2):
            self.ws = await self.session.ws_connect(url(self.addresses["https"], "wss") + SAMSUNG_PATH,
                                                    params=params, ssl=False)
            started = monotonic()
            message = await self.ws.receive_json(timeout=2)
            if message["event"] == "ms.channel.connect":
                self.credential = message["data"]["token"]
                if "token" not in params:
                    self.pair_times.append(monotonic() - started)
                return
            await self.close()
            self.credential = None
            if params.pop("token", None) is None:
                break
        self.pair_failures += 1
        raise ConnectionError("Samsung rejected pairing")

    async def lg_connect(self):
        endpoint = url(self.addresses["http"], "ws")
        self.ws = await self.session.ws_connect(endpoint)
        for _ in range(2):
            cached_key = self.credential
            payload = {"pairingType": "PROMPT"}
            if cached_key:
                payload["client-key"] = cached_key
            started = monotonic()
            await self.ws.send_json({"type": "register", "id": "register", "payload": payload})
            message = await self.ws.receive_json(timeout=2)
            if message["type"] == "response":
                message = await self.ws.receive_json(timeout=2)
            if message["type"] == "registered":
                self.credential = message["payload"]["client-key"]
                if not cached_key:
                    self.pair_times.append(monotonic() - started)
                return
            self.credential = None
            if not cached_key:
                break
        self.pair_failures += 1
        raise ConnectionError("LG rejected pairing")

    async def send(self):
        key = KEYS[self.name]
        if self.name == "roku":
            async with self.session.post(url(self.addresses["http"]) + f"/keypress/{key}") as response:
                await response.read()
        elif self.name == "google":
            self.remote.send_key_command(int(key))
        elif self.name == "samsung":
            if self.ws.closed:
                raise ConnectionError("Samsung session closed")
            await self.ws.send_json({"method": "ms.remote.control", "params": {
                "Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey",
            }})
        else:
            await self.ws.send_json({"id": "volume", "type": "request", "uri": "ssap://audio/volumeUp"})
            message = await self.ws.receive(timeout=2)
            if message.type != WSMsgType.TEXT or not message.json().get("payload", {}).get("returnValue"):
                raise ConnectionError("LG did not accept command")

    async def sample(self):
        started = monotonic()
        recovered = False
        for attempt in range(2):
            try:
                status = await self.api.status(self.name)
                if attempt or self.addresses != status["addresses"]:
                    await self.connect(status)
                count = status["key_count"]
                await self.send()
                async with asyncio.timeout(1):
                    while True:
                        updated = await self.api.status(self.name)
                        if updated["key_count"] > count and updated["keys"][-1]["name"] == KEYS[self.name]:
                            return (monotonic() - started) * 1000, recovered, None
                        await asyncio.sleep(0.005)
            except RECOVERABLE as exc:
                recovered = True
                await self.close()
                self.addresses = None
                failure = type(exc).__name__
        return (monotonic() - started) * 1000, recovered, failure


def p95(values):
    return sorted(values)[math.ceil(len(values) * 0.95) - 1] if values else None


def metrics(rows, seconds, probes):
    successful = [row["latency_ms"] for row in rows if row["error"] is None and not row["chaos"]]
    setup = [elapsed * 1000 for probe in probes for elapsed in probe.ready_times[:1]]
    paired = sum(len(probe.pair_times) for probe in probes)
    rejected = sum(probe.pair_failures for probe in probes)
    pairing_rate = paired / (paired + rejected) if paired + rejected else None
    failures = [row for row in rows if row["error"]]
    unexpected_drops = sum(row["recovered"] for row in rows if not row["chaos"])
    drops = unexpected_drops * 7200 / seconds / len(probes)
    latency_p95, ready_p95 = p95(successful), p95(setup)
    return {
        "samples": len(rows), "failures": len(failures), "unplanned_drops": unexpected_drops,
        "failures_by_error": dict(Counter(row["error"] for row in failures)),
        "injected_samples": sum(bool(row["chaos"]) for row in rows),
        "recoveries": sum(row["recovered"] for row in rows),
        "latency_p50_ms": median(successful) if successful else None, "latency_p95_ms": latency_p95,
        "injected_latency_p95_ms": p95([row["latency_ms"] for row in rows if row["chaos"] and not row["error"]]),
        "ready_p95_ms": ready_p95, "drops_per_2h_per_tv": drops,
        "pairing_success": pairing_rate,
        "slo": {
            "pairing_success_at_least_95_percent": None if pairing_rate is None else pairing_rate >= 0.95,
            "ready_p95_under_2s": None if ready_p95 is None else ready_p95 < 2000,
            "command_p95_under_250ms": None if latency_p95 is None else latency_p95 < 250,
            "unplanned_drops_per_2h_under_1": drops < 1 if seconds >= 7200 else None,
            "crash_free_sessions_at_least_99_5_percent": None,
        },
    }


async def inject(api, name, action, lab):
    if action == "rebind":
        await api.chaos(name, action=action, ports={key: 0 for key in DEFAULT_PORTS[name]})
    elif action == "sleep":
        state = await api.chaos(name, action="sleep")
        if name in ("samsung", "lg"):
            packet = b"\xff" * 6 + bytes.fromhex(state["mac"].replace(":", "")) * 16
            loop = asyncio.get_running_loop()
            transport, _ = await loop.create_datagram_endpoint(asyncio.DatagramProtocol,
                                                                remote_addr=(lab.host, lab.wol_port))
            try:
                transport.sendto(packet)
                async with asyncio.timeout(2):
                    while (await api.status(name))["sleeping"]:
                        await asyncio.sleep(0.01)
            finally:
                transport.close()
        else:
            await api.chaos(name, action="wake")
    elif action == "network":
        await api.chaos(name, action="network", latency_ms=30, packet_loss=0)
    else:
        await api.chaos(name, action=action)


async def run(duration, interval, output, chaos_every=5):
    if duration <= 0 or interval <= 0 or chaos_every < 0:
        raise ValueError("duration and interval must be positive; chaos-every must be nonnegative")
    rows = []
    async with AsyncExitStack() as stack:
        lab = await stack.enter_async_context(Lab(ports={tv: dict.fromkeys(ports, 0)
                                                       for tv, ports in DEFAULT_PORTS.items()},
                                                  control_port=0, ssdp_port=0, wol_port=0, bonjour=False))
        session = await stack.enter_async_context(ClientSession(timeout=ClientTimeout(total=3), raise_for_status=True))
        api = Controller(url((lab.host, lab.control_port)), session)
        probes = [Probe(session, api, tv, Path(lab.directory.name)) for tv in DEFAULT_PORTS]
        for probe in probes:
            stack.push_async_callback(probe.close)
        start = monotonic()
        index = 0
        while index == 0 or monotonic() - start < duration:
            target = action = None
            if chaos_every and index and index % chaos_every == 0:
                event = index // chaos_every - 1
                target = probes[event % len(probes)].name
                action = CHAOS[event % len(CHAOS)]
                await inject(api, target, action, lab)
            results = await asyncio.gather(*(probe.sample() for probe in probes))
            elapsed = monotonic() - start
            rows.extend({"round": index, "elapsed_s": round(elapsed, 3), "tv": probe.name,
                         "latency_ms": round(ms, 3), "recovered": recovered, "error": error,
                         "chaos": action if probe.name == target else None}
                        for probe, (ms, recovered, error) in zip(probes, results))
            if action == "network":
                await api.chaos(target, action="network", latency_ms=0)
            index += 1
            await asyncio.sleep(max(0, min(duration, index * interval) - (monotonic() - start)))
        seconds = monotonic() - start
    report = {
        "scope": "simulated TVs only", "duration_s": round(seconds, 3),
        "summary": metrics(rows, seconds, probes),
        "by_tv": {probe.name: metrics([row for row in rows if row["tv"] == probe.name], seconds, [probe])
                  for probe in probes},
    }
    output.with_suffix(".json").write_text(json.dumps({**report, "samples": rows}, indent=2) + "\n")
    with output.with_suffix(".csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    return report
