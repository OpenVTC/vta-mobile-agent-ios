import XCTest

@testable import VtaMobileAgent

/// Exercises the TSP reply correlator — the piece that makes request/response
/// work on a transport that has no `thid` demux.
///
/// The rules under test:
/// - a reply is matched by `threadId` against a *registered* expectation;
/// - unregistered traffic passes through untouched, so the inbox loop still
///   sees genuine step-up / task-consent requests;
/// - a reply that beats its `wait` is buffered rather than dropped (the common
///   case, since the inbox loop and the sender run concurrently);
/// - a correlated document that fails verification is not consumed, and does
///   not displace the genuine reply.
///
/// Verification itself is the engine's (`verifyTrustTaskReply`, tested in
/// `vta-mobile-core`); here it is injected, so these tests pin what the router
/// does with its verdict.
final class TspReplyRouterTests: XCTestCase {
    private struct Forged: Error {}

    /// Accepts every reply — for the correlation tests.
    private static let acceptAll: TspReplyRouter.ReplyVerifier = { _, _, _ in }

    /// Accepts only replies whose text contains `genuine`.
    private static let genuineOnly: TspReplyRouter.ReplyVerifier = { _, reply, _ in
        guard reply.contains("genuine") else { throw Forged() }
    }

    private let vta = "did:web:vta.example"

    private func makeRouter(_ verify: @escaping TspReplyRouter.ReplyVerifier = TspReplyRouterTests.acceptAll)
        -> TspReplyRouter
    {
        TspReplyRouter(verify: verify)
    }

    private func expect(_ router: TspReplyRouter, _ id: String) async {
        await router.expect(id, request: "{\"id\": \"\(id)\"}", from: vta)
    }

    private func doc(id: String? = nil, threadId: String? = nil) -> String {
        var fields: [String] = ["\"type\": \"https://trusttasks.org/spec/whoami/0.1#response\""]
        if let id { fields.append("\"id\": \"\(id)\"") }
        if let threadId { fields.append("\"threadId\": \"\(threadId)\"") }
        return "{\(fields.joined(separator: ", "))}"
    }

    /// The inbox must not swallow unsolicited traffic: a document nobody is
    /// waiting for has to fall through to the request classifiers.
    func testUnexpectedDocumentIsNotConsumed() async {
        let router = makeRouter()
        let consumed = await router.deliver(doc(id: "urn:uuid:x", threadId: "urn:uuid:nobody"))
        XCTAssertFalse(consumed)
    }

    /// A document with no `threadId` at all (a pushed request) is never a reply.
    func testDocumentWithoutThreadIdIsNotConsumed() async {
        let router = makeRouter()
        await expect(router, "urn:uuid:a")
        let consumed = await router.deliver(doc(id: "urn:uuid:pushed"))
        XCTAssertFalse(consumed)
    }

    /// The ordinary path: register, deliver, then await.
    func testReplyArrivingBeforeWaitIsBuffered() async throws {
        let router = makeRouter()
        await expect(router, "urn:uuid:a")

        let consumed = await router.deliver(doc(id: "urn:uuid:r", threadId: "urn:uuid:a"))
        XCTAssertTrue(consumed, "a registered threadId must be consumed as a reply")

        let reply = try await router.wait("urn:uuid:a", timeoutSecs: 5)
        XCTAssertTrue(reply.contains("urn:uuid:r"))
    }

    /// The concurrent path: a waiter parked first, resolved by a later delivery.
    func testWaitResolvedByLaterDelivery() async throws {
        let router = makeRouter()
        await expect(router, "urn:uuid:b")

        async let pending = router.wait("urn:uuid:b", timeoutSecs: 5)
        // Give `wait` a turn to park its continuation before delivering.
        try await Task.sleep(nanoseconds: 50_000_000)
        let consumed = await router.deliver(doc(id: "urn:uuid:s", threadId: "urn:uuid:b"))
        XCTAssertTrue(consumed)

        let reply = try await pending
        XCTAssertTrue(reply.contains("urn:uuid:s"))
    }

