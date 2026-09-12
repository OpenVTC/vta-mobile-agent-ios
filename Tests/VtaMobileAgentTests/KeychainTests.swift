import Foundation
import XCTest

@testable import VtaMobileAgent

/// How the holder signing key is stored.
///
/// The inverse of the original finding: the item used to go in with no
/// accessibility class and no access control, so it took the keychain's default
/// (`kSecAttrAccessibleWhenUnlocked`) — which travels in an encrypted backup and
/// can be restored onto a different device — and it was written by deleting the
/// old item before adding the new one.
final class KeychainTests: XCTestCase {
    private let account = "holder-ed25519"
    private let seed = Data(repeating: 0x00, count: 32)
    /// Device-bound, excluded from backups and migration, still readable after
    /// the first unlock so a background push wake works while locked.
    private let deviceBound = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    private func accessibility(_ attributes: [String: Any]) -> String? {
        attributes[kSecAttrAccessible as String] as? String
    }

    private func synchronizable(_ attributes: [String: Any]) -> Bool? {
        (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue
    }

    // MARK: Attributes

    func testAddAttributesAreDeviceBound() {
        let attributes = Keychain.addAttributes(account: account, data: seed)

        XCTAssertEqual(accessibility(attributes), deviceBound)
        XCTAssertEqual(synchronizable(attributes), false)
    }

    /// `kSecAttrAccessControl` is **deliberately absent**, and this test exists
    /// to stop it being "fixed" back in. An ACL on this item would gate reading
    /// the seed, which happens once per launch: it would prompt on every cold
    /// start, fail outright on a background push wake while the device is
    /// locked, and still leave every later signature unprompted, because the
    /// engine holds the seed for the session. Presence per approval is
    /// `ApprovalGate`'s job instead.
    func testAddAttributesOmitAccessControl() {
        let attributes = Keychain.addAttributes(account: account, data: seed)

        XCTAssertNil(attributes[kSecAttrAccessControl as String])
    }

    func testAddAttributesIdentifyTheOneItemAndCarryTheKey() {
        let attributes = Keychain.addAttributes(account: account, data: seed)

        XCTAssertEqual(
            attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, account)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, seed)
    }

    // MARK: Writing

    func testWriteAddsTheItem() throws {
        let keychain = FakeKeychain()

        try Keychain.write(account: account, data: seed, backend: keychain.backend)

        XCTAssertEqual(keychain.added.count, 1)
        XCTAssertEqual(keychain.added[0][kSecValueData as String] as? Data, seed)
        XCTAssertEqual(accessibility(keychain.added[0]), deviceBound)
        XCTAssertTrue(keychain.updated.isEmpty)
    }

    /// An item already there is updated in place. Nothing is deleted first, so a
    /// failed write can never leave the device without its identity —
    /// `KeychainBackend` has no delete to call.
    func testWriteUpdatesAnExistingItemInsteadOfDeletingIt() throws {
        let keychain = FakeKeychain()
        keychain.addStatus = errSecDuplicateItem

        try Keychain.write(account: account, data: seed, backend: keychain.backend)

        XCTAssertEqual(keychain.updated.count, 1)
        XCTAssertEqual(keychain.updated[0].query[kSecAttrAccount as String] as? String, account)
        XCTAssertEqual(keychain.updated[0].attributes[kSecValueData as String] as? Data, seed)
        XCTAssertEqual(accessibility(keychain.updated[0].attributes), deviceBound)
    }

    func testWriteSurfacesAnUnexpectedStatus() {
        let keychain = FakeKeychain()
        keychain.addStatus = errSecMissingEntitlement

        XCTAssertThrowsError(
            try Keychain.write(account: account, data: seed, backend: keychain.backend)
        ) { error in
            guard case .keychain(let status) = error as? AgentError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(status, errSecMissingEntitlement)
        }
    }

    // MARK: Migration of an item stored by an earlier build

    func testReadUpgradesTheProtectionOfAnExistingItem() throws {
        let keychain = FakeKeychain()
        keychain.stored = seed

        XCTAssertEqual(try Keychain.read(account: account, backend: keychain.backend), seed)

        XCTAssertEqual(keychain.updated.count, 1)
        let (query, attributes) = keychain.updated[0]
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, account)
        XCTAssertNil(query[kSecReturnData as String], "an update must not ask for the data back")
        XCTAssertEqual(accessibility(attributes), deviceBound)
        XCTAssertEqual(synchronizable(attributes), false)
        XCTAssertNil(attributes[kSecValueData as String], "the seed itself is not rewritten")
    }

    /// A locked device (a background push wake) can read the item but not
    /// rewrite its attributes. The read still succeeds and the upgrade waits for
    /// the next foreground read.
    func testReadSucceedsWhenTheUpgradeIsRefusedBecauseTheDeviceIsLocked() throws {
        let keychain = FakeKeychain()
        keychain.stored = seed
        keychain.updateStatus = errSecInteractionNotAllowed

        XCTAssertEqual(try Keychain.read(account: account, backend: keychain.backend), seed)

        XCTAssertEqual(keychain.updated.count, 1, "no retry while the device is locked")
    }

    /// If an OS refuses to change `kSecAttrSynchronizable` in an update, the
    /// accessibility — the attribute that keeps the key out of backups — is
    /// still applied on its own.
    func testUpgradeFallsBackToAccessibilityAlone() throws {
        let keychain = FakeKeychain()
        keychain.stored = seed
        keychain.updateStatus = errSecParam

        XCTAssertEqual(try Keychain.read(account: account, backend: keychain.backend), seed)

        XCTAssertEqual(keychain.updated.count, 2)
        XCTAssertEqual(accessibility(keychain.updated[1].attributes), deviceBound)
        XCTAssertNil(keychain.updated[1].attributes[kSecAttrSynchronizable as String])
    }

    func testReadOfAMissingItemIsNilAndUpgradesNothing() throws {
        let keychain = FakeKeychain()

        XCTAssertNil(try Keychain.read(account: account, backend: keychain.backend))

        XCTAssertTrue(keychain.updated.isEmpty)
    }

    func testReadSurfacesAnUnexpectedStatus() {
        let keychain = FakeKeychain()
        keychain.copyStatus = errSecMissingEntitlement

        XCTAssertThrowsError(try Keychain.read(account: account, backend: keychain.backend))
    }
}

/// A stand-in keychain. The real one is unavailable to a package test bundle
/// (`errSecMissingEntitlement`, -34018), which is why `KeychainBackend` exists.
private final class FakeKeychain {
    var stored: Data?
    var copyStatus: OSStatus?
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess

    var added: [[String: Any]] = []
    var updated: [(query: [String: Any], attributes: [String: Any])] = []

    var backend: KeychainBackend {
        KeychainBackend(
            copyMatching: { [self] _, result in
                if let copyStatus { return copyStatus }
                guard let stored else { return errSecItemNotFound }
                result = stored as CFTypeRef
                return errSecSuccess
            },
            add: { [self] attributes in
                added.append(attributes)
                if addStatus == errSecSuccess {
                    stored = attributes[kSecValueData as String] as? Data
                }
                return addStatus
            },
            update: { [self] query, attributes in
                updated.append((query, attributes))
                return updateStatus
            })
    }
}
