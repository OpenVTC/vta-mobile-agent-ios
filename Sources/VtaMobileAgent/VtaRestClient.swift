import Foundation

/// Thin REST transport to a VTA. Posts engine-built Trust Task documents and
/// returns the raw response body for the engine to parse.
///
/// The VTA's auth endpoints content-negotiate: because we POST Trust Task
/// documents, they reply with TT `#response` documents — exactly what
/// `vta-mobile-core`'s `parse_*` functions consume. No DIDComm / mediator
/// needed; this is plain REST.
public struct VtaRestClient {
    /// VTA base URL, e.g. `http://192.168.1.10:8100` (no trailing slash).
    private let base: String
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        self.base = s
        self.session = session
    }

    /// POST a document body to `path` (kept verbatim, incl. the trailing slash
    /// on `/auth/`) and return the response body, or throw on a non-2xx.
    func post(path: String, body: String, bearer: String? = nil) async throws -> String {
        guard let url = URL(string: base + path) else {
            throw AgentError.badResponse("invalid URL: \(base + path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            throw AgentError.http(status: status, body: text)
        }
        return text
    }
}
