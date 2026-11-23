#if canImport(Security)
import Foundation
import Security

enum GoogleTVClientCertificate {
    private static let publicKeyAlgorithm = DER.sequence(Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]))
    private static let signatureAlgorithm = DER.sequence(Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00]))

    static func create() throws -> GoogleTVClientIdentity {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(key),
              let keyBytes = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw TVError.invalidResponse
        }
        let name = DER.sequence(DER.field(0x31, DER.sequence(
            Data([0x06, 0x03, 0x55, 0x04, 0x03]) + DER.field(0x0C, Data("TVRemote".utf8))
        )))
        let now = Date()
        let validity = DER.sequence(DER.time(now.addingTimeInterval(-86_400)) + DER.time(now.addingTimeInterval(157_680_000)))
        let publicKeyInfo = DER.sequence(publicKeyAlgorithm + DER.field(0x03, Data([0]) + publicBytes))
        let serial = Data(UUID().uuidString.replacingOccurrences(of: "-", with: "").utf8.prefix(18))
        let body = DER.sequence(DER.field(0x02, serial) + signatureAlgorithm + name + validity + name + publicKeyInfo)
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, body as CFData, nil) as Data? else {
            throw TVError.invalidResponse
        }
        let certificate = DER.sequence(body + signatureAlgorithm + DER.field(0x03, Data([0]) + signature))
        return GoogleTVClientIdentity(privateKey: keyBytes, certificate: certificate, publicKey: try parseRSA(publicBytes))
    }

    static func identity(from data: GoogleTVClientIdentity) throws -> SecIdentity {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let certificate = SecCertificateCreateWithData(nil, data.certificate as CFData),
              let key = SecKeyCreateWithData(data.privateKey as CFData, attributes as CFDictionary, nil),
              try publicKey(of: certificate) == data.publicKey,
              let identity = SecIdentityCreate(nil, certificate, key) else {
            throw TVError.credentialRejected
        }
        return identity
    }

    static func publicKey(of certificate: SecCertificate) throws -> GoogleTVPublicKey {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw TVError.invalidResponse
        }
        return try parseRSA(data)
    }

    private static func parseRSA(_ der: Data) throws -> GoogleTVPublicKey {
        var outer = DERReader(Array(der))
        var key = DERReader(try outer.take(0x30))
        let modulus = try key.take(0x02).drop(while: { $0 == 0 })
        let exponent = try key.take(0x02).drop(while: { $0 == 0 })
        guard outer.isAtEnd, key.isAtEnd, !modulus.isEmpty, !exponent.isEmpty else {
            throw TVError.invalidResponse
        }
        return GoogleTVPublicKey(modulus: Data(modulus), exponent: Data(exponent))
    }
}

private enum DER {
    static func sequence(_ body: Data) -> Data { field(0x30, body) }

    static func field(_ tag: UInt8, _ body: Data) -> Data {
        if body.count < 128 { return Data([tag, UInt8(body.count)]) + body }
        var length = UInt64(body.count).bigEndian
        let bytes = withUnsafeBytes(of: &length) { Data($0.drop(while: { $0 == 0 })) }
        return Data([tag, UInt8(0x80 | bytes.count)]) + bytes + body
    }

    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let year = formatter.calendar.component(.year, from: date)
        let usesUTCTime = (1950..<2050).contains(year)
        formatter.dateFormat = usesUTCTime ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return field(usesUTCTime ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
    }
}

private struct DERReader {
    private var index = 0
    private let bytes: [UInt8]

    var isAtEnd: Bool { index == bytes.count }

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func take(_ tag: UInt8) throws -> [UInt8] {
        guard try byte() == tag else { throw TVError.invalidResponse }
        let first = try byte()
        var count = Int(first)
        if first >= 0x80 {
            let lengthBytes = Int(first & 0x7F)
            guard (1...4).contains(lengthBytes) else { throw TVError.invalidResponse }
            count = 0
            for _ in 0..<lengthBytes { count = (count << 8) | Int(try byte()) }
        }
        guard count <= bytes.count - index else { throw TVError.invalidResponse }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    private mutating func byte() throws -> UInt8 {
        guard !isAtEnd else { throw TVError.invalidResponse }
        defer { index += 1 }
        return bytes[index]
    }
}
#endif
