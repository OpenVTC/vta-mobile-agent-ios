import XCTest

@testable import VtaMobileAgent

final class PairingPayloadTests: XCTestCase {
    func testEncodeThenParseRoundTrips() {
        let p = PairingPayload(
            vtaDID: "did:webvh:vta",
            mediatorDID: "did:key:zMediator",
            gatewayURL: "https://gw.example",
            tenant: "acme")
        let encoded = p.encoded()
        XCTAssertTrue(encoded.hasPrefix("cierge-pair://v1?"))
        XCTAssertEqual(PairingPayload.parse(encoded), p)
    }

    /// The mediator-only pairing the agent actually needs: DID pair, no REST URL.
    func testParsesMediatorOnlyUrl() {
        let p = PairingPayload.parse(
            "cierge-pair://v1?did=did:webvh:vta&mediator=did:key:zMediator")
        XCTAssertEqual(p?.vtaDID, "did:webvh:vta")
        XCTAssertEqual(p?.mediatorDID, "did:key:zMediator")
        XCTAssertNil(p?.vtaURL)
    }

    /// The DID alone is enough — the operator fills the mediator in Settings.
    func testParsesDidOnlyUrl() {
        let p = PairingPayload.parse("cierge-pair://v1?did=did:webvh:vta")
        XCTAssertEqual(p?.vtaDID, "did:webvh:vta")
        XCTAssertNil(p?.mediatorDID)
    }

    /// A code minted for a pre-mediator client still scans; `vta` is carried but
    /// unused rather than making the code invalid.
    func testLegacyVtaUrlIsAcceptedAndIgnored() {
        let p = PairingPayload.parse("cierge-pair://v1?vta=https://vta.example&did=did:webvh:vta")
        XCTAssertEqual(p?.vtaDID, "did:webvh:vta")
        XCTAssertEqual(p?.vtaURL, "https://vta.example")
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
        // Missing the one required field: the VTA DID.
        XCTAssertNil(PairingPayload.parse("cierge-pair://v1?vta=https://vta.example"))
        // Wrong scheme.
        XCTAssertNil(PairingPayload.parse("other://v1?vta=x&did=y"))
    }
}
