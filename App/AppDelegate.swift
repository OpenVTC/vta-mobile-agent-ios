import UIKit
import UserNotifications

/// Bridges UIKit's APNs lifecycle into the SwiftUI app (wired via
/// `@UIApplicationDelegateAdaptor` in `VtaMobileAgentApp`):
///
/// - captures the APNs **device token** → registers the wake channel
///   (`AgentModel.onApnsToken` → `push/register` + `device/set-wake`),
/// - handles a **background (contentless) push** → drains the mediator and
///   ratifies any queued step-up (`AgentModel.handlePushWake`).
///
/// All work is delegated to the shared `AgentModel`; this class is just the
/// UIKit seam SwiftUI doesn't expose directly.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await AgentModel.shared.onApnsToken(hex) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { await AgentModel.shared.onApnsRegisterFailed(error) }
    }

    /// Background (`content-available`) push — the contentless wake. Drain +
    /// ratify, then report whether anything arrived so the OS can schedule the
    /// next background opportunity appropriately.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let approved = await AgentModel.shared.handlePushWake()
        return approved ? .newData : .noData
    }

    /// Show foreground notifications too, so a live test is visible while the app
    /// is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
