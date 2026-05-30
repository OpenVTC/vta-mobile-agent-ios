# vta-mobile-agent-ios

The iOS VTA mobile agent — a login/authentication agent that provides biometric
AAL1→AAL2 step-up. It consumes the **`vta-mobile-core`** engine (Rust + UniFFI,
built in [`OpenVTC/verifiable-trust-infrastructure`](https://github.com/OpenVTC/verifiable-trust-infrastructure))
as a precompiled `VtaMobileCore.xcframework`, distributed via GitHub Releases
and pinned by SwiftPM checksum.

## Layout

```
Package.swift                         SwiftPM manifest (pins the engine release)
Sources/VtaMobileCore/                generated UniFFI Swift bindings (vendored)
Sources/VtaMobileAgent/               agent façade over the engine
Tests/VtaMobileAgentTests/            on-simulator smoke test
App/                                  reference SwiftUI sources for the app target
.github/workflows/ci.yml              runs the smoke test on an iOS Simulator
```

`VtaMobileCoreFFI` (the `binaryTarget`) is the compiled engine + C module.
`VtaMobileCore` compiles the generated Swift wrapper against it. `VtaMobileAgent`
is the thin façade the app imports.

## Important: this is iOS-only

`VtaMobileCore.xcframework` contains **iOS slices only** (device + simulator).
A plain `swift build` / `swift test` targets macOS and will fail to find a
slice — that's expected. Always build/test against an **iOS Simulator**:

```sh
xcodebuild test -scheme VtaMobileAgent-Package \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

(Run `xcrun simctl list devices available | grep -i iphone` to pick an
installed simulator.) Or open `Package.swift` in Xcode, choose an iPhone
simulator, and press ⌘U.

## Pinning / upgrading the engine

`Package.swift` pins one engine release. The Swift wrapper
(`Sources/VtaMobileCore/VtaMobileCore.swift`) and the binary checksum are a
**matched set** — never mix versions. To adopt a new
`vta-mobile-core-vX.Y.Z` release:

```sh
TAG=vta-mobile-core-v0.1.0   # the release to adopt
REPO=OpenVTC/verifiable-trust-infrastructure

# 1. re-vendor the generated wrapper
gh release download "$TAG" -R "$REPO" -p 'VtaMobileCore.swift' \
  -D Sources/VtaMobileCore/ --clobber

# 2. read the checksum to paste into Package.swift (engineChecksum)
gh release download "$TAG" -R "$REPO" -p 'VtaMobileCore.xcframework.zip.sha256' -O -
```

Then set `engineTag` + `engineChecksum` in `Package.swift` to match.

> On first setup, `engineChecksum` is a placeholder — paste the real value from
> the `vta-mobile-core-v0.1.0` release (step 2 above) before the remote build
> will resolve.

## Local engine development

To iterate against a locally-built xcframework (no release needed), build it in
the engine repo (`vta-mobile-core/scripts/package-ios.sh`) and drop a
`VtaMobileCore.xcframework` at this package's root (it's gitignored). When that
file is present, `Package.swift` uses it instead of the published release:

```sh
ln -s /abs/path/to/target/mobile/ios/VtaMobileCore.xcframework ./VtaMobileCore.xcframework
xcodebuild test -scheme VtaMobileAgent-Package \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

(Remember to also vendor that build's `VtaMobileCore.swift` into
`Sources/VtaMobileCore/` so the wrapper matches the binary.)

## Running the app

SwiftPM doesn't build iOS `.app` bundles. To run the SwiftUI shell in `App/`,
open `Package.swift` in Xcode and add an iOS App target
(`bundle id: org.openvtc.vta.agent`) that depends on the `VtaMobileAgent`
product — see the header comment in `App/VtaMobileAgentApp.swift`.

## License

Apache-2.0.
