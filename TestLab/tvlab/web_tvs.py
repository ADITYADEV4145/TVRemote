import base64
import binascii
import json
import secrets
from contextlib import asynccontextmanager
from xml.etree.ElementTree import Element, SubElement, tostring

from aiohttp import WSMsgType, web

SAMSUNG_PATH = "/api/v2/channels/samsung.remote.control"
SAMSUNG_KEYS = set("""KEY_POWER KEY_HOME KEY_RETURN KEY_EXIT KEY_MENU KEY_SOURCE KEY_INFO
KEY_UP KEY_DOWN KEY_LEFT KEY_RIGHT KEY_ENTER KEY_VOLUP KEY_VOLDOWN KEY_MUTE KEY_CHUP KEY_CHDOWN
KEY_PLAY KEY_PAUSE KEY_STOP KEY_REWIND KEY_FF KEY_PLAYPAUSE KEY_GUIDE KEY_CH_LIST
KEY_RED KEY_GREEN KEY_YELLOW KEY_BLUE KEY_TOOLS KEY_PRECH KEY_SEARCH KEY_HDMI KEY_TV
KEY_CONTENTS KEY_SMART KEY_PANEL_CH_UP KEY_PANEL_CH_DOWN""".split()) | {f"KEY_{i}" for i in range(10)}
LG_KEYS = set("""UP DOWN LEFT RIGHT ENTER BACK HOME MENU EXIT INFO DASH SAP CC GUIDE
VOLUMEUP VOLUMEDOWN MUTE CHANNELUP CHANNELDOWN PLAY PAUSE STOP REWIND FASTFORWARD
RED GREEN YELLOW BLUE POWER LIST LIVE TV INPUT""".split()) | {str(i) for i in range(10)}


@asynccontextmanager
async def websocket(request, tv):
    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=64 * 1024)
    await ws.prepare(request)

    async def close():
        request.transport and request.transport.abort()

    tv.connections.add(close)
    try:
        yield ws
    finally:
        tv.connections.discard(close)


def description(tv, friendly, model, kind, request):
    root = Element("root", xmlns="urn:schemas-upnp-org:device-1-0")
    version = SubElement(root, "specVersion")
    SubElement(version, "major").text = "1"
    SubElement(version, "minor").text = "0"
    SubElement(root, "URLBase").text = f"{request.scheme}://{request.host}/"
    device = SubElement(root, "device")
    for name, value in {
        "friendlyName": friendly, "deviceType": kind, "manufacturer": model,
        "modelName": model, "UDN": f"uuid:lab-{tv.platform}-{tv.mac.replace(':', '')}",
    }.items():
        SubElement(device, name).text = value
    return web.Response(body=tostring(root, encoding="utf-8", xml_declaration=True),
                        content_type="text/xml")


def samsung_routes(app, tv):
    async def info(request):
        return web.json_response({
            "id": f"uuid:lab-samsung-{tv.mac.replace(':', '')}",
            "name": "Lab Samsung", "type": "Samsung SmartTV",
            "version": "2.0.25", "uri": f"{request.scheme}://{request.host}/api/v2/",
            "device": {"name": "Lab Samsung", "modelName": "Tizen Simulator", "wifiMac": tv.mac,
                       "OS": "Tizen", "PowerState": "on", "TokenAuthSupport": "true"},
        })

    async def device(request):
        return description(tv, "Lab Samsung", "Samsung", "urn:samsung.com:device:RemoteControlReceiver:1", request)

    async def applications(request):
        app_id = request.match_info["app_id"]
        if request.method == "POST":
            tv.launch(app_id)
            return web.json_response({"id": app_id, "result": "success"})
        return web.json_response({"id": app_id, "running": tv.app == app_id,
                                  "visible": tv.app == app_id, "version": "1.0"})

    async def remote(request):
        async with websocket(request, tv) as ws:
            encoded = request.query.get("name", "")
            try:
                name = base64.b64decode(encoded, validate=True).decode()
            except (UnicodeError, binascii.Error):
                name = ""
            token = request.query.get("token")
            authorized = bool(name) and (
                (token is not None and not tv.token_regression and tv.credentials.get(name) == token)
                or (token is None and tv.approval)
            )
            if not authorized:
                await ws.send_json({"event": "ms.channel.unauthorized"})
                await ws.close()
                return ws
            if token is None:
                token = secrets.token_hex(4)
                tv.credentials[name] = token
            await ws.send_json({"event": "ms.channel.connect", "data": {
                "id": "lab-samsung", "token": token,
                "clients": [{"id": "lab-samsung", "deviceName": encoded, "isHost": False}],
            }})
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                if not await tv.delivers():
                    request.transport and request.transport.abort()
                    break
                try:
                    message = json.loads(msg.data)
                    params = message["params"]
                    if message["method"] == "ms.remote.control":
                        key = params["DataOfCmd"]
                        if params["TypeOfRemote"] != "SendRemoteKey" or key not in SAMSUNG_KEYS:
                            raise ValueError
                        tv.key(key, {"Click": "press", "Press": "down", "Release": "up"}[params["Cmd"]])
                    elif (message["method"], params["event"]) == ("ms.channel.emit", "ed.apps.launch"):
                        tv.launch(str(params["data"]["appId"]))
                    else:
                        raise ValueError
                except (KeyError, TypeError, ValueError):
                    await ws.send_json({"event": "ms.error", "data": {"message": "unsupported command"}})
                if tv.sleeping:
                    await ws.close()
                    await tv.disconnect()
                    break
        return ws

    app.add_routes([web.get("/api/v2/", info), web.get("/api/v2", info), web.get("/description.xml", device),
                    web.get(SAMSUNG_PATH, remote), web.get("/api/v2/applications/{app_id}", applications),
                    web.post("/api/v2/applications/{app_id}", applications)])


