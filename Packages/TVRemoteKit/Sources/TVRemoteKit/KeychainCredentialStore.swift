#if canImport(Security)
import Foundation
import Security

public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "TVRemoteKit.credentials") {
        self.service = service
    }

    public func load(for identity: TVIdentity) throws -> Credential? {
        var query = item(for: identity)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw TVError.invalidResponse }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    public func save(_ credential: Credential, for identity: TVIdentity) throws {
        let data = try JSONEncoder().encode(credential)
        let query = item(for: identity)
        var entry = query
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            try check(SecItemUpdate(query as CFDictionary, update as CFDictionary))
        } else {
            try check(status)
        }
    }

    public func remove(for identity: TVIdentity) throws {
        let status = SecItemDelete(item(for: identity) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func item(for identity: TVIdentity) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(identity.platform.rawValue):\(identity.identifier)"
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw TVError.credentialStoreFailure(status: Int(status)) }
    }
}
#endif
