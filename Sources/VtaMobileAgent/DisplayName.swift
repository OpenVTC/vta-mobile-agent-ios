import Foundation
import VtaMobileCore

/// DID → human-readable name, the one seam this app renders identifiers through.
///
/// The phone shows DIDs where it has no choice: *who* is asking for a step-up,
/// *who* delivered a task-consent request, which VTA and mediator it is bound to.
/// A `did:webvh` in a caption is unreadable, and on an approval sheet unreadable
/// is not a cosmetic problem — it is the operator approving something they cannot
/// identify.
///
/// The lookup itself lives in the engine (`VtaMobileCore.resolveAgentName`),
/// which is a skin over `vta_sdk::display_name` — the same seam the PNM/CNM CLIs,
/// the VTC CLI and the admin console render through. This file is the app's cache
/// and rendering policy on top of it; it deliberately contains **no** part of the
/// verification decision.
///
/// ## The rules this file exists to enforce
///
/// 1. **The DID always stays visible.** A name the operator cannot cross-check
///    against an identifier is a name they cannot audit, so every surface shows
///    the name *over* the shortened DID, never instead of it.
/// 2. **An unverified name is never rendered bare.** `alsoKnownAs` is
///    self-asserted. A hostile DID can claim `mybank.com/@treasury`, and printing
///    that claim unqualified tells the operator, in an authoritative voice, that
///    they are looking at their bank — on the one screen where they are about to
///    approve something. Use ``DisplayName/rendered``, which carries the tag; do
///    not reach for ``DisplayName/name`` when building UI text.

/// Where a display name came from.
///
/// A deliberate near-copy of `vta_sdk::display_name::NameSource`, reduced to the
/// sources a phone can observe. The CLIs also draw on operator-typed labels (ACL
/// entries, local VTA aliases) read from stores this app has no access to, so an
/// agent name is the only source here. Kept as an enum rather than collapsed to a
/// `Bool` so that adding, say, an operator-typed nickname later slots in beside
/// it with the ranking rules already in place.
public enum NameSource: Equatable, Sendable {
    /// An `alsoKnownAs` entry on the DID's own document. `verified` means the
    /// engine resolved the claimed name forward and it led back to this same DID.
    case agentName(verified: Bool)

    /// Whether a name from this source may be shown without qualification.
    ///
    /// False only for an unverified agent name — see the file header.
    public var isTrusted: Bool {
        switch self {
        case .agentName(let verified): return verified
        }
    }

    /// Precedence when two sources name the same DID; higher wins.
    ///
    /// Mirrors `NameSource::rank`. With one case this decides nothing today, and
    /// that is the point: the ordering is written down now so a future local
    /// label cannot be silently displaced by a stranger's unchecked claim.
    public var rank: UInt8 {
        switch self {
        case .agentName(verified: true): return 100
        case .agentName(verified: false): return 10
        }
    }
}

/// A name for a DID, and the provenance of that name.
public struct DisplayName: Equatable, Sendable {
    /// The claimed name, e.g. `example.com/@treasury`. **Not for display on its
    /// own** — use ``rendered``.
    public let name: String
    public let source: NameSource

    public init(name: String, source: NameSource) {
        self.name = name
        self.source = source
    }

    /// See ``NameSource/isTrusted``.
    public var isTrusted: Bool { source.isTrusted }

    /// Marker appended to a name that did not round-trip. Surfaces may restyle it
    /// (this app colours it amber and swaps the seal for a warning) but must not
    /// drop it. Matches `vta_sdk::display_name::UNVERIFIED_SUFFIX`.
    public static let unverifiedSuffix = " [unverified]"

    /// The name as it may be shown: tagged when unverified.
    ///
    /// Every UI path goes through here, so there is no way to render a
    /// self-asserted claim as though the app believed it.
    public var rendered: String {
        isTrusted ? name : name + Self.unverifiedSuffix
    }
}

