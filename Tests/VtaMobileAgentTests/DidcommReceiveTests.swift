import CryptoKit
import VtaMobileCore
import XCTest

@testable import VtaMobileAgent

/// Exercises the inbound DIDComm receive primitive on the engine binding: pack
/// an authcrypt message "VTA → holder" and unpack it on the holder side,
/// proving the v0.2.1 (didcomm 0.15) engine round-trips through the FFI. Plus
/// the `isStepUpApproveRequest` plaintext filter.
final class DidcommReceiveTests: XCTestCase {
    /// Engine `HolderKeys` for a fresh Ed25519 identity (no Keychain).
    private func makeKeys() throws -> (keys: HolderKeys, did: String) {
        let sk = Curve25519.Signing.PrivateKey()
        let did = HolderIdentity.deriveDidKey(sk.publicKey)
        let keys = try didcommHolderKeys(did: did, signingPrivateEd25519: sk.rawRepresentation)
        return (keys, did)
    }

    /// A `Peer` (public key-agreement) for a counterparty to register, derived
    /// from the keyset's private X25519.
    private func peer(for keys: HolderKeys) throws -> Peer {
        let priv = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: keys.keyAgreementPrivateX25519)
        return Peer(
            did: keys.did,
            keyAgreementKid: keys.keyAgreementKid,
            keyAgreementPublicX25519: priv.publicKey.rawRepresentation)
    }

    func testAuthcryptRoundTripUnpacks() throws {
        let (vtaKeys, vtaDid) = try makeKeys()
        let (holderKeys, holderDid) = try makeKeys()

        // VTA side packs a DIDComm message carrying the approve-request in
        // `body` to the holder.
        let vtaSession = try DidcommSession(holder: vtaKeys)
        try vtaSession.addPeer(peer: peer(for: holderKeys))
        let message =
            #"{"id":"urn:uuid:msg","type":"https://didcomm.org/trust-task/1.0/task","body":{"type":"https://trusttasks.org/spec/auth/step-up/approve-request/0.1","id":"urn:uuid:abc","payload":{"subject":"\#(holderDid)","sessionId":"s1","challenge":"chal","targetAcr":"aal2"}}}"#
        let packed = try vtaSession.packAuthcrypt(messageJson: message, recipientDid: holderDid)

        // Holder side unpacks it (authenticating the VTA as sender).
        let holderSession = try DidcommSession(holder: holderKeys)
        try holderSession.addPeer(peer: peer(for: vtaKeys))
        let unpacked = try holderSession.unpack(packed: packed, senderDid: vtaDid)

        XCTAssertTrue(unpacked.senderAuthenticated, "authcrypt must authenticate the sender")
        // The approve-request round-trips inside the DIDComm `body`.
        let body = try XCTUnwrap(
            VtaMobileAgent.didcommBody(unpacked.messageJson),
            "unpacked message should have a body: \(unpacked.messageJson)")
        XCTAssertTrue(
            VtaMobileAgent.isStepUpApproveRequest(body),
            "the body should be the approve-request: \(body)")
    }

    func testIsStepUpApproveRequestFilters() {
        XCTAssertTrue(
            VtaMobileAgent.isStepUpApproveRequest(
                #"{"type":"https://trusttasks.org/spec/auth/step-up/approve-request/0.1"}"#))
        XCTAssertFalse(
            VtaMobileAgent.isStepUpApproveRequest(
                #"{"type":"https://trusttasks.org/spec/auth/whoami/0.1"}"#))
        XCTAssertFalse(VtaMobileAgent.isStepUpApproveRequest("not json"))
    }
}
