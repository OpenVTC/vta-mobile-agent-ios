import XCTest

import VtaMobileCore

@testable import VtaMobileAgent

/// Exercises the engine → Swift path for the structured authorization context:
/// `parseStepUpRequest` (real FFI, now verifying the request's Data Integrity
/// proof against the enrolled-executor allowlist) surfaces
/// `authorizationContext`, and `AuthorizationContext.decode` turns it into the
/// typed model the card renders.
///
/// The fixtures are **signed**: `eddsa-jcs-2022` proofs minted by
/// vta-mobile-core's deterministic test executor key (`proof::test_support`,
/// seed 17), whose `did:key` issuer resolves offline — so the tests exercise
/// the full on-device verification path without touching the network. The
/// proof has no expiry, so the static fixtures stay valid.
final class AuthorizationContextTests: XCTestCase {
    /// The deterministic executor DID the fixtures are issued and signed by —
    /// the "enrolled VTA" of these tests.
    private let fixtureIssuer = "did:key:z6MktULudTtAsAhRegYPiZ6631RV3viv12qd4GQF8z1xB22S"

    /// A share ask carried under the reverse-DNS `payload.ext` key, signed by
    /// the fixture issuer.
    private let shareRequest = #"""
        {"id":"urn:uuid:x","issuer":"did:key:z6MktULudTtAsAhRegYPiZ6631RV3viv12qd4GQF8z1xB22S","payload":{"challenge":"VHJhbnNmZXJDb25maXJtTm9uY2VYWQ","ext":{"org.openvtc.authorization-context":{"action":{"capabilities":[],"fields":["salaryBand"],"from":"finance","kind":"share","purpose":"book flights within policy","to":"travel","ttlSeconds":3600},"detail":"book flights within policy","domain":"finance","risk":"high","summary":"finance wants to share salaryBand with travel","tenant":"acme","type":"https://openvtc.org/cierge/authorization-context/0.1"}},"reason":"finance wants to share salaryBand with travel","sessionId":"sess-1","subject":"did:webvh:operator","targetAcr":"aal2"},"proof":{"created":"2026-07-29T08:23:48Z","cryptosuite":"eddsa-jcs-2022","proofPurpose":"assertionMethod","proofValue":"zy4Xvrxydfv2UX5udwCUMEmCoP5MfA4VGY8LW1amgJSsNX93TMQ5dKCMMByooSmpHa5UPVzib6e1KHYjT3B4wmeQ","type":"DataIntegrityProof","verificationMethod":"did:key:z6MktULudTtAsAhRegYPiZ6631RV3viv12qd4GQF8z1xB22S#z6MktULudTtAsAhRegYPiZ6631RV3viv12qd4GQF8z1xB22S"},"type":"https://trusttasks.org/spec/auth/step-up/approve-request/0.1"}
        """#

    /// A plain login-elevation step-up (no ext), signed by the fixture issuer.
    private let plainRequest = #"""
        {"id":"urn:uuid:y","issuer":"did:key:z6MktULudTtAsAhRegYPiZ6631RV3viv12qd4GQF8z1xB22S","payload":{"challenge":"VHJhbnNmZXJDb25maXJtTm9uY2VYWQ","reason":"Approve sign-in","sessionId":"s1","subject":"did:key:zAlice"},"proof":{"created":"2026-07-29T08:23:48Z","cryptosuite":"eddsa-jcs-2022","proofPurpose":"assertionMethod","proofValue":"z2Z5iDnaLHGJtKHCQP8SJXSjvV3QFEVB6nCUs1F8tFQ9AQiMyYb3HCZqkGpzQyt5YcDuSDJZ3JJqamYdbPekWNejV","type":"DataIntegrityProof","verificationMethod":"did:key:z6MktULudTtAsAhRegYPiZ6631RV3viv12qd4GQF8z1xB22S#z6MktULudTtAsAhRegYPiZ6631RV3viv12qd4GQF8z1xB22S"},"type":"https://trusttasks.org/spec/auth/step-up/approve-request/0.1"}
        """#

    private var enrolled: [String] { [fixtureIssuer] }

    func testInspectSurfacesDecodedShareContext() async throws {
        let review = try await VtaMobileAgent.inspect(
            approveRequest: shareRequest, trustedIssuers: enrolled)
        XCTAssertEqual(review.reason, "finance wants to share salaryBand with travel")
        XCTAssertEqual(review.targetAcr, "aal2")
        XCTAssertEqual(review.relyingParty, fixtureIssuer)  // the *proven* signer
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
    func testInspectWithoutContextIsNil() async throws {
        let review = try await VtaMobileAgent.inspect(
            approveRequest: plainRequest, trustedIssuers: enrolled)
        XCTAssertEqual(review.reason, "Approve sign-in")
        XCTAssertNil(review.authorizationContext)
    }

    /// The review gate: a context-carrying ask must be shown for consent; a
    /// plain login step-up may be auto-ratified.
    func testRequiresReviewGate() async throws {
        let shareReview = try await VtaMobileAgent.inspect(
            approveRequest: shareRequest, trustedIssuers: enrolled)
        XCTAssertTrue(VtaMobileAgent.requiresReview(shareReview))

        let plainReview = try await VtaMobileAgent.inspect(
            approveRequest: plainRequest, trustedIssuers: enrolled)
        XCTAssertFalse(VtaMobileAgent.requiresReview(plainReview))
    }

    /// The "drop, never prompt" signal: an unsigned request — the exact
    /// document the old lenient parse accepted — is refused as
    /// `UntrustedIssuer` before anything showable is returned.
    func testUnsignedRequestIsRefusedAsUntrustedIssuer() async {
        let unsigned = """
            {
              "id": "urn:uuid:z",
              "type": "https://trusttasks.org/spec/auth/step-up/approve-request/0.1",
              "issuer": "\(fixtureIssuer)",
              "payload": {
                "subject": "did:key:zAlice", "sessionId": "s1",
                "challenge": "VHJhbnNmZXJDb25maXJtTm9uY2VYWQ", "reason": "Approve sign-in"
              }
            }
            """
        do {
            _ = try await VtaMobileAgent.inspect(
                approveRequest: unsigned, trustedIssuers: enrolled)
            XCTFail("an unsigned request must not parse")
        } catch FfiError.UntrustedIssuer {
            // expected — the caller logs and drops, never prompts
        } catch {
            XCTFail("expected UntrustedIssuer, got \(error)")
        }
    }

    /// A validly signed request whose issuer is not on the enrolled-executor
    /// allowlist is refused the same way.
    func testSignedRequestFromNonEnrolledIssuerIsRefused() async {
        do {
            _ = try await VtaMobileAgent.inspect(
                approveRequest: shareRequest, trustedIssuers: ["did:key:zSomeoneElse"])
            XCTFail("a non-enrolled issuer must not parse")
        } catch FfiError.UntrustedIssuer {
            // expected
        } catch {
            XCTFail("expected UntrustedIssuer, got \(error)")
        }
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
