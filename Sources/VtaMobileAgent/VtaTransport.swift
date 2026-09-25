import Foundation
import VtaMobileCore

/// How a signed Trust Task document reaches the VTA.
///
/// Both transports submit the *same* document to the *same* VTA dispatcher
/// (`dispatch_trust_task_core` — the one that used to sit behind
/// `POST /api/trust-tasks`); they differ only in framing and in how the reply
/// finds its way back.
///
/// **Neither carries a bearer token, and neither transport authorizes
/// anything on its own.** The VTA accepts a document over DIDComm or TSP only
/// when its Data Integrity proof verifies as its `issuer` and that issuer is the
/// transport sender (authcrypt for DIDComm, the sealed sender VID for TSP). So
/// every document submitted is holder-signed (under `authentication`, except
/// the step-up `approve-response`, the approver's own answer, which is signed
/// under `assertionMethod`), names this device as `issuer` and the VTA as
/// `recipient`, and carries a fresh `id` and `issuedAt`; the engine refuses to
/// send one that does not. There is no
/// challenge/authenticate round trip and nothing to refresh: possession of the
/// holder key **is** the credential.
///
/// **Replies are verified before they are returned.** A reply is read only when
/// it carries a proof by the VTA under `authentication`, is threaded to the
/// request's `id`, and is addressed to this device — error replies included.
/// Anything else is `FfiError.UnverifiedReply` and is discarded unread.
///
/// The device's `did:key` must still be enrolled in the VTA's ACL
/// (`pnm acl create --did <did:key> …`) — the same prerequisite REST had.
public protocol VtaTransport {
    /// Submit `document` — a complete, holder-signed Trust Task document — and
    /// return the VTA's **verified** framework `#response` document as JSON.
    ///
    /// The returned bytes are the same shape REST used to return, so the
    /// engine's `parse*Response` functions consume them unchanged.
    func submit(_ document: String) async throws -> String
}

// MARK: - DIDComm

/// Submits over an authcrypt DIDComm message through the holder's mediator.
///
/// The engine's `sendTrustTask` correlates the reply by `thid`, so this is a
/// true request/response call and is safe to run concurrently with the inbox
/// loop — the delivery layer demuxes replies to their waiter rather than
/// letting them race the unsolicited stream. The engine also verifies the reply
/// (a proof by the session's VTA under `authentication`, threaded to the
/// request) before returning it, and throws `FfiError.UnverifiedReply` if it
/// cannot.
public struct DidcommTransport: VtaTransport {
    private let session: MediatorSession
    private let timeoutSecs: UInt64

    public init(session: MediatorSession, timeoutSecs: UInt64 = 30) {
        self.session = session
        self.timeoutSecs = timeoutSecs
    }

    public func submit(_ document: String) async throws -> String {
        try await session.sendTrustTask(docJson: document, timeoutSecs: timeoutSecs)
    }
}

// MARK: - TSP

/// Submits over TSP, routed through the mediator.
///
/// Unlike DIDComm this is *not* natively request/response: TSP has no `thid`
/// demux, and `receiveNext` holds the socket lock for its whole budget, so a
/// submit that tried to read its own reply would deadlock against a running
/// inbox loop. Instead the inbox loop stays the single reader and hands every
/// frame to a ``TspReplyRouter``, which matches replies back to their waiting
/// `submit` and verifies each one before handing it over. See
/// ``TspReplyRouter`` for the correlation and verification rules.
public struct TspTransport: VtaTransport {
    private let session: TspMediatorSession
    private let vtaDid: String
    private let mediatorDid: String
    private let router: TspReplyRouter
    private let timeoutSecs: UInt64

    public init(
        session: TspMediatorSession,
        vtaDid: String,
        mediatorDid: String,
        router: TspReplyRouter,
        timeoutSecs: UInt64 = 30
    ) {
        self.session = session
        self.vtaDid = vtaDid
        self.mediatorDid = mediatorDid
        self.router = router
        self.timeoutSecs = timeoutSecs
    }

    public func submit(_ document: String) async throws -> String {
        guard let id = TspReplyRouter.documentId(of: document) else {
            throw AgentError.badResponse(
                "cannot submit a Trust Task document with no `id` — the VTA's reply "
                    + "would have no `threadId` to correlate against")
        }

        // Register the expectation *before* sending: the VTA's reply can land on
        // the inbox before `sendTrustTask` has even returned, and an unexpected
        // `threadId` is passed through to the inbox loop as unsolicited traffic.
        await router.expect(id, request: document, from: vtaDid)
        do {
            try await session.sendTrustTask(
                vtaDid: vtaDid, mediatorDid: mediatorDid, docJson: document)
        } catch {
            await router.cancel(id)
            throw error
        }
        return try await router.wait(id, timeoutSecs: timeoutSecs)
    }
}

