import Foundation
import VtaMobileCore

/// Task-execution **consent approver**: the device acts as a second approving
/// device for a privileged Trust Task (e.g. a delegated `did:webvh` update). The
/// VTA pushes a signed `task-consent/request/0.1` to this device over DIDComm;
/// the operator sees *what executing the task would do* (the VTA's dry-run
/// effects) and a match code, and — behind a biometric — the device returns a
/// holder-signed `task-consent/decision/0.1`. The decision's Data Integrity
/// proof is the approver's authority: the VTA takes the signer from it and, if
/// the signer is a member of the policy's approver set (and, for a delegated
/// task, an admin of the DID's context), mints the single-use grant the
/// requester consumes.
///
/// Mirrors the step-up approver ([`approveStepUp`] / [`denyStepUp`]); the same
/// holder key signs both, and the private material never leaves the device.
extension VtaMobileAgent {
    /// Outcome of submitting a task-consent decision.
    public struct TaskConsentOutcome {
        /// The salted digest the decision was bound to (echoed from the request).
        public let payloadDigest: String
        /// The executor's status for this decision — `granted` once the approval
        /// threshold is met, else `pending`.
        public let status: String
    }

    /// Parse **and verify** an inbound `task-consent/request/0.1` (the DIDComm
    /// `body`) into the fields the approval UI shows — effects,
    /// side-effect/exposure class, the requester, and the match code.
    ///
    /// The engine verifies the request's `eddsa-jcs-2022` Data Integrity proof
    /// and that the proven signer is in `trustedIssuers` (the enrolled-executor
    /// allowlist) *before* returning anything. Throws
    /// `FfiError.UntrustedIssuer` for an unverifiable request — the caller MUST
    /// log and drop it without prompting the operator (spec rule: an
    /// unverifiable request MUST NOT prompt).
    public static func inspectTaskConsent(
        request doc: String, trustedIssuers: [String]
    ) async throws -> TaskConsentRequest {
        try await parseTaskConsentRequest(json: doc, trustedIssuers: trustedIssuers)
    }

    /// **Approve** the task described by `request` (a `task-consent/request/0.1`
    /// document — the DIDComm `body`): post a holder-signed `decision: approve`
    /// echoing the request's `challenge` + `payloadDigest`, and return the
    /// executor's status.
    ///
    /// The approver's authority is the decision proof, so this device always
    /// signs as its own holder DID. `transport` proves the *sender* to the VTA
    /// (authcrypt or TSP), which is what authorizes the submission — there is no
    /// bearer token.
    @discardableResult
    public static func approveTaskConsent(
        request doc: String,
        transport: VtaTransport,
        vtaDid: String,
        identity: HolderIdentity,
        trustedIssuers: [String]
    ) async throws -> TaskConsentOutcome {
        let request = try await parseTaskConsentRequest(json: doc, trustedIssuers: trustedIssuers)
        let draft = TaskConsentDecisionDraft(
            id: "urn:uuid:\(UUID().uuidString)",
            issuerDid: identity.didKey,  // the approver (us) — the proof carries our authority
            recipientDid: vtaDid,
            issuedAt: ISO8601DateFormatter().string(from: Date()),
            challenge: request.challenge,
            payloadDigest: request.payloadDigest)
        let decisionDoc = try buildTaskConsentDecisionDidSigned(draft: draft, signer: identity)

        let body = try await transport.submit(decisionDoc)
        let status = Self.taskConsentJSONString(in: body, path: ["payload", "status"]) ?? "granted"
        return TaskConsentOutcome(payloadDigest: request.payloadDigest, status: status)
    }

    /// **Decline** the task described by `request`: post a holder-signed
    /// `decision: deny` carrying `reason`. The VTA verifies the proof (so a
    /// refusal can't be forged), aborts the pending request, and nothing
    /// executes. This is how the operator says *no* from the device.
    @discardableResult
    public static func denyTaskConsent(
        request doc: String,
        reason: String,
        transport: VtaTransport,
        vtaDid: String,
        identity: HolderIdentity,
        trustedIssuers: [String]
    ) async throws -> TaskConsentOutcome {
        let request = try await parseTaskConsentRequest(json: doc, trustedIssuers: trustedIssuers)
        let draft = TaskConsentDecisionDraft(
            id: "urn:uuid:\(UUID().uuidString)",
            issuerDid: identity.didKey,
            recipientDid: vtaDid,
            issuedAt: ISO8601DateFormatter().string(from: Date()),
            challenge: request.challenge,
            payloadDigest: request.payloadDigest)
        let decisionDoc = try buildTaskConsentDecisionDenied(
            draft: draft, reason: reason, signer: identity)

        let body = try await transport.submit(decisionDoc)
        let status = Self.taskConsentJSONString(in: body, path: ["payload", "status"]) ?? "denied"
        return TaskConsentOutcome(payloadDigest: request.payloadDigest, status: status)
    }

    /// Pull a nested string out of a JSON object body, or `nil`.
    private static func taskConsentJSONString(in body: String, path: [String]) -> String? {
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
