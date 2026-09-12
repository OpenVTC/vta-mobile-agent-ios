import XCTest

@testable import VtaMobileAgent

/// The push-gateway URL rules. Table-driven: the first table is every gateway
/// the previous `URL(string:)` + `scheme != nil` check let through; the rest
/// are the URL, name and scheme vectors shared with the server-side egress
/// checks (Swift expectation: block even where Foundation does not normalise
/// the host, e.g. `2130706433`, `0x7f.0.0.1`, `127.1`).
final class GatewayURLPolicyTests: XCTestCase {
    private let vtaDID = "did:webvh:QmSCID:example.com"

    private func assertRefused(
        _ raw: String, _ expected: GatewayURLError? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch GatewayURLPolicy.validate(raw, vtaDID: vtaDID) {
        case .success(let url):
            XCTFail("accepted \(raw) as \(url)", file: file, line: line)
        case .failure(let error):
            XCTAssertFalse(
                error.isWarning, "\(raw) must be refused outright, got \(error)",
                file: file, line: line)
            if let expected {
                XCTAssertEqual(error, expected, raw, file: file, line: line)
            }
            // The structural check alone must refuse it too — use time relies on it.
            if case .success(let url) = GatewayURLPolicy.validateStructure(raw) {
                XCTFail("validateStructure accepted \(raw) as \(url)", file: file, line: line)
            }
        }
    }

    // MARK: Previously accepted gateways

