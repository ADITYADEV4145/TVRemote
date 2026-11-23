import asyncio
import hashlib
import hmac
import logging
import secrets

from OpenSSL import SSL
from cryptography.hazmat.primitives import hashes

LOGGER = logging.getLogger(__name__)
MAX_FRAME = 64 * 1024
FEATURES = 1 | 2 | 4 | 32 | 64 | 512
KEYS = set(range(1, 305))
DIRECTIONS = {1: "down", 2: "up", 3: "press"}


def varint(value):
    result = bytearray()
    while value > 127:
        result.append(128 | (value & 127))
        value >>= 7
    result.append(value)
    return bytes(result)


def read_varint(data, offset):
    value = 0
    for shift in range(0, 64, 7):
        if offset == len(data):
            raise EOFError
        byte = data[offset]
        value |= (byte & 127) << shift
        offset += 1
        if byte < 128:
            return value, offset
    raise ValueError("oversized protobuf varint")


def wire(*fields):
    output = bytearray()
    for number, value in fields:
        if isinstance(value, int):
            output.extend(varint(number << 3) + varint(value))
        else:
            raw = value.encode() if isinstance(value, str) else value
            output.extend(varint((number << 3) | 2) + varint(len(raw)) + raw)
    return bytes(output)


def fields(data):
    result = {}
    offset = 0
    while offset < len(data):
        tag, offset = read_varint(data, offset)
        number, kind = divmod(tag, 8)
        if not number:
            raise ValueError("invalid protobuf field")
        if kind == 0:
            value, offset = read_varint(data, offset)
        elif kind in (1, 2, 5):
            if kind == 2:
                length, offset = read_varint(data, offset)
            else:
                length = 8 if kind == 1 else 4
            end = offset + length
            if end > len(data):
                raise EOFError
            value = bytes(data[offset:end])
            offset = end
        else:
            raise ValueError("unsupported protobuf wire type")
        result.setdefault(number, []).append(value)
    return result


def get(message, number, default=None):
    return message.get(number, [default])[-1]


class TLSStream:
    def __init__(self, context, reader, writer, scheme, trace):
        self.conn = SSL.Connection(context)
        self.conn.set_accept_state()
        self.reader, self.writer = reader, writer
        self.buffer = bytearray()
        self.scheme, self.trace = scheme, trace

    def capture(self, direction, packet, decoded):
        if self.trace is not None:
            frame = {"channel": self.scheme, "direction": direction}
            if self.scheme == "pair" and (40 in decoded or 41 in decoded):
                frame["redacted_field"] = "secret" if 40 in decoded else "secret_ack"
            else:
                frame["delimited_hex"] = (varint(len(packet)) + packet).hex()
            self.trace.append(frame)

    async def flush(self):
        while True:
            try:
                self.writer.write(self.conn.bio_read(16 * 1024))
            except SSL.WantReadError:
                break
        await self.writer.drain()

    async def operation(self, op, *args):
        while True:
            try:
                result = op(*args)
            except SSL.WantReadError:
                await self.flush()
                incoming = await self.reader.read(16 * 1024)
                if not incoming:
                    raise EOFError
                self.conn.bio_write(incoming)
            except SSL.WantWriteError:
                await self.flush()
            else:
                await self.flush()
                return result

    async def receive(self):
        while True:
            try:
                size, offset = read_varint(self.buffer, 0)
            except EOFError:
                pass
            else:
                if size > MAX_FRAME:
                    raise ValueError("oversized frame")
                if len(self.buffer) >= offset + size:
                    frame = bytes(self.buffer[offset:offset + size])
                    del self.buffer[:offset + size]
                    message = fields(frame)
                    self.capture("client_to_tv", frame, message)
                    return message
            self.buffer.extend(await self.operation(self.conn.recv, 16 * 1024))

    async def send(self, packet):
        if self.trace is not None:
            self.capture("tv_to_client", packet, fields(packet))
        data = varint(len(packet)) + packet
        while data:
            size = await self.operation(self.conn.send, data)
            data = data[size:]


