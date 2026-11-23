import SwiftUI

struct SettingsScreen: View {
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("largeControls") private var largeControls = false
    var openRemote: () -> Void = {}

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Settings", "Make yourself at home.")
            Panel {
                route("slider.horizontal.3", "Appearance", "System, light or dark") { AppearanceScreen() }
                Toggle(isOn: $haptics) { DetailRow(icon: "hand.tap", title: "Haptics", detail: "A little feedback with each press") }
                Toggle(isOn: $largeControls) { DetailRow(icon: "hand.point.up", title: "Large controls", detail: "Bigger targets, scrollable remote") }
                route("mic", "Voice", "On-device access and command help") { VoiceSettingsScreen() }
            }
            Panel {
                route("wifi.exclamationmark", "Fix my connection", "Free help, whenever you need it") { DiagnosticsScreen(openRemote: openRemote) }
                route("tv", "Compatibility", "TV platforms and capabilities") { CompatibilityScreen() }
                route("lock.shield", "Privacy", "Local by design") { PrivacyScreen() }
            }
            Panel {
                route("sparkles", "TV Remote Plus", "Optional upgrade · Preview") { UpgradeScreen() }
                route("square.stack", "Scenes", "Build a local draft") { ScenesScreen() }
                route("square.and.arrow.up", "Siri & Shortcuts", "Integration status") { ShortcutsScreen() }
            }
            #if DEBUG
            NavigationLink("Design states") { DesignCatalogScreen() }
                .frame(minHeight: 44)
            #endif
            SupportingCopy(title: "The honest remote", detail: "No ads or purchases. Connections were tested with simulated TVs only.")
        }
        .buttonStyle(.plain)
    }

    private func route<Destination: View>(_ icon: String, _ title: String, _ detail: String,
                                         @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            DetailRow(icon: icon, title: title, detail: detail, trailing: "chevron.right")
        }
    }
}

struct AppearanceScreen: View {
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Appearance", "Comfortable in every light.")
            HeroCard(icon: "circle.lefthalf.filled", title: "Your room. Your choice.",
                     detail: "Use your iPhone’s appearance or choose a look just for this app.")
            Panel {
                ForEach(["System", "Light", "Dark"], id: \.self) { choice in
                    Button { appearance = choice } label: {
                        DetailRow(icon: choice == "System" ? "iphone" : choice == "Light" ? "sun.max" : "moon",
                                  title: choice, detail: choice == "System" ? "Follow iPhone settings" : "Always use \(choice.lowercased())",
                                  trailing: appearance == choice ? "checkmark.circle.fill" : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(appearance == choice ? [.isSelected] : [])
                }
            }
        }.modifier(TaskSurface())
    }
}

struct VoiceSettingsScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("", "Voice settings", "Simple commands. On your terms.")
            HeroCard(icon: "mic", title: "On-device by design",
                     detail: "Voice recognition is not connected in this build. No microphone or speech permission is requested.")
            Panel {
                DetailRow(icon: "hand.raised", title: "Only when you tap", detail: "No always-on listening")
                DetailRow(icon: "iphone", title: "No cloud fallback", detail: "On-device recognition must be available")
                DetailRow(icon: "arrow.uturn.backward", title: "Buttons stay free", detail: "Use navigation and volume without voice")
            }
            NavigationLink("Voice help") { VoiceScreen(phase: .introduction) }.buttonStyle(SecondaryActionStyle())
        }.modifier(TaskSurface())
    }
}

