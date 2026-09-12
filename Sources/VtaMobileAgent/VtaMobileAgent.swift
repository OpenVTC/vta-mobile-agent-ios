import VtaMobileCore

/// Agent-facing façade over the `vta-mobile-core` engine.
///
/// The app layer talks to this, not to the raw UniFFI surface — it's where
/// device custody (today ``HolderIdentity``: a software-held Ed25519 `Signer`
/// whose seed lives in the Keychain), the mediator transport, step-up and push
/// wiring hang as the agent grows. Tier-1 custody — an approval key in the
/// Secure Enclave, or WebAuthn user verification — is not here yet; what this
/// build has is a device-owner check on each approval (``ApprovalGate``). For
/// now this enum exposes a single linkage check so the app (and the smoke test)
/// can confirm the engine is loaded.
public enum VtaMobileAgent {
    /// A human-readable summary of the linked engine, e.g. `"vta_mobile_core v0.1.0"`.
    /// The simplest proof that the FFI bridge is live on-device.
    public static func engineSummary() -> String {
        let info = engineInfo()
        return "\(info.namespace) v\(info.version)"
    }
}
