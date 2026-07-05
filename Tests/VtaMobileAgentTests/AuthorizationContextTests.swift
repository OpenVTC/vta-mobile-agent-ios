import XCTest

@testable import VtaMobileAgent

/// Exercises the engine → Swift path for the structured authorization context:
/// `parseStepUpRequest` (real FFI) surfaces `authorizationContext`, and
/// `AuthorizationContext.decode` turns it into the typed model the card renders.
final class AuthorizationContextTests: XCTestCase {
    /// A share ask carried under the reverse-DNS `payload.ext` key.
    private let shareRequest = """
        {
          "id": "urn:uuid:x",
          "type": "https://trusttasks.org/spec/auth/step-up/approve-request/0.1",
          "issuer": "did:webvh:vta",
          "payload": {
            "subject": "did:webvh:operator",
            "sessionId": "sess-1",
            "challenge": "VHJhbnNmZXJDb25maXJtTm9uY2VYWQ",
            "reason": "finance wants to share salaryBand with travel",
            "targetAcr": "aal2",
            "ext": {
              "org.openvtc.authorization-context": {
                "type": "https://openvtc.org/cierge/authorization-context/0.1",
                "domain": "finance",
                "tenant": "acme",
                "summary": "finance wants to share salaryBand with travel",
                "detail": "book flights within policy",
                "risk": "high",
                "action": {
                  "kind": "share", "from": "finance", "to": "travel",
                  "fields": ["salaryBand"], "capabilities": [],
                  "purpose": "book flights within policy", "ttlSeconds": 3600
                }
              }
            }
          }
        }
        """

    func testInspectSurfacesDecodedShareContext() throws {
        let review = try VtaMobileAgent.inspect(approveRequest: shareRequest)
        XCTAssertEqual(review.reason, "finance wants to share salaryBand with travel")
        XCTAssertEqual(review.targetAcr, "aal2")
        let ctx = try XCTUnwrap(review.authorizationContext)
        XCTAssertEqual(ctx.domain, "finance")
        XCTAssertEqual(ctx.tenant, "acme")
        XCTAssertEqual(ctx.risk, .high)
        XCTAssertTrue(ctx.summary.contains("salaryBand"))
        guard case let .share(from, to, fields, _, _, ttlSeconds) = ctx.action else {
            return XCTFail("expected a share action, got \(ctx.action)")
        }
        XCTAssertEqual(from, "finance")
        XCTAssertEqual(to, "travel")
        XCTAssertEqual(fields, ["salaryBand"])
        XCTAssertEqual(ttlSeconds, 3600)
        XCTAssertEqual(ctx.action.kindLabel, "Share")
    }

    /// A plain login-elevation step-up (no ext) → no structured context; the UI
    /// falls back to `reason`.
    func testInspectWithoutContextIsNil() throws {
        let plain = """
            {
              "id": "urn:uuid:y",
              "type": "https://trusttasks.org/spec/auth/step-up/approve-request/0.1",
              "issuer": "did:webvh:vta",
              "payload": {
                "subject": "did:key:zAlice",
                "sessionId": "s1",
                "challenge": "VHJhbnNmZXJDb25maXJtTm9uY2VYWQ",
                "reason": "Approve sign-in"
              }
            }
            """
        let review = try VtaMobileAgent.inspect(approveRequest: plain)
        XCTAssertEqual(review.reason, "Approve sign-in")
        XCTAssertNil(review.authorizationContext)
    }

    /// The review gate: a context-carrying ask must be shown for consent; a
    /// plain login step-up may be auto-ratified.
    func testRequiresReviewGate() throws {
        let shareReview = try VtaMobileAgent.inspect(approveRequest: shareRequest)
        XCTAssertTrue(VtaMobileAgent.requiresReview(shareReview))

        let plain = """
            {
              "id": "urn:uuid:z",
              "type": "https://trusttasks.org/spec/auth/step-up/approve-request/0.1",
              "issuer": "did:webvh:vta",
              "payload": {
                "subject": "did:key:zAlice", "sessionId": "s1",
                "challenge": "VHJhbnNmZXJDb25maXJtTm9uY2VYWQ", "reason": "Approve sign-in"
              }
            }
            """
        let plainReview = try VtaMobileAgent.inspect(approveRequest: plain)
        XCTAssertFalse(VtaMobileAgent.requiresReview(plainReview))
    }

    /// Spend + tool variants decode from their kind-tagged JSON.
    func testDecodesSpendAndToolActions() throws {
        let spend = AuthorizationContext.decode(
            fromJSON: """
                {"domain":"research","summary":"spend $4 over budget","risk":"medium",
                 "action":{"kind":"spend","amountUsd":4.0,"budgetRemainingUsd":0.5,
                 "provider":"anthropic","model":"opus-4.8"}}
                """)
        guard case let .spend(amount, _, provider, _)? = spend?.action else {
            return XCTFail("expected spend")
        }
        XCTAssertEqual(amount, 4.0, accuracy: 0.001)
        XCTAssertEqual(provider, "anthropic")

        let tool = AuthorizationContext.decode(
            fromJSON: """
                {"domain":"legal","summary":"sign the Q3 resolution","risk":"high",
                 "action":{"kind":"tool","tool":"sign_document",
                 "argumentsSummary":"sign the Q3 board resolution","target":"Q3 board resolution"}}
                """)
        XCTAssertEqual(tool?.action.kindLabel, "Tool")

        // An unmodeled future kind degrades to `.unknown` (still renders via summary).
        let future = AuthorizationContext.decode(
            fromJSON: """
                {"domain":"d","summary":"s","risk":"low","action":{"kind":"teleport"}}
                """)
        XCTAssertEqual(future?.action.kindLabel, "teleport")
    }
}
