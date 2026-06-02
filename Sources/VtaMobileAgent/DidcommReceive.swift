import Foundation
import VtaMobileCore

/// Inbound DIDComm for the **proxied** step-up path: the VTA addresses an
/// `auth/step-up/approve-request/0.1` to the holder's approver DID (this
/// device) and delivers it over DIDComm (via the holder's mediator), instead of
/// a desktop relaying a `403` body out-of-band. This device unpacks it with the
/// holder key and ratifies it via the existing `approveStepUp`.
extension VtaMobileAgent {
    /// Trust Task `type` of a step-up approve-request.
    static let stepUpApproveRequestType =
        "https://trusttasks.org/spec/auth/step-up/approve-request/0.1"

    /// Unpack `packed` — an authcrypt DIDComm message received from the VTA —
    /// and, if it carries a step-up approve-request, approve it. Returns the
    /// outcome, or `nil` when the message isn't a step-up approve-request (the
    /// caller routes other message types elsewhere).
    ///
    /// `vtaPeer` carries the VTA's key-agreement public key so the engine can
    /// authenticate the authcrypt sender; the caller resolves it from the VTA's
    /// DID document (the mediator/pickup layer). The unpacked message MUST be
    /// sender-authenticated — an anoncrypt or unauthenticated message is
    /// refused, since approving a step-up is a holder-authorizing action.
    @discardableResult
    public static func receiveStepUpApproveRequest(
        packed: String,
        vtaPeer: Peer,
        vtaURL: URL,
        vtaDid: String,
        identity: HolderIdentity,
        accessToken: String
    ) async throws -> StepUpOutcome? {
        let session = try DidcommSession(holder: identity.didcommHolderKeys())
        try session.addPeer(peer: vtaPeer)

        let unpacked = try session.unpack(packed: packed, senderDid: vtaDid)
        guard unpacked.senderAuthenticated else {
            throw AgentError.badResponse(
                "inbound DIDComm message was not sender-authenticated; refusing to act on it")
        }
        // The unpacked plaintext is a DIDComm message `{ id, type, body, … }`;
        // the approve-request Trust Task rides in `body` (the convention the
        // VTA's outbound send will follow). Extract it and approve.
        guard let approveRequest = didcommBody(unpacked.messageJson),
            isStepUpApproveRequest(approveRequest)
        else {
            return nil
        }
        return try await approveStepUp(
            approveRequest: approveRequest, vtaURL: vtaURL, vtaDid: vtaDid,
            identity: identity, accessToken: accessToken)
    }

    /// Re-serialize the `body` object of a DIDComm message as a JSON string, or
    /// `nil` when the message has no object `body`.
    static func didcommBody(_ messageJson: String) -> String? {
        guard let data = messageJson.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let body = obj["body"],
            let bodyData = try? JSONSerialization.data(withJSONObject: body),
            let bodyString = String(data: bodyData, encoding: .utf8)
        else { return nil }
        return bodyString
    }

    /// True when `doc` is an `auth/step-up/approve-request/0.1` document.
    static func isStepUpApproveRequest(_ doc: String) -> Bool {
        guard let data = doc.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return false }
        return type == stepUpApproveRequestType
    }
}
