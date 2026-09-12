import Foundation
import Security

/// The Security-framework calls ``Keychain`` makes, behind closures so the
/// storage rules can be asserted without a keychain. A package test bundle has
/// no keychain-access-groups entitlement, so every real `SecItem…` call in one
/// fails with `errSecMissingEntitlement` (-34018) — the item itself is only ever
/// exercised by the app.
///
/// There is deliberately **no delete**: the holder key is stored with an add and
/// then an update, never a delete followed by an add, so a write that fails
/// can't leave the device with no identity.
public struct KeychainBackend {
    /// `SecItemCopyMatching`.
    public var copyMatching: (_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus
    /// `SecItemAdd` (the returned item is never wanted, so no `result`).
    public var add: (_ attributes: [String: Any]) -> OSStatus
    /// `SecItemUpdate`.
    public var update: (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus

    public init(
        copyMatching: @escaping (_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus,
        add: @escaping (_ attributes: [String: Any]) -> OSStatus,
        update: @escaping (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    ) {
        self.copyMatching = copyMatching
        self.add = add
        self.update = update
    }

    /// The device's real keychain.
    public static let system = KeychainBackend(
        copyMatching: { query, result in SecItemCopyMatching(query as CFDictionary, &result) },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) })
}

/// Minimal Keychain wrapper for a single generic-password item: the holder
/// Ed25519 seed.
///
/// **Protection class.** The item is stored
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and non-synchronizable, so
/// it is device-bound — excluded from encrypted backups, from device-to-device
/// migration and from iCloud Keychain — while staying readable after the first
/// unlock, which a background push wake on a locked phone needs in order to open
/// the mediator inbox. `WhenUnlockedThisDeviceOnly` would be stricter and would
/// break that wake; it is a product trade-off, not a code one.
///
/// **No `kSecAttrAccessControl`.** A biometric ACL here would gate *reading the
/// seed*, which happens once per launch: it would prompt on every cold start,
/// fail outright during a background wake while the device is locked, and still
/// leave every later signature unprompted, because the engine holds the seed for
/// the session and signs each message with it. User presence therefore belongs
/// on each approval, next to the decision the operator is actually making.
enum Keychain {
    private static let service = "org.openvtc.vta.agent"

    /// Identifies the one item — the query for a read, an update or an add.
    static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// How the item is protected. Applied when it is stored, and applied again
    /// to an item an earlier build stored without it (see
    /// ``upgradeProtection(account:backend:)``).
    static var protectionAttributes: [String: Any] {
        [
            // Device-bound and excluded from backups/migration, yet readable on
            // a locked background wake.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            // Never iCloud Keychain.
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    /// The exact attribute dictionary `SecItemAdd` receives. Pure, so the
    /// storage rules are assertable in a test.
    static func addAttributes(account: String, data: Data) -> [String: Any] {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        for (key, value) in protectionAttributes { attributes[key] = value }
        return attributes
    }

    static func read(account: String, backend: KeychainBackend = .system) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = backend.copyMatching(query, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AgentError.keychain(status)
        }
        // An item an earlier build stored carries the keychain's default
        // accessibility (`kSecAttrAccessibleWhenUnlocked`), which travels in an
        // encrypted backup. Upgrade it in place, best effort.
        upgradeProtection(account: account, backend: backend)
        return data
    }

    /// Store the holder key: `SecItemAdd`, falling back to `SecItemUpdate` on
    /// `errSecDuplicateItem`. Not delete-then-add — that loses the identity for
    /// good if the add then fails.
    static func write(account: String, data: Data, backend: KeychainBackend = .system) throws {
        let status = backend.add(addAttributes(account: account, data: data))
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw AgentError.keychain(status) }
        var attributes = protectionAttributes
        attributes[kSecValueData as String] = data
        let updated = backend.update(baseQuery(account: account), attributes)
        guard updated == errSecSuccess else { throw AgentError.keychain(updated) }
    }

    /// Bring an item stored by an earlier build up to the current protection
    /// class.
    ///
    /// Best effort by design. `errSecInteractionNotAllowed` means the device is
    /// locked — a background wake can read an `AfterFirstUnlock`-class item but
    /// not rewrite its attributes — so the upgrade is left for the next
    /// foreground read rather than treated as a failure. An OS that refuses to
    /// change `kSecAttrSynchronizable` in an update gets a second attempt with
    /// the accessibility alone, which is the attribute that matters for backups.
    @discardableResult
    static func upgradeProtection(account: String, backend: KeychainBackend = .system) -> OSStatus {
        let query = baseQuery(account: account)
        let status = backend.update(query, protectionAttributes)
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return status }
        return backend.update(
            query,
            [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly])
    }
}
