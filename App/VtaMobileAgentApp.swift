// Reference SwiftUI app sources for the iOS app target.
//
// SwiftPM does not build iOS .app bundles, so these are NOT compiled by
// `swift build`/`xcodebuild test` against the package. To run the actual app:
//
//   1. Open Package.swift in Xcode (or this folder).
//   2. File ▸ New ▸ Target… ▸ iOS ▸ App  (name: VtaMobileAgent,
//      bundle id: org.openvtc.vta.agent, interface: SwiftUI).
//   3. Add the `VtaMobileAgent` package product to the app target's
//      Frameworks/Dependencies.
//   4. Replace the generated App/ContentView files with these two, or point
//      the new target at this App/ folder.
//   5. Pick an iPhone simulator and Run.
//
// The package's smoke test already proves the engine links and runs on a
// simulator; this is the thin UI shell on top of `VtaMobileAgent`.

import SwiftUI

import VtaMobileAgent

@main
struct VtaMobileAgentApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
