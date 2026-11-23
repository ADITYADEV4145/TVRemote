import asyncio
import ipaddress
import math
import secrets
import tempfile
from pathlib import Path

from aiohttp import web

from . import android, roku
from .certs import identity, server_context
from .discovery import Bonjour, Wake, ssdp_listener
from .state import TV
from .web_tvs import lg_routes, samsung_routes

DEFAULT_PORTS = {
    "roku": {"http": 8060}, "google": {"remote": 6466, "pair": 6467},
    "samsung": {"http": 8001, "https": 8002}, "lg": {"http": 3000, "https": 3001},
}
ROUTES = {"roku": roku.routes, "samsung": samsung_routes, "lg": lg_routes}


class Lab:
    def __init__(self, host="127.0.0.1", advertise=None, ports=None, control_port=8090,
                 ssdp_port=1900, wol_port=9, bonjour=True):
        self.host = str(ipaddress.IPv4Address(host))
        self.advertise = str(ipaddress.IPv4Address(advertise or host))
        if self.advertise == "0.0.0.0":
            raise ValueError("--advertise must be the reachable LAN IP when binding 0.0.0.0")
        self.ssdp_port, self.wol_port, self.control_port = ssdp_port, wol_port, control_port
        self.bonjour_enabled = bonjour
        self.bonjour = None
        self.tvs = {name: TV(name, f"02:00:00:00:00:{index:02x}")
                    for index, name in enumerate(DEFAULT_PORTS, start=1)}
        self.bindings = {name: (host, self.advertise, values.copy())
                         for name, values in (ports or DEFAULT_PORTS).items()}
        self.endpoints = {name: {} for name in self.tvs}
        self.stops = {name: [] for name in self.tvs}
        self.transports = []
        self.admin = None
        self.lock = asyncio.Lock()

    def address(self, name, scheme):
        return self.endpoints[name][scheme]

    async def __aenter__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="tvlab-")
        self.cert, self.key = identity("TestLab Simulated TV", self.advertise)
        self.tls = server_context(Path(self.directory.name), self.cert, self.key)
        try:
            for name in self.tvs:
                await self.start_tv(name)
            ssdp = await ssdp_listener(self, self.host if self.advertise.startswith("127.") else "0.0.0.0",
                                       self.ssdp_port)
            self.transports.append(ssdp)
            self.ssdp_port = ssdp.get_extra_info("sockname")[1]
            wake, _ = await asyncio.get_running_loop().create_datagram_endpoint(
                lambda: Wake(self), local_addr=(self.host if self.advertise.startswith("127.") else "0.0.0.0",
                                                self.wol_port), allow_broadcast=True)
            self.transports.append(wake)
            self.wol_port = wake.get_extra_info("sockname")[1]
            admin = web.Application(client_max_size=64 * 1024)
            admin.add_routes([web.get("/tvs", self.list_tvs), web.get("/tvs/{name}", self.get_tv),
                              web.post("/tvs/{name}/chaos", self.chaos)])
            self.admin, port = await serve(admin, self.host, self.control_port)
            self.control_port = port
            if self.bonjour_enabled:
                self.bonjour = Bonjour(secrets.token_hex(3), self.advertise)
                await self.update_bonjour()
            return self
        except BaseException:
            await self.__aexit__(None, None, None)
            raise

    async def __aexit__(self, *_):
        if self.admin:
            await self.admin.cleanup()
        if self.bonjour:
            await self.bonjour.close()
        for transport in self.transports:
            transport.close()
        for name in self.tvs:
            await self.stop_tv(name)
        self.directory.cleanup()

    async def update_bonjour(self):
        if self.bonjour:
            address = self.address("google", "remote")
            await self.bonjour.update(*address, self.tvs["google"].sleeping)

    async def set_sleeping(self, name, sleeping, notify=None):
        tv = self.tvs[name]
        tv.sleeping = sleeping
        try:
            if notify:
                await notify()
        finally:
            if sleeping:
                await tv.disconnect()
            if name == "google":
                await self.update_bonjour()

    async def power_off_google(self, notify):
        async with self.lock:
            if not self.tvs["google"].sleeping:
                await self.set_sleeping("google", True, notify)

    async def start_tv(self, name):
        bind, advertise, ports = self.bindings[name]
        tv = self.tvs[name]
        for scheme, requested in ports.items():
            if name == "google":
                server = await android.serve(tv, bind, requested, scheme, self.cert, self.key,
                                             self.power_off_google)
                port = server.sockets[0].getsockname()[1]

                async def stop(server=server):
                    server.close()
                    await server.wait_closed()

                self.stops[name].append(stop)
            else:
                @web.middleware
                async def network(request, handler):
                    if not await tv.delivers():
                        request.transport and request.transport.abort()
                        return web.Response(status=503)
                    return await handler(request)

                app = web.Application(middlewares=[network])
                ROUTES[name](app, tv)
                runner, port = await serve(app, bind, requested, self.tls if scheme == "https" else None)
                self.stops[name].append(runner.cleanup)
            self.endpoints[name][scheme] = (advertise, port)

    async def stop_tv(self, name):
        await self.tvs[name].disconnect()
        for stop in self.stops[name]:
            await stop()
        self.stops[name].clear()
        self.endpoints[name].clear()

    def snapshot(self, name):
        return {**self.tvs[name].snapshot(), "addresses": self.endpoints[name]}

    async def list_tvs(self, _):
        return web.json_response({name: self.snapshot(name) for name in self.tvs})

    async def get_tv(self, request):
        name = request.match_info["name"]
        if name not in self.tvs:
            raise web.HTTPNotFound()
        return web.json_response(self.snapshot(name))

    async def chaos(self, request):
        name = request.match_info["name"]
        if name not in self.tvs:
            raise web.HTTPNotFound()
        origins = request.headers.getall("Origin", [])
        if origins and origins != [f"{request.scheme}://{request.host}"]:
            raise web.HTTPForbidden(text="Cross-origin chaos requests are not allowed")
        if request.content_type != "application/json":
            raise web.HTTPUnsupportedMediaType(text="Expected application/json")
        async with self.lock:
            try:
                await self.apply(name, await request.json())
            except (KeyError, TypeError, ValueError, OSError) as exc:
                raise web.HTTPBadRequest(text=str(exc)) from exc
        return web.json_response(self.snapshot(name))

    async def apply(self, name, payload):
        tv = self.tvs[name]
        action = payload["action"]
        if action in ("sleep", "wake"):
            await self.set_sleeping(name, action == "sleep")
        elif action == "drop":
            await tv.disconnect()
        elif action == "revoke":
            tv.credential_epoch += 1
            tv.credentials.clear()
            await tv.disconnect()
        elif action == "approval":
            if not isinstance(payload["allow"], bool):
                raise ValueError("allow must be a boolean")
            tv.approval = payload["allow"]
        elif action == "network":
            latency = float(payload.get("latency_ms", tv.latency_ms))
            loss = float(payload.get("packet_loss", tv.packet_loss))
            if not math.isfinite(latency) or not 0 <= latency <= 60_000 or not 0 <= loss <= 1:
                raise ValueError("latency_ms must be 0..60000; packet_loss must be 0..1")
            tv.latency_ms, tv.packet_loss = latency, loss
        elif action == "firmware" and name == "samsung":
            if not isinstance(payload["token_regression"], bool):
                raise ValueError("token_regression must be a boolean")
            tv.token_regression = payload["token_regression"]
            await tv.disconnect()
        elif action == "rebind":
            previous = self.bindings[name]
            bind = str(ipaddress.IPv4Address(payload.get("host", previous[0])))
            advertise = str(ipaddress.IPv4Address(payload.get("advertise", bind if bind != previous[0] else previous[1])))
            requested = payload.get("ports", {})
            if not isinstance(requested, dict):
                raise ValueError("ports must be a map")
            ports = {scheme: port for scheme, (_, port) in self.endpoints[name].items()}
            if (advertise == "0.0.0.0" or requested.keys() - ports.keys()
                    or any(type(p) is not int or not 0 <= p <= 65535 for p in requested.values())):
                raise ValueError("invalid bind address or protocol port")
            prior_bound = ports.copy()
            ports.update(requested)
            await self.stop_tv(name)
            self.bindings[name] = (bind, advertise, ports)
            try:
                await self.start_tv(name)
            except OSError:
                await self.stop_tv(name)
                self.bindings[name] = (previous[0], previous[1], prior_bound)
                await self.start_tv(name)
                raise
            if name == "google":
                await self.update_bonjour()
        else:
            raise ValueError("unknown chaos action")


async def serve(app, host, port, tls=None):
    runner = web.AppRunner(app, access_log=None, shutdown_timeout=1)
    await runner.setup()
    try:
        await web.TCPSite(runner, host, port, ssl_context=tls, reuse_address=True).start()
    except BaseException:
        await runner.cleanup()
        raise
    return runner, runner.addresses[0][1]
