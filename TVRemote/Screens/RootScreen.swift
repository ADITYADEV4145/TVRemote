import SwiftUI

struct RootScreen: View {
    @Environment(RemoteViewModel.self) private var connection
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var tab = Tab.remote
    @State private var sheet: Tool?
    @State private var remotePath: [RemoteDestination] = []
    @State private var appsPath: [AppsScreen.Destination] = []
    @State private var devicesStackID = UUID()
    @State private var settingsStackID = UUID()
    var showWelcome = true
    var remoteTouchpad = false
    var forceLarge = false

    init(initialTab: Tab = .remote, showWelcome: Bool = true, remoteTouchpad: Bool = false, forceLarge: Bool = false) {
        _tab = State(initialValue: initialTab)
        self.showWelcome = showWelcome
        self.remoteTouchpad = remoteTouchpad
        self.forceLarge = forceLarge
    }

    enum Tab: String, CaseIterable {
        case remote, apps, devices, settings

        var title: String {
            switch self {
            case .remote: "Remote"
            case .apps: "Apps"
            case .devices: "My TVs"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .remote: "square.grid.2x2"
            case .apps: "play"
            case .devices: "tv"
            case .settings: "slider.horizontal.3"
            }
        }
    }
    enum RemoteDestination: Hashable { case diagnostics }
    enum Tool: String, Identifiable {
        case setup, keyboard, trackpad, voice, inputs, keypad
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                NavigationStack(path: $remotePath) {
                    RemoteScreen(touchpad: remoteTouchpad, forceLarge: forceLarge, open: { sheet = $0 }).toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: RemoteDestination.self) { _ in
                            DiagnosticsScreen(openRemote: returnToRemote)
                        }
                }
                .toolbar(nativeTabBarVisibility, for: .tabBar)
                .tabItem { Label("Remote", systemImage: "square.grid.2x2") }.tag(Tab.remote)

                NavigationStack(path: $appsPath) {
                    AppsScreen(setup: { sheet = .setup }).toolbar(.hidden, for: .navigationBar)
                }
                .toolbar(nativeTabBarVisibility, for: .tabBar)
                .tabItem { Label("Apps", systemImage: "play") }.tag(Tab.apps)

                NavigationStack {
                    DevicesScreen(add: { sheet = .setup }, connected: returnToRemote)
                        .toolbar(.hidden, for: .navigationBar)
                }
                .id(devicesStackID)
                .toolbar(nativeTabBarVisibility, for: .tabBar)
                .tabItem { Label("My TVs", systemImage: "tv") }.tag(Tab.devices)

                NavigationStack {
                    SettingsScreen(openRemote: returnToRemote).toolbar(.hidden, for: .navigationBar)
                }
                .id(settingsStackID)
                .toolbar(nativeTabBarVisibility, for: .tabBar)
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(Tab.settings)
            }
            if #available(iOS 26, *) {
                FloatingTabBar(selection: tab, select: selectTab)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(RemoteTheme.canvas.ignoresSafeArea(edges: .bottom))
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
        .onAppear {
            if showWelcome && !hasSeenWelcome {
                if connection.savedDevices.isEmpty { sheet = .setup }
                hasSeenWelcome = true
            }
        }
        .onChange(of: tab) { connection.clearMessages() }
        .onChange(of: sheet) { connection.clearMessages() }
        // Favorites belong to the selected TV, not the previous tab context.
        .onChange(of: connection.currentDevice?.id) { appsPath.removeAll() }
        .sheet(item: $sheet) { tool in
            NavigationStack {
                switch tool {
                case .setup: SetupScreen(initiallyStarted: !connection.savedDevices.isEmpty, connected: returnToRemote)
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

    private var nativeTabBarVisibility: Visibility {
        if #available(iOS 26, *) { .hidden } else { .automatic }
    }

    private func selectTab(_ selected: Tab) {
        guard selected == tab else {
            tab = selected
            return
        }
        // Reselecting an active tab returns to its root, like the native bar.
        // These identities change only on an explicit tap, never on appearance.
        switch selected {
        case .remote: remotePath.removeAll()
        case .apps: appsPath.removeAll()
        case .devices: devicesStackID = UUID()
        case .settings: settingsStackID = UUID()
        }
    }

    private func returnToRemote() {
        sheet = nil
        remotePath.removeAll()
        tab = .remote
    }
}

/// Keep the content-owning TabView stable: only this small glass surface is
/// recreated when its appearance changes, avoiding iOS 26's stale tab material.
@available(iOS 26, *)
private struct FloatingTabBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let selection: RootScreen.Tab
    let select: (RootScreen.Tab) -> Void

    var body: some View {
        Group {
            if reduceTransparency {
                buttons.background(RemoteTheme.surface, in: Capsule())
            } else {
                buttons.glassEffect(.regular, in: .capsule)
            }
        }
        .id(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityIdentifier("primaryTabBar")
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(RootScreen.Tab.allCases, id: \.self) { tab in
                Button { select(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .accessibilityHidden(true)
                        Text(tab.title).font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(selection == tab ? RemoteTheme.accent : RemoteTheme.muted)
                    .background(selection == tab ? RemoteTheme.accentSoft : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }
        .padding(4)
        // As with system tabs, keep labels compact while content honors AX sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
