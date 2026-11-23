import Foundation
import TVRemoteCore

enum GoogleTVPairing {
    private static let hexEncoding = Proto([(1, .number(3)), (2, .number(6))])

    static func exchange(
        wire: GoogleTVWire,
        clientName: String,
        identity: GoogleTVClientIdentity,
        peer: GoogleTVPublicKey,
        digest: GoogleTVDigest,
        prompt: PairingPromptHandler
    ) async throws {
        try await send(wire, field: 10, message: Proto([
            (1, Proto.string("atvremote")), (2, Proto.string(clientName))
        ]))
        _ = try await receive(wire, field: 11)
        try await send(wire, field: 20, message: Proto([(1, Proto.message(hexEncoding)), (3, .number(1))]))
        let options = try await receive(wire, field: 20)
        let encodings = try options.byteValues(2).map(Proto.init(decoding:))
        guard encodings.contains(where: { $0.number(1) == 3 && $0.number(2) == 6 }) else {
            throw TVError.notSupported
        }
        try await send(wire, field: 30, message: Proto([(1, Proto.message(hexEncoding)), (2, .number(1))]))
        _ = try await receive(wire, field: 31)
        guard case .code(let code) = try await prompt(.enterCode(length: 6)) else {
            throw TVError.pairingRequired
        }
        let bytes = Array(code.utf8)
        guard bytes.count == 6,
              bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let checksum = UInt8(String(decoding: bytes.prefix(2), as: UTF8.self), radix: 16),
              let nonce = UInt16(String(decoding: bytes.suffix(4), as: UTF8.self), radix: 16) else {
            throw TVError.credentialRejected
        }
        let secret = digest(identity.publicKey.modulus + identity.publicKey.exponent + peer.modulus + peer.exponent
                            + Data([UInt8(nonce >> 8), UInt8(truncatingIfNeeded: nonce)]))
        guard secret.count == 32, secret.first == checksum else { throw TVError.credentialRejected }
        try await send(wire, field: 40, message: Proto([(1, .bytes(secret))]))
        let acknowledgement = try await receive(wire, field: 41)
        guard acknowledgement.byteValues(1).last == secret else { throw TVError.credentialRejected }
    }

    private static func send(_ wire: GoogleTVWire, field: Int, message: Proto) async throws {
        try await wire.send(Proto([(1, .number(2)), (2, .number(200)), (field, Proto.message(message))]))
    }

    private static func receive(_ wire: GoogleTVWire, field: Int) async throws -> Proto {
        let response = try await wire.read()
        guard response.number(1) == 2, let status = response.number(2) else { throw TVError.invalidResponse }
        switch status {
        case 200: break
        case 400 where field == 11: throw TVError.pairingDeclined
        case 402: throw TVError.credentialRejected
        case 401: throw TVError.notSupported
        default: throw TVError.invalidResponse
        }
        guard let payload = try response.message(field) else { throw TVError.invalidResponse }
        return payload
    }
}
