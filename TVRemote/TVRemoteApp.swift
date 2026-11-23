import SwiftUI

@main
struct TVRemoteApp: App {
    @State private var connection = ConnectionManager(driver: MockTVDriver(), isDemo: true)

    var body: some Scene {
        WindowGroup {
            RootScreen()
                .environment(connection)
                .tint(RemoteTheme.accent)
        }
    }
}
