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

The SwiftUI app target (`App/`, bundle id `org.openvtc.vta.agent`) is described
declaratively in `project.yml` and generated with [XcodeGen] — the `.xcodeproj`
is **not** committed (regenerate it any time):

```sh
brew install xcodegen        # once
xcodegen generate            # writes VtaMobileAgentApp.xcodeproj
open VtaMobileAgentApp.xcodeproj
```

Pick an **installed** iPhone simulator (the latest-runtime one — e.g. iPhone 17
— is safest; `name=iPhone 16` only resolves if a matching OS is installed) and
Run. The screen shows the live engine version via `engineInfo()` across the FFI.

CLI build/run without opening Xcode:

```sh
xcodegen generate
xcodebuild build -scheme VtaMobileAgentApp \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

[XcodeGen]: https://github.com/yonaskolb/XcodeGen

## Push wake-up (APNs)

The agent can be **woken by a push** to ratify a step-up while backgrounded,
instead of holding a live mediator connection. The contentless push is a
doorbell (push wake-up binding
[`/binding/push/0.1`](https://trusttasks.org/binding/push/0.1)); the real
(encrypted) approve-request is pulled from the mediator after the app wakes.

**On-device flow** (`PushRegistration.swift` + `AppDelegate.swift`):

1. *Enable push wake* → request notification authorization + `registerForRemoteNotifications`.
2. APNs returns the device token → engine `build_push_register` → **gateway**
   (`push/register`, the token is held by the gateway only) → opaque `WakeHandle`.
3. Engine `build_device_set_wake` (holder-signed) → **VTA** (`device/set-wake`) —
   the VTA owns the trigger allowlist and provisions the gateway.
4. On a delegated step-up the VTA sends `push/wake` → the gateway delivers a
   contentless APNs push → the app wakes → drains its mediator → **ratifies** the
   approve-request with the holder key (`receiveStepUpOnce`).

**Apple setup (token-based APNs):**

- An **App ID** for `org.openvtc.vta.agent` with **Push Notifications** enabled,
  and Xcode **automatic signing** (it provisions the device + push entitlement).
  The app declares the `aps-environment` entitlement + the `remote-notification`
  background mode (both via `project.yml`).
- An **APNs Auth Key (`.p8`)** + its Key ID + your Team ID — these go in the
  **gateway** (`GATEWAY_APNS_KEY_FILE` / `GATEWAY_APNS_KEY_ID` /
  `GATEWAY_APNS_TEAM_ID`), never in the app.
- A **real device** — APNs doesn't deliver remote pushes to the Simulator. Dev
  builds get a **sandbox** APNs token, so the gateway routes via the APNs sandbox
  host automatically (the registration's `environment` is `.sandbox`).

**Quick delivery check (no VTA).** Tap *Enable push wake*; the app shows its
**APNs token** in the UI (also `print`ed to the Xcode console). Run the gateway
with the APNs creds and fire a wake straight at the token — no `did:webvh`
gateway identity, no VTA:

```sh
cargo run -- test-wake-apns http://<gateway-host>:8300 <apns-token> org.openvtc.vta.agent
```

The phone wakes and drains its mediator. (For the full VTA-triggered loop,
register the wake channel from the app instead and trigger a delegated step-up.)

## License

Apache-2.0.
