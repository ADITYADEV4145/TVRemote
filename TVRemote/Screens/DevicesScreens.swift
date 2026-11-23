import SwiftUI

enum SetupPage: String {
    case welcome, network, discovery, code, approval, retry, ready, manual, denied, empty
}

struct SetupScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var page: SetupPage
    @State private var address = ""
    @State private var code = ""
    private let movedDeviceID: String?
    private let initiallyStarted: Bool
    let connected: () -> Void

    init(initiallyStarted: Bool = false, initialPage: SetupPage? = nil, movedDeviceID: String? = nil,
         connected: @escaping () -> Void) {
        _page = State(initialValue: initialPage ?? (initiallyStarted ? .discovery : .welcome))
        self.initiallyStarted = initiallyStarted
        self.movedDeviceID = movedDeviceID
        self.connected = connected
    }

    var body: some View {
        ScreenBody {
            switch page {
            case .welcome:
                ScreenHeading("", "Your phone. Your remote.", "No accounts. No ads. Just your TV.")
                HeroCard(icon: "square.grid.2x2", title: "Right where you left it.",
                         detail: "Find your TV on Wi-Fi and get back to watching. The basic remote is always free.")
                SupportingCopy(title: connection.isDemo ? "Try the remote" : "Made for smart TVs",
                               detail: connection.isDemo
                               ? "This build uses simulated TVs. It does not access your network or control a physical TV."
                               : "Your iPhone and TV need the same Wi-Fi. Network control is required.")
                Button("Find my TV") { page = .network }.buttonStyle(PrimaryActionStyle())
                NavigationLink("Check compatibility") { CompatibilityScreen() }.buttonStyle(SecondaryActionStyle())
            case .network:
                ScreenHeading("", "Let’s find your TV", "Your TV and iPhone need the same Wi-Fi.")
                HeroCard(icon: "wifi", title: "A local connection.",
                         detail: connection.isDemo
                         ? "No Local Network permission is requested in demo mode. We’ll find two simulated TVs."
                         : "Allow Local Network access when discovery asks so this phone can find and control your TV.")
                SupportingCopy(title: "You’re in control", detail: "We ask for access only when it’s needed. You can change it in iPhone Settings.")
                Button("Find TVs") { page = .discovery }.buttonStyle(PrimaryActionStyle())
                Button("Not now", action: connected).buttonStyle(SecondaryActionStyle())
            case .discovery:
                discovery
            case .code:
                pairing
            case .manual:
                manual
            case .ready:
                ScreenHeading("", "You’re connected", "\(connection.currentDevice?.name ?? "Your TV") is ready.")
                HeroCard(icon: "checkmark.circle", title: "Give it a try.",
                         detail: "Tap Home on your remote to check the connection. You can start using the basic buttons for free.")
                Button("Open remote", action: connected).buttonStyle(PrimaryActionStyle())
                SupportingCopy(title: "No payment needed", detail: "Power, supported navigation, volume and recovery stay free.")
            default:
                SetupStatusContent(page: page, retry: {
                    if page == .approval { connection.retryTVApproval() }
                    else { chooseAnotherTV() }
                },
                                   chooseAnother: chooseAnotherTV,
                                   manual: { page = .manual },
                                   retryDisabled: page == .approval && connection.awaitingTVApproval)
            }
            if connection.isConnecting { ProgressView("Connecting to TV") }
            if page != .approval || !connection.awaitingTVApproval { ConnectionMessage() }
        }
        .modifier(CloseTool())
        .toolbar {
            if page != .welcome && movedDeviceID == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left") {
                        connection.cancelPairing()
                        switch page {
                        case .network: page = .welcome
                        case .discovery:
                            if initiallyStarted { dismiss() }
                            else { page = .network }
                        default: page = .discovery
                        }
                    }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    .disabled(connection.isConnecting)
                }
            }
        }
        .task(id: page) { if page == .discovery { await connection.discover() } }
        .onChange(of: connection.pairingPrompt) {
            if let prompt = connection.pairingPrompt { page = prompt == .approval ? .approval : .code }
        }
        .onChange(of: connection.pairingCompletion) { page = .ready }
        .interactiveDismissDisabled(connection.isConnecting)
        .onDisappear { connection.cancelPairing() }
    }

    private func chooseAnotherTV() {
        connection.cancelPairing()
        page = .discovery
    }

    private var discovery: some View {
        Group {
            ScreenHeading("", "Find your TV", connection.isDemo ? "Simulated TVs nearby" : "Searching your local Wi-Fi…")
            Panel {
                Text("Looking nearby").font(.headline)
                Text("Turn on your TV and keep this screen open.").foregroundStyle(RemoteTheme.muted)
                if connection.isDiscovering { ProgressView() }
            }
            ForEach(connection.devices) { device in
                Button {
                    Task { if await connection.select(device) { page = .ready } }
                } label: {
                    Panel {
                        DetailRow(icon: "tv", title: device.name, detail: device.platform, trailing: "chevron.right")
                    }
                }
                .buttonStyle(.plain).disabled(connection.isConnecting)
            }
            if connection.devices.isEmpty && !connection.isDiscovering {
                SupportingCopy(title: "No TVs found yet", detail: "Check the same Wi-Fi, turn the TV on, and enable network control.")
                Button("Search again") { Task { await connection.discover() } }.buttonStyle(PrimaryActionStyle())
            }
            SupportingCopy(title: "Don’t see your TV?", detail: "Check that both devices are on the same Wi-Fi. Guest networks can block discovery.")
            if connection.supportsManualAddress {
                Button("Enter IP address") { page = .manual }.buttonStyle(SecondaryActionStyle())
            }
            NavigationLink("Check compatibility") { CompatibilityScreen() }.frame(minHeight: 44)
        }
    }

    private var pairing: some View {
        Group {
            ScreenHeading("", "Check your TV", "Enter the code shown on the TV.")
            HeroCard(icon: "tv", title: "Pair with \(connection.pairingDevice?.name ?? "your TV")",
                     detail: connection.isDemo ? "Use 123456 for the Bedroom demo TV."
                     : "Enter all characters exactly as shown. Your TV controls the code format.")
            TextField("TV pairing code", text: $code)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .padding(16).background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("pairingCode")
            Button("Pair TV") {
                Task { if await connection.submit(code: code) { page = .ready } }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.isConnecting)
            Button("Choose another TV") {
                connection.cancelPairing(); code = ""; page = .discovery
            }
            .buttonStyle(SecondaryActionStyle()).disabled(connection.isConnecting)
        }
    }

    private var manual: some View {
        Group {
            ScreenHeading("", movedDeviceID == nil ? "Add by IP address" : "Update TV address",
                          movedDeviceID == nil ? "When your TV doesn’t appear automatically." : "Enter the new address for your saved TV.")
            Text("TV address").font(.subheadline).foregroundStyle(RemoteTheme.muted)
            TextField("192.168.1.42", text: $address)
                .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(16).background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            SupportingCopy(title: "Stay on the same Wi-Fi", detail: connection.isDemo
                           ? "Demo addresses: 192.0.2.10 or 192.0.2.11."
                           : "Find the address in your TV’s network settings. An address is not a substitute for pairing.")
            Button("Find TV") {
                Task { if await connection.find(address: address, matching: movedDeviceID) { page = .ready } }
            }
            .buttonStyle(PrimaryActionStyle()).disabled(address.isEmpty || connection.isConnecting)
            if movedDeviceID == nil {
                Button("Back to nearby TVs") { page = .discovery }.buttonStyle(SecondaryActionStyle())
            }
        }
    }
}

