from xml.etree.ElementTree import Element, SubElement, tostring

from aiohttp import web

KEYS = set("""Home Rev Fwd Play Select Left Right Down Up Back InstantReplay Info Backspace
Search Enter FindRemote ChannelUp ChannelDown VolumeDown VolumeMute VolumeUp PowerOff
PowerOn Power InputTuner InputHDMI1 InputHDMI2 InputHDMI3 InputHDMI4 InputAV1""".split())
APPS = {"12": "Netflix", "837": "YouTube"}
DEVICE_TYPE = "urn:roku-com:device:player:1-0"
SERVICE_TYPE = "urn:roku-com:service:ecp:1"


def udn(tv):
    return f"uuid:roku:ecp:{tv.mac.replace(':', '')}"


def xml(root):
    return web.Response(body=tostring(root, encoding="utf-8", xml_declaration=True),
                        content_type="text/xml")


def fields(root, values):
    for key, value in values.items():
        SubElement(root, key).text = value
    return root


def routes(app, tv):
    async def description(request):
        root = Element("root", xmlns="urn:schemas-upnp-org:device-1-0")
        fields(SubElement(root, "specVersion"), {"major": "1", "minor": "0"})
        SubElement(root, "URLBase").text = f"{request.scheme}://{request.host}/"
        device = fields(SubElement(root, "device"), {
            "deviceType": DEVICE_TYPE, "friendlyName": "Lab Roku", "manufacturer": "Roku",
            "modelName": "Roku TV", "modelNumber": "SIM", "serialNumber": "SIMROKU001",
            "UDN": udn(tv),
        })
        services = SubElement(device, "serviceList")
        fields(SubElement(services, "service"), {
            "serviceType": SERVICE_TYPE, "serviceId": "urn:roku-com:serviceId:ecp1",
            "controlURL": "/", "eventSubURL": "/", "SCPDURL": "/ecp_SCPD.xml",
        })
        return xml(root)

    async def service_description(_):
        root = Element("scpd", xmlns="urn:schemas-upnp-org:service-1-0")
        fields(SubElement(root, "specVersion"), {"major": "1", "minor": "0"})
        SubElement(root, "actionList")
        SubElement(root, "serviceStateTable")
        return xml(root)

    async def device(_):
        return xml(fields(Element("device-info"), {
            "udn": udn(tv), "serial-number": "SIMROKU001",
            "device-id": "SIMROKU001", "model-name": "Roku TV", "model-number": "SIM",
            "friendly-device-name": "Lab Roku", "user-device-name": "Lab Roku",
            "is-tv": "true", "power-mode": "PowerOn", "supports-find-remote": "true",
            "wifi-mac": tv.mac, "software-version": "14.0.0",
        }))

    async def apps(_):
        root = Element("apps")
        for app_id, name in APPS.items():
            SubElement(root, "app", id=app_id, type="appl", version="1.0").text = name
        return xml(root)

    async def active(_):
        root = Element("active-app")
        SubElement(root, "app", id=tv.app if tv.app in APPS else "").text = APPS.get(tv.app, "Roku")
        return xml(root)

    async def player(_):
        return xml(Element("player", state=tv.media, error="false"))

    async def send(request):
        key = request.match_info["key"]
        if key not in KEYS and not (key.startswith("Lit_") and len(key[4:]) == 1):
            raise web.HTTPBadRequest(text="Unknown ECP key")
        tv.key(key, {"keypress": "press", "keydown": "down", "keyup": "up"}[request.match_info["op"]])
        if key.startswith("Lit_") and request.match_info["op"] != "keyup":
            tv.search += key[4:]
        return web.Response()

    async def launch(request):
        app_id = request.match_info["app_id"]
        if app_id not in APPS:
            raise web.HTTPNotFound(text="Unknown app")
        tv.launch(app_id)
        if request.query:
            tv.events.append({"launch_parameters": dict(request.query)})
        return web.Response()

    async def search(request):
        tv.search = request.query.get("keyword", "")
        tv.events.append({"search": tv.search})
        return web.Response()

    async def input_event(request):
        tv.events.append({"input": dict(request.query)})
        return web.Response()

    app.add_routes([
        web.get("/", description), web.get("/ecp_SCPD.xml", service_description),
        web.get("/query/device-info", device), web.get("/query/apps", apps),
        web.get("/query/active-app", active), web.get("/query/media-player", player),
        web.post("/{op:keypress|keydown|keyup}/{key}", send), web.post("/launch/{app_id}", launch),
        web.post("/search/browse", search), web.post("/input", input_event),
    ])
