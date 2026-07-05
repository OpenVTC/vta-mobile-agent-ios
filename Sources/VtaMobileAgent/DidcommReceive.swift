import Foundation
import VtaMobileCore

/// Inbound DIDComm for the **proxied** step-up path: the VTA addresses an
/// `auth/step-up/approve-request/0.1` to the holder's approver DID (this device)
/// and delivers it over DIDComm via the holder's mediator, instead of a desktop
/// relaying a `403` body out-of-band. This device approves it with the holder
/// key via the existing `approveStepUp`.
///
/// Two entry points share one core (`approveIfStepUpRequest`):
/// - `receiveStepUpOnce(session:…)` — pulls the next message off a live
///   `MediatorSession` (ATM has already unpacked it). This is the live path.
/// - `receiveStepUpApproveRequest(packed:…)` — unpacks a raw packed message
///   itself (for transports that hand over ciphertext directly).
extension VtaMobileAgent {
    /// Trust Task `type` of a step-up approve-request.
    static let stepUpApproveRequestType =
        "https://trusttasks.org/spec/auth/step-up/approve-request/0.1"

    /// Pull the next inbound message off a connected `MediatorSession` (waiting
    /// up to `timeoutSecs`) and, if it carries a step-up approve-request,
    /// approve it. Returns the outcome, `nil` if nothing arrived in time or the
    /// message wasn't a step-up request. Call in a loop to keep servicing.
    ///
    /// `MediatorSession` (ATM) has already authenticated the sender and
    /// decrypted under the holder key, so the message is plaintext here.
    @discardableResult
    public static func receiveStepUpOnce(
        session: MediatorSession,
        vtaURL: URL,
        vtaDid: String,
        identity: HolderIdentity,
        accessToken: String,
        timeoutSecs: UInt64 = 30
    ) async throws -> StepUpOutcome? {
        guard let messageJson = try await session.receiveNext(timeoutSecs: timeoutSecs) else {
            return nil  // nothing within the timeout
        }
        return try await approveIfStepUpRequest(
            messageJson: messageJson, vtaURL: vtaURL, vtaDid: vtaDid,
            identity: identity, accessToken: accessToken)
    }

    /// Pull the next inbound message and return its step-up approve-request
    /// document (the DIDComm `body`) **without acting on it** — so the app can
    /// present it for operator consent and then call `approveStepUp` /
    /// `denyStepUp`. Returns `nil` if nothing arrived within `timeoutSecs` or the
    /// message wasn't a step-up request. This is the human-in-the-loop path;
    /// `receiveStepUpOnce` is the auto-ratify path.
    public static func nextApproveRequest(
        session: MediatorSession,
        timeoutSecs: UInt64 = 30
    ) async throws -> String? {
        guard let messageJson = try await session.receiveNext(timeoutSecs: timeoutSecs) else {
            return nil
        }
        guard let approveRequest = didcommBody(messageJson),
            isStepUpApproveRequest(approveRequest)
        else {
            return nil
        }
        return approveRequest
    }

    /// Unpack a raw `packed` authcrypt message from the VTA and, if it carries a
    /// step-up approve-request, approve it. For transports that deliver
    /// ciphertext directly (not via `MediatorSession`, which unpacks for you).
    ///
    /// `vtaPeer` carries the VTA's key-agreement public key so the engine can
    /// authenticate the authcrypt sender. The message MUST be
    /// sender-authenticated — approving a step-up is a holder-authorizing action.
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
        return try await approveIfStepUpRequest(
            messageJson: unpacked.messageJson, vtaURL: vtaURL, vtaDid: vtaDid,
            identity: identity, accessToken: accessToken)
    }

    /// Core: given an **unpacked** DIDComm message `{ id, type, body, … }`,
    /// approve it iff `body` is a step-up approve-request. The Trust Task rides
    /// in the DIDComm `body` (the convention the VTA's outbound send follows).
    static func approveIfStepUpRequest(
        messageJson: String,
        vtaURL: URL,
        vtaDid: String,
        identity: HolderIdentity,
        accessToken: String
    ) async throws -> StepUpOutcome? {
        guard let approveRequest = didcommBody(messageJson),
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
