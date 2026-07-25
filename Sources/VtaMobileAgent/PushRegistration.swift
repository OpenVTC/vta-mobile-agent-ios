import Foundation
import VtaMobileCore

/// Device-side push wake-up registration (push wake-up binding,
/// <https://trusttasks.org/binding/push/0.1>). Two engine-built Trust Tasks —
/// the engine builds + (for set-wake) signs them via the holder `Signer`:
///
///   1. `push/register` → the **gateway** (unauthenticated HTTP): hand over the
///      APNs token, get back an opaque `WakeHandle`. The token is held by the
///      gateway only — it never reaches the VTA or the mediator.
///   2. `device/set-wake` → the **VTA**, over the messaging transport
///      (holder-signed): convey the handle so the VTA owns the trigger
///      allowlist and provisions the gateway.
///
/// After this, a `push/wake` from an allowed trigger → contentless APNs push →
/// the app wakes and drains its mediator (see `AgentModel.handlePushWake`).
///
/// **On "no REST".** Dropping the VTA's REST API does not remove *this* HTTP
/// call: the gateway is a different service, addressed by URL and deliberately
/// unauthenticated, and it is the one component that must see the raw APNs
/// token. Only step 2 — the leg that talks to the VTA — moves onto DIDComm/TSP.
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
    /// `device/set-wake` to the VTA over `transport`. `topic` is the app bundle
    /// id (the APNs topic); `environment` is `.sandbox` for development builds,
    /// `.production` for TestFlight/App Store. `controllerVtaDid` is the VTA
    /// permitted to provision the handle — normally `vtaDid`.
    @discardableResult
    public static func registerApnsWake(
        apnsToken: String,
        topic: String,
        environment: ApnsEnvironment,
        gatewayURL: URL,
        controllerVtaDid: String,
        transport: VtaTransport,
        vtaDid: String,
        identity: HolderIdentity,
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
        let registerResponse = try await GatewayClient(baseURL: gatewayURL)
            .post(path: "/trust-tasks", body: registerDoc)
        let handle = try parsePushRegisterResponse(json: registerResponse)

        // 2. device/set-wake → VTA, over the messaging transport. `device/set-wake`
        //    is dispatcher-routed, so it takes the same path as any other Trust
        //    Task and is authorized by the proven sender DID.
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
        let setWakeResponse = try await transport.submit(setWakeDoc)
        let outcome = try parseDeviceSetWakeResponse(json: setWakeResponse)

        return PushWakeSetup(
            pushCapable: outcome.pushCapable, allowedTriggers: outcome.allowedTriggers ?? [])
    }

    /// RFC 3339 "now" — the document `issuedAt` (and the set-wake proof's
    /// `created`, which the VTA rejects if future-dated).
    static func rfc3339Now() -> String { ISO8601DateFormatter().string(from: Date()) }
}

/// Minimal HTTP poster for the **push gateway** — the one service still
/// addressed by URL. Deliberately not a general VTA client: the VTA is reached
/// over ``VtaTransport`` and nothing else.
struct GatewayClient {
    private let base: String

    init(baseURL: URL) {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        self.base = s
    }

    /// POST a document to `path` and return the response body, or throw on non-2xx.
    func post(path: String, body: String) async throws -> String {
        guard let url = URL(string: base + path) else {
            throw AgentError.badResponse("invalid gateway URL: \(base + path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            throw AgentError.http(status: status, body: text)
        }
        return text
    }
}
