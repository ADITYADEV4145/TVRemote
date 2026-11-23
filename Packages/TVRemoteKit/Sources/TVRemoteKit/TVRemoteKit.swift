import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
@_exported import GoogleTVDriver
@_exported import RokuDriver
@_exported import TVRemoteCore

public enum TVRemoteKit {
    public static func makeManager(
        discovery: any DiscoverySource = LocalDiscoverySource(),
        credentials: any CredentialStore = defaultCredentialStore(),
        clock: any ConnectionClock = SystemConnectionClock()
    ) -> ConnectionManager {
        var drivers = [rokuFactory(discovery)]
        #if canImport(CryptoKit) && canImport(Network) && canImport(Security)
        let transport = NetworkGoogleTVTLSTransport()
        drivers.append(TVDriverFactory(platform: .googleTV) {
            GoogleTVRemoteDriver(transport: transport, discovery: discovery) { Data(SHA256.hash(data: $0)) }
        })
        #endif
        return ConnectionManager(drivers: drivers, credentials: credentials, clock: clock)
    }

    public static func makeRokuManager(
        discovery: any DiscoverySource = LocalDiscoverySource(),
        credentials: any CredentialStore = defaultCredentialStore(),
        clock: any ConnectionClock = SystemConnectionClock()
    ) -> ConnectionManager {
        ConnectionManager(
            drivers: [rokuFactory(discovery)],
            credentials: credentials,
            clock: clock
        )
    }

    private static func rokuFactory(_ discovery: any DiscoverySource) -> TVDriverFactory {
        TVDriverFactory(platform: .roku) {
            RokuECPDriver(http: URLSessionHTTPTransport(), discovery: discovery)
        }
    }

    public static func defaultCredentialStore() -> any CredentialStore {
        #if canImport(Security)
        KeychainCredentialStore()
        #else
        MemoryCredentialStore()
        #endif
    }
}
