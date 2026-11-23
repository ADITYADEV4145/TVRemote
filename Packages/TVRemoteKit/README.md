# TVRemoteKit

Swift package for local-network TV control (iOS 17+, macOS 14+). Includes Roku ECP, Google TV Remote v2, Samsung Tizen, and LG webOS drivers.

## App and voice integration

Add the local package at `Packages/TVRemoteKit`, link its `TVRemoteKit` product, and `import TVRemoteKit`. Hold one `ConnectionManager` actor for the active remote; do not instantiate drivers in app or voice code.

```swift
import TVRemoteKit

let remote = TVRemoteKit.makeManager(
    discovery: LocalDiscoverySource(enableSubnetProbe: true)
)

// Setup: stream results; let the user select one.
for await device in remote.discover() {
    // Deduplicate by device.id; an updated endpoint replaces the old row.
}

// Manual IP: use the chosen platform's ECP port for Roku.
let roku = try await remote.probe(TVEndpoint(host: "192.168.1.42", port: 8060), platform: .roku)
try await remote.pair(roku) // No prompt or credential for Roku.
try await remote.send(.volumeUp)
try await remote.launch(AppID(rawValue: "12"))
try await remote.search("Severance")
```

For Google TV, declare `_androidtvremote2._tcp` in `NSBonjourServices` and use the discovered device. With manual IP, call `probe(TVEndpoint(host: address, port: 6466), platform: .googleTV)`. Probing and on-TV pairing use TLS port 6467; commands and server-driven keepalives use Remote v2 over TLS on port 6466.

`pair(_:prompt:)` requests a six-character **hexadecimal** code. The app should accept 0–9 and A–F (case insensitive) and pass the typed code back unchanged. The package validates the TV's challenge, stores the generated client RSA identity and the TV's pinned public key in the configured credential store, and reconnects with the stored identity. App code must not read or log the credential.

Google TV supports navigation, volume, playback, and power key commands. For `launch(_:)`, pass a TV-supported app-link URI such as an HTTPS deep link; a bare Android package name is not a link. The driver negotiates key and app-link support with the TV. Free-form text, search, and waking an unreachable device are not supported.

**Samsung Tizen:** Browse `_samsungmsf._tcp`, use SSDP if enabled, or manually probe port 8002 (secure) or 8001 (plain). The driver probes device information, requests `.approveOnTV`, and stores the TV-issued token when available. It supports remote keys; app launch, search and keyboard input are not supported.

**LG webOS:** Use SSDP or manually probe port 3001 (secure) or 3000 (plain). Approve the SSAP registration on the TV; the package stores the returned client key. LG supports remote keys, native app IDs for launch and keyboard commands where the TV allows them. Before registration the driver identifies an LG endpoint by host; if its address changes, discover or enter the new address and pair again. An LG probe checks for a WebSocket upgrade; successful SSAP registration confirms protocol support.

**Samsung and LG security and wake:** When pairing over TLS, the driver learns the TV's self-signed certificate and pins it for later authenticated connections. Confirm the approval prompt on the intended TV. Legacy plain connections are unencrypted and should only be used on a trusted LAN; existing secure credentials are not sent over plain sockets. Wake-on-LAN requires an available unicast MAC address (`TVDevice.wakeAddress`), TV firmware/settings that keep the network adapter awake, and broadcast access on the same LAN. Samsung reads the address from device info; LG attempts to read it after SSAP registration. A host with the address can also include it when restoring the device. Apple broadcast access may require the multicast entitlement on iOS. Call `remote.wake()` explicitly for a sleeping network-wake-capable TV.

