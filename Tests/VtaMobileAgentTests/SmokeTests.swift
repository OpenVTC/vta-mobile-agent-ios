import XCTest

import VtaMobileAgent
import VtaMobileCore

/// End-to-end proof that the consumed xcframework links and its FFI calls run
/// on-device. Must be run against an iOS Simulator destination — the
/// xcframework ships iOS slices only, so a plain `swift test` (macOS) won't
/// find a matching slice.
final class SmokeTests: XCTestCase {
    func testEngineLinkageAndCalls() throws {
        // Simplest round-trip across the FFI boundary.
        XCTAssertFalse(libraryVersion().isEmpty)

        // A UniFFI record across the boundary.
        XCTAssertEqual(engineInfo().namespace, "vta_mobile_core")

        // The agent façade.
        XCTAssertTrue(VtaMobileAgent.engineSummary().contains("vta_mobile_core"))

        // A real pure function over the Result/FfiError boundary: a valid
        // (≥16-byte) base64url challenge returns its decoded length…
        let len = try challengeLenBytes(challengeB64url: "VHJhbnNmZXJDb25maXJtTm9uY2VYWQ")
        XCTAssertGreaterThanOrEqual(len, 16)

        // …and a too-short challenge surfaces as a thrown error.
        XCTAssertThrowsError(try challengeLenBytes(challengeB64url: "short"))
    }
}
