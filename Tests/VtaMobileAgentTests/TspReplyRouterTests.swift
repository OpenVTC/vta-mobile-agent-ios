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
///   case, since the inbox loop and the sender run concurrently).
final class TspReplyRouterTests: XCTestCase {
    private func doc(id: String? = nil, threadId: String? = nil) -> String {
        var fields: [String] = ["\"type\": \"https://trusttasks.org/spec/whoami/0.1#response\""]
        if let id { fields.append("\"id\": \"\(id)\"") }
        if let threadId { fields.append("\"threadId\": \"\(threadId)\"") }
        return "{\(fields.joined(separator: ", "))}"
    }

    /// The inbox must not swallow unsolicited traffic: a document nobody is
    /// waiting for has to fall through to the request classifiers.
    func testUnexpectedDocumentIsNotConsumed() async {
        let router = TspReplyRouter()
        let consumed = await router.deliver(doc(id: "urn:uuid:x", threadId: "urn:uuid:nobody"))
        XCTAssertFalse(consumed)
    }

    /// A document with no `threadId` at all (a pushed request) is never a reply.
    func testDocumentWithoutThreadIdIsNotConsumed() async {
        let router = TspReplyRouter()
        await router.expect("urn:uuid:a")
        let consumed = await router.deliver(doc(id: "urn:uuid:pushed"))
        XCTAssertFalse(consumed)
    }

    /// The ordinary path: register, deliver, then await.
    func testReplyArrivingBeforeWaitIsBuffered() async throws {
        let router = TspReplyRouter()
        await router.expect("urn:uuid:a")

        let consumed = await router.deliver(doc(id: "urn:uuid:r", threadId: "urn:uuid:a"))
        XCTAssertTrue(consumed, "a registered threadId must be consumed as a reply")

        let reply = try await router.wait("urn:uuid:a", timeoutSecs: 5)
        XCTAssertTrue(reply.contains("urn:uuid:r"))
    }

    /// The concurrent path: a waiter parked first, resolved by a later delivery.
    func testWaitResolvedByLaterDelivery() async throws {
        let router = TspReplyRouter()
        await router.expect("urn:uuid:b")

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
        let router = TspReplyRouter()
        await router.expect("urn:uuid:one")
        await router.expect("urn:uuid:two")

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
        let router = TspReplyRouter()
        await router.expect("urn:uuid:c")
        await router.cancel("urn:uuid:c")
        let consumed = await router.deliver(doc(id: "urn:uuid:r", threadId: "urn:uuid:c"))
        XCTAssertFalse(consumed)
    }

    /// A reply that never comes must fail the submit rather than hang it.
    func testWaitTimesOut() async {
        let router = TspReplyRouter()
        await router.expect("urn:uuid:d")
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
