import asyncio
import base64
import hashlib
import json
import socket
import ssl
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
from aiohttp import ClientConnectionError, ClientSession, ClientTimeout, web
from androidtvremote2 import AndroidTVRemote
from androidtvremote2.exceptions import CannotConnect, ConnectionClosed, InvalidAuth
from androidtvremote2.polo_pb2 import OuterMessage
from androidtvremote2.remotemessage_pb2 import RemoteKeyCode
from cryptography import x509
from zeroconf import IPVersion
from zeroconf.asyncio import AsyncServiceInfo, AsyncZeroconf

from tvlab.certs import identity, write_identity
from tvlab.roku import KEYS as ROKU_KEYS
from tvlab.soak import Controller, run, url
from tvlab.web_tvs import LG_KEYS, SAMSUNG_KEYS, SAMSUNG_PATH


async def reached(predicate, timeout=2):
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.005)


async def ssdp(lab, target, count=1):
    data = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
            f'MAN: "ssdp:discover"\r\nMX: 1\r\nST: {target}\r\n\r\n').encode()
    loop = asyncio.get_running_loop()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setblocking(False)
        await loop.sock_sendto(sock, data, (lab.host, lab.ssdp_port))
        async with asyncio.timeout(2):
            return [(await loop.sock_recv(sock, 4096)).decode() for _ in range(count)]


@pytest.mark.parametrize(("target", "platforms"), [
    ("roku:ecp", ["roku"]),
    ("urn:samsung.com:device:RemoteControlReceiver:1", ["samsung"]),
    ("urn:schemas-upnp-org:device:MediaRenderer:1", ["samsung", "lg"]),
    ("urn:lge-com:service:webos-second-screen:1", ["lg"]),
])
async def test_ssdp(lab, target, platforms):
    replies = await ssdp(lab, target, len(platforms))
    async with ClientSession() as client:
        for reply, platform in zip(replies, platforms):
            assert f"ST: {target}\r\n" in reply
            headers = dict(line.split(": ", 1) for line in reply.splitlines()[1:] if ": " in line)
            location = headers["LOCATION"]
            assert location.startswith(url(lab.address(platform, "http")))
            async with client.get(location) as resp:
                assert resp.status == 200
                root = ET.fromstring(await resp.text())
                udn = root.findtext(".//{*}UDN")
                assert udn == headers["USN"].split("::")[0]
                if platform == "roku":
                    assert root.findtext(".//{*}deviceType") == "urn:roku-com:device:player:1-0"
                    assert root.findtext(".//{*}serviceType") == "urn:roku-com:service:ecp:1"
                    service_url = root.findtext("{*}URLBase").rstrip("/") + root.findtext(".//{*}SCPDURL")
                    async with client.get(service_url) as service:
                        assert service.status == 200
                        assert ET.fromstring(await service.text()).tag.endswith("}scpd")


async def test_bonjour(lab):
    async with AsyncZeroconf(interfaces=[lab.host], ip_version=IPVersion.V4Only) as zc:
        info = AsyncServiceInfo("_androidtvremote2._tcp.local.", lab.bonjour.name)
        assert await info.async_request(zc.zeroconf, 3000)
        assert info.parsed_addresses() == [lab.host]
        assert info.port == lab.address("google", "remote")[1]


