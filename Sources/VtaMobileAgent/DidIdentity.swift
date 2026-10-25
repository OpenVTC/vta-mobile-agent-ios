import Foundation

/// The identity a DID names.
///
/// A `did:scid:vh:1` identity is the DID `did:scid:vh:1:<scid>`; a `?src=`
/// on it is only where its log is found, and the log can move without the
/// identity changing (VTI-KEY-160). Nothing else is touched: a `did:scid` and
/// the `did:webvh` of its log are different identities (VTI-KEY-164), and any
/// other DID compares exactly as given. Mirrors the engine's
/// `affinidi_did_common::scid::strip_scid_src`.
public enum DidIdentity {
    /// `did` without a did:scid `?src=` locator, when that is its only query.
    public static func of(_ did: String) -> String {
        guard did.hasPrefix("did:scid:"), let q = did.firstIndex(of: "?") else { return did }
        let base = did[..<q]
        let rest = did[did.index(after: q)...]
        let fragmentStart = rest.firstIndex(of: "#")
        let query = fragmentStart.map { rest[..<$0] } ?? rest
        let fragment = fragmentStart.map { rest[$0...] } ?? ""
        guard query.hasPrefix("src="), query.count > 4, !query.contains("&") else { return did }
        return String(base) + fragment
    }

    /// Whether two DIDs name the same identity.
    public static func same(_ a: String, _ b: String) -> Bool {
        a == b || of(a) == of(b)
    }

    /// The `src` locator of a `did:scid` DID URL, if it carries one.
    public static func scidSource(_ did: String) -> String? {
        guard did.hasPrefix("did:scid:"), of(did) != did,
            let q = did.firstIndex(of: "?")
        else { return nil }
        let rest = did[did.index(after: q)...]
        let query = rest.firstIndex(of: "#").map { rest[..<$0] } ?? rest
        return String(query.dropFirst("src=".count))
    }
}
