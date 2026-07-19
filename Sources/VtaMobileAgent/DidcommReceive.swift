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

    /// Trust Task `type` of a task-consent request (the delegated-execution
    /// approval this device answers as a second approving device).
    static let taskConsentRequestType =
        "https://trusttasks.org/spec/task-consent/request/0.1"

    /// A human-in-the-loop inbound the VTA addressed to this device, tagged by
    /// kind so the app can route it to the right approval surface. Carries the
    /// DIDComm `body` document verbatim (the app re-parses it for display and to
    /// build the signed response/decision).
    public enum InboundRequest {
        /// An `auth/step-up/approve-request/0.1` — answer with `approveStepUp` /
        /// `denyStepUp`.
        case stepUp(String)
        /// A `task-consent/request/0.1` — answer with `approveTaskConsent` /
        /// `denyTaskConsent`.
        case taskConsent(String)
    }

    /// Pull the next inbound message off a connected `MediatorSession` (waiting up
    /// to `timeoutSecs`) and, if it is one of the requests this device answers,
    /// return it tagged **without acting on it** — so the app can present it for
    /// operator consent. Returns `nil` if nothing arrived in time or the message
    /// is neither a step-up nor a task-consent request. Supersedes
    /// [`nextApproveRequest`] for a listener that services both.
    ///
    /// `MediatorSession` (ATM) has already authenticated the sender and decrypted
    /// under the holder key, so the message is plaintext here.
    public static func nextInbound(
        session: MediatorSession,
        timeoutSecs: UInt64 = 30
    ) async throws -> InboundRequest? {
        guard let messageJson = try await session.receiveNext(timeoutSecs: timeoutSecs),
            let body = didcommBody(messageJson)
        else {
            return nil
        }
        if isStepUpApproveRequest(body) {
            return .stepUp(body)
        }
        if isTaskConsentRequest(body) {
            return .taskConsent(body)
        }
        return nil  // some other traffic (e.g. a granted notice for a requester) — ignore
    }

    /// TSP counterpart of ``nextInbound(session:timeoutSecs:)``. TSP carries the
    /// Trust-Task document **directly** rather than inside a DIDComm envelope's
    /// `body`, so the string `receiveNext` returns *is* the document — there is
    /// no `body` to unwrap. The classifiers and the returned tags are otherwise
    /// identical, so the caller dispatches `.stepUp` / `.taskConsent` the same
    /// way regardless of transport.
    ///
    /// The TSP session (ATM) has already proven the sender VID and decrypted
    /// under the holder key, so the document is authenticated plaintext here,
    /// exactly as with DIDComm authcrypt.
    public static func nextInboundTsp(
        session: TspMediatorSession,
        timeoutSecs: UInt64 = 30
    ) async throws -> InboundRequest? {
        guard let doc = try await session.receiveNext(timeoutSecs: timeoutSecs) else {
            return nil
        }
        if isStepUpApproveRequest(doc) {
            return .stepUp(doc)
        }
        if isTaskConsentRequest(doc) {
            return .taskConsent(doc)
        }
        return nil  // other traffic — ignore
    }

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
        docType(doc) == stepUpApproveRequestType
    }

    /// True when `doc` is a `task-consent/request/0.1` document.
    static func isTaskConsentRequest(_ doc: String) -> Bool {
        docType(doc) == taskConsentRequestType
    }

    /// The `type` string of a JSON document, or `nil` if it has none.
    private static func docType(_ doc: String) -> String? {
        guard let data = doc.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["type"] as? String
    }
}