async def test_roku_keys_and_endpoints(lab):
    endpoint = url(lab.address("roku", "http"))
    async with ClientSession(raise_for_status=True) as client:
        async def get(path):
            async with client.get(endpoint + path) as response:
                return ET.fromstring(await response.text())

        async def post(path, **kwargs):
            async with client.post(endpoint + path, **kwargs) as response:
                return response.status

        assert (await get("/query/device-info")).findtext("serial-number") == "SIMROKU001"
        assert (await get("/query/device-info")).findtext("is-tv") == "true"
        catalog = await get("/query/apps")
        assert catalog.findtext("app") == "Netflix"
        assert {item.get("id"): item.text for item in catalog.findall("./app[@type='tvin']")} == {
            "tvinput.hdmi1": "HDMI 1", "tvinput.hdmi2": "HDMI 2", "tvinput.hdmi3": "HDMI 3",
            "tvinput.hdmi4": "HDMI 4", "tvinput.dtv": "Live TV", "tvinput.cvbs": "AV",
        }
        keys = sorted(ROKU_KEYS - {"Power", "PowerOff"}) + ["Lit_%E2%9C%93"]
        for key in keys:
            assert await post("/keypress/" + key) == 200
        assert [entry["name"] for entry in lab.tvs["roku"].keys] == keys[:-1] + ["Lit_✓"]
        assert await post("/keydown/Up") == 200
        assert lab.tvs["roku"].held == {"Up"}
        assert await post("/keyup/Up") == 200
        assert lab.tvs["roku"].held == set()
        assert await post("/keypress/___bad", raise_for_status=False) == 400
        assert await post("/launch/unknown", raise_for_status=False) == 404
        assert await post("/launch/tvinput.hdmi2") == 200
        assert (await get("/query/active-app")).find("app").attrib["id"] == "tvinput.hdmi2"
        assert lab.tvs["roku"].input == "tvinput.hdmi2"
        for key, input_id in [
            ("InputHDMI1", "tvinput.hdmi1"), ("InputTuner", "tvinput.dtv"), ("InputAV1", "tvinput.cvbs"),
        ]:
            assert await post(f"/keypress/{key}") == 200
            assert (await get("/query/active-app")).find("app").attrib["type"] == "tvin"
            assert lab.tvs["roku"].snapshot()["input"] == input_id
        assert await post("/launch/12?contentID=example&mediaType=movie") == 200
        assert (await get("/query/active-app")).findtext("app") == "Netflix"
        assert await post("/keypress/Play") == 200
        assert (await get("/query/media-player")).attrib["state"] == "play"
        assert await post("/search/browse?keyword=hello") == 200
        assert await post("/input?text=movie") == 200
        assert lab.tvs["roku"].search == "hello"
        assert lab.tvs["roku"].events[-1] == {"input": {"text": "movie"}}
        for power in ("Power", "PowerOff"):
            assert await post(f"/keypress/{power}") == 200
            assert lab.tvs["roku"].sleeping
            await lab.apply("roku", {"action": "wake"})


async def test_chaos_rejects_cross_origin_and_non_json_requests(lab):
    origin = url((lab.host, lab.control_port))
    endpoint = f"{origin}/tvs/roku/chaos"
    action = '{"action":"sleep"}'
    async with ClientSession() as client:
        for headers, expected in (
            ({"Origin": "https://unrelated.example", "Content-Type": "application/json"}, 403),
            ({"Origin": "null", "Content-Type": "application/json"}, 403),
            ({"Origin": origin, "Content-Type": "text/plain"}, 415),
            ({"Content-Type": "text/plain"}, 415),
        ):
            async with client.post(endpoint, data=action, headers=headers) as response:
                assert response.status == expected
            assert not lab.tvs["roku"].sleeping
        async with client.post(endpoint, json={"action": "sleep"}, headers={"Origin": origin}) as response:
            assert response.status == 200
            assert (await response.json())["sleeping"]


async def test_slow_chaos_body_does_not_block_google_power_off(lab, monkeypatch):
    reading = asyncio.Event()
    finish_body = asyncio.Event()
    notified = asyncio.Event()
    original_json = web.Request.json

    async def observe_json(request):
        reading.set()
        return await original_json(request)

    async def chunks():
        yield b'{"action":'
        await finish_body.wait()
        yield b'"sleep"}'

    async def notify():
        notified.set()

    monkeypatch.setattr(web.Request, "json", observe_json)
    endpoint = f"{url((lab.host, lab.control_port))}/tvs/roku/chaos"
    async with ClientSession() as client:
        async def post():
            async with client.post(endpoint, data=chunks(),
                                   headers={"Content-Type": "application/json"}) as response:
                return response.status

        slow_post = asyncio.create_task(post())
        try:
            await asyncio.wait_for(reading.wait(), 1)
            await asyncio.wait_for(lab.power_off_google(notify), 2)
            assert notified.is_set() and lab.tvs["google"].sleeping
            assert not slow_post.done()
        finally:
            finish_body.set()
            assert await slow_post == 200


