// swift-tools-version:5.9
import Foundation

import PackageDescription

// The vta-mobile-core engine release this checkout consumes. After cutting a
// new `vta-mobile-core-v*` release, bump `engineTag` AND re-vendor the matched
// pair: Sources/VtaMobileCore/VtaMobileCore.swift (the release's
// VtaMobileCore.swift asset) and `engineChecksum` (its
// VtaMobileCore.xcframework.zip.sha256). The Swift wrapper and the binary are a
// matched set — never mix versions.
// TODO(release): the vendored Sources/VtaMobileCore/VtaMobileCore.swift is
// generated from the *unreleased* core carrying on-device proof verification
// (verifiable-trust-infrastructure#871, post-v0.6.16). Until the next
// `vta-mobile-core-v*` release is cut and this pin bumped to it, a fresh
// checkout must use the local-xcframework override below (build it with
// `vta-mobile-core/scripts/package-ios.sh`) — the v0.6.16 binary no longer
// matches the vendored bindings.
let engineTag = "vta-mobile-core-v0.6.17"
let engineChecksum = "d8e417d06797ce27bf47d54f0e946aabd7cd4198f3d613481cbfe3fdc484258b"

// Local-dev override: iterate against a locally-built xcframework without a
// published release. Drop (or symlink) a `VtaMobileCore.xcframework` at the
// package root and it's used instead of the release — it's gitignored, and
// `binaryTarget(path:)` requires a path *relative* to the package root, so the
// override keys off the file's presence rather than an absolute env var. E.g.:
//   ln -s /abs/path/to/VtaMobileCore.xcframework ./VtaMobileCore.xcframework
let localXcframework = "VtaMobileCore.xcframework"
let useLocalXcframework = FileManager.default.fileExists(
    atPath: "\(Context.packageDirectory)/\(localXcframework)"
)

let ffiTarget: Target = useLocalXcframework
    ? .binaryTarget(name: "VtaMobileCoreFFI", path: localXcframework)
    : .binaryTarget(
        name: "VtaMobileCoreFFI",
        url: "https://github.com/OpenVTC/verifiable-trust-infrastructure/releases/download/\(engineTag)/VtaMobileCore.xcframework.zip",
        checksum: engineChecksum
    )

let package = Package(
    name: "VtaMobileAgent",
    platforms: [.iOS(.v16)],
    products: [
        // The agent-facing façade the app target imports.
        .library(name: "VtaMobileAgent", targets: ["VtaMobileAgent"]),
        // The raw UniFFI engine surface, if a consumer wants it directly.
        .library(name: "VtaMobileCore", targets: ["VtaMobileCore"]),
    ],
    targets: [
        // Compiled Rust engine + C headers/modulemap (module: VtaMobileCoreFFI).
        ffiTarget,
        // Generated UniFFI Swift bindings; `import VtaMobileCore` for the engine API.
        .target(name: "VtaMobileCore", dependencies: ["VtaMobileCoreFFI"]),
        // Thin agent façade over the engine.
        .target(name: "VtaMobileAgent", dependencies: ["VtaMobileCore"]),
        // Smoke test exercising the FFI bridge end-to-end (run on an iOS Simulator).
        .testTarget(
            name: "VtaMobileAgentTests", dependencies: ["VtaMobileAgent", "VtaMobileCore"]),
    ]
)
