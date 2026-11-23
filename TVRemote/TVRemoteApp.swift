import SwiftUI
import TVRemoteKit

@main
struct TVRemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection = makeConnection()

    var body: some Scene {
        WindowGroup {
            appRoot
                .environment(connection)
                .tint(RemoteTheme.accent)
                .task { await connection.restoreSelection() }
                .task(id: scenePhase) {
                    if scenePhase == .active { await connection.monitor() }
                }
        }
    }

    private static func makeConnection() -> RemoteViewModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            return RemoteViewModel(driver: MockTVDriver())
        }
        if ProcessInfo.processInfo.arguments.contains("-lab-ui-test"),
           let preferences = UserDefaults(suiteName: "TVRemoteLabUITests") {
            preferences.removePersistentDomain(forName: "TVRemoteLabUITests")
            let connection = RemoteViewModel(live: LiveTVSession(defaults: preferences, credentials: MemoryCredentialStore()))
            connection.approvalResponseDelay = .seconds(3)
            return connection
        }
        #endif
        return RemoteViewModel(live: LiveTVSession())
    }

    @ViewBuilder private var appRoot: some View {
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-design-screen"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
           let number = Int(ProcessInfo.processInfo.arguments[index + 1]),
           DesignSpec.allCases.indices.contains(number) {
            DesignStateHost(spec: DesignSpec.allCases[number],
                            appearance: ProcessInfo.processInfo.arguments.contains("Dark") ? .dark : .light)
        } else {
            RootScreen()
        }
        #else
        RootScreen()
        #endif
    }
}