/// Abbreviate a DID for a narrow phone caption, keeping the part that identifies
/// it — a `did:webvh`'s domain and path tail, or a head+tail of an opaque id.
///
/// Delegates to the engine rather than reimplementing the rule, so the phone, the
/// CLIs and the admin console cannot drift: an operator moves between all three
/// looking at the same community, and a DID abbreviated two ways is one they must
/// re-identify on every switch. `DisplayNameTests` re-asserts the shared vector
/// table through this function.
public func shortenDid(_ did: String) -> String {
    VtaMobileCore.shortenDid(did: did)
}

/// Resolves display names for DIDs, once each, and caches the answer.
///
/// A lookup costs a DID resolution plus an outbound HTTPS fetch per claimed name,
/// which is far too much to repeat inside a SwiftUI `body`. So views ask this
/// actor, render the shortened DID immediately, and upgrade in place when the
/// name arrives — a name is an enhancement to an approval prompt, never something
/// the prompt waits on.
public actor NameResolver {
    /// The engine call, injectable so tests exercise the cache without a network.
    public typealias Lookup = @Sendable (String) async -> DisplayName?

    /// Shared instance the UI uses; one cache per process.
    public static let shared = NameResolver()

    /// How long a *found* name is trusted. A verified name is cryptographically
    /// bound to the DID and changes about as often as the DID does.
    static let hitTTL: TimeInterval = 6 * 60 * 60

    /// How long a *miss* is remembered. Much shorter than a hit: no DID in the
    /// ecosystem publishes a name yet, so today every lookup misses, and a miss
    /// cached for the session would mean an app that never notices the day names
    /// start being minted.
    static let missTTL: TimeInterval = 10 * 60

    private struct Entry {
        let name: DisplayName?
        let at: Date
    }

    private let lookup: Lookup
    private let now: @Sendable () -> Date
    private var cache: [String: Entry] = [:]
    /// In-flight lookups, so N views asking about the same DID in the same frame
    /// produce one network round trip rather than N.
    private var inFlight: [String: Task<DisplayName?, Never>] = [:]

    public init(
        lookup: @escaping Lookup = NameResolver.engineLookup,
        // A closure literal rather than `Date.init`: an unapplied initializer
        // reference is not `Sendable`, so passing it here warns about data races.
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lookup = lookup
        self.now = now
    }

    /// The default ``Lookup``: the engine's round-tripped agent-name resolution.
    ///
    /// `verified` is the engine's conclusion, carried across the FFI rather than
    /// re-derived here — the round trip is a spoofing defence, and two
    /// implementations of it in two languages would have to agree forever.
    public static let engineLookup: Lookup = { did in
        guard let found = await VtaMobileCore.resolveAgentName(did: did) else { return nil }
        return DisplayName(name: found.name, source: .agentName(verified: found.verified))
    }

    /// The name for `did`, from cache when fresh, otherwise looked up.
    ///
    /// Never throws and never fails the caller: an unreachable name server
    /// degrades to `nil`, i.e. show the DID.
    public func name(for did: String) async -> DisplayName? {
        if let entry = cache[did], !isStale(entry) {
            return entry.name
        }
        if let running = inFlight[did] {
            return await running.value
        }

        let task = Task<DisplayName?, Never> { [lookup] in await lookup(did) }
        inFlight[did] = task
        let found = await task.value
        inFlight[did] = nil
        cache[did] = Entry(name: found, at: now())
        return found
    }

    /// The cached name for `did`, if one was already resolved and is still fresh.
    ///
    /// For synchronous render paths that want a name *if it is free* and the
    /// shortened DID otherwise.
    public func cached(_ did: String) -> DisplayName? {
        guard let entry = cache[did], !isStale(entry) else { return nil }
        return entry.name
    }

    private func isStale(_ entry: Entry) -> Bool {
        let ttl = entry.name == nil ? Self.missTTL : Self.hitTTL
        return now().timeIntervalSince(entry.at) >= ttl
    }
}
