# TV Remote

A native iPhone remote for Wi-Fi-enabled TVs.

## Run the iPhone foundation

Open `TVRemote.xcodeproj`, select the **TVRemote** scheme and an iPhone simulator, then run. The minimum deployment target is iOS 17. The project builds with Xcode 26.6 using the Swift 5 language mode. To regenerate the project after adding files, run `xcodegen generate`.

In the app, choose **Find a TV → Find TVs**. Living Room connects without a code; Bedroom accepts `123456` and supports the trackpad. Both TVs are simulated in-process: the app does not access the network, request device permissions, record audio or control hardware. The demo catalog is not a list of installed apps. Pairings are kept in memory; app favorites persist on the phone.

```sh
xcodebuild -scheme TVRemote -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme TVRemote -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- `TVDriverKit/` is the plan’s eight-member `TVDriver` contract and its value types. Code entry, manual IP lookup and pointer movement are optional capabilities, not additions to the contract.
- `TVRemote/State/` adapts the injected driver to SwiftUI and contains the demo driver. The app composition root is `TVRemoteApp.swift`; shipping integration needs the real platform driver, its connection coordinator and secure credential storage.
- `TVRemote/Design/` and `TVRemote/Screens/` contain the adaptive palette, shared SwiftUI components and iPhone screens. The remote uses a fixed d-pad layout, haptics and a separate keyboard entrance, informed by the [official Roku remote](https://support.roku.com/article/roku-remote-on-your-phone); system typography, visible status labels and large controls follow [Apple’s accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility) and the [SwiftUI Pro accessibility checklist](https://github.com/twostraws/swiftui-agent-skill/blob/main/swiftui-pro/references/accessibility.md).
- `TVRemoteTests/` exercises discovery, pairing, switching, command gating, sleep and wake with the demo driver.

## Integration and follow-on phases

Next, wire the real driver and exercise system permissions, secure pairing, reconnects and standby on supported hardware. Integrate on-device voice and Apple system surfaces, then ship StoreKit, the privacy policy, TestFlight and store assets after the physical-TV release gates pass. The settings screens only preview diagnostics and plans in this build; they do not probe a network or accept purchases.

After the launch roadmap, validate a one-handed accessibility mode against task-completion and mis-tap rates; then measure whether opt-in, redacted self-diagnostics improve recovery before adding more recovery automation. Use those results and real model compatibility to prioritize future platforms.
