import Foundation
import VtaMobileCore

/// Session introspection over a messaging transport.
///
/// **There is no `authenticate` step any more.** The REST flow was
/// challenge → holder-signed `authenticate` → bearer token → present that token
/// on every later call. Over DIDComm/TSP every document carries the holder's own
/// proof, which the VTA requires to verify as the document's `issuer` and binds
/// to the transport sender before it derives the caller's role, contexts and
/// session from that DID. Possession of the holder key **is** the credential,
/// so there is nothing to exchange up front and nothing to refresh before it
/// expires.
///
/// What "connecting" means now is simply: the mediator inbox is open. `whoami`
/// is how the app confirms the VTA agrees — it is a liveness probe and an
/// identity check in one, and it returns the live `acr`/`amr` the UI shows.
extension VtaMobileAgent {
    /// Introspect this device's session at the VTA: live `acr`/`amr`, roles and
    /// scopes. Doubles as the post-connect handshake check — a successful
    /// response proves the mediator round trip works *and* that this holder's
    /// `did:key` is enrolled in the VTA's ACL.
    ///
    /// An ACL miss surfaces here as a rejection rather than as the old REST
    /// `401`: the VTA refuses to derive claims for an unknown DID, so this is
    /// the first place a device that was never enrolled will fail.
    public static func whoami(
        transport: VtaTransport,
        vtaDid: String,
        identity: HolderIdentity
    ) async throws -> SessionInfo {
        let doc = try buildWhoami(
            env: envelope(holder: identity.didKey, vtaDid: vtaDid),
            signer: identity)
        let response = try await transport.submit(doc)
        return try parseWhoamiResponse(json: response)
    }

    /// Announce this device's TSP reachability to the VTA: a holder-signed
    /// `messaging/ping/0.1`, routed through `mediatorDid`. The VTA records the
    /// proven sender of any inbound TSP frame as TSP-reachable (learn-from-inbound)
    /// and answers the ping; the pong arrives on the inbox as unsolicited traffic
    /// and is ignored there.
    ///
    /// Signed like every other document: the VTA refuses an unsigned one with
    /// `proofRequired`, which is what the engine's old unsigned `announce` got.
    public static func announceTsp(
        session: TspMediatorSession,
        vtaDid: String,
        mediatorDid: String,
        identity: HolderIdentity
    ) async throws {
        let ping = try buildMessagingPing(
            env: envelope(holder: identity.didKey, vtaDid: vtaDid),
            signer: identity)
        try await session.sendTrustTask(vtaDid: vtaDid, mediatorDid: mediatorDid, docJson: ping)
    }

    /// A fresh document envelope. `issuedAt` is "now" (RFC 3339) — also the
    /// proof's `created`, which the VTA rejects if future-dated.
    static func envelope(holder: String, vtaDid: String) -> AuthEnvelope {
        AuthEnvelope(
            id: "urn:uuid:\(UUID().uuidString)",
            holderDid: holder,
            vtaDid: vtaDid,
            issuedAt: ISO8601DateFormatter().string(from: Date()))
    }
}
