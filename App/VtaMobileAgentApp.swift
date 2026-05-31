// The iOS app target. Built via the XcodeGen project (`project.yml`) which
// wires this `App/` folder into an app that depends on the `VtaMobileAgent`
// package product. Generate + open with `xcodegen generate`.

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