struct SetupStatusContent: View {
    let page: SetupPage
    var retry: () -> Void = {}
    var chooseAnother: () -> Void = {}
    var manual: () -> Void = {}
    var retryDisabled = false

    var body: some View {
        Group {
            ScreenHeading("", title, subtitle)
            HeroCard(icon: icon, title: cardTitle, detail: detail)
            if page == .denied {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }.buttonStyle(PrimaryActionStyle())
            } else {
                Button(page == .approval ? "Try again" : "Search again", action: retry).buttonStyle(PrimaryActionStyle())
                    .disabled(retryDisabled)
            }
            Button(page == .empty ? "Enter IP address" : "Choose another TV",
                   action: page == .empty ? manual : chooseAnother).buttonStyle(SecondaryActionStyle())
        }
    }

    private var title: String {
        switch page {
        case .approval: "Allow this phone"
        case .retry: "Let’s try that again"
        case .denied: "Local access is off"
        default: "No TVs found yet"
        }
    }
    private var subtitle: String { page == .approval ? "One quick step on your TV." : "Your remote is still here." }
    private var icon: String { page == .approval ? "tv" : page == .denied ? "wifi.slash" : "arrow.uturn.backward" }
    private var cardTitle: String {
        page == .approval ? "Look up at the TV" : page == .denied ? "Allow Local Network" : page == .retry ? "That code didn’t work" : "A few things to check"
    }
    private var detail: String {
        switch page {
        case .approval: "Choose Allow on the TV’s connection request. Keep this screen open while it connects."
        case .denied: "Open Settings, choose this app and turn on Local Network. Your paired TVs are not removed."
        case .retry: "The code may have expired. Request a fresh code and enter it from your TV."
        default: "Use the same Wi-Fi, turn your TV on, and enable network control in its settings."
        }
    }
}

