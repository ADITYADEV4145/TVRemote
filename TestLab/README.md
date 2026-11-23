# Smart TV Remote Test Lab

Four local network simulators for developing and testing the iOS drivers without a TV. **The protocol and soak checks here exercise simulated TVs only. They do not establish real-device compatibility, iOS app performance, or the hardware and TestFlight release gates from the master plan.**

## Start the lab

Requires Python 3.11+ on Linux or macOS. Run these commands from `TestLab/`:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e '.[test]'
python -m tvlab up
```

| TV | Driver endpoint | Discovery | Pairing |
|---|---|---|---|
| Roku | HTTP ECP, 8060 | SSDP `roku:ecp` | None |
| Google TV | TLS Remote v2, 6466; TLS Polo pairing, 6467 | Bonjour `_androidtvremote2._tcp.local.` | Six hex characters logged and exposed by the lab control API when the client reaches PIN entry |
| Samsung | WS 8001 / WSS 8002, `/api/v2/channels/samsung.remote.control` | SSDP | Token from `ms.channel.connect` after simulated approval |
| LG | SSAP WS 3000 / WSS 3001, plus the returned pointer socket | SSDP | Send SSAP `register` with `pairingType: PROMPT`; retain the returned `client-key` |

The default bind is loopback. For a physical iPhone or a Simulator on a different host, run the lab on the same LAN as the client, for example:

```sh
python -m tvlab up --host 0.0.0.0 --advertise 192.168.1.50
```

Allow inbound connections through the host firewall on the protocol ports and UDP 1900 (SSDP), 5353 (Bonjour), and 9 (Wake-on-LAN). If UDP 9 is unavailable, run with `--wol-port 9009` and direct WOL there in a debug client. `python -m tvlab up --help` lists every port override; TCP port `0` selects an ephemeral port, shown in startup output and the control API. The service records still advertise the real selected ports. Multiple simulators share a host/IP but have separate stable device IDs and protocol ports. A run's server certificate is self-signed; use a **test-only** trust override restricted to the simulator (never change production trust/security settings). For iOS local networking, grant Local Network access, declare the Google TV Bonjour type, and use the driver's manual endpoint path if multicast SSDP is unavailable due to entitlement or LAN restrictions. Any HTTP transport exemption should likewise be debug-only. On a Mac running both the lab and the iOS Simulator, try the addresses printed by the lab or the Mac's LAN IP. macOS and iOS integration were not exercised here.

## Control API and driver failure cases

The lab-only HTTP control API is on port 8090 by default. It is intentionally unauthenticated and exposes test PINs and state: use loopback or a trusted isolated test LAN only. Never expose the lab ports to the public internet.

```sh
curl http://127.0.0.1:8090/tvs
curl http://127.0.0.1:8090/tvs/google
curl -s -X POST http://127.0.0.1:8090/tvs/samsung/chaos \
  -H 'Content-Type: application/json' -d '{"action":"drop"}'
