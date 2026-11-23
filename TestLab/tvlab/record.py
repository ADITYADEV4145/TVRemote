import asyncio
import base64
import json
from pathlib import Path

from aiohttp import ClientSession
from androidtvremote2 import AndroidTVRemote
from androidtvremote2.exceptions import InvalidAuth

from .lab import DEFAULT_PORTS, Lab
from .soak import url
from .web_tvs import SAMSUNG_PATH


async def record(directory):
    directory.mkdir(parents=True, exist_ok=True)
    ports = {name: dict.fromkeys(schemes, 0) for name, schemes in DEFAULT_PORTS.items()}
    traces = {name: [] for name in ports}
    async with Lab(ports=ports, control_port=0, ssdp_port=0, wol_port=0, bonjour=False) as lab:
        async with ClientSession() as session:
            await record_roku(lab, session, traces["roku"])
            await record_samsung(lab, session, traces["samsung"])
            await record_lg(lab, session, traces["lg"])
            await record_google(lab, traces["google"])
    for name, frames in traces.items():
        data = {"platform": name, "source": "TestLab simulator, not hardware", "frames": frames}
        (directory / f"{name}.json").write_text(json.dumps(data, indent=2) + "\n")


async def record_roku(lab, session, trace):
    base = url(lab.address("roku", "http"))
    for method, path in [
        ("GET", "/query/device-info"), ("GET", "/query/apps"), ("POST", "/keypress/VolumeUp"),
        ("POST", "/launch/12"), ("GET", "/query/active-app"), ("POST", "/search/browse?keyword=movie"),
        ("POST", "/keypress/InvalidKey"), ("POST", "/launch/tvinput.hdmi1"),
        ("GET", "/query/active-app"),
    ]:
        async with session.request(method, base + path) as response:
            trace.append({"request": {"method": method, "path": path},
                          "response": {"status": response.status, "body": await response.text()}})


async def record_samsung(lab, session, trace):
    base = url(lab.address("samsung", "https"), "wss")
    params = {"name": base64.b64encode(b"Fixture client").decode()}
    trace.append({"connect": SAMSUNG_PATH, "query": params})
    async with session.ws_connect(base + SAMSUNG_PATH, params=params, ssl=False) as ws:
        paired = await ws.receive_json()
        paired["data"]["token"] = "<token>"
        trace.append({"received": paired})
        key = {"method": "ms.remote.control", "params": {"Cmd": "Click", "DataOfCmd": "KEY_VOLUP",
                                                       "Option": "false", "TypeOfRemote": "SendRemoteKey"}}
        await ws.send_json(key)
        trace.append({"sent": key})
        key = {**key, "params": {**key["params"], "DataOfCmd": "KEY_INVALID"}}
        await ws.send_json(key)
        trace.extend([{"sent": key}, {"received": await ws.receive_json()}])
        command = {"method": "ms.channel.emit", "params": {"event": "ed.installedApp.get", "to": "host"}}
        await ws.send_json(command)
        trace.extend([{"sent": command}, {"received": await ws.receive_json()}])
        for params_to_send in (
            {"Cmd": base64.b64encode("café".encode()).decode(), "DataOfCmd": "base64",
             "TypeOfRemote": "SendInputString"},
            {"TypeOfRemote": "SendInputEnd"},
        ):
            command = {"method": "ms.remote.control", "params": params_to_send}
            await ws.send_json(command)
            trace.append({"sent": command})
        async with asyncio.timeout(2):
            while lab.tvs["samsung"].text != "café" or lab.tvs["samsung"].text_entry_active:
                await asyncio.sleep(.005)
    params = {**params, "token": "wrong-token"}
    trace.append({"connect": SAMSUNG_PATH, "query": params})
    async with session.ws_connect(base + SAMSUNG_PATH, params=params, ssl=False) as ws:
        trace.append({"received": await ws.receive_json()})


async def record_lg(lab, session, trace):
    base = url(lab.address("lg", "http"), "ws")
    async with session.ws_connect(base) as ws:
        signup = {"type": "register", "id": "register", "payload": {"pairingType": "PROMPT"}}
        await ws.send_json(signup)
        trace.extend([{"sent": signup}, {"received": await ws.receive_json()}])
        approved = await ws.receive_json()
        approved["payload"]["client-key"] = "<client-key>"
        trace.append({"received": approved})
        command = {"id": "vol", "type": "request", "uri": "ssap://audio/getVolume"}
        await ws.send_json(command)
        trace.extend([{"sent": command}, {"received": await ws.receive_json()}])
        for ident, uri, payload in (
            ("channels", "tv/getChannelList", {}),
            ("up", "tv/channelUp", {}),
            ("current-channel", "tv/getCurrentChannel", {}),
            ("down", "tv/channelDown", {}),
            ("inputs", "tv/getExternalInputList", {}),
            ("switch", "tv/switchInput", {"inputId": "HDMI_1"}),
        ):
            command = {"type": "request", "id": ident, "uri": f"ssap://{uri}", "payload": payload}
            await ws.send_json(command)
            trace.extend([{"sent": command}, {"received": await ws.receive_json()}])
        command = {"id": "pointer", "type": "request",
                   "uri": "ssap://com.webos.service.networkinput/getPointerInputSocket"}
        await ws.send_json(command)
        reply = await ws.receive_json()
        pointer_path = reply["payload"]["socketPath"]
        reply["payload"]["socketPath"] = "ws://<host>/resources/<ticket>.sock"
        trace.extend([{"sent": command}, {"received": reply}])
        async with session.ws_connect(pointer_path) as pointer:
            press = "type:button\nname:LEFT\n\n"
            await pointer.send_str(press)
            trace.append({"pointer_sent": press})
            async with asyncio.timeout(2):
                while not lab.tvs["lg"].key_count:
                    await asyncio.sleep(.005)


async def record_google(lab, trace):
    host, remote_port = lab.address("google", "remote")
    directory = Path(lab.directory.name)
    tv = lab.tvs["google"]
    tv.trace = trace
    client = AndroidTVRemote("Fixture client", str(directory / "trace.crt"), str(directory / "trace.key"),
                             host, remote_port, lab.address("google", "pair")[1])
    try:
        await client.async_generate_cert_if_missing()
        await client.async_start_pairing()
        await client.async_finish_pairing(tv.code)
        await client.async_connect()
        client.send_key_command("VOLUME_UP")
        client.send_launch_app_command("https://www.youtube.com")
        async with asyncio.timeout(7):
            while not any("keepalive" in event for event in tv.events):
                await asyncio.sleep(.02)
        await lab.apply("google", {"action": "revoke"})
        try:
            await client.async_connect()
        except InvalidAuth as exc:
            trace.append({"channel": "remote", "tls_alert": exc.__cause__.reason, "client_error": "InvalidAuth"})
        else:
            raise RuntimeError("Google TV accepted a revoked certificate")
    finally:
        client.disconnect()
        tv.trace = None
