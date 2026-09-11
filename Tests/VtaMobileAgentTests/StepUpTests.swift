import XCTest

@testable import VtaMobileAgent

/// Unit tests for the approver's input handling. (The full approve round-trip
/// is exercised manually against a live VTA — it needs a pending step-up + an
/// authenticated holder session.)
final class StepUpTests: XCTestCase {
    /// A VTA `403` body carries the document under `approveRequest` — unwrap it.
    func testUnwrapExtractsApproveRequestFrom403Body() {
        let body = """
            {"error":"step_up_required","requiredAcr":"aal2",
             "approveRequest":{"id":"urn:uuid:x","type":"…/approve-request/0.1",
             "payload":{"subject":"did:key:zSubject","sessionId":"sess-1",
             "challenge":"abc","targetAcr":"aal2"}}}
            """
        let doc = VtaMobileAgent.unwrapApproveRequest(body)
        let obj = try! JSONSerialization.jsonObject(with: Data(doc.utf8)) as! [String: Any]
        // It's the inner document, not the 403 envelope.
        XCTAssertNil(obj["approveRequest"])
        XCTAssertEqual(obj["id"] as? String, "urn:uuid:x")
        XCTAssertEqual((obj["payload"] as? [String: Any])?["sessionId"] as? String, "sess-1")
    }

    /// A bare approve-request document is returned unchanged.
    func testUnwrapPassesThroughBareDocument() {
        let doc = #"{"id":"urn:uuid:y","type":"…/approve-request/0.1","payload":{}}"#
        XCTAssertEqual(VtaMobileAgent.unwrapApproveRequest(doc), doc)
    }

    /// Non-JSON input is returned unchanged (surfaces later as a parse error).
    func testUnwrapPassesThroughNonJSON() {
        XCTAssertEqual(VtaMobileAgent.unwrapApproveRequest("not json"), "not json")
    }

    /// The review-based `StepUpPolicy.decide` keys off the authorization context.
    func testStepUpPolicyDecidesFromTheReview() throws {
        let context = try XCTUnwrap(
            AuthorizationContext.decode(
                fromJSON: #"{"domain":"d","summary":"s","risk":"low","action":{"kind":"teleport"}}"#))
        func review(_ ctx: AuthorizationContext?) -> VtaMobileAgent.StepUpReview {
            VtaMobileAgent.StepUpReview(
                reason: "Approve sign-in", subject: "did:key:zAlice", sessionId: "s1",
                targetAcr: "aal2", authorizationContext: ctx, relyingParty: "did:key:zVta")
        }
        XCTAssertEqual(
            StepUpPolicy.decide(review: review(nil), appActive: true, autoApproveSignIns: true),
            .autoApprove)
        XCTAssertEqual(
            StepUpPolicy.decide(review: review(nil), appActive: false, autoApproveSignIns: true),
            .queueForReview)
        XCTAssertEqual(
            StepUpPolicy.decide(review: review(context), appActive: true, autoApproveSignIns: true),
            .queueForReview)
    }
}
