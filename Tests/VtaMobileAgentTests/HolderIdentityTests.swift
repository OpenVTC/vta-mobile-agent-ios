import CryptoKit
import XCTest

@testable import VtaMobileAgent

/// Unit tests for the agent's custom crypto plumbing — the Base58 encoder and
/// the Ed25519 `did:key` derivation. (The full REST auth flow is exercised
/// manually against a live VTA; the Keychain-backed `HolderIdentity.loadOrCreate`
/// needs a host app, so it isn't unit-tested here.)
final class HolderIdentityTests: XCTestCase {
    func testBase58KnownVectors() {
        XCTAssertEqual(Base58.encode([]), "")
        XCTAssertEqual(Base58.encode([0x00]), "1") // leading zero → '1'
        XCTAssertEqual(Base58.encode([0x00, 0x00]), "11")
        XCTAssertEqual(Base58.encode([0xff]), "5Q")
    }

    func testDidKeyIsEd25519Multibase() {
        // Deterministic key from a fixed seed.
        let seed = Data(repeating: 7, count: 32)
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)

        let did = HolderIdentity.deriveDidKey(key.publicKey)

        // Ed25519 did:keys are multibase-base58btc of a `0xed01`-tagged key,
        // which always renders with the `z6Mk` prefix.
        XCTAssertTrue(did.hasPrefix("did:key:z6Mk"), "unexpected did:key: \(did)")
        // Derivation is a pure function of the public key.
        XCTAssertEqual(did, HolderIdentity.deriveDidKey(key.publicKey))
    }

    func testDistinctKeysYieldDistinctDids() {
        let a = Curve25519.Signing.PrivateKey()
        let b = Curve25519.Signing.PrivateKey()
        XCTAssertNotEqual(
            HolderIdentity.deriveDidKey(a.publicKey),
            HolderIdentity.deriveDidKey(b.publicKey))
    }
}