def pairing_secret(client, server, nonce):
    h = hashlib.sha256()
    for cert in (client, server):
        nums = cert.public_key().public_numbers()
        for value in (nums.n, nums.e):
            h.update(value.to_bytes((value.bit_length() + 7) // 8, "big"))
    h.update(nonce)
    return h.digest()


async def pair(tv, link, client, server):
    encoding = wire((1, 3), (2, 6))

    async def reply(tag=None, payload=b"", status=200):
        header = wire((1, 2), (2, status))
        await link.send(header + (wire((tag, payload)) if tag else b""))

    async def expect(tag):
        message = await link.receive()
        if not await tv.delivers():
            raise EOFError
        if get(message, 1) != 2 or get(message, 2) != 200 or tag not in message:
            raise ValueError("unexpected pairing message")
        return fields(get(message, tag))

    fingerprint = client.fingerprint(hashes.SHA256())
    pending = object()
    try:
        await expect(10)
        if not tv.approval:
            await reply(status=400)
            return
        await reply(11, wire((1, "Lab Google TV")))
        options = await expect(20)
        if not any(get(enc, 1) == 3 and get(enc, 2) == 6
                   for value in options.get(1, ()) for enc in [fields(value)]):
            await reply(status=401)
            return
        await reply(20, wire((2, encoding), (3, 2)))
        configuration = await expect(30)
        chosen = fields(get(configuration, 1, b""))
        if get(configuration, 2) != 1 or get(chosen, 1) != 3 or get(chosen, 2) != 6:
            await reply(status=401)
            return
        try:
            nonce = secrets.token_bytes(2)
            expected = pairing_secret(client, server, nonce)
        except AttributeError:
            await reply(status=401)
            return
        tv.code = (expected[:1] + nonce).hex().upper()
        tv.pending_codes[pending] = tv.code
        LOGGER.info("Google TV pairing code: %s", tv.code)
        await reply(31)
        offered = get(await expect(40), 1, b"")
        if not isinstance(offered, bytes) or not hmac.compare_digest(offered, expected):
            tv.events.append({"pair": "bad_secret"})
            await reply(status=402)
            return
        tv.credentials[fingerprint] = True
        tv.events.append({"pair": "accepted"})
        await reply(41, wire((1, expected)))
    finally:
        tv.pending_codes.pop(pending, None)
        tv.code = next(reversed(tv.pending_codes.values()), None)


async def control(tv, link):
    async def send(tag, *values):
        await link.send(wire((tag, wire(*values))))

    async def volume():
        await send(50, (3, "Lab Google TV"), (6, 100), (7, tv.volume), (8, int(tv.muted)))

    async def foreground():
        await send(20, (1, wire((1, 1), (12, tv.app))), (2, wire((1, 1))))

    async def expect(tag):
        config = await asyncio.wait_for(link.receive(), 10)
        if tag not in config or not await tv.delivers():
            raise EOFError
        return fields(get(config, tag))

    await send(1, (1, FEATURES), (2, wire(
        (1, "Lab Google TV"), (2, "TestLab"), (3, 1), (4, "1"),
        (5, "com.google.android.tv.remote.service"), (6, "1.0"),
    )))
    configured = get(await expect(1), 1, 0) & FEATURES
    await send(2, (1, configured))
    active = get(await expect(2), 1, 0) & configured
    await foreground()
    await volume()
    await send(40, (1, 1))
    loop = asyncio.get_running_loop()
    next_ping = loop.time() + 5
    ping = 0
    pending = None
    while True:
        try:
            message = await asyncio.wait_for(link.receive(), max(0, next_ping - loop.time()))
        except TimeoutError:
            if pending is not None:
                return
            ping += 1
            pending = ping
            await send(8, (1, ping), (2, 0))
            next_ping = loop.time() + 5
            continue
        if not await tv.delivers():
            return
        if 9 in message and pending is not None and get(fields(get(message, 9)), 1) == pending:
            tv.events.append({"keepalive": pending})
            pending = None
        elif 8 in message:
            await send(9, (1, get(fields(get(message, 8)), 1, 0)))
        elif 10 in message and active & 2:
            key = fields(get(message, 10))
            code, direction = get(key, 1, 0), get(key, 2, 0)
            if code in KEYS and direction in DIRECTIONS:
                tv.key(str(code), DIRECTIONS[direction])
                if code in (24, 25, 164):
                    await volume()
                if code == 3:
                    await foreground()
                if tv.sleeping:
                    await send(40, (1, 0))
                    return
            else:
                await send(3, (1, 1))
        elif 21 in message and active & 4:
            for encoded in fields(get(message, 21)).get(3, []):
                edit = fields(encoded)
                if get(edit, 1) == 1:
                    tv.search += get(fields(get(edit, 2, b"")), 3, b"").decode()
        elif 90 in message and active & 512:
            url = get(fields(get(message, 90)), 1, b"").decode()
            if url:
                tv.launch(url)
                await foreground()


async def serve(tv, host, port, scheme, cert, key):
    context = SSL.Context(SSL.TLS_SERVER_METHOD)
    context.set_min_proto_version(SSL.TLS1_2_VERSION)
    context.use_certificate(cert)
    context.use_privatekey(key)
    # The peer proves possession in TLS; trust is established by the Polo code.
    context.set_verify(SSL.VERIFY_PEER | SSL.VERIFY_FAIL_IF_NO_PEER_CERT, lambda *_: True)

    async def connect(reader, writer):
        async def close():
            writer.transport.abort()

        tv.connections.add(close)
        try:
            if not await tv.delivers():
                return
            link = TLSStream(context, reader, writer, scheme, tv.trace)
            await asyncio.wait_for(link.operation(link.conn.do_handshake), 10)
            client = link.conn.get_peer_certificate(as_cryptography=True)
            if scheme == "pair":
                await asyncio.wait_for(pair(tv, link, client, cert), 120)
            elif client.fingerprint(hashes.SHA256()) in tv.credentials:
                await control(tv, link)
            else:
                tv.events.append({"control": "unpaired_certificate"})
        except (SSL.Error, EOFError, OSError, TimeoutError, KeyError, TypeError, ValueError) as exc:
            LOGGER.debug("Google TV %s connection closed: %s", scheme, exc)
        finally:
            tv.connections.discard(close)
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass

    return await asyncio.start_server(connect, host, port, reuse_address=True)
