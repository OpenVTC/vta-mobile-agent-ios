import VtaMobileCore

/// Agent-facing façade over the `vta-mobile-core` engine.
///
/// The app layer talks to this, not to the raw UniFFI surface — it's where
/// device custody (Secure Enclave `Signer`), the mediator transport, passkey
/// step-up, and push wiring will hang as the agent grows. For now it exposes a
/// single linkage check so the app (and the smoke test) can confirm the engine
/// is loaded.
public enum VtaMobileAgent {
    /// A human-readable summary of the linked engine, e.g. `"vta_mobile_core v0.1.0"`.
    /// The simplest proof that the FFI bridge is live on-device.
    public static func engineSummary() -> String {
        let info = engineInfo()
        return "\(info.namespace) v\(info.version)"
    }
}