```

Send the following payloads to `POST /tvs/{roku|google|samsung|lg}/chaos`:

| Payload | Expected driver behavior |
|---|---|
| `{"action":"drop"}` | Existing *persistent* sessions break; reconnect with the old credential. Roku ECP is stateless. |
| `{"action":"sleep"}`, then `{"action":"wake"}` | Commands fail during simulated standby. On LG/Samsung, instead of the second API call, send a real WoL magic packet to the lab's UDP WoL port using the MAC in state. |
| `{"action":"rebind","host":"127.0.0.2","ports":{"http":0}}` (Linux/Roku example) | Old address stops responding; rediscover the same device identity at the new address. Select an IP already assigned to the host on operating systems such as macOS. `advertise` overrides the published address. Omitted port keys preserve their current ports; for Google use `remote` and `pair`. |
| `{"action":"revoke"}` | Tokens, SSAP keys, or Google client certificate authorization are erased and sessions drop; a cached credential should not work until the driver re-pairs. Roku has no credential. |
| `{"action":"network","latency_ms":150,"packet_loss":0.1}` | Delay/drop command delivery, not individual physical packets. Use a loss of `1` for deterministic failure and restore both values to `0` on recovery. |
| `{"action":"approval","allow":false}` | Reject fresh pairing on Google TV, Samsung, or LG; valid cached credentials remain valid. |
| `{"action":"firmware","token_regression":true}` | Samsung only: disconnect current sessions and reject token reuse while enabled. |

Correlate responses with `GET /tvs/{platform}`: inspect `app`, `volume`, `muted`, `keys`, `key_count`, `search`, and `events`. For reconnect tests, drive discovery and the stale cached address through the real driver; the control API is the test oracle, never a production dependency. Discovery and automatic pairing are separate: an SSDP location or Bonjour record does not authorize commands. Google emits a pairing code only after the requesting TLS client negotiates six-symbol hexadecimal output; query `pairing_code` after starting the pairing session, before submitting it.

## Tests and soak

```sh
python -m pytest -q
python -m tvlab soak --duration 12h --interval 3s
python -m tvlab soak --duration 3m --interval 1s --chaos-every 5 --output soak
python -m tvlab record
```

The tests use actual HTTP, WebSocket, TLS/protobuf, DNS-SD and UDP sockets. The Google TV interoperability test uses the independent `androidtvremote2` client. The lab covers approval denial, bad Polo secrets, unknown/revoked credentials, rebind, drops, sleep/wake, and command effects. It does not ship iOS unit or state-machine tests; the iOS driver package can use the lab for those.

Soak starts its own four loopback TVs (ephemeral ports), performs pairing and probes command delivery against observed state. It cycles drops, rebinds, sleep/wake, credential revocation, and latency. It refreshes endpoints from the control API after rebind rather than timing driver discovery. `--chaos-every 0` runs a baseline. The JSON report has aggregate/per-TV metrics, command failures, injected events and SLO comparisons; CSV has one row per command attempt cycle including elapsed time, latency, injected scenario, recovery, and failure. Latency measures the reference client's send through observed simulator state, including test-oracle polling and reconnect time when applicable. Baseline command percentiles exclude injected samples. The drop rate is estimated from unexpected samples that needed retry, not packet capture or spontaneous disconnect telemetry. The two-hour drop verdict is unset on shorter runs and crash-free iOS sessions are never measured here. The CLI fails if commands do not recover within the retry budget. None of the numbers are field performance.

`transcripts/` contains recorded exchanges from the simulators. Web frames retain parsed JSON, Roku stores HTTP path/status/body, and Google records hex of the length-delimited plaintext protobuf frame so a driver can feed it to its decoder. Dynamic Samsung tokens, LG keys and socket addresses, and Google pairing proof/ACK are redacted; generate valid credentials for live tests rather than replaying fixture tokens. Use `python -m tvlab record` to regenerate.

## Protocol references and simulator limits

- [Roku ECP documentation](https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md): queries, key verbs, app launch, input and SSDP. The simulator includes a small synthetic app catalog and allows legacy search/input calls; actual firmware may restrict those commands or require enabling control by mobile apps.
- [Android TV Remote v2 protocol notes](https://github.com/Aymkdn/assistant-freebox-cloud/wiki/Google-TV-(aka-Android-TV)-Remote-Control-(v2)), [Polo pairing](https://android.googlesource.com/platform/external/google-tv-pairing-protocol/), and [androidtvremote2 schemas/client](https://github.com/tronikos/androidtvremote2): TLS, certificate-bound Polo proof, protobuf framing, negotiation, keepalive, keys, IME text and app links. No voice/audio protocol, Android package resolution, hardware standby or OEM-specific quirks are modeled.
- [samsung-tv-ws-api](https://github.com/xchwarze/samsung-tv-ws-api): v2 WS/REST shapes and key names. Firmware approval UI, token policies, app ID catalogs and WSS behavior vary across devices. The lab has a toggle for one token reuse failure mode, not a firmware emulator.
- [aiowebostv](https://github.com/home-assistant-libs/aiowebostv) and [lgtv2](https://github.com/hobbyquaker/lgtv2): registration, SSAP, pointer input. The lab does not verify LG permission manifests or emit real TV subscription streams. Its mac/path semantics and supported commands are deliberately small.
- [UPnP Device Architecture / SSDP](https://openconnectivity.org/developer/specifications/upnp-resources/upnp/): the lab answers M-SEARCH for common advertised targets and serves description XML. It does not emulate all vendor discovery hints, unsolicited NOTIFY traffic, or DIAL services. WoL simulates the packet/identity match, not hardware network-standby quirks.
