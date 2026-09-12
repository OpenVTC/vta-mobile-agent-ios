import XCTest

@testable import VtaMobileAgent

/// A pairing code is unauthenticated input. These pin what the policy does with
/// it: nothing is applied without a review, the mediator comes from the VTA's
/// DID document, and the gateway passes the URL rules.
final class PairingPolicyTests: XCTestCase {
    private let unexpectedQR =
        "cierge-pair://v1?did=did:web:attacker-vta&mediator=did:web:attacker-mediator&gateway=https://attacker.example/"

    /// Any well-formed code still parses — parsing is not trust. What it yields
    /// is a review naming every identity involved, flagged as replacing the
    /// currently paired VTA.
    func testCodeForAnotherVtaBecomesAReviewThatReplacesTheCurrentOne() throws {
        let payload = try XCTUnwrap(PairingPayload.parse(unexpectedQR))
        let review = try PairingPolicy.review(
            payload, resolvedMediator: "did:web:attacker-mediator",
            currentVtaDID: "did:webvh:legit"
        ).get()

        XCTAssertEqual(review.replacingVtaDID, "did:webvh:legit")
        XCTAssertTrue(review.replacesDifferentVta)
        XCTAssertEqual(review.vtaDID, "did:web:attacker-vta")
        XCTAssertEqual(review.mediatorDID, "did:web:attacker-mediator")
        XCTAssertEqual(review.gatewayURL, URL(string: "https://attacker.example/"))
        // The gateway is not under the VTA's domain, so the sheet warns.
        XCTAssertEqual(review.gatewayWarning, .hostNotBoundToVta("attacker.example"))
    }

    /// The code's mediator is a cross-check only.
    func testMediatorDifferentFromTheDidDocumentIsRejected() throws {
        let payload = try XCTUnwrap(PairingPayload.parse(unexpectedQR))
        XCTAssertEqual(
            PairingPolicy.review(
                payload, resolvedMediator: "did:web:mediator.example.com", currentVtaDID: nil),
            .failure(
                .mediatorMismatch(
                    qr: "did:web:attacker-mediator", didDoc: "did:web:mediator.example.com")))
    }

    /// The JSON form is gone entirely, gateway and all.
    func testRawJsonNoLongerParses() {
        let json =
            #"{"vtaDID":"did:web:attacker-vta","mediatorDID":"did:web:attacker-mediator","gatewayURL":"http://169.254.169.254/"}"#
        XCTAssertNil(PairingPayload.parse(json))
    }

    func testDidOnlyCodeWithoutAMediatorInTheDidDocumentIsRejected() throws {
        let payload = try XCTUnwrap(PairingPayload.parse("cierge-pair://v1?did=did:web:attacker-vta"))
        XCTAssertEqual(
            PairingPolicy.review(payload, resolvedMediator: nil, currentVtaDID: nil),
            .failure(.noDidcommService))
        XCTAssertEqual(
            PairingPolicy.review(payload, resolvedMediator: "  ", currentVtaDID: nil),
            .failure(.noDidcommService))
    }

    func testDidOnlyCodeTakesTheMediatorFromTheDidDocument() throws {
        let payload = try XCTUnwrap(
            PairingPayload.parse("cierge-pair://v1?did=did:webvh:QmSCID:example.com"))
        let review = try PairingPolicy.review(
            payload, resolvedMediator: "did:web:mediator.example.com", currentVtaDID: nil
        ).get()
        XCTAssertEqual(review.mediatorDID, "did:web:mediator.example.com")
        XCTAssertNil(review.gatewayURL)
        XCTAssertNil(review.gatewayWarning)
        XCTAssertNil(review.replacingVtaDID)
        XCTAssertFalse(review.replacesDifferentVta)
        XCTAssertEqual(review.vtaDomain, "example.com")
    }

    func testGatewayBreakingAHardRuleRejectsThePairing() throws {
        let payload = try XCTUnwrap(
            PairingPayload.parse(
                "cierge-pair://v1?did=did:webvh:QmSCID:example.com&gateway=http://169.254.169.254/"))
        XCTAssertEqual(
            PairingPolicy.review(
                payload, resolvedMediator: "did:web:mediator.example.com", currentVtaDID: nil),
            .failure(.gateway(.notHTTPS)))

        let ip = PairingPayload(vtaDID: "did:webvh:QmSCID:example.com", gatewayURL: "https://10.0.0.5/")
        XCTAssertEqual(
            PairingPolicy.review(ip, resolvedMediator: "did:web:m.example.com", currentVtaDID: nil),
            .failure(.gateway(.ipLiteral)))
    }

    func testGatewayUnderTheVtaDomainHasNoWarning() throws {
        let payload = PairingPayload(
            vtaDID: "did:webvh:QmSCID:vta.example.com", gatewayURL: "https://push.example.com",
            tenant: "acme")
        let review = try PairingPolicy.review(
            payload, resolvedMediator: "did:web:mediator.example.com", currentVtaDID: nil
        ).get()
        XCTAssertEqual(review.gatewayURL, URL(string: "https://push.example.com"))
        XCTAssertNil(review.gatewayWarning)
        XCTAssertEqual(review.tenant, "acme")
    }

    /// Re-saving the same VTA (e.g. a new gateway) is not a replacement.
    func testSameVtaIsNotAReplacement() throws {
        let payload = PairingPayload(vtaDID: " did:webvh:QmSCID:example.com ")
        let review = try PairingPolicy.review(
            payload, resolvedMediator: "did:web:m.example.com",
            currentVtaDID: "did:webvh:QmSCID:example.com"
        ).get()
        XCTAssertEqual(review.vtaDID, "did:webvh:QmSCID:example.com")
        XCTAssertEqual(review.replacingVtaDID, "did:webvh:QmSCID:example.com")
        XCTAssertFalse(review.replacesDifferentVta)
    }

    func testEmptyCurrentVtaIsAFirstPairing() throws {
        let review = try PairingPolicy.review(
            PairingPayload(vtaDID: "did:web:example.com"), resolvedMediator: "did:web:m.example.com",
            currentVtaDID: ""
        ).get()
        XCTAssertNil(review.replacingVtaDID)
        XCTAssertFalse(review.replacesDifferentVta)
    }

    func testNonDidVtaIsRejected() {
        for bad in ["", "   ", "example.com", "did:", "did:web", "did:web:", "did:web:exa mple.com"] {
            XCTAssertEqual(
                PairingPolicy.review(
                    PairingPayload(vtaDID: bad), resolvedMediator: "did:web:m.example.com",
                    currentVtaDID: nil),
                .failure(.invalidVtaDID), bad)
        }
    }

    /// Round-tripping through the app's own encoder changes nothing: the
    /// re-parsed code gets exactly the same review.
    func testEncodedRoundTripYieldsTheSameReview() throws {
        let payload = try XCTUnwrap(PairingPayload.parse(unexpectedQR))
        let rebuilt = try XCTUnwrap(PairingPayload.parse(payload.encoded()))
        XCTAssertEqual(
            PairingPolicy.review(
                rebuilt, resolvedMediator: "did:web:attacker-mediator", currentVtaDID: nil),
            PairingPolicy.review(
                payload, resolvedMediator: "did:web:attacker-mediator", currentVtaDID: nil))
    }
}
