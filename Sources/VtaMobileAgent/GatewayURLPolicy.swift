import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Why a push-gateway URL was refused — or, for ``hostNotBoundToVta(_:)`` only,
/// why it deserves a warning before it is saved.
public enum GatewayURLError: Error, Equatable {
    /// Not parseable, no host, or a host with characters outside ASCII letters,
    /// digits, `-` and `.`.
    case malformed
    case notHTTPS
    case userInfo
    /// A port other than the https default (443).
    case port
    case queryOrFragment
    /// An IP address in any spelling a URL parser or `getaddrinfo` accepts.
    case ipLiteral
    /// A single-label host or a name under a local-only suffix.
    case localName
    /// Structurally acceptable, but the host is not under the paired VTA's
    /// `did:web` / `did:webvh` domain. Advisory: surface it, don't hide it.
    case hostNotBoundToVta(String)

    /// Only the domain-binding result is a warning; every other case refuses
    /// the URL outright.
    public var isWarning: Bool {
        if case .hostNotBoundToVta = self { return true }
        return false
    }
}

extension GatewayURLError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformed:
            return "The push gateway URL is not a valid https URL with a DNS host name."
        case .notHTTPS:
            return "The push gateway URL must use https."
        case .userInfo:
            return "The push gateway URL must not contain a user name or password."
        case .port:
            return "The push gateway URL must use the default https port."
        case .queryOrFragment:
            return "The push gateway URL must not contain a query or fragment."
        case .ipLiteral:
            return "The push gateway must be addressed by a DNS name, not an IP address."
        case .localName:
            return "The push gateway must have a public DNS name, not a local or single-label one."
        case .hostNotBoundToVta(let host):
            return "\(host) is not under the paired VTA's domain."
        }
    }
}

/// The rules a push-gateway URL must satisfy before this app will POST an APNs
/// token to it. Pure and deterministic, so the same function runs when a URL is
/// written (pairing review, Settings save) and again when it is used.
///
/// What this can enforce: https only, no userinfo, default port, no query or
/// fragment, a DNS host that is not an IP literal in any spelling and not a
/// local-only name. What it cannot: DNS rebinding (URLSession exposes no
/// resolver hook), or telling a legitimate public gateway from any other public
/// host — the domain binding below is a hint for the operator, not proof.
public enum GatewayURLPolicy {
    /// Structural validation followed by the domain binding. A binding miss is
    /// returned as `.failure(.hostNotBoundToVta)`; callers that treat it as a
    /// warning use ``validateStructure(_:)`` and ``bindingWarning(for:vtaDID:)``.
    public static func validate(_ raw: String, vtaDID: String?) -> Result<URL, GatewayURLError> {
        validateStructure(raw).flatMap { url in
            bindingWarning(for: url, vtaDID: vtaDID).map { .failure($0) } ?? .success(url)
        }
    }