/// Correlates VTA replies arriving on the shared TSP inbox back to the `submit`
/// call waiting for them, and verifies each one before it is handed over.
///
/// **The correlation rule.** The Trust Task framework builds a response with
/// `threadId = request.threadId ?? request.id`, so a request sent with
/// `id == X` is answered by a document carrying `threadId == X`.
///
/// **The verification rule.** A document threaded to an expected request is a
/// reply only once it verifies as the word of the peer the request was sent to
/// (`verifyTrustTaskReply`: a proof by that peer under `authentication`,
/// `threadId` and `type` answering the request, addressed to this device).
/// Verification happens *before* the waiter is resolved, so a forged frame that
/// merely echoes a `threadId` cannot take the waiter's place: it is not
/// consumed, the expectation stays open, and the genuine reply still resolves
/// the `submit` when it arrives. A `submit` whose reply never verifies times
/// out rather than returning anything unverified.
///
/// **Ownership.** The inbox loop is the only reader of the TSP socket. It must
/// offer every inbound document to ``deliver(_:)`` first; a `false` return means
/// "not a verified reply anyone is waiting for", i.e. unsolicited traffic (a
/// step-up request, a task-consent request, an announce pong) that the loop
/// should handle as it always has.
public actor TspReplyRouter {
    /// Verifies `reply` as `signer`'s answer to `request`, or throws.
    public typealias ReplyVerifier =
        @Sendable (_ request: String, _ reply: String, _ signer: String) async throws -> Void

    /// What a `submit` has announced it is waiting for, keyed by the `threadId`
    /// its reply will carry: the request as sent and the peer it was sent to,
    /// which is what the reply is verified against. Without this, ``deliver(_:)``
    /// could not tell a reply meant for us from unsolicited traffic that merely
    /// happens to carry a `threadId`.
    private var expected: [String: (request: String, signer: String)] = [:]
    /// Replies that arrived before their `wait` did — the common case, since the
    /// inbox loop and the sender run concurrently.
    private var arrived: [String: Result<String, Error>] = [:]
    private var waiters: [String: CheckedContinuation<String, Error>] = [:]
    private let verify: ReplyVerifier

    /// `verify` defaults to the engine's `verifyTrustTaskReply`; tests inject
    /// their own.
    public init(
        verify: @escaping ReplyVerifier = { request, reply, signer in
            try await verifyTrustTaskReply(
                requestJson: request, replyJson: reply, expectedSigner: signer)
        }
    ) {
        self.verify = verify
    }

    /// Announce that a reply to `request` (whose `id` is `threadId`), sent to
    /// `signer`, is coming. Call before sending.
    func expect(_ threadId: String, request: String, from signer: String) {
        expected[threadId] = (request, signer)
    }

    /// Abandon an expectation (the send failed, so no reply is coming).
    func cancel(_ threadId: String) {
        expected[threadId] = nil
        arrived[threadId] = nil
        waiters[threadId] = nil
    }

    /// Offer an inbound document to the waiters.
    ///
    /// Returns `true` when it was consumed as a verified, correlated reply;
    /// `false` when the inbox loop should treat it as unsolicited. A document
    /// that is threaded to an expected request but fails verification is **not**
    /// consumed, and the request keeps waiting for its genuine reply.
    public func deliver(_ document: String) async -> Bool {
        guard let thread = Self.threadId(of: document), let pending = expected[thread] else {
            return false
        }
        do {
            try await verify(pending.request, document, pending.signer)
        } catch {
            return false
        }
        // Verification suspended this actor; the expectation may have been
        // satisfied, cancelled or timed out meanwhile.
        guard expected.removeValue(forKey: thread) != nil else { return false }
        if let waiter = waiters.removeValue(forKey: thread) {
            waiter.resume(returning: document)
        } else {
            arrived[thread] = .success(document)  // beat its `wait`; hold it
        }
        return true
    }

    /// Await the reply correlated to `threadId`, or throw once `timeoutSecs`
    /// elapses with nothing matching.
    func wait(_ threadId: String, timeoutSecs: UInt64) async throws -> String {
        if let already = arrived.removeValue(forKey: threadId) {
            return try already.get()
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutSecs &* 1_000_000_000)
            await self?.fail(
                threadId,
                AgentError.badResponse(
                    "timed out after \(timeoutSecs)s waiting for a verified reply from the VTA over TSP"))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[threadId] = continuation
        }
    }

    /// Resolve a waiter with an error (timeout, or a failed send).
    ///
    /// The `expected` guard matters: a timeout task can fire in the window
    /// between ``deliver(_:)`` resuming a waiter and `wait`'s `defer` cancelling
    /// it. `deliver` clears `expected` first, so a late timeout for an
    /// already-satisfied request is a no-op here instead of parking an
    /// uncollectable `.failure` in `arrived`.
    private func fail(_ threadId: String, _ error: Error) {
        guard expected.removeValue(forKey: threadId) != nil else { return }
        if let waiter = waiters.removeValue(forKey: threadId) {
            waiter.resume(throwing: error)
        } else {
            arrived[threadId] = .failure(error)
        }
    }

    /// The `id` of a Trust Task document we are about to send.
    static func documentId(of document: String) -> String? {
        field("id", of: document)
    }

    /// The `threadId` of an inbound document — what a response echoes back.
    static func threadId(of document: String) -> String? {
        field("threadId", of: document)
    }

    private static func field(_ name: String, of document: String) -> String? {
        guard let data = document.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[name] as? String
    }
}
