import SwiftUI

struct RootScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var tab = Tab.remote
    @State private var sheet: Tool?
    @State private var remotePath: [RemoteDestination] = []
    var showWelcome = true
    var remoteTouchpad = false
    var forceLarge = false

    init(initialTab: Tab = .remote, showWelcome: Bool = true, remoteTouchpad: Bool = false, forceLarge: Bool = false) {
        _tab = State(initialValue: initialTab)
        self.showWelcome = showWelcome
        self.remoteTouchpad = remoteTouchpad
        self.forceLarge = forceLarge
    }

    enum Tab { case remote, devices, apps, settings }
    enum RemoteDestination: Hashable { case diagnostics }
    enum Tool: String, Identifiable {
        case setup, keyboard, trackpad, voice, inputs, keypad
        var id: Self { self }
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $remotePath) {
                RemoteScreen(touchpad: remoteTouchpad, forceLarge: forceLarge, open: { sheet = $0 }).toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: RemoteDestination.self) { _ in
                        DiagnosticsScreen(openRemote: returnToRemote)
                    }
            }
            .tabItem { Label("Remote", systemImage: "square.grid.2x2") }.tag(Tab.remote)

            NavigationStack {
                AppsScreen(setup: { sheet = .setup }).toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Apps", systemImage: "play") }.tag(Tab.apps)

            NavigationStack {
                DevicesScreen(add: { sheet = .setup }, connected: returnToRemote)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("My TVs", systemImage: "tv") }.tag(Tab.devices)

            NavigationStack {
                SettingsScreen(openRemote: returnToRemote).toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(Tab.settings)
        }
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
        .onAppear {
            if showWelcome && !hasSeenWelcome { sheet = .setup; hasSeenWelcome = true }
        }
        .onChange(of: tab) { connection.clearMessages() }
        .onChange(of: sheet) { connection.clearMessages() }
        .sheet(item: $sheet) { tool in
            NavigationStack {
                switch tool {
                case .setup: SetupScreen(connected: returnToRemote)
                case .keyboard: KeyboardScreen()
                case .trackpad: TrackpadScreen()
                case .voice: VoiceScreen()
                case .inputs: InputsScreen().modifier(CloseTool())
                case .keypad: KeypadScreen().modifier(CloseTool())
                }
            }
            .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
        }
    }

    private func returnToRemote() {
        sheet = nil
        remotePath.removeAll()
        tab = .remote
    }
}

struct CloseTool: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.modifier(TaskSurface()).toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }
}