    func testGatewaysThePreviousCheckAcceptedAreNowRefused() {
        assertRefused(
            "http://169.254.169.254/latest/meta-data/iam/security-credentials/", .notHTTPS)
        assertRefused("http://127.0.0.1:6379/", .notHTTPS)
        assertRefused("http://internal.svc/collect", .notHTTPS)
        assertRefused("https://internal.svc/collect", .localName)
        assertRefused("http://10.0.0.5:8080/x", .notHTTPS)
        // https + public name, but outside the VTA's domain: not silently accepted.
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://attacker.example/collect", vtaDID: vtaDID),
            .failure(.hostNotBoundToVta("attacker.example")))
    }

    /// The same hosts over https, so the host rules — not just the scheme — are
    /// what refuses them.
    func testPreviouslyAcceptedHostsAreRefusedOverHttpsToo() {
        assertRefused("https://169.254.169.254/latest/meta-data/", .ipLiteral)
        assertRefused("https://127.0.0.1/", .ipLiteral)
        assertRefused("https://10.0.0.5/x", .ipLiteral)
    }

    // MARK: Plan vectors

    func testAdditionalRefusals() {
        assertRefused("http://2130706433/", .notHTTPS)
        assertRefused("https://2130706433/", .ipLiteral)
        assertRefused("https://0x7f000001/", .ipLiteral)
        assertRefused("https://[::1]/", .ipLiteral)
        assertRefused("https://[::ffff:169.254.169.254]/", .ipLiteral)
        assertRefused("https://user:pw@gw.example.com/", .userInfo)
        assertRefused("https://gw.example.com:8443/", .port)
        assertRefused("https://localhost/", .localName)
        assertRefused("https://printer.local/", .localName)
    }

    // MARK: Shared conformance vectors

    func testIPv4AndIPv6SpellingsAreRefused() {
        for raw in [
            "https://2130706433/", "https://0x7f000001/", "https://017700000001/",
            "https://0177.0.0.1/", "https://0x7f.0.0.1/", "https://127.1/", "https://127.0.1/",
            "https://0/", "https://169.254.169.254./", "https://[::ffff:127.0.0.1]/",
            "https://[0:0:0:0:0:ffff:7f00:1]/", "https://[::1]:8443/",
            // Invalid as IPv4 to a WHATWG parser, still never a DNS name.
            "https://0x100000000/", "https://1.2.3.4.5/", "https://[fe80::1%25en0]/",
        ] {
            assertRefused(raw)
        }
    }

    /// Percent-encoded, full-width and circled-digit spellings: Foundation may
    /// normalise these to `127.0.0.1` or keep them non-ASCII depending on the OS
    /// version. Either way they must not pass.
    func testEncodedAndUnicodeHostSpellingsAreRefused() {
        for raw in [
            "https://%31%32%37.0.0.1/", "https://①②⑦.0.0.1/", "https://127。0。0。1/",
        ] {
            assertRefused(raw)
        }
    }

    func testUserInfoIsRefused() {
        assertRefused("https://example.com@127.0.0.1/", .userInfo)
        assertRefused("https://user:pass@example.com/", .userInfo)
        assertRefused("https://@example.com/", .userInfo)
        // Parsers disagree on which side of `\@` the host is.
        assertRefused("https://127.0.0.1\\@example.com/")
    }

    func testLocalAndSingleLabelNamesAreRefused() {
        for raw in [
            "https://localhost/", "https://LOCALHOST./", "https://svc.localhost/",
            "https://printer.local/", "https://kube-dns.kube-system.svc.cluster.local/",
            "https://metadata.google.internal/", "https://router.home.arpa/",
            "https://metadata/",
        ] {
            assertRefused(raw, .localName)
        }
    }

    func testNonHttpsSchemesAreRefused() {
        for raw in [
            "http://example.com/", "ws://example.com/", "wss://example.com/",
            "ftp://example.com/", "file:///etc/passwd", "gopher://example.com/",
            "data:text/plain,x", "javascript:alert(1)", "blob:https://x/y",
        ] {
            assertRefused(raw, .notHTTPS)
        }
    }

    func testQueryFragmentAndMalformedInputAreRefused() {
        assertRefused("https://gw.example.com/?token=1", .queryOrFragment)
        assertRefused("https://gw.example.com/?", .queryOrFragment)
        assertRefused("https://gw.example.com/#x", .queryOrFragment)
        assertRefused("", .malformed)
        assertRefused("gw.example.com", .notHTTPS)
        assertRefused("https:///trust-tasks", .malformed)
        assertRefused("https://gw..example.com/", .malformed)
        assertRefused("https://gw_1.example.com/", .malformed)
    }

    // MARK: Accepted

    func testGatewayUnderTheVtaDomainIsAccepted() {
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://push.example.com", vtaDID: vtaDID),
            .success(URL(string: "https://push.example.com")!))
    }

    func testPublicNamesAreAcceptedAndNormalised() {
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://example.com/", vtaDID: vtaDID),
            .success(URL(string: "https://example.com/")!))
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://example.com./", vtaDID: vtaDID),
            .success(URL(string: "https://example.com/")!))
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://localhost.example.com/", vtaDID: vtaDID),
            .success(URL(string: "https://localhost.example.com/")!))
        XCTAssertEqual(
            GatewayURLPolicy.validate("  HTTPS://Push.Example.COM:443/gw/v1  ", vtaDID: vtaDID),
            .success(URL(string: "https://push.example.com/gw/v1")!))
    }

    // MARK: Domain binding (warning)

    func testHostOutsideTheVtaDomainIsAWarning() {
        let result = GatewayURLPolicy.validate("https://attacker.example", vtaDID: vtaDID)
        XCTAssertEqual(result, .failure(.hostNotBoundToVta("attacker.example")))
        if case .failure(let error) = result { XCTAssertTrue(error.isWarning) }
        // Structurally fine, so a caller can still show it with the warning.
        XCTAssertEqual(
            GatewayURLPolicy.validateStructure("https://attacker.example"),
            .success(URL(string: "https://attacker.example")!))
    }

    func testLookalikeSuffixIsNotBound() {
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://push.notexample.com", vtaDID: vtaDID),
            .failure(.hostNotBoundToVta("push.notexample.com")))
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://example.com.evil.net", vtaDID: vtaDID),
            .failure(.hostNotBoundToVta("example.com.evil.net")))
    }

    /// A VTA on a subdomain binds its parent; a VTA on a registrable domain
    /// binds only that domain, never the TLD.
    func testBindingBase() {
        let sub = "did:webvh:QmSCID:vta.example.com:tenants:acme"
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://push.example.com", vtaDID: sub),
            .success(URL(string: "https://push.example.com")!))
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://other.com", vtaDID: "did:web:example.com"),
            .failure(.hostNotBoundToVta("other.com")))
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://attacker.co.uk", vtaDID: "did:web:example.co.uk"),
            .failure(.hostNotBoundToVta("attacker.co.uk")))
    }

    func testDidWithoutAWebDomainHasNoBinding() {
        XCTAssertEqual(
            GatewayURLPolicy.validate(
                "https://gw.example.net", vtaDID: "did:key:z6MkfrQjWzPQrTuVwXyZaBcDeFgH"),
            .success(URL(string: "https://gw.example.net")!))
        XCTAssertEqual(
            GatewayURLPolicy.validate("https://gw.example.net", vtaDID: nil),
            .success(URL(string: "https://gw.example.net")!))
    }

    func testWebDomainOfDID() {
        XCTAssertEqual(GatewayURLPolicy.webDomain(ofDID: "did:web:Example.com"), "example.com")
        XCTAssertEqual(
            GatewayURLPolicy.webDomain(ofDID: "did:web:vta.example.com%3A8443:users:a"),
            "vta.example.com")
        XCTAssertEqual(
            GatewayURLPolicy.webDomain(ofDID: "did:webvh:QmSCID:webvh.example.org:glenn-vta"),
            "webvh.example.org")
        XCTAssertNil(GatewayURLPolicy.webDomain(ofDID: "did:webvh:QmSCID"))
        XCTAssertNil(GatewayURLPolicy.webDomain(ofDID: "did:key:z6Mk"))
        XCTAssertNil(GatewayURLPolicy.webDomain(ofDID: "not a did"))
    }
}