    /// The hard rules only. On success returns a normalised URL (lowercased
    /// host, no trailing dot, no explicit port) built from the validated parts,
    /// so the URL that is dialled is exactly the one that was checked.
    public static func validateStructure(_ raw: String) -> Result<URL, GatewayURLError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Foundation reads `\` as part of the userinfo while WHATWG parsers read
        // it as a path separator; refuse input where the two disagree on the host.
        guard !trimmed.isEmpty, !trimmed.contains("\\"),
            let comps = URLComponents(string: trimmed)
        else { return .failure(.malformed) }
        guard comps.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard comps.percentEncodedUser == nil, comps.percentEncodedPassword == nil else {
            return .failure(.userInfo)
        }
        guard let rawHost = comps.host, !rawHost.isEmpty else { return .failure(.malformed) }
        guard comps.port == nil || comps.port == 443 else { return .failure(.port) }
        guard comps.percentEncodedQuery == nil, comps.percentEncodedFragment == nil else {
            return .failure(.queryOrFragment)
        }
        return normalizedHost(rawHost).flatMap { host in
            var out = URLComponents()
            out.scheme = "https"
            out.host = host
            out.percentEncodedPath = comps.percentEncodedPath
            return out.url.map { .success($0) } ?? .failure(.malformed)
        }
    }

    /// `.hostNotBoundToVta` when `vtaDID` is a `did:web` / `did:webvh` and the
    /// URL's host is neither under that domain nor under its parent; `nil` when
    /// bound, or when the DID names no web domain to bind to (e.g. `did:key`).
    public static func bindingWarning(for url: URL, vtaDID: String?) -> GatewayURLError? {
        guard let vtaDID, let domain = webDomain(ofDID: vtaDID),
            let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let base = bindingBase(for: domain)
        if host == base || host.hasSuffix("." + base) { return nil }
        return .hostNotBoundToVta(host)
    }

    /// The web domain a `did:web` / `did:webvh` resolves against — lowercased,
    /// with any `%3A` port and path segments dropped — or `nil` for any other
    /// DID method.
    public static func webDomain(ofDID did: String) -> String? {
        let parts = did.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "did" else { return nil }
        let segment: Substring
        switch parts[1] {
        case "web":
            segment = parts[2]
        case "webvh":
            // did:webvh:<scid>:<domain>[:path…]
            guard parts.count >= 4 else { return nil }
            segment = parts[3]
        default:
            return nil
        }
        guard let decoded = String(segment).removingPercentEncoding,
            var host = decoded.split(separator: ":", maxSplits: 1).first.map(String.init)
        else { return nil }
        host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    // MARK: Host rules

    /// Suffixes that never name a public host. `home.arpa` and the reverse-DNS
    /// zones are covered by `arpa`; `svc` is the Kubernetes service suffix.
    static let localSuffixes = [
        "localhost", "local", "localdomain", "internal", "intranet", "lan", "home", "corp",
        "arpa", "svc",
    ]

    static func normalizedHost(_ raw: String) -> Result<String, GatewayURLError> {
        // `URLComponents.host` keeps IPv6 brackets while `URL.host` drops them;
        // a colon only appears in a host as part of an IPv6 literal (or zone id)
        // either way.
        if raw.hasPrefix("[") || raw.contains(":") { return .failure(.ipLiteral) }
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253,
            host.unicodeScalars.allSatisfy({ isLetterDigitHyphenOrDot($0) })
        else { return .failure(.malformed) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else {
            return .failure(.malformed)
        }
        if isIPv4Literal(host, lastLabel: labels[labels.count - 1]) {
            return .failure(.ipLiteral)
        }
        if labels.count < 2 { return .failure(.localName) }
        if localSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return .failure(.localName)
        }
        return .success(host)
    }

    /// Foundation leaves `2130706433`, `0x7f.0.0.1` and `127.1` as they are,
    /// while `getaddrinfo` treats all three as `127.0.0.1`. Two checks close
    /// that gap: the WHATWG "ends in a number" rule (a final label that is all
    /// decimal digits or `0x`-hex makes the host an IPv4 address — which also
    /// catches out-of-range forms such as `0x100000000` and `1.2.3.4.5`), and
    /// `inet_aton`, which accepts every shorthand the system resolver does.
    static func isIPv4Literal(_ host: String, lastLabel: Substring) -> Bool {
        let digits = lastLabel.unicodeScalars
        if digits.allSatisfy({ ("0"..."9").contains($0) }) { return true }
        if lastLabel.hasPrefix("0x"),
            lastLabel.dropFirst(2).unicodeScalars.allSatisfy({
                ("0"..."9").contains($0) || ("a"..."f").contains($0)
            })
        {
            return true
        }
        var addr = in_addr()
        return inet_aton(host, &addr) != 0
    }

    private static func isLetterDigitHyphenOrDot(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("0"..."9").contains(s) || s == "-" || s == "."
    }

    /// The domain a gateway host must fall under. A VTA at `vta.example.com`
    /// binds `*.example.com`; a VTA at `example.com` binds `*.example.com`
    /// itself, never `*.com`. Without a public-suffix list a three-label domain
    /// with a short middle label (`example.co.uk`) is bound to itself rather
    /// than its parent, so the rule errs towards a spurious warning, never a
    /// missing one.
    static func bindingBase(for domain: String) -> String {
        let labels = domain.split(separator: ".")
        guard labels.count >= 3 else { return domain }
        if labels.count == 3 && labels[1].count <= 3 { return domain }
        return labels.dropFirst().joined(separator: ".")
    }
}