- **Setup and pairing:** `discover()` is a cancellable, finite `AsyncStream<TVDevice>`; cancellation stops the browse. `probe(_:platform:)` checks a manually entered endpoint and obtains its stable identity; an open port alone is not a TV. `pair(_:prompt:)` emits `.enterCode(length:)` or `.approveOnTV` via the async handler when required; return `.code(String)` or `.acknowledged` respectively. The on-TV approval response acknowledges the prompt, not successful pairing; the driver waits for the device's reply. Propagate cancellation from the handler when the user backs out.
- **Device and capabilities:** `TVDevice.id` combines platform and device identity (see the LG host-identity limitation above). `endpoint` is the last known host and port, and `capabilities` advertises remote keys, app launch, search, keyboard, network wake and pointer support as appropriate. A capability flag is not a guarantee on every firmware or TV setting. `currentDevice` gives the selected device, including a rediscovered endpoint; persist this metadata in the app, never an authentication secret. Credentials for paired platforms live in Keychain on Apple systems; the default on Linux is an in-memory store.
- **Commands:** `send(_:)` takes a `RemoteKey` for navigation, volume, channels, power, playback, digits and keyboard input (`.text(String)`, `.delete`). Call `launch(_:)` with the platform-native app ID and `search(_:)` with a query. Unsupported commands throw `TVError.notSupported`; do not present that as a connection error. Roku exposes a playback toggle, not discrete play/pause/stop through ECP. On a recoverable command failure, the manager retries once with a fresh session and then recovers without another command replay. Text is never replayed automatically: Roku sends individual characters and the TV may have accepted part of the text. After an ambiguous failure, check the TV before resending. Route press bursts through a serialized command queue; overlapping calls may throw `.busy`.
- **Connection:** Observe `state` in a task; each subscription receives the current state and later transitions. States are `.idle`, `.discovering`, `.connecting`, `.ready`, `.degraded`, `.asleep`, `.recovering`, and `.needsRepair`. Use `connect(_:) ` with restored metadata on cold launch; the saved endpoint races quiet discovery by identity. Call `reconnect()` on foreground/network changes with an active selection, and schedule `checkConnection()` while foregrounded if keepalives are needed. The manager does not keep a timer alive in the background. `wake()` explicitly requests network power on where supported; `disconnect()` clears the active selection, not pairing credentials. On `.needsRepair`, present the pairing prompt again. Cancellation and superseded connections cannot replace a newer active session.
- **Permission and discovery:** The host app owns `NSLocalNetworkUsageDescription`, `NSBonjourServices` (declare the services you browse; see `LocalDiscoverySource.bonjourServiceTypes`), and the Apple multicast entitlement. Pass `enableSSDP: true` only when multicast is authorized. If Bonjour/SSDP do not find Roku, enable the bounded IPv4 unicast probe or offer manual IP. The probe checks only port 8060 on up to one /24 of the local active Ethernet/Wi-Fi interface, then verifies a Roku device response. Host app ATS policy must allow Roku's local HTTP where necessary. Roku may require **Control by mobile apps / Network access** to be enabled; network wake is only available where the TV remains reachable in standby.

## Driver and test seams

`TVDriver` defines driver-level discovery, endpoint probing, pairing, connection, remote key, launch, search, wake, keepalive and state. A `TVDriverFactory` must vend a fresh session on each call. Drivers must verify device identity when opening an endpoint and cooperate with task cancellation. `TVRemoteCore` contains the portable protocol, types, manager and transport interfaces; `RokuDriver` translates remote commands into ECP with an injected `HTTPTransport`. `GoogleTVDriver` uses an injected `GoogleTVTLSTransport` with cancellable `TLSByteStream` reads and writes and a SHA-256 provider. `SamsungTizenDriver` and `LGWebOSDriver` use an injected `WebSocketTransport`; `WakeOnLAN` accepts a `UDPDatagramTransport`. On Apple systems, `TVRemoteKit.makeManager` wires all four drivers, Apple Bonjour/SSDP, Keychain, Network TLS, CryptoKit, URLSession and UDP broadcast. `makeRokuManager` remains available for Roku-only use. Portable tests can provide their own transport, discovery, credential store, digest and clock implementations.

Protocol references: [AOSP Polo pairing](https://android.googlesource.com/platform/external/google-tv-pairing-protocol/) and [Android TV Remote v2 message schemas](https://github.com/tronikos/androidtvremote2/tree/main/src/androidtvremote2).

```sh
cd Packages/TVRemoteKit
swift build
swift test
xcodebuild build -scheme TVRemoteKit -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/TVRemoteKitDerivedData
```

Tests use fake transports, protocol transcripts and a fake clock; this does not establish real-hardware interoperability, firmware coverage, hardware-soak reliability or beta SLOs.