    /// Two submissions in flight must not steal each other's replies.
    func testConcurrentWaitersEachGetTheirOwnReply() async throws {
        let router = makeRouter()
        await expect(router, "urn:uuid:one")
        await expect(router, "urn:uuid:two")

        async let first = router.wait("urn:uuid:one", timeoutSecs: 5)
        async let second = router.wait("urn:uuid:two", timeoutSecs: 5)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Deliver out of order, to prove matching is by threadId and not arrival.
        _ = await router.deliver(doc(id: "urn:uuid:second-reply", threadId: "urn:uuid:two"))
        _ = await router.deliver(doc(id: "urn:uuid:first-reply", threadId: "urn:uuid:one"))

        let (a, b) = try await (first, second)
        XCTAssertTrue(a.contains("first-reply"))
        XCTAssertTrue(b.contains("second-reply"))
    }

    /// A cancelled expectation (the send failed) stops matching.
    func testCancelDropsTheExpectation() async {
        let router = makeRouter()
        await expect(router, "urn:uuid:c")
        await router.cancel("urn:uuid:c")
        let consumed = await router.deliver(doc(id: "urn:uuid:r", threadId: "urn:uuid:c"))
        XCTAssertFalse(consumed)
    }

    /// A forged frame that echoes the `threadId` is not consumed, and the
    /// genuine reply still resolves the waiter.
    func testUnverifiedReplyIsNotConsumedAndDoesNotDisplaceTheGenuineOne() async throws {
        let router = makeRouter(Self.genuineOnly)
        await expect(router, "urn:uuid:e")

        async let pending = router.wait("urn:uuid:e", timeoutSecs: 5)
        try await Task.sleep(nanoseconds: 50_000_000)

        let forged = await router.deliver(doc(id: "urn:uuid:forged", threadId: "urn:uuid:e"))
        XCTAssertFalse(forged, "an unverified reply must not be consumed")

        let genuine = await router.deliver(doc(id: "urn:uuid:genuine", threadId: "urn:uuid:e"))
        XCTAssertTrue(genuine)

        let reply = try await pending
        XCTAssertTrue(reply.contains("urn:uuid:genuine"))
    }

    /// The verifier is given the request as sent and the peer it was sent to.
    func testVerifierSeesTheRequestAndThePeer() async {
        let seen = SeenArgs()
        let router = router { request, _, signer in await seen.record(request, signer) }
        await router.expect("urn:uuid:f", request: "{\"id\": \"urn:uuid:f\"}", from: vta)
        _ = await router.deliver(doc(id: "urn:uuid:r", threadId: "urn:uuid:f"))
        let (request, signer) = await seen.values
        XCTAssertEqual(request, "{\"id\": \"urn:uuid:f\"}")
        XCTAssertEqual(signer, vta)
    }

    /// A reply that never verifies fails the submit with a timeout, never with
    /// the unverified content.
    func testReplyThatNeverVerifiesTimesOut() async {
        let router = makeRouter(Self.genuineOnly)
        await expect(router, "urn:uuid:g")
        _ = await router.deliver(doc(id: "urn:uuid:forged", threadId: "urn:uuid:g"))
        do {
            _ = try await router.wait("urn:uuid:g", timeoutSecs: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("timed out"))
        }
    }

    /// A reply that never comes must fail the submit rather than hang it.
    func testWaitTimesOut() async {
        let router = makeRouter()
        await expect(router, "urn:uuid:d")
        do {
            _ = try await router.wait("urn:uuid:d", timeoutSecs: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("timed out"),
                "unexpected error: \(error.localizedDescription)")
        }
    }
}

private actor SeenArgs {
    private(set) var values: (String?, String?) = (nil, nil)
    func record(_ request: String, _ signer: String) { values = (request, signer) }
}
