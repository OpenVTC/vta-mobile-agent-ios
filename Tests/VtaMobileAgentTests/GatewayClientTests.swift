import XCTest

@testable import VtaMobileAgent

/// The push-gateway POST must never follow a redirect: the body carries the
/// APNs token, and only the host that passed `GatewayURLPolicy` may receive it.
final class GatewayClientTests: XCTestCase {
    private let gateway = URL(string: "https://gw.example.com")!

    override func setUp() {
        super.setUp()
        RedirectingURLProtocol.reset()
    }

    private func stubConfiguration(
        _ base: URLSessionConfiguration = GatewayClient.sessionConfiguration()
    ) -> URLSessionConfiguration {
        base.protocolClasses = [RedirectingURLProtocol.self]
        return base
    }

    /// Control: a stock session does follow the stub's 307, so the refusals
    /// below are not passing vacuously.
    func testStubRedirectIsFollowedByAStockSession() async throws {
        let session = URLSession(configuration: stubConfiguration(.ephemeral))
        var req = URLRequest(url: gateway.appendingPathComponent("trust-tasks"))
        req.httpMethod = "POST"
        _ = try? await session.data(for: req)
        XCTAssertEqual(
            RedirectingURLProtocol.requestedHosts,
            [gateway.host!, RedirectingURLProtocol.redirectHost])
    }

    func testDefaultSessionRefusesRedirect() async {
        let client = GatewayClient(
            baseURL: gateway,
            session: GatewayClient.makeSession(configuration: stubConfiguration()))
        await assertRedirectRefused(client)
    }

    /// Redirects are refused per task too, so an injected session can't turn
    /// them back on.
    func testInjectedStockSessionStillRefusesRedirect() async {
        let client = GatewayClient(
            baseURL: gateway, session: URLSession(configuration: stubConfiguration(.ephemeral)))
        await assertRedirectRefused(client)
    }

    private func assertRedirectRefused(
        _ client: GatewayClient, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await client.post(path: "/trust-tasks", body: #"{"token":"x"}"#)
            XCTFail("a 307 must not succeed", file: file, line: line)
        } catch AgentError.http(let status, _) {
            XCTAssertEqual(status, 307, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertEqual(
            RedirectingURLProtocol.requestedHosts, [gateway.host!],
            "exactly one request, to the gateway itself", file: file, line: line)
    }

    func testSessionConfigurationIsEphemeralAndBounded() {
        let config = GatewayClient.sessionConfiguration()
        XCTAssertEqual(config.timeoutIntervalForRequest, 15)
        XCTAssertEqual(config.timeoutIntervalForResource, 15)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertTrue(GatewayClient.defaultSession.delegate is RefuseRedirects)
    }
}

/// Answers the gateway host with a 307 to another host, and anything else with
/// a 200. Records every request it is asked to load.
final class RedirectingURLProtocol: URLProtocol {
    static let redirectHost = "collector.example.net"

    private static let lock = NSLock()
    private static var hosts: [String] = []

    static var requestedHosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    static func reset() {
        lock.lock()
        hosts = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.hosts.append(url.host ?? "")
        Self.lock.unlock()

        if url.host != Self.redirectHost {
            let target = URL(string: "https://\(Self.redirectHost)/trust-tasks")!
            let redirect = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let ok = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
