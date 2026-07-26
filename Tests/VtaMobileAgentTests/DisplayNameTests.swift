import XCTest

@testable import VtaMobileAgent

/// The DID→name display seam.
///
/// Two things are being defended here, and they are not the same thing:
///
/// - **Abbreviation agrees with the rest of the ecosystem.** The vector table
///   below is the one asserted by `shorten_did_matches_shared_vectors` in
///   `vta-sdk/src/display_name/mod.rs` and reproduced in the admin console's
///   `format.ts`. An operator moves between this app, a terminal and the console
///   looking at the same community; a DID abbreviated three ways is one they must
///   re-identify on every switch.
/// - **An unverified claim can never render as fact.** `alsoKnownAs` is
///   self-asserted, so a hostile DID can claim `mybank.com/@treasury`. These tests
///   pin the tagging so a refactor cannot quietly drop it.
final class DisplayNameTests: XCTestCase {

    // MARK: shortenDid — the shared vector table

    /// Asserted against the engine, which is where the implementation lives. If
    /// this fails after an engine bump, the Rust vector table changed and this
    /// app, the CLIs and the console have drifted apart.
    func testShortenDidMatchesTheSharedVectors() {
        let vectors: [(String, String)] = [
            // Not a DID — untouched.
            ("alice", "alice"),
            ("https://example.com/@alice", "https://example.com/@alice"),
            // webvh: SCID abbreviated, domain + path tail kept in full. The tail is
            // the informative half, which a trailing ellipsis would have eaten.
            (
                "did:webvh:QmXkAbCdEfGhIjKlMnOp:webvh.storm.ws:glenn-vta",
                "did:webvh:QmXkAbCdEf…:webvh.storm.ws:glenn-vta"
            ),
            // web: same rule.
            (
                "did:web:QmXkAbCdEfGhIjKlMnOp:example.com",
                "did:web:QmXkAbCdEf…:example.com"
            ),
            // Short SCID — nothing to gain, left alone.
            ("did:webvh:Qm123:example.com", "did:webvh:Qm123:example.com"),
            // did:key — no human tail, so middle-truncate head + tail.
            (
                "did:key:z6MkfrQjWzPQrTuVwXyZaBcDeFgHiJkLmNoPqRsTuVwXyZ4rT",
                "did:key:z6MkfrQjWz…XyZ4rT"
            ),
            // Under the threshold, untouched.
            ("did:key:z6MkfrQjWz", "did:key:z6MkfrQjWz"),
            // A 3-segment webvh has no domain tail to protect, so it falls through
            // to the generic middle-truncating arm.
            (
                "did:webvh:QmXkAbCdEfGhIjKlMnOpQrSt",
                "did:webvh:QmXkAbCdEf…OpQrSt"
            ),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(shortenDid(input), expected, "input: \(input)")
        }
    }

    /// The abbreviation must survive a DID that is already short, and an empty
    /// string, without trapping — a text field hands us both mid-typing.
    func testShortenDidToleratesDegenerateInput() {
        XCTAssertEqual(shortenDid(""), "")
        XCTAssertEqual(shortenDid("did:"), "did:")
    }

    // MARK: Trust and rendering

    func testAVerifiedNameRendersBare() {
        let name = DisplayName(name: "example.com/@ops", source: .agentName(verified: true))
        XCTAssertTrue(name.isTrusted)
        XCTAssertEqual(name.rendered, "example.com/@ops")
    }

    /// The spoof this whole seam exists for: a DID claiming somebody else's name
    /// must never reach the screen looking believed.
    func testAnUnverifiedNameIsAlwaysTagged() {
        let name = DisplayName(
            name: "mybank.com/@treasury", source: .agentName(verified: false))
        XCTAssertFalse(name.isTrusted)
        XCTAssertTrue(
            name.rendered.contains("unverified"),
            "a self-asserted name must never render bare: \(name.rendered)")
        XCTAssertTrue(name.rendered.hasPrefix("mybank.com/@treasury"))
    }

    /// Mirrors `unverified_agent_name_ranks_below_every_local_source` in the SDK:
    /// an unchecked claim must never outrank a name we have reason to believe.
    func testVerifiedOutranksUnverified() {
        XCTAssertGreaterThan(
            NameSource.agentName(verified: true).rank,
            NameSource.agentName(verified: false).rank)
    }

    // MARK: NameResolver — caching

