import asyncio
import random
from collections import deque
from dataclasses import dataclass, field


@dataclass
class TV:
    platform: str
    mac: str
    sleeping: bool = False
    app: str = "home"
    input: str | None = None
    channel: str | None = None
    volume: int = 25
    muted: bool = False
    search: str = ""
    text: str = ""
    text_entry_active: bool = False
    approval: bool = True
    token_regression: bool = False
    latency_ms: float = 0
    packet_loss: float = 0
    drops: int = 0
    key_count: int = 0
    code: str | None = None
    pending_codes: dict = field(default_factory=dict)
    credentials: dict = field(default_factory=dict)
    credential_epoch: int = 0
    keys: deque = field(default_factory=lambda: deque(maxlen=64))
    events: deque = field(default_factory=lambda: deque(maxlen=256))
    connections: set = field(default_factory=set)
    held: set = field(default_factory=set)
    media: str = "stop"
    trace: list | None = None

    def snapshot(self):
        return {
            "platform": self.platform, "mac": self.mac, "sleeping": self.sleeping,
            "app": self.app, "input": self.input, "channel": self.channel,
            "volume": self.volume, "muted": self.muted,
            "text": self.text, "text_entry_active": self.text_entry_active,
            "search": self.search, "approval": self.approval, "drops": self.drops,
            "pairing_code": self.code, "pairing_codes": list(self.pending_codes.values()),
            "keys": list(self.keys), "key_count": self.key_count, "held": sorted(self.held), "media": self.media,
            "events": list(self.events),
        }

    async def delivers(self):
        if self.latency_ms:
            await asyncio.sleep(self.latency_ms / 1000)
        return not self.sleeping and random.random() >= self.packet_loss

    async def disconnect(self):
        self.drops += 1
        await asyncio.gather(*(close() for close in tuple(self.connections)), return_exceptions=True)

    def key(self, name, action="press"):
        self.key_count += 1
        self.keys.append({"name": name, "action": action})
        self.events.append({"key": name, "action": action})
        if action == "down":
            self.held.add(name)
        if action == "up":
            self.held.discard(name)
            return
        if name in {"VolumeUp", "KEY_VOLUP", "VOLUMEUP", "24"}:
            self.volume = min(100, self.volume + 1)
        elif name in {"VolumeDown", "KEY_VOLDOWN", "VOLUMEDOWN", "25"}:
            self.volume = max(0, self.volume - 1)
        elif name in {"VolumeMute", "KEY_MUTE", "MUTE", "164"}:
            self.muted = not self.muted
        elif name in {"Home", "KEY_HOME", "HOME", "3"}:
            self.app = "home"
        elif name in {"Power", "PowerOff", "KEY_POWER", "POWER"}:
            self.sleeping = True
        elif name in {"Play", "KEY_PLAY", "PLAY", "126"}:
            self.media = "play"
        elif name in {"Pause", "KEY_PAUSE", "PAUSE", "127"}:
            self.media = "pause"
        elif name in {"KEY_STOP", "STOP", "86"}:
            self.media = "stop"

    def launch(self, app):
        self.app = app
        self.events.append({"launch": app})

    def select_input(self, input_id, app_id):
        self.input = input_id
        self.app = app_id
        self.events.append({"select_input": input_id})
