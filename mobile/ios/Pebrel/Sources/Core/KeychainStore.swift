import Foundation
import Security

/// Keychain storage for SSH host secrets, imported SSH private keys, and encrypted relay profiles.
final class KeychainStore {
    static let shared = KeychainStore()

    private let passwordService = "io.github.kuddev.pebrel.mobile.ssh.password"
    private let keyService = "io.github.kuddev.pebrel.mobile.ssh.key"
    private let relayService = "io.github.kuddev.pebrel.mobile.relay.profiles"
    private let savedIdsKey = "pebrel_saved_password_ids"

    private init() {}

    // MARK: - SSH Host Passwords / Key Passphrases

    func saveHostPassword(_ password: ZeroizedBytes, for hostId: String) -> Bool {
        let data = Data(password.copyBytes())
        let ok = writeSecret(data, service: passwordService, account: hostId)
        if ok {
            var ids = savedPasswordIds()
            ids.insert(hostId)
            persistSavedPasswordIds(ids)
        }
        return ok
    }

    func loadHostPassword(for hostId: String) -> ZeroizedBytes? {
        guard let data = readSecret(service: passwordService, account: hostId) else { return nil }
        return ZeroizedBytes([UInt8](data))
    }

    func deleteHostPassword(for hostId: String) {
        deleteSecret(service: passwordService, account: hostId)
        var ids = savedPasswordIds()
        ids.remove(hostId)
        persistSavedPasswordIds(ids)
    }

    func hasSavedPassword(for hostId: String) -> Bool {
        savedPasswordIds().contains(hostId) && readSecret(service: passwordService, account: hostId) != nil
    }

    func savedPasswordIds() -> Set<String> {
        let list = UserDefaults.standard.stringArray(forKey: savedIdsKey) ?? []
        return Set(list)
    }

    private func persistSavedPasswordIds(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: savedIdsKey)
    }

    // MARK: - SSH Private Key Material

    func savePrivateKey(_ data: Data, for keyId: String) -> Bool {
        guard data.count <= 65536 else { return false }
        return writeSecret(data, service: keyService, account: keyId)
    }

    func loadPrivateKey(for keyId: String) -> ZeroizedBytes? {
        guard let data = readSecret(service: keyService, account: keyId) else { return nil }
        return ZeroizedBytes([UInt8](data))
    }

    func deletePrivateKey(for keyId: String) {
        deleteSecret(service: keyService, account: keyId)
    }

    // MARK: - Saved Relay Profiles (contains PSK & bearer tokens -> stored in Keychain)

    func saveRelayProfilesJSON(_ data: Data) -> Bool {
        writeSecret(data, service: relayService, account: "profiles_v2")
    }

    func loadRelayProfilesJSON() -> Data? {
        readSecret(service: relayService, account: "profiles_v2")
    }

    // MARK: - Low-level Keychain helpers

    private func writeSecret(_ data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private func readSecret(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteSecret(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
