import Foundation
@_exported import RokuDriver
@_exported import TVRemoteCore

public enum TVRemoteKit {
    public static func makeRokuManager(
        discovery: any DiscoverySource = LocalDiscoverySource(),
        credentials: any CredentialStore = defaultCredentialStore(),
        clock: any ConnectionClock = SystemConnectionClock()
    ) -> ConnectionManager {
        ConnectionManager(
            drivers: [
                TVDriverFactory(platform: .roku) {
                    RokuECPDriver(http: URLSessionHTTPTransport(), discovery: discovery)
                }
            ],
            credentials: credentials,
            clock: clock
        )
    }

    public static func defaultCredentialStore() -> any CredentialStore {
        #if canImport(Security)
        KeychainCredentialStore()
        #else
        MemoryCredentialStore()
        #endif
    }
}
