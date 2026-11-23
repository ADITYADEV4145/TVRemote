# TV Remote

A native iPhone remote for Wi-Fi-enabled TVs.

## Run the iPhone foundation

Open `TVRemote.xcodeproj`, select the **TVRemote** scheme and an iPhone simulator, then run. The minimum deployment target is iOS 17. The project builds with Xcode 26.6 using the Swift 5 language mode. To regenerate the project after adding files, run `xcodegen generate`.

On first run, choose **Find my TV → Find TVs**, then allow Local Network access. Select a discovered TV, or use **Enter IP address** with an optional control port. Roku connects without a code; Google TV shows a code to enter; Samsung and LG require approval on the TV. Successful setup opens a confirmation, then the Remote. Credentials are stored in Keychain; return to **My TVs** to reconnect to a previously paired TV.

To use the isolated in-app demo instead, add the `-demo` launch argument in a Debug build. Living Room connects without a code; Bedroom accepts `123456` and supports the touchpad. Demo devices never access the network.

```sh
xcodebuild -scheme TVRemote -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme TVRemote -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- [`Packages/TVRemoteKit/`](Packages/TVRemoteKit/) owns the driver contract, discovery, pairing and reconnect logic.
- `TVRemote/State/` bridges the package connection manager to SwiftUI and contains the opt-in demo. The app composition root is `TVRemoteApp.swift`.
- `TVRemote/Design/` and `TVRemote/Screens/` contain the adaptive palette, shared SwiftUI components and iPhone screens. The remote uses a fixed d-pad layout, haptics and a separate keyboard entrance, informed by the [official Roku remote](https://support.roku.com/article/roku-remote-on-your-phone); system typography, visible status labels and large controls follow [Apple’s accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility) and the [SwiftUI Pro accessibility checklist](https://github.com/twostraws/swiftui-agent-skill/blob/main/swiftui-pro/references/accessibility.md).
- `TVRemoteTests/` exercises discovery, pairing, switching, command gating, sleep and wake with the demo driver.

## Try the simulated-TV lab

Check out [the lab](https://github.com/ADITYADEV4145/TVRemote/pull/2) separately. From its `TestLab/` directory:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e .
.venv/bin/python -m tvlab up --ssdp-port 1900 --wol-port 9009
```

In an iPhone Simulator on the same Mac, use **Enter IP address**:

| TV | Address | Pairing |
| --- | --- | --- |
| Roku | `127.0.0.1:8060` | No approval needed |
| Google TV | `127.0.0.1:6466` | Enter the six-character code printed by the lab after the app opens the code screen |
| Samsung | `127.0.0.1:8002` (or `8001`) | The lab approves automatically |
| LG | `127.0.0.1:3001` (or `3000`) | The lab approves automatically |

The opt-in UI tests verify command delivery and recovery against the isolated loopback lab. They use temporary app credentials, revoke existing **lab** credentials, and restart its TV listeners, so use a dedicated test instance:

```sh
TEST_RUNNER_TVREMOTE_RUN_LAB=1 xcodebuild -scheme TVRemote \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' -parallel-testing-enabled NO \
  -only-testing:TVRemoteUITests/SimulatedTVTests test
```

## Figma iPhone implementation

The [authoritative design handoff](https://www.figma.com/design/Ld7lB1XacMlPrOIrq5YBCx?node-id=12-381) is implemented with `RemoteTheme` semantic light/dark colors, native SF Symbols, a 252-point direction disc with 56-point arrow targets and an 84-point OK landmark, 24-point content gutters, native four-tab navigation (Remote / Apps / My TVs / Settings), and scrollable Dynamic Type layouts. Native safe areas and keyboards replace the schematic Figma device chrome. No downloaded mockup artwork or third-party UI dependencies are needed.

Setup, discovery, code pairing, retry feedback, free remote, sleep/wake, keyboard **search**, simulated app launching, favorites pinning/reordering, forgetting, settings and redacted support sharing are wired to the foundation or local state. Inputs and numeric entry explain missing driver capabilities. Voice recognition, system permissions, StoreKit, secure persistent pairing, scene execution and system surfaces are deliberately not faked. Scene creation only saves a local draft. Commerce prices are explicitly illustrative; no purchase is offered.

In a Debug build, **Settings → Design states** exposes all 55 iPhone screen/state presentations from the handoff. Every fixture is visibly marked **DESIGN PREVIEW**; transient voice, permission, purchase, recovery and scene results are view contracts, not actual service events. The catalog and its launch arguments are excluded from Release builds. Watch/widgets/Live Activity/Control Center were later-surface concepts, not iPhone screens or implemented extensions.

An opt-in visual inventory scheme captures each state in Light and Dark as XCTest attachments:

```sh
xcodebuild -scheme TVRemoteDesignReview -destination 'platform=iOS Simulator,id=EDD9B083-63F1-44E6-9A7B-0A6964CC2561' -resultBundlePath DesignReview.xcresult test
xcrun xcresulttool export attachments --path DesignReview.xcresult --output-path DesignReviewShots
```

Use an available iOS simulator ID from `xcrun simctl list devices`; the example ID is not portable. The normal `TVRemote` scheme keeps the functional unit/UI regressions separate from the longer visual inventory.

Next, exercise system permissions, secure pairing, reconnects and standby on supported hardware. Integrate on-device voice and Apple system surfaces, then ship StoreKit, the privacy policy, TestFlight and store assets after the physical-TV release gates pass. The plans screen does not accept purchases.

After the launch roadmap, validate a one-handed accessibility mode against task-completion and mis-tap rates; then measure whether opt-in, redacted self-diagnostics improve recovery before adding more recovery automation. Use those results and real model compatibility to prioritize future platforms.
