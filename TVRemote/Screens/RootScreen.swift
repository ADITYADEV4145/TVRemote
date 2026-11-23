import SwiftUI

struct RootScreen: View {
    @Environment(ConnectionManager.self) private var connection
    @State private var tab = Tab.remote
    @State private var sheet: Tool?

    enum Tab { case remote, devices, apps, settings }

    enum Tool: String, Identifiable {
        case setup, keyboard, trackpad, voice
        var id: Self { self }
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                RemoteScreen(open: { sheet = $0 })
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Remote", systemImage: "dot.circle.and.hand.point.up.left.fill") }
            .tag(Tab.remote)

            NavigationStack {
                DevicesScreen(
                    add: { sheet = .setup },
                    connected: { tab = .remote }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("My TVs", systemImage: "tv") }
            .tag(Tab.devices)

            NavigationStack {
                AppsScreen(setup: { sheet = .setup })
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            .tag(Tab.apps)

            NavigationStack {
                SettingsScreen()
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .onChange(of: tab) { connection.clearMessages() }
        .onChange(of: sheet) { connection.clearMessages() }
        .sheet(item: $sheet) { tool in
            NavigationStack {
                switch tool {
                case .setup:
                    SetupScreen { sheet = nil; tab = .remote }
                case .keyboard:
                    KeyboardScreen()
                case .trackpad:
                    TrackpadScreen()
                case .voice:
                    VoiceScreen()
                }
            }
        }
    }
}

struct CloseTool: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