struct DiagnosticsScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @State private var showRepair = false
    @State private var editingAddress = false
    var openRemote: () -> Void = {}

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Fix my connection", "Let’s get you back to watching.")
            Panel {
                DetailRow(icon: "tv", title: connection.currentDevice?.name ?? "No TV selected", detail: connection.state.rawValue)
                DetailRow(icon: "wifi", title: "Local network", detail: connection.isDemo ? "Not checked · Demo mode" : connection.networkStatus)
                DetailRow(icon: "lock.shield", title: "Local Network permission", detail: connection.networkPermission)
                DetailRow(icon: "key", title: "Pairing", detail: connection.state == .needsRepair ? "Needs authorization" : "Use the TV’s approval or code when asked")
            }
            if connection.currentDevice != nil {
                Button(connection.state == .needsRepair ? "Pair again" : "Reconnect") {
                    Task {
                        if !(await connection.reconnect()), connection.pairingDevice != nil { showRepair = true }
                    }
                }
                .buttonStyle(PrimaryActionStyle()).disabled(connection.isConnecting)
                if connection.canTryPairingAgain {
                    Button("Try pairing again") { connection.tryPairingAgain() }
                        .buttonStyle(SecondaryActionStyle()).disabled(connection.isConnecting)
                    SupportingCopy(title: "Pairing may need to be renewed",
                                   detail: "Google TV can drop the connection without saying why. If reconnecting doesn’t work, try a new pairing code.")
                }
                if connection.canForgetAfterConnectionFailure, let device = connection.currentDevice {
                    NavigationLink("Forget this TV") { ForgetTVScreen(device: device) }
                        .buttonStyle(SecondaryActionStyle(destructive: true))
                }
                if !connection.isDemo, !connection.canControl {
                    Button("Update TV address") { editingAddress = true }
                        .buttonStyle(SecondaryActionStyle()).disabled(connection.isConnecting)
                }
            }
            NavigationLink("Connection details") { ConnectionDetailsScreen() }.buttonStyle(SecondaryActionStyle())
            Panel {
                SupportingCopy(title: "Same Wi-Fi?", detail: "Guest networks and client isolation can prevent devices from seeing each other.")
                SupportingCopy(title: "TV turned on?", detail: "Some TVs need Network Standby or Quick Start enabled to wake over Wi-Fi.")
                SupportingCopy(title: "Still not working?", detail: "Restart the TV, check network control is enabled, then retry. Your saved TV is kept.")
            }
            NavigationLink("Preview support report") { SupportPreviewScreen() }.buttonStyle(SecondaryActionStyle())
            ConnectionMessage()
        }
        .modifier(TaskSurface())
        .task { await connection.observeNetwork() }
        .onAppear { connection.clearMessages() }
        .onChange(of: connection.pairingPrompt) {
            if connection.pairingPrompt != nil && !editingAddress { showRepair = true }
        }
        .sheet(isPresented: $showRepair) {
            NavigationStack {
                SetupScreen(initialPage: connection.pairingPrompt == .approval ? .approval : .code) {
                    showRepair = false
                    openRemote()
                }
            }
        }
        .sheet(isPresented: $editingAddress) {
            NavigationStack {
                SetupScreen(initialPage: .manual, movedDeviceID: connection.currentDevice?.id) {
                    editingAddress = false
                    openRemote()
                }
            }
        }
    }
}

struct ConnectionDetailsScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    var device: TVDevice? = nil

    private var target: TVDevice? { device ?? connection.currentDevice }
    private var selected: Bool { target != nil && target?.id == connection.currentDevice?.id }
    private var commands: [RemoteViewModel.RecentCommand] {
        guard let target else { return [] }
        return connection.recentCommands.filter { $0.deviceID == target.id }
    }

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Connection details", "Evidence, not guesses.")
            Panel {
                DetailRow(icon: "tv", title: "TV", detail: target?.name ?? "None selected")
                DetailRow(icon: "circle.dotted", title: "Driver state", detail: selected ? connection.state.rawValue : "Not selected")
                DetailRow(icon: "testtube.2", title: "Mode", detail: connection.isDemo ? "In-process simulation" : "Live driver")
                DetailRow(icon: "clock", title: "Last connection check", detail: checkTime)
                if let id = target?.id, let failure = connection.commandFailures[id] {
                    DetailRow(icon: "exclamationmark.circle", title: "Last failure: \(failure.title)", detail: failure.reason)
                }
            }
            Text("Recent commands").font(.title3.weight(.semibold))
            Panel {
                if commands.isEmpty { Text("No commands sent to this TV yet.").foregroundStyle(RemoteTheme.muted) }
                ForEach(commands) { command in
                    DetailRow(icon: "arrow.up.right", title: command.title,
                              detail: "Driver acknowledged · \(command.timestamp.formatted(.dateTime.hour().minute().second()))")
                }
            }
            SupportingCopy(title: "What acknowledgment means", detail: "The driver accepted the action. It does not prove that the TV visibly changed.")
            if selected {
                NavigationLink("Preview support report") { SupportPreviewScreen() }.buttonStyle(SecondaryActionStyle())
            }
        }.modifier(TaskSurface())
    }

    private var checkTime: String {
        guard let id = target?.id, let duration = connection.checkDurations[id] else { return "Not measured" }
        let parts = duration.components
        let milliseconds = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        return "\(milliseconds) ms elapsed"
    }
}

