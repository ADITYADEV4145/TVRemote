import asyncio
import ipaddress
import socket

from zeroconf import IPVersion, ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

from .roku import udn as roku_udn

SSDP_GROUP = "239.255.255.250"
SSDP_TYPES = {
    "roku": ("roku:ecp",),
    "samsung": ("urn:samsung.com:device:RemoteControlReceiver:1", "urn:schemas-upnp-org:device:MediaRenderer:1"),
    "lg": ("urn:schemas-upnp-org:device:MediaRenderer:1", "urn:lge-com:service:webos-second-screen:1"),
}


class SSDP(asyncio.DatagramProtocol):
    def __init__(self, lab):
        self.lab = lab

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, peer):
        lines = data.decode("ascii", errors="ignore").splitlines()
        if not lines or lines[0].upper() != "M-SEARCH * HTTP/1.1":
            return
        headers = dict((key.strip().lower(), value.strip()) for line in lines[1:]
                       if ":" in line for key, value in [line.split(":", 1)])
        if headers.get("man", "").lower() != '"ssdp:discover"':
            return
        requested = headers.get("st", "").lower()
        for platform, types in SSDP_TYPES.items():
            tv = self.lab.tvs[platform]
            if tv.sleeping:
                continue
            identity = tv.mac.replace(":", "")
            udn = roku_udn(tv) if platform == "roku" else f"uuid:lab-{platform}-{identity}"
            for target in (*types, "upnp:rootdevice", udn):
                if requested not in (target.lower(), "ssdp:all"):
                    continue
                address = self.lab.address(platform, "http")
                path = "/" if platform == "roku" else "/description.xml"
                usn = udn if target == udn else f"{udn}::{target}"
                reply = (
                    f"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=60\r\n"
                    f"LOCATION: http://{address[0]}:{address[1]}{path}\r\n"
                    f"ST: {target}\r\nUSN: {usn}\r\nSERVER: TestLab UPnP/1.0\r\n\r\n"
                )
                self.transport.sendto(reply.encode("ascii"), peer)


class Wake(asyncio.DatagramProtocol):
    def __init__(self, lab):
        self.lab = lab

    def datagram_received(self, data, _):
        for platform in ("samsung", "lg"):
            tv = self.lab.tvs[platform]
            magic = b"\xff" * 6 + bytes.fromhex(tv.mac.replace(":", "")) * 16
            if magic in data:
                tv.sleeping = False
                tv.events.append({"wake": "wol"})


async def ssdp_listener(lab, bind, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((bind, port))
        if not ipaddress.IPv4Address(lab.advertise).is_loopback:
            membership = socket.inet_aton(SSDP_GROUP) + socket.inet_aton(lab.advertise)
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
        sock.setblocking(False)
        transport, _ = await asyncio.get_running_loop().create_datagram_endpoint(lambda: SSDP(lab), sock=sock)
        return transport
    except BaseException:
        sock.close()
        raise


class Bonjour:
    service_type = "_androidtvremote2._tcp.local."

    def __init__(self, unique_name, interface):
        self.zc = AsyncZeroconf(interfaces=[interface], ip_version=IPVersion.V4Only)
        self.info = None
        self.name = f"Lab Google TV {unique_name}.{self.service_type}"
        self.hostname = f"lab-google-tv-{unique_name}.local."

    async def update(self, host, port, sleeping):
        if self.info:
            await (await self.zc.async_unregister_service(self.info))
            self.info = None
        if not sleeping:
            self.info = ServiceInfo(self.service_type, self.name, addresses=[socket.inet_aton(host)],
                                    port=port, server=self.hostname,
                                    properties={"bt": "false"})
            await (await self.zc.async_register_service(self.info, strict=False))

    async def close(self):
        if self.info:
            await (await self.zc.async_unregister_service(self.info))
        await self.zc.async_close()