struct DevicesScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    let add: () -> Void
    let connected: () -> Void

    var body: some View {
        ScreenBody {
            ScreenHeading("", "My TVs", "One familiar remote. Every room.")
            if connection.savedDevices.isEmpty {
                HeroCard(icon: "tv", title: "Your TVs live here", detail: "Pair a TV to switch rooms without relearning the remote.")
            }
            ForEach(connection.savedDevices) { device in
                Panel {
                    Button {
                        Task {
                            if await connection.select(device) { connected() }
                        }
                    } label: {
                        DetailRow(icon: "tv", title: device.name,
                                  detail: connection.currentDevice?.id == device.id ? connection.state.rawValue : device.platform,
                                  trailing: connection.currentDevice?.id == device.id ? "checkmark.circle" : "chevron.right")
                    }
                    .buttonStyle(.plain).disabled(connection.isConnecting)
                    NavigationLink("TV details") { TVDetailScreen(device: device) }.frame(minHeight: 44)
                }
            }
            if connection.pairingDevice != nil {
                NavigationLink("Finish pairing") {
                    SetupScreen(initialPage: connection.pairingPrompt == .approval ? .approval : .code,
                                connected: connected)
                }
                    .buttonStyle(PrimaryActionStyle())
            }
            Button("Add a TV", systemImage: "plus", action: add).buttonStyle(PrimaryActionStyle())
            ConnectionMessage()
        }
        .onChange(of: connection.pairingCompletion) { connected() }
    }
}

struct TVDetailScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    let device: TVDevice
    private var savedDevice: TVDevice { connection.savedDevices.first { $0.id == device.id } ?? device }

    var body: some View {
        ScreenBody {
            ScreenHeading("", savedDevice.name, device.platform)
            Panel {
                DetailRow(icon: "tv", title: "Connection", detail: connection.currentDevice?.id == device.id ? connection.state.rawValue : "Not selected")
                DetailRow(icon: "network", title: "TV address", detail: device.address)
                DetailRow(icon: "hand.point.up.left", title: "Touchpad", detail: device.supportsPointer ? "Available with this driver" : "Not supported")
            }
            NavigationLink("Connection details") { ConnectionDetailsScreen(device: device) }.buttonStyle(SecondaryActionStyle())
            if !connection.isDemo {
                NavigationLink("Rename TV") { RenameTVScreen(device: savedDevice) }
                    .buttonStyle(SecondaryActionStyle())
            }
            NavigationLink("Forget this TV") { ForgetTVScreen(device: device) }.buttonStyle(SecondaryActionStyle(destructive: true))
            SupportingCopy(title: "On this phone only", detail: "Forgetting removes this app’s pairing. It does not change TV apps or settings.")
        }
        .modifier(TaskSurface())
    }
}

private struct RenameTVScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @Environment(\.dismiss) private var dismiss
    let device: TVDevice
    @State private var name: String

    init(device: TVDevice) {
        self.device = device
        _name = State(initialValue: device.name)
    }

    var body: some View {
        ScreenBody {
            ScreenHeading("", "Rename TV", "This name is only used on this iPhone.")
            TextField("TV name", text: $name).padding(16)
                .background(RemoteTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            Button("Save name") {
                connection.rename(device, to: name)
                dismiss()
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .modifier(TaskSurface())
    }
}

struct ForgetTVScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var forgotten = false
    let device: TVDevice

    var body: some View {
        ScreenBody {
            ScreenHeading("", forgotten ? "TV forgotten" : "Forget \(device.name)?", "This only affects this iPhone.")
            HeroCard(icon: "tv", title: forgotten ? "Pair again any time" : "Your TV stays as it is",
                     detail: "TV apps and settings are not changed. You’ll need to pair again before using this remote.")
            Button("Keep TV") { dismiss() }.buttonStyle(PrimaryActionStyle()).disabled(forgotten)
            Button(forgotten ? "Forgotten" : "Forget TV", role: .destructive) {
                Task { await connection.forget(device); forgotten = true }
            }
            .buttonStyle(SecondaryActionStyle(destructive: true)).disabled(connection.isConnecting || forgotten)
        }
        .modifier(TaskSurface())
    }
}
