# TV Remote

A native iPhone remote for Wi-Fi-enabled TVs.

## Run the iPhone foundation

Open `TVRemote.xcodeproj`, select the **TVRemote** scheme and an iPhone simulator, then run. The minimum deployment target is iOS 17. The project builds with Xcode 26.6 using the Swift 5 language mode. To regenerate the project after adding files, run `xcodegen generate`.

On first run, choose **Find my TV → Find TVs**. Living Room connects without a code; Bedroom accepts `123456` and supports the touchpad. Successful pairing opens a confirmation, then the free Remote. Both TVs are simulated in-process: the app does not access the network, request device permissions, record audio or control hardware. The clearly labeled demo catalog is not a list of installed apps. Pairings are kept in memory; favorites, appearance, haptics, large-controls preference and scene drafts persist on the phone.

```sh
xcodebuild -scheme TVRemote -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme TVRemote -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- `TVDriverKit/` is the plan’s eight-member `TVDriver` contract and its value types. Code entry, manual IP lookup and pointer movement are optional capabilities, not additions to the contract.
- `TVRemote/State/` adapts the injected driver to SwiftUI and contains the demo driver. The app composition root is `TVRemoteApp.swift`; shipping integration needs the real platform driver, its connection coordinator and secure credential storage.
- `TVRemote/Design/` and `TVRemote/Screens/` contain the adaptive palette, shared SwiftUI components and iPhone screens. The remote uses a fixed d-pad layout, haptics and a separate keyboard entrance, informed by the [official Roku remote](https://support.roku.com/article/roku-remote-on-your-phone); system typography, visible status labels and large controls follow [Apple’s accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility) and the [SwiftUI Pro accessibility checklist](https://github.com/twostraws/swiftui-agent-skill/blob/main/swiftui-pro/references/accessibility.md).
- `TVRemoteTests/` exercises discovery, pairing, switching, command gating, sleep and wake with the demo driver.

## Integration and follow-on phases

## Figma iPhone implementation

The [authoritative design handoff](https://www.figma.com/design/Ld7lB1XacMlPrOIrq5YBCx?node-id=12-381) is implemented with `RemoteTheme` semantic light/dark colors, native SF Symbols, a 252-point direction disc with 56-point arrow targets and an 84-point OK landmark, 24-point content gutters, native four-tab navigation (Remote / Apps / My TVs / Settings), and scrollable Dynamic Type layouts. Native safe areas and keyboards replace the schematic Figma device chrome. No downloaded mockup artwork or third-party UI dependencies are needed.

Setup, discovery, code pairing, retry feedback, free remote, sleep/wake, keyboard **search**, simulated app launching, favorites pinning/reordering, forgetting, settings and redacted support sharing are wired to the foundation or local state. Inputs and numeric entry explain missing driver capabilities. Voice recognition, system permissions, StoreKit, secure persistent pairing, scene execution and system surfaces are deliberately not faked. Scene creation only saves a local draft. Commerce prices are explicitly illustrative; no purchase is offered.

In a Debug build, **Settings → Design states** exposes all 55 iPhone screen/state presentations from the handoff. Every fixture is visibly marked **DESIGN PREVIEW**; transient voice, permission, purchase, recovery and scene results are view contracts, not actual service events. The catalog and its launch arguments are excluded from Release builds. Watch/widgets/Live Activity/Control Center were later-surface concepts, not iPhone screens or implemented extensions.

An opt-in visual inventory scheme captures each state in Light and Dark as XCTest attachments:

```sh
xcodebuild -scheme TVRemoteDesignReview -destination 'platform=iOS Simulator,id=EDD9B083-63F1-44E6-9A7B-0A6964CC2561' -resultBundlePath DesignReview.xcresult test
xcrun xcresulttool export attachments --path DesignReview.xcresult --output-path DesignReviewShots
```

Use an available iOS simulator ID from `xcrun simctl list devices`; the example ID is not portable. The normal `TVRemote` scheme keeps the functional unit/UI regressions separate from the longer visual inventory. The existing `TVDriver` protocol is unchanged so the platform-driver package can land independently.

Next, wire the real driver and exercise system permissions, secure pairing, reconnects and standby on supported hardware. Integrate on-device voice and Apple system surfaces, then ship StoreKit, the privacy policy, TestFlight and store assets after the physical-TV release gates pass. The settings screens only preview diagnostics and plans in this build; they do not probe a network or accept purchases.

After the launch roadmap, validate a one-handed accessibility mode against task-completion and mis-tap rates; then measure whether opt-in, redacted self-diagnostics improve recovery before adding more recovery automation. Use those results and real model compatibility to prioritize future platforms.
