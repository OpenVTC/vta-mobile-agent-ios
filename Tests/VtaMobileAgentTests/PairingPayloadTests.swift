import XCTest

@testable import VtaMobileAgent

final class PairingPayloadTests: XCTestCase {
    func testEncodeThenParseRoundTrips() {
        let p = PairingPayload(
            vtaURL: "https://vta.example",
            vtaDID: "did:webvh:vta",
            mediatorDID: "did:key:zMediator",
            gatewayURL: "https://gw.example",
            tenant: "acme")
        let encoded = p.encoded()
        XCTAssertTrue(encoded.hasPrefix("cierge-pair://v1?"))
        XCTAssertEqual(PairingPayload.parse(encoded), p)
    }

    func testParsesMinimalUrl() {
        let p = PairingPayload.parse("cierge-pair://v1?vta=https://vta.example&did=did:webvh:vta")
        XCTAssertEqual(p?.vtaURL, "https://vta.example")
        XCTAssertEqual(p?.vtaDID, "did:webvh:vta")
        XCTAssertNil(p?.mediatorDID)
    }

    func testParsesRawJson() {
        let json = #"{"vtaURL":"https://v","vtaDID":"did:webvh:v","tenant":"acme"}"#
        let p = PairingPayload.parse(json)
        XCTAssertEqual(p?.vtaDID, "did:webvh:v")
        XCTAssertEqual(p?.tenant, "acme")
    }

    func testRejectsJunkOrIncomplete() {
        XCTAssertNil(PairingPayload.parse("not a pairing code"))
        XCTAssertNil(PairingPayload.parse("https://example.com/other"))
        // Missing the required did.
        XCTAssertNil(PairingPayload.parse("cierge-pair://v1?vta=https://vta.example"))
        // Wrong scheme.
        XCTAssertNil(PairingPayload.parse("other://v1?vta=x&did=y"))
    }
}