LG_APPS = [{"id": "netflix", "title": "Netflix"}, {"id": "youtube.leanback.v4", "title": "YouTube"}]


def lg_routes(app, tv):
    tickets = set()

    async def device(request):
        return description(tv, "Lab LG webOS", "LG Electronics",
                           "urn:schemas-upnp-org:device:MediaRenderer:1", request)

    async def remote(request):
        async with websocket(request, tv) as ws:
            client_key = None
            ticket = None
            try:
                async for msg in ws:
                    if msg.type != WSMsgType.TEXT:
                        continue
                    if not await tv.delivers():
                        request.transport and request.transport.abort()
                        break
                    ident = None
                    try:
                        message = json.loads(msg.data)
                        ident, kind = message["id"], message["type"]
                        payload = message.get("payload", {})
                        if kind == "hello":
                            response = {"type": "hello", "id": ident, "payload": {"deviceUUID": tv.mac}}
                        elif kind == "register":
                            key = payload.get("client-key")
                            if key is None and tv.approval and payload.get("pairingType") == "PROMPT":
                                await ws.send_json({"type": "response", "id": ident, "payload": {
                                    "returnValue": True, "pairingType": "PROMPT",
                                }})
                                key = secrets.token_hex(16)
                                tv.credentials[key] = True
                            if key is None or key not in tv.credentials:
                                raise ValueError("403 insufficient permissions")
                            client_key = key
                            response = {"type": "registered", "id": ident, "payload": {"client-key": key}}
                        elif kind in ("request", "subscribe") and client_key in tv.credentials:
                            uri = message["uri"]
                            if uri == "ssap://com.webos.service.networkinput/getPointerInputSocket":
                                if ticket:
                                    tickets.discard(ticket)
                                ticket = secrets.token_hex(16)
                                tickets.add(ticket)
                                protocol = "wss" if request.secure else "ws"
                                result = {"socketPath": f"{protocol}://{request.host}/resources/{ticket}.sock"}
                            else:
                                result = lg_request(tv, uri, payload)
                            response = {"type": "response", "id": ident,
                                        "payload": {"returnValue": True, **result}}
                        else:
                            raise ValueError("401 not registered")
                    except (KeyError, TypeError):
                        response = {"type": "error", "id": ident, "error": "400 malformed request"}
                    except ValueError as exc:
                        response = {"type": "error", "id": ident, "error": str(exc)}
                    await ws.send_json(response)
                    if tv.sleeping:
                        await ws.close()
                        await tv.disconnect()
                        break
            finally:
                tickets.discard(ticket)
        return ws

    async def pointer(request):
        if request.match_info["ticket"] not in tickets:
            raise web.HTTPForbidden()
        async with websocket(request, tv) as ws:
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                if not await tv.delivers() or request.match_info["ticket"] not in tickets:
                    request.transport and request.transport.abort()
                    break
                data = dict(line.split(":", 1) for line in msg.data.splitlines() if ":" in line)
                if data.get("type") == "button" and data.get("name") in LG_KEYS:
                    tv.key(data["name"])
                elif data.get("type") in ("click", "move", "scroll"):
                    tv.events.append({"pointer": data})
                if tv.sleeping:
                    await ws.close()
                    await tv.disconnect()
                    break
        return ws

    app.add_routes([web.get("/", remote), web.get("/description.xml", device),
                    web.get("/resources/{ticket}.sock", pointer)])


def lg_request(tv, uri, payload):
    if uri == "ssap://audio/getVolume":
        return {"volume": tv.volume, "muted": tv.muted,
                "volumeStatus": {"volume": tv.volume, "muteStatus": tv.muted}}
    if uri == "ssap://audio/setVolume":
        tv.volume = min(100, max(0, int(payload["volume"])))
    elif uri in ("ssap://audio/volumeUp", "ssap://audio/volumeDown"):
        tv.key("VOLUMEUP" if uri.endswith("Up") else "VOLUMEDOWN")
    elif uri == "ssap://audio/setMute":
        tv.muted = bool(payload["mute"])
    elif uri == "ssap://system.launcher/launch":
        tv.launch(payload["id"])
    elif uri == "ssap://com.webos.applicationManager/getForegroundAppInfo":
        return {"appId": tv.app}
    elif uri in ("ssap://com.webos.applicationManager/listApps", "ssap://com.webos.applicationManager/listLaunchPoints"):
        return {"apps": LG_APPS, "launchPoints": LG_APPS}
    elif uri == "ssap://system/turnOff":
        tv.sleeping = True
    elif uri in ("ssap://system/turnOn", "ssap://system/getSystemInfo", "ssap://system/getPowerState"):
        return {"state": "Active", "modelName": "Lab webOS", "receiverType": "TV"}
    elif uri == "ssap://com.webos.service.ime/insertText":
        tv.search += payload["text"]
    elif uri == "ssap://com.webos.service.ime/deleteCharacters":
        count = int(payload.get("count", 1))
        tv.search = tv.search[:-count] if count > 0 else tv.search
    elif uri in ("ssap://media.controls/play", "ssap://media.controls/pause", "ssap://media.controls/stop"):
        tv.key(uri.rsplit("/", 1)[-1].upper())
    else:
        raise ValueError("404 no such service or method")
    return {}