async def test_chaos_endpoint_ip_changes_network_and_sleep(lab):
    async with ClientSession(timeout=ClientTimeout(total=1), raise_for_status=True) as client:
        api = Controller(url((lab.host, lab.control_port)), client)
        before = await api.status("roku")
        old = url(before["addresses"]["http"])
        old_identity = (await ssdp(lab, "roku:ecp"))[0].split("USN: ")[1]
        moved = await api.chaos("roku", action="rebind", host="127.0.0.2", ports={"http": 0})
        assert moved["addresses"]["http"][0] == "127.0.0.2"
        new = url(moved["addresses"]["http"])
        reply = (await ssdp(lab, "roku:ecp"))[0]
        assert f"LOCATION: {new}/" in reply and old_identity in reply
        with pytest.raises(ClientConnectionError):
            await client.get(old + "/query/device-info")
        with pytest.raises(ClientConnectionError):
            await api.chaos("roku", action="sleep")
            await client.get(new + "/query/device-info")
        await api.chaos("roku", action="wake")
        await api.chaos("roku", action="network", packet_loss=1)
        with pytest.raises(ClientConnectionError):
            await client.get(new + "/query/device-info")
        await api.chaos("roku", action="network", latency_ms=25, packet_loss=0)
        start = asyncio.get_running_loop().time()
        async with client.get(new + "/query/device-info") as response:
            assert response.status == 200
            assert asyncio.get_running_loop().time() - start >= .025


async def wake(lab, tv):
    packet = b"\xff" * 6 + bytes.fromhex(tv.mac.replace(":", "")) * 16
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.sendto(packet, (lab.host, lab.wol_port))
    await reached(lambda: not tv.sleeping)


async def test_samsung_tokens_keys_app_and_wake(lab):
    tv = lab.tvs["samsung"]
    params = {"name": base64.b64encode(b"Swift reference").decode()}
    http = url(lab.address("samsung", "http"))
    https = url(lab.address("samsung", "https"), "https")
    wss = url(lab.address("samsung", "https"), "wss") + SAMSUNG_PATH

    async with ClientSession() as client:
        for endpoint in (http, https):
            async with client.get(endpoint + "/api/v2/", ssl=False) as response:
                assert response.status == 200
                info = await response.json()
                assert info["device"]["TokenAuthSupport"] == "true"
                assert info["device"]["ImeSyncedSupport"] == "true"
                assert "isSupport" not in info["device"]
                support = json.loads(info["isSupport"])
                assert support["ImeSyncedSupport"] == info["device"]["ImeSyncedSupport"]
                assert support["TokenAuthSupport"] == info["device"]["TokenAuthSupport"]

        await lab.apply("samsung", {"action": "approval", "allow": False})
        async with client.ws_connect(wss, params=params, ssl=False) as ws:
            assert (await ws.receive_json())["event"] == "ms.channel.unauthorized"

        await lab.apply("samsung", {"action": "approval", "allow": True})
        async with client.ws_connect(wss, params=params, ssl=False) as ws:
            paired = await ws.receive_json()
            assert paired["event"] == "ms.channel.connect"
            params["token"] = paired["data"]["token"]
        await lab.apply("samsung", {"action": "approval", "allow": False})
        async with client.ws_connect(wss, params=params, ssl=False) as ws:
            assert (await ws.receive_json())["event"] == "ms.channel.connect"

            await ws.send_json({"method": "ms.channel.emit", "params": {
                "event": "ed.installedApp.get", "to": "host",
            }})
            installed = await ws.receive_json()
            assert installed["event"] == "ed.installedApp.get"
            assert {"appId": "11101200001", "name": "Netflix", "app_type": 2} in installed["data"]["data"]
            for sample in ("café ", "東京"):
                await ws.send_json({"method": "ms.remote.control", "params": {
                    "TypeOfRemote": "SendInputString", "DataOfCmd": "base64",
                    "Cmd": base64.b64encode(sample.encode()).decode(),
                }})
            await reached(lambda: tv.snapshot()["text"] == "café 東京")
            assert tv.snapshot()["text_entry_active"]
            await ws.send_json({"method": "ms.remote.control", "params": {"TypeOfRemote": "SendInputEnd"}})
            await reached(lambda: not tv.text_entry_active)
            await ws.send_json({"method": "ms.channel.emit", "params": {
                "event": "custom.remote.textReceived", "to": "broadcast",
            }})
            await reached(lambda: tv.text_entry_active)
            await ws.send_json({"method": "ms.remote.control", "params": {
                "TypeOfRemote": "SendInputString", "DataOfCmd": "base64", "Cmd": "!!!",
            }})
            assert (await ws.receive_json())["event"] == "ms.error"
            assert tv.text == "café 東京"

            async def press(key, cmd="Click"):
                await ws.send_json({"method": "ms.remote.control", "params": {
                    "Cmd": cmd, "DataOfCmd": key, "TypeOfRemote": "SendRemoteKey", "Option": "false",
                }})

            keys = sorted(SAMSUNG_KEYS - {"KEY_POWER"})
            for key in keys:
                await press(key)
            await press("KEY_INVALID")
            assert (await ws.receive_json())["event"] == "ms.error"
            assert [entry["name"] for entry in tv.keys] == keys
            await press("KEY_UP", "Press")
            await reached(lambda: tv.held == {"KEY_UP"})
            await press("KEY_UP", "Release")
            await reached(lambda: not tv.held)
            async with client.post(http + "/api/v2/applications/11101200001") as response:
                assert response.status == 200
            async with client.get(http + "/api/v2/applications/11101200001") as response:
                assert (await response.json())["running"]
            await press("KEY_POWER")
            await reached(lambda: tv.sleeping)
        with pytest.raises(ClientConnectionError):
            await client.get(http + "/api/v2/")
        await wake(lab, tv)
        await lab.apply("samsung", {"action": "firmware", "token_regression": True})
        ws_url = url(lab.address("samsung", "http"), "ws") + SAMSUNG_PATH
        async with client.ws_connect(ws_url, params=params) as ws:
            assert (await ws.receive_json())["event"] == "ms.channel.unauthorized"


