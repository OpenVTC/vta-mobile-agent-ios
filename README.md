# vta-mobile-agent-ios

The iOS VTA mobile agent — a login/authentication agent that provides biometric
AAL1→AAL2 step-up. It talks to its VTA **only over the mediator** (DIDComm or
TSP) — there is no REST client and no bearer token; see
[Transport](#transport-no-vta-rest). It consumes the **`vta-mobile-core`** engine (Rust + UniFFI,
built in [`OpenVTC/verifiable-trust-infrastructure`](https://github.com/OpenVTC/verifiable-trust-infrastructure))
as a precompiled `VtaMobileCore.xcframework`, distributed via GitHub Releases
and pinned by SwiftPM checksum.

## Layout

```
Package.swift                         SwiftPM manifest (pins the engine release)
Sources/VtaMobileCore/                generated UniFFI Swift bindings (vendored)
Sources/VtaMobileAgent/               agent façade over the engine
Sources/VtaMobileAgent/VtaTransport.swift   DIDComm / TSP submission + TSP reply correlation
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
xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme VtaMobileAgent-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

(Run `xcrun simctl list devices available | grep -i iphone` to pick an
installed simulator. Note the `-workspace`: with the generated `.xcodeproj`
present in the repo root, a bare `-scheme` resolves against *it* rather than
`Package.swift`, and the package schemes won't be found.) Or open `Package.swift` in Xcode, choose an iPhone
simulator, and press ⌘U.

## Transport (no VTA REST)

The agent reaches its VTA over the holder's mediator and nothing else. There is
no `authenticate` step and no token to refresh: the VTA proves the sender
cryptographically on every message — authcrypt for DIDComm, the sealed sender
VID for TSP — and derives the caller's role, contexts and session from that DID
alone (*intrinsic-sender auth*). **Possession of the holder key is the
credential.**

Everything the device submits (`auth/step-up/approve-response`,
`task-consent/decision`, `device/set-wake`, `whoami`) goes through
`VtaTransport.submit`, which reaches the same VTA dispatcher that used to sit
behind `POST /api/trust-tasks`.

|                   | DIDComm                            | TSP                                     |
| ----------------- | ---------------------------------- | --------------------------------------- |
| Framing           | Trust Task in the message `body`   | Trust Task bytes directly               |
| Reply correlation | native, by `thid`                  | by `threadId`, via `TspReplyRouter`     |
| `submit` waits?   | yes, in-place                      | yes, but the reply arrives on the inbox |

TSP needs the router because it has no `thid` demux and `receiveNext` holds the
socket lock for its whole budget — so a submit that read its own reply would
deadlock the inbox loop. Instead the listen loop stays the sole reader and
offers every frame to the router first. The correlation rule is the framework's:
a response carries `threadId = request.threadId ?? request.id`.

**What still isn't DIDComm.** Two things deliberately remain over HTTP:

- **Enrolment.** The device `did:key` must be in the VTA's ACL
  (`pnm acl create --did <did:key> …`) before *any* message from it is accepted.
  An unenrolled device fails at the post-connect `whoami`.
- **Push gateway registration.** `push/register` goes to the **gateway**, a
  different service that is the only component permitted to see the raw APNs
  token. Only the `device/set-wake` leg — the one addressed to the VTA — moved
  onto the transport.

`demoSelfStepUp` is gone: it provoked a `403` from an AAL2-gated endpoint, a
challenge carried by an HTTP status, which the messaging transports have no
equivalent for.

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
cp -R /abs/path/to/target/mobile/ios/VtaMobileCore.xcframework ./VtaMobileCore.xcframework
rm -rf .build ~/Library/Caches/org.swift.swiftpm/manifests   # see the two gotchas below
xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme VtaMobileAgent-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Two things that will otherwise cost you an hour:

1. **Copy, don't symlink.** `Package.swift` selects the local xcframework with
   `FileManager.fileExists`, and a symlink at that path does not reliably
   satisfy it — SwiftPM silently falls back to downloading the pinned release,
   and you debug "missing" FFI symbols that are right there in the header.
2. **Clear the SwiftPM manifest cache.** Evaluated manifests are cached
   *globally* in `~/Library/Caches/org.swift.swiftpm/manifests`, so the
   local-vs-remote decision sticks across `rm -rf .build` and fresh
   DerivedData.

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
Run.

### App UI

The app is organised as a bottom **tab bar** so each context is focused:

- **Home** — at-a-glance status hero + the single primary action. Once
  configured the agent runs itself; this screen just reflects that.
- **Test** — manual surfaces for development: *who am I*, live mediator
  listening, pasted ratification, push-wake registration.
- **History** — a chronological, color-coded record of authentications,
  approvals (live / pasted / push), and errors.
- **Logs** — the engine + app `stdout`/`stderr` stream captured in-app
  (`LogStore`), with copy/clear — diagnose on-device without Xcode attached.
- **Settings** — all configuration (VTA DID / mediator / gateway, auto-connect),
  the device identity, and the **theme picker**.

**Everything is auto and recoverable.** Once a VTA is configured the agent
auto-connects on launch and supervises the mediator listener with
exponential-backoff reconnects — a dropped network/VTA recovers with no user
action. There is no token refresh to schedule: *connected* simply means the
inbox is open and the VTA answered a `whoami` over it. A connection **status pill** is always visible in
the nav bar on every tab.

**Themes** (`Theme.swift`) are user-selectable at runtime (Vibrant / Neon /
Pastel / Minimal) and persisted; the choice restyles the whole app live.

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
