import argparse
import asyncio
import json
import logging
import math
from pathlib import Path

from .lab import DEFAULT_PORTS, Lab
from .record import record
from .soak import run


def seconds(value):
    suffix = value[-1:].lower()
    factors = {"s": 1, "m": 60, "h": 3600}
    try:
        result = float(value[:-1] if suffix in factors else value) * factors.get(suffix, 1)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected a duration like 3s, 5m, or 12h") from exc
    if result <= 0 or not math.isfinite(result):
        raise argparse.ArgumentTypeError("duration must be positive and finite")
    return result


async def up(args):
    ports = {name: {scheme: getattr(args, f"{name}_{scheme}_port") for scheme in defaults}
             for name, defaults in DEFAULT_PORTS.items()}
    async with Lab(args.host, args.advertise, ports, args.control_port, args.ssdp_port,
                   args.wol_port, bonjour=not args.no_bonjour) as lab:
        for name, addresses in lab.endpoints.items():
            print(f"{name}: " + ", ".join(f"{scheme}={host}:{port}" for scheme, (host, port) in addresses.items()))
        print(f"Control API: http://{lab.advertise}:{lab.control_port}/tvs")
        print(f"SSDP: UDP {lab.ssdp_port}; Wake-on-LAN: UDP {lab.wol_port}")
        print("Google TV's six-character code prints when pairing begins. Samsung/LG auto-approve by default.",
              flush=True)
        await asyncio.Event().wait()


def main():
    cli = argparse.ArgumentParser(prog="python -m tvlab")
    sub = cli.add_subparsers(dest="command", required=True)
    server = sub.add_parser("up", help="start all four simulators")
    server.add_argument("--host", default="127.0.0.1")
    server.add_argument("--advertise", help="reachable IPv4 address; required for --host 0.0.0.0")
    server.add_argument("--control-port", type=int, default=8090)
    server.add_argument("--ssdp-port", type=int, default=1900)
    server.add_argument("--wol-port", type=int, default=9)
    server.add_argument("--no-bonjour", action="store_true")
    for name, ports in DEFAULT_PORTS.items():
        for scheme, port in ports.items():
            server.add_argument(f"--{name}-{scheme}-port", type=int, default=port)
    soak = sub.add_parser("soak", help="run a soak against private loopback simulators")
    soak.add_argument("--duration", type=seconds, default=12 * 3600)
    soak.add_argument("--interval", type=seconds, default=3)
    soak.add_argument("--output", type=Path, default=Path("soak"), help="report basename")
    soak.add_argument("--chaos-every", type=int, default=5, help="inject chaos every N rounds; 0 disables")
    recorder = sub.add_parser("record", help="regenerate simulator protocol traces")
    recorder.add_argument("--directory", type=Path, default=Path("transcripts"))
    args = cli.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        if args.command == "up":
            asyncio.run(up(args))
        elif args.command == "record":
            asyncio.run(record(args.directory))
        else:
            report = asyncio.run(run(args.duration, args.interval, args.output, args.chaos_every))
            print(json.dumps(report, indent=2))
            if report["summary"]["failures"]:
                raise SystemExit(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
