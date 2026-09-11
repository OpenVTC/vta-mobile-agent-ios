import Foundation

#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

/// Confirms that the person holding the device is its owner before a change
/// that re-points whose requests this device approves. Injectable so the
/// decision can be exercised without biometrics.
public protocol DeviceOwnerAuthenticator {
    /// `true` only if the owner authenticated. Never throws: any failure,
    /// cancellation or unavailability is `false`.
    func authenticate(reason: String) async -> Bool
}

#if canImport(LocalAuthentication)
    /// `LAPolicy.deviceOwnerAuthentication`: biometrics with the device passcode
    /// as fallback. A device with no passcode set cannot authenticate, so the
    /// guarded change is refused.
    public struct LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticator {
        public init() {}

        public func authenticate(reason: String) async -> Bool {
            let context = LAContext()
            // Always a fresh check, never a recent unlock.
            context.touchIDAuthenticationAllowableReuseDuration = 0
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                return false
            }
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                return false
            }
        }
    }
#endif
