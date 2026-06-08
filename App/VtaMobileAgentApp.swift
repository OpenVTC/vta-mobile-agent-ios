// The iOS app target. Built via the XcodeGen project (`project.yml`) which
// wires this `App/` folder into an app that depends on the `VtaMobileAgent`
// package product. Generate + open with `xcodegen generate`.

import SwiftUI

import VtaMobileAgent

@main
struct VtaMobileAgentApp: App {
    // UIKit seam for the APNs lifecycle (device token + background pushes).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
