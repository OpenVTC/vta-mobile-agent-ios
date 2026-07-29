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
    /// The VTA binds the approve-response's `issuer` to the proven sender
    /// (`auth.did == issuer`), and this device always signs as its own holder —
    /// so `transport` must be this holder's own session. The VTA then elevates
    /// the subject's session when this holder is the subject (**self**) or the
    /// subject's authorized **delegated** approver.
    @discardableResult
    public static func approveStepUp(
        approveRequest: String,
        transport: VtaTransport,
        vtaDid: String,
        identity: HolderIdentity,
        trustedIssuers: [String]
    ) async throws -> StepUpOutcome {
        let requestDoc = Self.unwrapApproveRequest(approveRequest)
        let request = try await parseStepUpRequest(
            json: requestDoc, trustedIssuers: trustedIssuers)

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

        let body = try await transport.submit(responseDoc)

        // The success `#response` payload echoes the elevated session's acr.
        let acr = Self.jsonString(in: body, path: ["payload", "session", "acr"])
            ?? request.targetAcr
        return StepUpOutcome(grantedAcr: acr, sessionId: request.sessionId)
    }

    /// Outcome of a signed **denial**.
    public struct DenyOutcome {
        public let sessionId: String
        public let reason: String
    }

    /// **Decline** a step-up described by `approveRequest`: post a holder-signed
    /// `decision: denied` approve-response carrying `reason`. The VTA verifies
    /// the did-signed gate (so a refusal can't be forged), audits `step_up_denied`,
    /// and elevates nothing. This is how the operator says *no* from the device.
    @discardableResult
    public static func denyStepUp(
        approveRequest: String,
        reason: String,
        transport: VtaTransport,
        vtaDid: String,
        identity: HolderIdentity,
        trustedIssuers: [String]
    ) async throws -> DenyOutcome {
        let requestDoc = Self.unwrapApproveRequest(approveRequest)
        let request = try await parseStepUpRequest(
            json: requestDoc, trustedIssuers: trustedIssuers)

        let draft = ApproveResponseDraft(
            id: "urn:uuid:\(UUID().uuidString)",
            issuerDid: identity.didKey,
            recipientDid: vtaDid,
            issuedAt: ISO8601DateFormatter().string(from: Date()),
            subject: request.subject,
            sessionId: request.sessionId,
            challenge: request.challenge,
            grantedAcr: nil)  // a denial elevates nothing
        let responseDoc = try buildApproveResponseDenied(
            draft: draft, reason: reason, signer: identity)

        _ = try await transport.submit(responseDoc)
        return DenyOutcome(sessionId: request.sessionId, reason: reason)
    }

    /// Whether an incoming step-up should be **shown to the operator for consent**
    /// rather than auto-ratified. A step-up that carries a structured
    /// authorization context (a Cierge share / spend / tool ask) always prompts —
    /// the human must see *what* they authorize. A plain login-elevation step-up
    /// (no context) may be auto-approved for a frictionless sign-in.
    public static func requiresReview(_ review: StepUpReview) -> Bool {
        review.authorizationContext != nil
    }

    // `demoSelfStepUp` is gone with REST. It worked by poking an AAL2-gated
    // endpoint (`POST /acl`) with an AAL1 token so the `RequireStepUp` extractor
    // would answer `403` with an approve-request for our own session — a
    // challenge carried by an *HTTP status*, which the messaging transports have
    // no equivalent for. Exercise the loop end-to-end instead by triggering a
    // delegated step-up at the VTA and letting it push the request to this
    // device, which is the path a real sign-in takes anyway.

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