struct SupportPreviewScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @State private var includeCommands = false

    private var report: String {
        var value = "TV Remote support report\nMode: \(connection.isDemo ? "Simulated" : "Live")\nDriver state: \(connection.state.rawValue)\nNetwork: Not checked\nPermission: Not checked\nTV names, addresses, identifiers, credentials and voice audio: omitted"
        if includeCommands {
            value += "\nRecent actions:\n" + connection.recentCommands.map(\.title).joined(separator: "\n")
        }
        return value
    }

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Before you share", "You choose what leaves your phone.")
            Panel {
                Toggle("Include recent action names", isOn: $includeCommands).frame(minHeight: 44)
                Text("Search text, TV names, addresses, pairing credentials and voice audio are never included.")
                    .font(.subheadline).foregroundStyle(RemoteTheme.muted)
            }
            Panel { Text(report).font(.footnote.monospaced()).textSelection(.enabled) }
            ShareLink(item: report) { Label("Share report", systemImage: "square.and.arrow.up") }
                .buttonStyle(PrimaryActionStyle())
        }.modifier(TaskSurface())
    }
}

struct CompatibilityScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("", "Will my TV work?", "A smart TV with network control is required.")
            Panel {
                DetailRow(icon: "testtube.2", title: "Tested with simulators only", detail: "Pairing and remote controls were tested on all four platforms")
                DetailRow(icon: "tv", title: "Drivers in this build", detail: "Roku TV, Google TV, Samsung Tizen and LG webOS")
                DetailRow(icon: "network.slash", title: "Hardware not validated", detail: "No physical TV was connected or tested")
            }
            SupportingCopy(title: "Not every TV is supported", detail: "An iPhone has no infrared blaster. Network control, model and firmware determine which features work.")
            SupportingCopy(title: "Support varies by model", detail: "A platform name is not a compatibility guarantee. Pairing, wake, apps, inputs and text depend on the installed driver.")
        }.modifier(TaskSurface())
    }
}

struct PrivacyScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("", "Privacy", "Local by design.")
            Panel {
                DetailRow(icon: "person.crop.circle.badge.checkmark", title: "No account", detail: "Use the local remote without signing in")
                DetailRow(icon: "iphone", title: "On this iPhone", detail: "Saved TVs, appearance, favorites and scene drafts are stored locally")
                DetailRow(icon: "mic.slash", title: "No recording", detail: "This build never requests microphone or speech access")
                DetailRow(icon: "hand.raised", title: "No automatic diagnostics", detail: "There is no telemetry service in this build")
            }
            SupportingCopy(title: "Saved connections", detail: "In normal use, pairing credentials stay in this iPhone’s Keychain. Saved TV names and network addresses stay in app storage so you can reconnect after a restart. Forgetting a TV removes its saved connection from this iPhone.")
            NavigationLink("Preview support report") { SupportPreviewScreen() }.buttonStyle(SecondaryActionStyle())
        }.modifier(TaskSurface())
    }
}

enum CommercePhase: String, CaseIterable {
    case offer, pending, failed, restore, empty, active
}

