import Foundation
import TVRemoteCore

public struct GoogleTVPublicKey: Sendable, Equatable, Codable {
    public let modulus: Data
    public let exponent: Data

    public init(modulus: Data, exponent: Data) {
        self.modulus = modulus
        self.exponent = exponent
    }
}

public struct GoogleTVClientIdentity: Sendable, Equatable, Codable {
    public let privateKey: Data
    public let certificate: Data
    public let publicKey: GoogleTVPublicKey

    public init(privateKey: Data, certificate: Data, publicKey: GoogleTVPublicKey) {
        self.privateKey = privateKey
        self.certificate = certificate
        self.publicKey = publicKey
    }
}

public enum GoogleTVTLSMode: Sendable, Equatable {
    case probe
    case pairing(GoogleTVClientIdentity)
    case control(GoogleTVClientIdentity, peer: GoogleTVPublicKey)
}

public struct GoogleTVTLSConnection: Sendable {
    public let stream: any TLSByteStream
    public let peer: GoogleTVPublicKey
    public let deviceName: String?

    public init(stream: any TLSByteStream, peer: GoogleTVPublicKey, deviceName: String? = nil) {
        self.stream = stream
        self.peer = peer
        self.deviceName = deviceName
    }
}

public protocol GoogleTVTLSTransport: Sendable {
    func makeClientIdentity() async throws -> GoogleTVClientIdentity
    func open(_ endpoint: TVEndpoint, mode: GoogleTVTLSMode) async throws -> GoogleTVTLSConnection
}

public typealias GoogleTVDigest = @Sendable (Data) -> Data

struct GoogleTVPairingCredential: Sendable, Equatable, Codable {
    let identity: GoogleTVClientIdentity
    let peer: GoogleTVPublicKey
}
