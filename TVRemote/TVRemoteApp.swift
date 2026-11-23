import SwiftUI

@main
struct TVRemoteApp: App {
    @State private var connection = ConnectionManager(driver: MockTVDriver(), isDemo: true)

    var body: some Scene {
        WindowGroup {
            appRoot
                .environment(connection)
                .tint(RemoteTheme.accent)
        }
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