async def test_lg_ssap_pointer_credentials_and_wake(lab):
    tv = lab.tvs["lg"]
    wss = url(lab.address("lg", "https"), "wss")

    async def register(ws, key=None):
        payload = {"pairingType": "PROMPT"}
        if key:
            payload["client-key"] = key
        await ws.send_json({"id": "pair", "type": "register", "payload": payload})
        return await ws.receive_json()

    async def call(ws, uri, **payload):
        await ws.send_json({"id": uri, "type": "request", "uri": f"ssap://{uri}", "payload": payload})
        response = await ws.receive_json()
        assert response["id"] == uri
        return response

    async with ClientSession() as client:
        async with client.ws_connect(wss, ssl=False) as ws:
            assert (await call(ws, "audio/getVolume"))["type"] == "error"
            await lab.apply("lg", {"action": "approval", "allow": False})
            assert (await register(ws))["type"] == "error"
            await lab.apply("lg", {"action": "approval", "allow": True})
            assert (await register(ws))["payload"]["pairingType"] == "PROMPT"
            key = (await ws.receive_json())["payload"]["client-key"]
        async with client.ws_connect(wss, ssl=False) as ws:
            assert (await register(ws, key))["type"] == "registered"
            result = await call(ws, "com.webos.service.networkinput/getPointerInputSocket")
            async with client.ws_connect(result["payload"]["socketPath"], ssl=False) as pointer:
                keys = sorted(LG_KEYS - {"POWER"})
                for key_name in keys:
                    await pointer.send_str(f"type:button\nname:{key_name}\n\n")
                await reached(lambda: tv.key_count == len(keys))
                assert [event["name"] for event in tv.keys] == keys
                await pointer.send_str("type:button\nname:CHANNELUP\n\n")
                await reached(lambda: tv.channel == "4-1")
                await pointer.send_str("type:button\nname:CHANNELDOWN\n\n")
                await reached(lambda: tv.channel == "2-1")
            channels = (await call(ws, "tv/getChannelList"))["payload"]["channelList"]
            assert [channel["channelNumber"] for channel in channels] == ["2-1", "4-1", "7-1"]
            assert (await call(ws, "tv/channelUp"))["payload"]["returnValue"]
            assert (await call(ws, "tv/getCurrentChannel"))["payload"]["channelNumber"] == "4-1"
            assert (await call(ws, "tv/channelDown"))["payload"]["returnValue"]
            assert tv.snapshot()["channel"] == "2-1"
            inputs = (await call(ws, "tv/getExternalInputList"))["payload"]["devices"]
            assert [(item["id"], item["label"]) for item in inputs] == [
                ("HDMI_1", "HDMI 1"), ("HDMI_2", "HDMI 2"), ("HDMI_3", "HDMI 3"),
            ]
            assert (await call(ws, "tv/switchInput", inputId=inputs[1]["id"]))["payload"]["returnValue"]
            assert tv.snapshot()["input"] == "HDMI_2"
            assert (await call(ws, "com.webos.applicationManager/getForegroundAppInfo"))["payload"]["appId"] == (
                "com.webos.app.hdmi2"
            )
            assert (await call(ws, "tv/switchInput", inputId="HDMI_99"))["type"] == "error"
            assert tv.input == "HDMI_2"
            assert (await call(ws, "audio/setVolume", volume=70))["payload"]["returnValue"]
            assert (await call(ws, "audio/getVolume"))["payload"]["volume"] == 70
            await call(ws, "system.launcher/launch", id="netflix")
            assert (await call(ws, "com.webos.applicationManager/getForegroundAppInfo"))["payload"]["appId"] == "netflix"
            await call(ws, "com.webos.service.ime/insertText", text="Hello")
            assert tv.search == "Hello"
            await call(ws, "system/turnOff")
        assert tv.sleeping
        await wake(lab, tv)
        async with client.ws_connect(wss, ssl=False) as ws:
            assert (await register(ws, key))["type"] == "registered"
            result = await call(ws, "com.webos.service.networkinput/getPointerInputSocket")
            async with client.ws_connect(result["payload"]["socketPath"], ssl=False) as pointer:
                await pointer.send_str("type:button\nname:POWER\n\n")
                await reached(lambda: tv.sleeping)
        await wake(lab, tv)
        await lab.apply("lg", {"action": "revoke"})
        endpoint = url(lab.address("lg", "http"), "ws")
        async with client.ws_connect(endpoint) as ws:
            assert (await register(ws, key))["error"].startswith("403")


