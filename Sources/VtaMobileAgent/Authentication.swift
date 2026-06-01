import Foundation
import VtaMobileCore

/// The agent's REST authentication flow against a VTA, composed from the engine
/// primitives. The engine builds + signs the Trust Task documents (the holder
/// key never leaves the device, via the `Signer`); this layer just moves them
/// over HTTP and hands the responses back to the engine to parse.
extension VtaMobileAgent {
    /// Run challenge → authenticate and return the issued tokens.
    ///
    /// 1. `build_auth_challenge` → POST `/auth/challenge` → `parse_auth_challenge_response`
    /// 2. `build_authenticate` (holder-signed via `identity`) → POST `/auth/`
    ///    → `parse_authenticate_response`
    ///
    /// `identity.didKey` must be enrolled in the VTA's ACL first
    /// (`pnm acl create --did <did:key> …`), or the VTA rejects the challenge.
    public static func authenticate(
        vtaURL: URL,
        vtaDid: String,
        identity: HolderIdentity
    ) async throws -> AuthTokens {
        let client = VtaRestClient(baseURL: vtaURL)

        // 1. Request a challenge for our holder DID.
        let challengeDoc = try buildAuthChallenge(
            env: envelope(holder: identity.didKey, vtaDid: vtaDid),
            subject: identity.didKey,
            purpose: nil)
        let challengeResponse = try await client.post(path: "/auth/challenge", body: challengeDoc)
        let challenge = try parseAuthChallengeResponse(json: challengeResponse)

        // 2. Present the challenge inside a holder-signed authenticate document
        //    (the proof IS the authentication).
        let authenticateDoc = try buildAuthenticate(
            env: envelope(holder: identity.didKey, vtaDid: vtaDid),
            challenge: challenge.challenge,
            sessionId: challenge.sessionId,
            scope: [],
            signer: identity)
        let authResponse = try await client.post(path: "/auth/", body: authenticateDoc)
        return try parseAuthenticateResponse(json: authResponse)
    }

    /// Introspect the current session (live `acr`/`amr` + roles/scopes) via the
    /// authenticated trust-task dispatcher. Bearer = the access token from
    /// [`authenticate`].
    public static func whoami(
        vtaURL: URL,
        vtaDid: String,
        identity: HolderIdentity,
        accessToken: String
    ) async throws -> SessionInfo {
        let client = VtaRestClient(baseURL: vtaURL)
        let doc = try buildWhoami(
            env: envelope(holder: identity.didKey, vtaDid: vtaDid),
            signer: identity)
        let response = try await client.post(
            path: "/api/trust-tasks", body: doc, bearer: accessToken)
        return try parseWhoamiResponse(json: response)
    }

    /// A fresh document envelope. `issuedAt` is "now" (RFC 3339) — also the
    /// authenticate proof's `created`, which the VTA rejects if future-dated.
    private static func envelope(holder: String, vtaDid: String) -> AuthEnvelope {
        AuthEnvelope(
            id: "urn:uuid:\(UUID().uuidString)",
            holderDid: holder,
            vtaDid: vtaDid,
            issuedAt: ISO8601DateFormatter().string(from: Date()))
    }
}
