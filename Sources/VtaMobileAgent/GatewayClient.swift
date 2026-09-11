import Foundation

/// Minimal HTTP poster for the **push gateway** — the one service still
/// addressed by URL. Deliberately not a general VTA client: the VTA is reached
/// over ``VtaTransport`` and nothing else.
///
/// The request carries the APNs token to an unauthenticated endpoint, so the
/// session is locked down to exactly that one POST: ephemeral (no cookies,
/// cache or credential store), a short timeout, and redirects refused, so the
/// body only ever reaches the host that passed ``GatewayURLPolicy``. A refused
/// redirect surfaces as ``AgentError/http(status:body:)`` with the 3xx status.
struct GatewayClient {
    private let base: String
    private let session: URLSession

    /// `session` is injectable for tests. Redirects are refused per task as
    /// well, so an injected session cannot re-enable them.
    init(baseURL: URL, session: URLSession = GatewayClient.defaultSession) {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        self.base = s
        self.session = session
    }

    /// One shared session for the process; it retains its delegate.
    static let defaultSession = makeSession()

    static let timeout: TimeInterval = 15

    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        return config
    }

    static func makeSession(
        configuration: URLSessionConfiguration = GatewayClient.sessionConfiguration()
    ) -> URLSession {
        URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    /// POST a document to `path` and return the response body, or throw on non-2xx.
    func post(path: String, body: String) async throws -> String {
        guard let url = URL(string: base + path) else {
            throw AgentError.badResponse("invalid gateway URL: \(base + path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: req, delegate: RefuseRedirects())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            throw AgentError.http(status: status, body: text)
        }
        return text
    }
}

/// Declines every HTTP redirect: the task completes with the 3xx response
/// itself instead of re-sending the request to the `Location` target.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
