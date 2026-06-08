import Foundation
import VtaMobileCore

/// AAL1 → AAL2 **step-up approver**: the device holds the holder key, so it can
/// ratify a step-up either for one of *its own* holder's sessions (**self** —
/// e.g. a desktop hits a gated op, gets a `403` carrying an
/// `auth/step-up/approve-request/0.1`, and relays it here out-of-band) or, as a
/// registered **delegated** approver, for *another* subject's session (the VTA
/// addresses the request to this device as that subject's `stepUp.approver`).
/// The engine builds the holder-signed `approve-response` (did-signed gate; the
/// key never leaves the device); the VTA verifies the gate against this holder's
/// key, authorizes the holder for the subject, and elevates the subject's
/// session.
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
    /// `accessToken` must be a token for *this holder's* session: the VTA binds
    /// the approve-response's `issuer` to the authenticated caller
    /// (`auth.did == issuer`), and this device always signs as its own holder.
    /// The VTA then elevates the subject's session when this holder is the
    /// subject (**self**) or the subject's authorized **delegated** approver.
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

        // Sign as ourselves — the holder key never leaves the device. When the
        // request's subject is us this is a *self* step-up (issuer == subject);
        // when it's a different VID we act as that subject's *delegated*
        // approver (issuer != subject). Either way we sign as
        // `issuerDid = our DID`; the VTA verifies the gate against this key and
        // authorizes us as the subject's approver before elevating, so there is
        // no holder-side subject restriction to enforce here.
        let draft = ApproveResponseDraft(
            id: "urn:uuid:\(UUID().uuidString)",
            issuerDid: identity.didKey, // the approver (us): self when == subject, delegated otherwise
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
