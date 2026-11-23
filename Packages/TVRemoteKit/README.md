# TVRemoteKit

Swift package for local-network TV control (iOS 17+, macOS 14+). This release contains the connection layer and Roku ECP driver. Google TV, Samsung and LG are platform identifiers, not available drivers yet.

## App and voice integration

Add the local package at `Packages/TVRemoteKit`, link its `TVRemoteKit` product, and `import TVRemoteKit`. Hold one `ConnectionManager` actor for the active remote; do not instantiate drivers in app or voice code.

```swift
import TVRemoteKit

let remote = TVRemoteKit.makeRokuManager(
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

- **Setup and pairing:** `discover()` is a cancellable, finite `AsyncStream<TVDevice>`; cancellation stops the browse. `probe(_:platform:)` checks a manually entered endpoint and obtains its stable identity; an open port alone is not a TV. `pair(_:prompt:)` emits `.enterCode(length:)` or `.approveOnTV` via the async handler when required; return `.code(String)` or `.acknowledged` respectively. The on-TV approval response acknowledges the prompt, not successful pairing; the driver waits for the device's reply. Propagate cancellation from the handler when the user backs out.
- **Device and capabilities:** `TVDevice.id` combines platform and stable identifier, not IP. `endpoint` is the last known host and port, and `capabilities` advertises remote keys, app launch, search, keyboard, network wake and pointer support as appropriate. A capability flag is not a guarantee on every firmware or TV setting. `currentDevice` gives the selected device, including a rediscovered endpoint; persist this metadata in the app, never an authentication secret. Credentials for paired platforms live in Keychain on Apple systems; the default on Linux is an in-memory store.
- **Commands:** `send(_:) ` takes a `RemoteKey` for navigation, volume, channels, power, playback, digits and keyboard input (`.text(String)`, `.delete`). Call `launch(_:) ` with the platform-native app ID and `search(_:) ` with a query. Unsupported commands throw `TVError.notSupported`; do not present that as a connection error. Roku exposes a playback toggle, not discrete play/pause/stop through ECP. On a recoverable command failure, the manager retries once with a fresh session and then recovers without another command replay. An ambiguous transport failure can mean the TV already acted; do not add another retry in the app. Route press bursts through a serialized command queue; overlapping calls may throw `.busy`.
- **Connection:** Observe `state` in a task; each subscription receives the current state and later transitions. States are `.idle`, `.discovering`, `.connecting`, `.ready`, `.degraded`, `.asleep`, `.recovering`, and `.needsRepair`. Use `connect(_:) ` with restored metadata on cold launch; the saved endpoint races quiet discovery by identity. Call `reconnect()` on foreground/network changes with an active selection, and schedule `checkConnection()` while foregrounded if keepalives are needed. The manager does not keep a timer alive in the background. `wake()` explicitly requests network power on where supported; `disconnect()` clears the active selection, not pairing credentials. On `.needsRepair`, present the pairing prompt again. Cancellation and superseded connections cannot replace a newer active session.
- **Permission and discovery:** The host app owns `NSLocalNetworkUsageDescription`, `NSBonjourServices` (declare the services you browse; see `LocalDiscoverySource.bonjourServiceTypes`), and the Apple multicast entitlement. Pass `enableSSDP: true` only when multicast is authorized. If Bonjour/SSDP do not find Roku, enable the bounded IPv4 unicast probe or offer manual IP. The probe checks only port 8060 on up to one /24 of the local active Ethernet/Wi-Fi interface, then verifies a Roku device response. Host app ATS policy must allow Roku's local HTTP where necessary. Roku may require **Control by mobile apps / Network access** to be enabled; network wake is only available where the TV remains reachable in standby.

## Driver and test seams

`TVDriver` defines driver-level discovery, endpoint probing, pairing, connection, remote key, launch, search, wake, keepalive and state. A `TVDriverFactory` must vend a fresh session on each call. Drivers must verify device identity when opening an endpoint and cooperate with task cancellation. `TVRemoteCore` contains the portable protocol, types, manager and transport interfaces; `RokuDriver` translates remote commands into ECP with an injected `HTTPTransport`; `TVRemoteKit` assembles the product with Apple Bonjour/SSDP and Keychain adapters. Fakes can supply transport, discovery, credential store and clock implementations.

```sh
cd Packages/TVRemoteKit
swift build
swift test
xcodebuild build -scheme TVRemoteKit -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/TVRemoteKitDerivedData
```

Tests use fake transports, protocol transcripts and a fake clock; this does not establish real-hardware interoperability, firmware coverage, hardware-soak reliability or beta SLOs.
