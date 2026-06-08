import Foundation
import VtaMobileCore

/// Device-side push wake-up registration (push wake-up binding,
/// <https://trusttasks.org/binding/push/0.1>). Two engine-built Trust Tasks,
/// posted like the `auth/*` documents — the engine builds + (for set-wake) signs
/// them via the holder `Signer`; this layer just moves them over HTTP:
///
///   1. `push/register` → the **gateway** (unauthenticated): hand over the APNs
///      token, get back an opaque `WakeHandle`. The token is held by the gateway
///      only — it never reaches the VTA or the mediator.
///   2. `device/set-wake` → the **VTA** (holder-signed, bearer-authed): convey
///      the handle so the VTA owns the trigger allowlist and provisions the
///      gateway. The VTA can then wake this device on a delegated step-up.
///
/// After this, a `push/wake` from an allowed trigger → contentless APNs push →
/// the app wakes and drains its mediator (see `AgentModel.handlePushWake`).
extension VtaMobileAgent {
    /// The VTA's effective wake policy after `device/set-wake`.
    public struct PushWakeSetup {
        /// Whether the device now has a usable wake channel.
        public let pushCapable: Bool
        /// The trigger DIDs the VTA provisioned to the gateway (e.g. its mediator
        /// + its own DID).
        public let allowedTriggers: [String]
    }

    /// Register an APNs token for wake-up: `push/register` to the gateway, then
    /// `device/set-wake` to the VTA. `accessToken` must be a token for *this
    /// holder's* session. `topic` is the app bundle id (the APNs topic);
    /// `environment` is `.sandbox` for development builds, `.production` for
    /// TestFlight/App Store. `controllerVtaDid` is the VTA permitted to provision
    /// the handle — normally `vtaDid`.
    @discardableResult
    public static func registerApnsWake(
        apnsToken: String,
        topic: String,
        environment: ApnsEnvironment,
        gatewayURL: URL,
        controllerVtaDid: String,
        vtaURL: URL,
        vtaDid: String,
        identity: HolderIdentity,
        accessToken: String,
        suggestedTriggers: [String] = []
    ) async throws -> PushWakeSetup {
        // 1. push/register → gateway (unauthenticated; issuer optional, no recipient
        //    when the gateway is addressed by URL).
        let registerDoc = try buildPushRegister(
            env: PushEnvelope(
                id: "urn:uuid:\(UUID().uuidString)",
                issuedAt: Self.rfc3339Now(),
                issuer: identity.didKey,
                recipient: nil),
            registration: .apns(token: apnsToken, topic: topic, environment: environment),
            controllerVtaDid: controllerVtaDid)
        let gateway = VtaRestClient(baseURL: gatewayURL)
        let registerResponse = try await gateway.post(path: "/trust-tasks", body: registerDoc)
        let handle = try parsePushRegisterResponse(json: registerResponse)

        // 2. device/set-wake → VTA (holder-signed; bearer-authed).
        let setWakeDoc = try buildDeviceSetWake(
            env: PushEnvelope(
                id: "urn:uuid:\(UUID().uuidString)",
                issuedAt: Self.rfc3339Now(),
                issuer: identity.didKey,
                recipient: vtaDid),
            wakeHandle: handle,
            pushPlatform: .apns,
            suggestedTriggers: suggestedTriggers,
            signer: identity)
        let vta = VtaRestClient(baseURL: vtaURL)
        let setWakeResponse = try await vta.post(
            path: "/api/trust-tasks", body: setWakeDoc, bearer: accessToken)
        let outcome = try parseDeviceSetWakeResponse(json: setWakeResponse)

        return PushWakeSetup(
            pushCapable: outcome.pushCapable, allowedTriggers: outcome.allowedTriggers ?? [])
    }

    /// RFC 3339 "now" — the document `issuedAt` (and the set-wake proof's
    /// `created`, which the VTA rejects if future-dated).
    static func rfc3339Now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