def google_client(lab, tmp_path):
    host, remote = lab.address("google", "remote")
    return AndroidTVRemote("Reference driver", str(tmp_path / "cert.pem"), str(tmp_path / "key.pem"),
                           host, remote, lab.address("google", "pair")[1])


async def test_google_reference_pair_launch_ime_keepalive_and_revoke(lab, tmp_path):
    tv = lab.tvs["google"]
    client = google_client(lab, tmp_path)
    await client.async_generate_cert_if_missing()
    try:
        with pytest.raises(InvalidAuth):
            await client.async_connect()
        await client.async_start_pairing()
        assert len(tv.code) == 6
        await client.async_finish_pairing(tv.code)
        await client.async_connect()
        assert client.device_info["model"] == "Lab Google TV"
        for key in ("DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "DPAD_CENTER",
                    "VOLUME_UP", "VOLUME_DOWN", "VOLUME_MUTE", "HOME", "BACK",
                    "MEDIA_PLAY", "MEDIA_PAUSE", "MEDIA_STOP", "SEARCH"):
            client.send_key_command(key)
        await reached(lambda: tv.key_count == 14)
        assert [event["name"] for event in tv.keys] == [
            "19", "20", "21", "22", "23", "24", "25", "164", "3", "4", "126", "127", "86", "84",
        ]
        assert tv.volume == 25 and tv.muted
        client.send_text("Movies")
        client.send_launch_app_command("https://www.youtube.com")
        await reached(lambda: tv.app == "https://www.youtube.com")
        assert tv.search == "Movies"
        await reached(lambda: any("keepalive" in event for event in tv.events), timeout=7)
        await lab.apply("google", {"action": "drop"})
        await client.async_connect()
        await lab.apply("google", {"action": "revoke"})
        with pytest.raises(InvalidAuth) as denied:
            await client.async_connect()
        assert isinstance(denied.value.__cause__, ssl.SSLError)
        assert denied.value.__cause__.reason == "TLSV1_ALERT_UNKNOWN_CA"
        await lab.apply("google", {"action": "sleep"})
        with pytest.raises((ConnectionClosed, CannotConnect)):
            await client.async_connect()
        await lab.apply("google", {"action": "wake"})
        await client.async_start_pairing()
        await client.async_finish_pairing(tv.code)
        await client.async_connect()
        power = RemoteKeyCode.Value("KEYCODE_POWER")
        codes = sorted(set(RemoteKeyCode.values()) - {0, power})
        for start in range(0, len(codes), 32):
            batch = codes[start:start + 32]
            count = tv.key_count
            for code in batch:
                client.send_key_command(code)
            await reached(lambda: tv.key_count == count + len(batch))
            assert [entry["name"] for entry in list(tv.keys)[-len(batch):]] == list(map(str, batch))
        client.send_key_command("DPAD_UP", "START_LONG")
        await reached(lambda: tv.held == {"19"})
        client.send_key_command("DPAD_UP", "END_LONG")
        await reached(lambda: not tv.held)
        observer = google_client(lab, tmp_path)
        try:
            await observer.async_connect()
            assert lab.bonjour.info is not None
            client.send_key_command(power)
            await reached(lambda: tv.sleeping and lab.bonjour.info is None and not tv.connections)
            async with AsyncZeroconf(interfaces=[lab.host], ip_version=IPVersion.V4Only) as zc:
                info = AsyncServiceInfo(lab.bonjour.service_type, lab.bonjour.name)
                assert not await info.async_request(zc.zeroconf, 500)
        finally:
            observer.disconnect()
    finally:
        client.disconnect()