struct UpgradeScreen: View {
    var phase: CommercePhase = .offer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenBody {
            ScreenHeading("", title, "Your basic remote stays free.")
            if phase == .offer {
                HeroCard(icon: "sparkles", title: "More, when you want it.",
                         detail: "Saving and switching between TVs is free. Plus cannot be purchased in this build.")
                Panel {
                    Text("Illustrative plans").font(.headline)
                    plan("Yearly", "$14.99 / year", "Eligible 7-day trial shown only with StoreKit eligibility")
                    Divider()
                    plan("Monthly", "$2.99 / month", "Billed monthly")
                    Divider()
                    plan("Lifetime", "$29.99 once", "One-time purchase")
                }
                SupportingCopy(title: "Design preview only", detail: "Prices are examples, not loaded products or an offer. StoreKit purchase, eligibility and entitlements are not connected.")
                Button("Purchase unavailable") {}.buttonStyle(PrimaryActionStyle()).disabled(true)
                NavigationLink("Restore purchases") { UpgradeScreen(phase: .restore) }.frame(minHeight: 44)
            } else {
                HeroCard(icon: icon, title: statusTitle, detail: statusDetail)
                if phase == .restore {
                    Button("Restore unavailable") {}.buttonStyle(PrimaryActionStyle()).disabled(true)
                }
            }
            Button("Keep free") { dismiss() }.buttonStyle(SecondaryActionStyle())
            HStack {
                NavigationLink("Terms") { PolicyStatusScreen(terms: true) }.frame(maxWidth: .infinity, minHeight: 44)
                NavigationLink("Privacy") { PrivacyScreen() }.frame(maxWidth: .infinity, minHeight: 44)
            }
            .font(.footnote)
        }.modifier(TaskSurface())
    }

    private func plan(_ title: String, _ price: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title).font(.headline); Spacer(); Text(price).font(.body.weight(.medium)) }
            Text(detail).font(.subheadline).foregroundStyle(RemoteTheme.muted)
        }.padding(.vertical, 8)
    }
    private var title: String {
        switch phase {
        case .offer: "TV Remote Plus"
        case .pending: "Waiting for approval"
        case .failed: "Purchase not completed"
        case .restore: "Restore purchases"
        case .empty: "No purchases found"
        case .active: "Plus is active"
        }
    }
    private var icon: String {
        switch phase {
        case .pending: "clock"
        case .failed: "exclamationmark.circle"
        case .empty: "arrow.clockwise"
        case .active: "checkmark.circle"
        default: "sparkles"
        }
    }
    private var statusTitle: String {
        switch phase {
        case .pending: "Nothing to do just yet"
        case .failed: "Your free remote is ready"
        case .restore: "Already have Plus?"
        case .empty: "Check your Apple Account"
        case .active: "Thanks for your support"
        default: "Optional. Always."
        }
    }
    private var statusDetail: String {
        switch phase {
        case .pending: "A pending transaction does not unlock Plus. Continue using the free remote while approval is pending."
        case .failed: "No entitlement was granted. Purchase errors never interrupt pairing, recovery or free controls."
        case .restore: "Restoring will check valid purchases for your Apple Account, without starting a new purchase. Not connected in this build."
        case .empty: "No valid entitlement was returned. Keep using the free remote, or check that you use the Apple Account that purchased Plus."
        case .active: "This screen requires a verified entitlement from StoreKit. The design catalog is only a presentation preview."
        default: ""
        }
    }
}

struct PolicyStatusScreen: View {
    var terms = false
    var body: some View {
        ScreenBody {
            ScreenHeading("", terms ? "Terms" : "Privacy policy", "Before release")
            HeroCard(icon: "doc.text", title: "Policy not published yet",
                     detail: "This demo does not sell subscriptions. Final legal terms and privacy policy must be published before StoreKit is enabled.")
        }.modifier(TaskSurface())
    }
}

struct ShortcutsScreen: View {
    var body: some View {
        ScreenBody {
            ScreenHeading("", "Siri & Shortcuts", "Your favorite actions, a little closer.")
            HeroCard(icon: "square.stack.3d.up", title: "Not installed in this build",
                     detail: "Siri intents, widgets, Control Center and Watch are later integrations. No system shortcut is created here.")
            SupportingCopy(title: "Choose the right TV", detail: "A shortcut must use an explicit saved TV and supported action. It must never silently choose another room.")
        }.modifier(TaskSurface())
    }
}