    /// Repeated asks for the same DID cost one lookup. Each lookup is a DID
    /// resolution plus an outbound fetch, and SwiftUI will ask on every reuse of a
    /// row.
    func testRepeatedAsksHitTheCache() async {
        let counter = Counter()
        let resolver = NameResolver(lookup: { _ in
            await counter.bump()
            return DisplayName(name: "example.com/@ops", source: .agentName(verified: true))
        })

        let first = await resolver.name(for: Self.did)
        let second = await resolver.name(for: Self.did)

        XCTAssertEqual(first?.name, "example.com/@ops")
        XCTAssertEqual(second, first)
        let lookups = await counter.count
        XCTAssertEqual(lookups, 1, "the second ask must not hit the network")
    }

    /// A miss is cached too — otherwise, with no DID publishing a name today,
    /// every render would re-attempt a resolution that is known to fail.
    func testAMissIsCachedAsWell() async {
        let counter = Counter()
        let resolver = NameResolver(lookup: { _ in
            await counter.bump()
            return nil
        })

        let first = await resolver.name(for: Self.did)
        let second = await resolver.name(for: Self.did)
        let lookups = await counter.count
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(lookups, 1)
    }

    /// A miss expires sooner than a hit: the day names start being minted, an app
    /// that cached "no name" for its whole session would never notice.
    func testAMissExpiresBeforeAHit() async {
        let counter = Counter()
        let clock = MutableClock()
        let resolver = NameResolver(
            lookup: { _ in
                await counter.bump()
                return nil
            },
            now: { clock.now })

        _ = await resolver.name(for: Self.did)
        clock.advance(by: NameResolver.missTTL + 1)
        _ = await resolver.name(for: Self.did)

        let lookups = await counter.count
        XCTAssertEqual(lookups, 2, "a stale miss must be retried")
        XCTAssertLessThan(NameResolver.missTTL, NameResolver.hitTTL)
    }

    /// A fresh hit is not re-fetched even well past the miss TTL — a verified name
    /// is cryptographically bound and does not churn.
    func testAHitSurvivesTheMissTTL() async {
        let counter = Counter()
        let clock = MutableClock()
        let resolver = NameResolver(
            lookup: { _ in
                await counter.bump()
                return DisplayName(name: "example.com/@ops", source: .agentName(verified: true))
            },
            now: { clock.now })

        _ = await resolver.name(for: Self.did)
        clock.advance(by: NameResolver.missTTL + 1)
        _ = await resolver.name(for: Self.did)

        let lookups = await counter.count
        XCTAssertEqual(lookups, 1)
    }

    /// Two DIDs must not share an answer — the cache is keyed, not a single slot.
    func testDifferentDidsResolveIndependently() async {
        let resolver = NameResolver(lookup: { did in
            DisplayName(name: "name-for-\(did)", source: .agentName(verified: true))
        })
        let a = await resolver.name(for: "did:key:zAAA")
        let b = await resolver.name(for: "did:key:zBBB")
        XCTAssertEqual(a?.name, "name-for-did:key:zAAA")
        XCTAssertEqual(b?.name, "name-for-did:key:zBBB")
    }

    /// `cached` is the synchronous peek a render path uses: nothing before the
    /// lookup, the answer after.
    func testCachedPeekIsEmptyUntilResolved() async {
        let resolver = NameResolver(lookup: { _ in
            DisplayName(name: "example.com/@ops", source: .agentName(verified: true))
        })
        let beforeLookup = await resolver.cached(Self.did)
        XCTAssertNil(beforeLookup)
        _ = await resolver.name(for: Self.did)
        let afterLookup = await resolver.cached(Self.did)
        XCTAssertEqual(afterLookup?.name, "example.com/@ops")
    }

    /// Concurrent asks for the same DID collapse to one lookup — N views rendering
    /// the same relying party in one frame must not become N round trips.
    func testConcurrentAsksCollapseToOneLookup() async {
        let counter = Counter()
        let resolver = NameResolver(lookup: { _ in
            // Yield so all callers are parked before the first one finishes.
            await Task.yield()
            await counter.bump()
            return DisplayName(name: "example.com/@ops", source: .agentName(verified: true))
        })

        let results = await withTaskGroup(of: DisplayName?.self) { group in
            for _ in 0..<8 {
                group.addTask { await resolver.name(for: Self.did) }
            }
            return await group.reduce(into: [DisplayName?]()) { $0.append($1) }
        }

        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0?.name == "example.com/@ops" })
        let lookups = await counter.count
        XCTAssertEqual(lookups, 1, "8 concurrent asks must share one lookup")
    }

    private static let did = "did:webvh:QmScidAbCdEfGh:example.com"
}

/// Counts lookups without tripping over concurrency checking.
private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// A clock the test moves by hand, so TTL behaviour is asserted without sleeping.
private final class MutableClock: @unchecked Sendable {
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { current }
    func advance(by interval: TimeInterval) { current = current.addingTimeInterval(interval) }
}