async def polo_exchange(reader, writer, req):
    data = req.SerializeToString()
    assert len(data) < 128
    writer.write(bytes([len(data)]) + data)
    await writer.drain()
    length = (await reader.readexactly(1))[0]
    assert length < 128
    return OuterMessage.FromString(await reader.readexactly(length))


async def polo_start(reader, writer):
    req = OuterMessage(protocol_version=2, status=200)
    req.pairing_request.service_name = "atvremote"
    reply = await polo_exchange(reader, writer, req)
    if reply.status != 200:
        return reply
    assert reply.HasField("pairing_request_ack")
    req.ClearField("pairing_request")
    req.options.input_encodings.add(type=3, symbol_length=6)
    reply = await polo_exchange(reader, writer, req)
    assert reply.options.output_encodings[0].symbol_length == 6
    req.ClearField("options")
    req.configuration.encoding.type = 3
    req.configuration.encoding.symbol_length = 6
    req.configuration.client_role = 1
    reply = await polo_exchange(reader, writer, req)
    assert reply.HasField("configuration_ack")
    return reply


async def test_google_wrong_code_and_denied_approval(lab, tmp_path):
    cert, key = write_identity(tmp_path, *identity("Independent Polo client"), "client")
    tls = ssl._create_unverified_context()
    tls.load_cert_chain(cert, key)
    tv = lab.tvs["google"]
    for approved in (False, True):
        await lab.apply("google", {"action": "approval", "allow": approved})
        reader, writer = await asyncio.open_connection(*lab.address("google", "pair"), ssl=tls)
        try:
            reply = await polo_start(reader, writer)
            if not approved:
                assert reply.status == 400 and tv.code is None
                continue
            server = x509.load_der_x509_certificate(writer.get_extra_info("ssl_object").getpeercert(True))
            numbers = [x for cert in (x509.load_pem_x509_certificate(Path(cert).read_bytes()), server)
                       for nums in [cert.public_key().public_numbers()] for x in (nums.n, nums.e)]
            nonce = int(tv.code[2:], 16) ^ 1
            digest = hashlib.sha256(b"".join(x.to_bytes((x.bit_length() + 7) // 8, "big") for x in numbers)
                                    + nonce.to_bytes(2, "big")).digest()
            req = OuterMessage(protocol_version=2, status=200)
            req.secret.secret = digest
            reply = await polo_exchange(reader, writer, req)
            assert reply.status == 402
            assert not tv.credentials
        finally:
            writer.close()
            await writer.wait_closed()


async def test_google_revoke_during_delayed_pairing_secret(lab, tmp_path, monkeypatch):
    tv = lab.tvs["google"]
    client = google_client(lab, tmp_path)
    await client.async_generate_cert_if_missing()
    await client.async_start_pairing()
    receiving_secret = asyncio.Event()
    resume = asyncio.Event()
    deliveries = tv.delivers

    async def delayed_delivery():
        receiving_secret.set()
        await resume.wait()
        return await deliveries()

    monkeypatch.setattr(tv, "delivers", delayed_delivery)
    finishing = asyncio.create_task(client.async_finish_pairing(tv.code))
    try:
        await asyncio.wait_for(receiving_secret.wait(), 2)
        await lab.apply("google", {"action": "revoke"})
        resume.set()
        with pytest.raises(ConnectionClosed):
            await finishing
        await reached(lambda: not tv.pending_codes)
        assert not tv.credentials
        assert {"pair": "accepted"} not in tv.events
    finally:
        resume.set()
        client.disconnect()
        await asyncio.gather(finishing, return_exceptions=True)


async def test_short_soak(tmp_path):
    result = await run(3, .15, tmp_path / "report.test", chaos_every=1)
    summary = result["summary"]
    assert summary["samples"] >= 24
    assert summary["failures"] == 0
    assert summary["injected_samples"] >= 5
    assert summary["latency_p95_ms"] is not None
    assert summary["slo"]["command_p95_under_250ms"]
    assert summary["slo"]["crash_free_sessions_at_least_99_5_percent"] is None
    assert (tmp_path / "report.test.csv").read_text().startswith("round,elapsed_s,tv,")
    assert (tmp_path / "report.test.json").is_file()
    assert not (tmp_path / "report.json").exists()
