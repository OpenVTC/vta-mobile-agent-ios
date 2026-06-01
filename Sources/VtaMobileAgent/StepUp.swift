import Foundation
import VtaMobileCore

/// AAL1 → AAL2 **step-up approver**: the device holds the holder key, so it can
/// ratify a step-up for any of that holder's sessions — including one running
/// on another device (a desktop hits a gated op, gets a `403` carrying an
/// `auth/step-up/approve-request/0.1`, and relays it here out-of-band). The
/// engine builds the holder-signed `approve-response` (did-signed gate; the key
/// never leaves the device); the VTA consumes it and elevates that session.
extension VtaMobileAgent {
    /// Outcome of submitting an approve-response.
    public struct StepUpOutcome {
        /// `acr` the VTA reports for the elevated session (e.g. `"aal2"`).
        public let grantedAcr: String?
        /// The session that was elevated.
        public let sessionId: String
    }

    /// Approve a step-up described by `approveRequest` (either the bare
    /// `auth/step-up/approve-request/0.1` document, or a VTA `403` body that
    /// carries it under `approveRequest`). Posts the holder-signed
    /// approve-response and returns the granted assurance level.
    ///
    /// `accessToken` must be a token for *this holder's* session — the VTA only
    /// lets the subject elevate their own sessions (`auth.did == subject`).
    @discardableResult
    public static func approveStepUp(
        approveRequest: String,
        vtaURL: URL,
        vtaDid: String,
        identity: HolderIdentity,
        accessToken: String
    ) async throws -> StepUpOutcome {
        let requestDoc = Self.unwrapApproveRequest(approveRequest)
        let request = try parseStepUpRequest(json: requestDoc)

        // We can only sign the did-signed gate for our own holder key.
        guard request.subject == identity.didKey else {
            throw AgentError.badResponse(
                "approve-request is for a different holder (\(request.subject)); "
                    + "this device holds \(identity.didKey)")
        }

        let draft = ApproveResponseDraft(
            id: "urn:uuid:\(UUID().uuidString)",
            issuerDid: identity.didKey, // the subject (us) issues + signs
            recipientDid: vtaDid,
            issuedAt: ISO8601DateFormatter().string(from: Date()),
            subject: request.subject,
            sessionId: request.sessionId,
            challenge: request.challenge,
            grantedAcr: request.targetAcr ?? "aal2")
        let responseDoc = try buildApproveResponseDidSigned(draft: draft, signer: identity)

        let client = VtaRestClient(baseURL: vtaURL)
        let body = try await client.post(
            path: "/api/trust-tasks", body: responseDoc, bearer: accessToken)

        // The success `#response` payload echoes the elevated session's acr.
        let acr = Self.jsonString(in: body, path: ["payload", "session", "acr"])
            ?? request.targetAcr
        return StepUpOutcome(grantedAcr: acr, sessionId: request.sessionId)
    }

    /// Self-contained demo: provoke a step-up on *this device's own* session by
    /// poking an AAL2-gated endpoint with the AAL1 token, then approve it.
    /// Returns the granted acr (expected `"aal2"`). Handy to exercise the whole
    /// loop without a second device.
    ///
    /// The `RequireStepUp` extractor fires before the route handler, so the
    /// probe `POST /acl` never creates anything — it just yields the `403`
    /// carrying the approve-request for our session.
    @discardableResult
    public static func demoSelfStepUp(
        vtaURL: URL,
        vtaDid: String,
        identity: HolderIdentity,
        accessToken: String
    ) async throws -> StepUpOutcome {
        let client = VtaRestClient(baseURL: vtaURL)
        let (status, body) = try await client.postRaw(
            path: "/acl", body: "{}", bearer: accessToken)
        guard status == 403, Self.unwrapApproveRequest(body) != body || body.contains("approveRequest")
        else {
            throw AgentError.badResponse(
                "expected a 403 step-up challenge from the gated endpoint, got HTTP \(status): \(body)")
        }
        return try await approveStepUp(
            approveRequest: body, vtaURL: vtaURL, vtaDid: vtaDid,
            identity: identity, accessToken: accessToken)
    }

    /// If `input` is a VTA `403` body `{ "approveRequest": {…} }`, return the
    /// embedded document; otherwise return `input` unchanged (already a bare
    /// approve-request document).
    static func unwrapApproveRequest(_ input: String) -> String {
        guard
            let data = input.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let inner = obj["approveRequest"],
            let innerData = try? JSONSerialization.data(withJSONObject: inner),
            let innerString = String(data: innerData, encoding: .utf8)
        else {
            return input
        }
        return innerString
    }

    /// Pull a nested string value out of a JSON object body, or `nil`.
    private static func jsonString(in body: String, path: [String]) -> String? {
        guard let data = body.data(using: .utf8),
            var node = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in path.dropLast() {
            guard let next = node[key] as? [String: Any] else { return nil }
            node = next
        }
        return node[path.last ?? ""] as? String
    }
}
