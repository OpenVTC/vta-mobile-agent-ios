import Foundation
import SwiftUI
import UIKit
import UserNotifications
import VtaMobileAgent
import VtaMobileCore

/// UI-facing state for the authentication demo. Owns the device holder identity
/// and drives the REST auth flow on the `VtaMobileAgent` façade.
@MainActor
final class AgentModel: ObservableObject {
    /// Shared instance so the `AppDelegate` (APNs callbacks) and the SwiftUI view
    /// drive the same state.
    static let shared = AgentModel()

    @Published var vtaURL = ""
    @Published var vtaDid = ""
    /// Push gateway base URL (HTTPS) — where `push/register` is POSTed.
    @Published var gatewayUrl = ""
    /// Status line for the push-wake flow (registration + push-driven drain).
    @Published var pushStatus: String?
    /// The device's APNs token (hex), once iOS returns it. Surfaced so it can be
    /// copied into the gateway's `test-wake-apns` helper for a delivery test.
    @Published var apnsToken: String?
    /// True once a wake channel is registered (device/set-wake reported capable).
    @Published var pushEnabled = false
    @Published var holderDid = "(loading…)"
    @Published var status = "Enter your VTA's URL and DID, then authenticate."
    @Published var busy = false
    @Published var isAuthenticated = false
    @Published var whoamiSummary: String?
    @Published var pastedApproveRequest = ""
    @Published var stepUpStatus: String?
    @Published var mediatorDid = ""
    @Published var listening = false

    private var identity: HolderIdentity?
    private var tokens: AuthTokens?
    private var mediatorSession: MediatorSession?
    private var listenTask: Task<Void, Never>?

    private var trimmedDid: String { vtaDid.trimmingCharacters(in: .whitespaces) }

    /// Load (or first-time create) the device holder key and surface its did:key.
    func start() {
        do {
            let id = try HolderIdentity.loadOrCreate()
            identity = id
            holderDid = id.didKey
        } catch {
            holderDid = "(key error)"
            status = "Holder-key error: \(error.localizedDescription)"
        }
    }

    func authenticate() async {
        guard let identity else {
            status = "Holder key not ready."
            return
        }
        guard let url = normalizedURL() else {
            status = "Enter a valid VTA URL (e.g. http://192.168.1.10:8100)."
            return
        }
        guard !vtaDid.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = "Enter the VTA's DID (the document recipient)."
            return
        }

        busy = true
        whoamiSummary = nil
        status = "Authenticating…"
        defer { busy = false }
        do {
            let issued = try await VtaMobileAgent.authenticate(
                vtaURL: url, vtaDid: vtaDid.trimmingCharacters(in: .whitespaces), identity: identity)
            tokens = issued
            isAuthenticated = true
            persistConnection()  // so a push can re-auth on a cold launch
            status = "✅ Authenticated — acr \(issued.acr ?? "—"), "
                + "access token valid \(issued.expiresIn)s"
        } catch {
            isAuthenticated = false
            status = "❌ Authentication failed — \(error.localizedDescription)"
        }
    }

    func whoami() async {
        guard let identity, let tokens, let url = normalizedURL() else { return }
        busy = true
        defer { busy = false }
        do {
            let info = try await VtaMobileAgent.whoami(
                vtaURL: url,
                vtaDid: vtaDid.trimmingCharacters(in: .whitespaces),
                identity: identity,
                accessToken: tokens.accessToken)
            let roles = info.roles.isEmpty ? "—" : info.roles.joined(separator: ", ")
            whoamiSummary = "session \(info.sessionId)\nacr \(info.acr ?? "—") · roles: \(roles)"
        } catch {
            whoamiSummary = "whoami failed — \(error.localizedDescription)"
        }
    }

    /// Self-contained demo: provoke + approve a step-up on this device's own
    /// session, then reflect the elevated `acr` via whoami.
    func demoStepUp() async {
        guard let identity, let tokens, let url = normalizedURL(), !trimmedDid.isEmpty else {
            stepUpStatus = "Authenticate (with a VTA DID) first."
            return
        }
        busy = true
        defer { busy = false }
        stepUpStatus = "Stepping up this session…"
        do {
            let outcome = try await VtaMobileAgent.demoSelfStepUp(
                vtaURL: url, vtaDid: trimmedDid, identity: identity, accessToken: tokens.accessToken)
            stepUpStatus = "✅ Elevated to \(outcome.grantedAcr ?? "—")"
            await whoami() // live session now reports the elevated acr
        } catch {
            stepUpStatus = "❌ Step-up failed — \(error.localizedDescription)"
        }
    }

    /// Proxied approver: ratify a step-up whose approve-request was relayed here
    /// from another device (paste the VTA `403` body or the bare document).
    func approvePasted() async {
        guard let identity, let tokens, let url = normalizedURL(), !trimmedDid.isEmpty else {
            stepUpStatus = "Authenticate (with a VTA DID) first."
            return
        }
        let request = pastedApproveRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            stepUpStatus = "Paste an approve-request to ratify."
            return
        }
        busy = true
        defer { busy = false }
        stepUpStatus = "Approving…"
        do {
            let outcome = try await VtaMobileAgent.approveStepUp(
                approveRequest: request, vtaURL: url, vtaDid: trimmedDid,
                identity: identity, accessToken: tokens.accessToken)
            stepUpStatus = "✅ Approved — session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")"
        } catch {
            stepUpStatus = "❌ Approve failed — \(error.localizedDescription)"
        }
    }

    /// Live proxied approver: connect to the holder's mediator and service
    /// VTA-pushed step-up approve-requests as they arrive (no copy-paste). Toggle
    /// off to disconnect. This is the end-to-end path — the VTA addresses an
    /// approve-request to this device's DID over DIDComm, the mediator delivers
    /// it, and we ratify it automatically with the holder key.
    func toggleMediatorListen() async {
        if listening {
            await stopMediatorListen()
            return
        }
        guard let identity, let tokens, let url = normalizedURL(), !trimmedDid.isEmpty else {
            stepUpStatus = "Authenticate (with a VTA DID) first."
            return
        }
        let mediator = mediatorDid.trimmingCharacters(in: .whitespaces)
        guard !mediator.isEmpty else {
            stepUpStatus = "Enter the mediator DID to listen on."
            return
        }

        busy = true
        stepUpStatus = "Connecting to mediator…"
        do {
            let session = try await identity.connectMediator(
                vtaDid: trimmedDid, mediatorDid: mediator)
            mediatorSession = session
            listening = true
            stepUpStatus = "👂 Listening for step-up requests…"
            let accessToken = tokens.accessToken
            // Drive the receive loop off the main actor; each `receiveStepUpOnce`
            // waits up to its timeout then loops, ratifying any approve-request.
            listenTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let outcome = try await VtaMobileAgent.receiveStepUpOnce(
                            session: session, vtaURL: url, vtaDid: self?.trimmedDid ?? "",
                            identity: identity, accessToken: accessToken)
                        guard let self else { return }
                        if let outcome {
                            self.stepUpStatus =
                                "✅ Approved — session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")"
                        }
                    } catch {
                        guard let self else { return }
                        if !Task.isCancelled {
                            self.stepUpStatus = "❌ Listener error — \(error.localizedDescription)"
                        }
                        return  // connection dropped; require an explicit reconnect
                    }
                }
            }
        } catch {
            stepUpStatus = "❌ Mediator connect failed — \(error.localizedDescription)"
        }
        busy = false
    }

    private func stopMediatorListen() async {
        listenTask?.cancel()
        listenTask = nil
        if let session = mediatorSession {
            await session.shutdown()
        }
        mediatorSession = nil
        listening = false
        stepUpStatus = "Stopped listening."
    }

    private func normalizedURL() -> URL? {
        let trimmed = vtaURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        return url
    }

    // MARK: Push wake-up (APNs)

    /// Ask for notification permission and register for remote notifications. The
    /// APNs device token comes back via the `AppDelegate` → `onApnsToken`. (The
    /// token doesn't require alert permission — silent pushes work regardless —
    /// but we request it so a live test surfaces a visible banner.)
    func enablePush() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            pushStatus = "Notification authorization error: \(error.localizedDescription)"
        }
        UIApplication.shared.registerForRemoteNotifications()
        pushStatus = "Registering for push…"
    }

    /// APNs handed us a device token — register the wake channel: `push/register`
    /// to the gateway, then `device/set-wake` to the VTA.
    func onApnsToken(_ hex: String) async {
        // Surface the token first, unconditionally — it's useful for the
        // `test-wake-apns` delivery check even before a VTA is connected.
        apnsToken = hex
        print("[vta-agent] APNs device token: \(hex)")
        guard let identity, let tokens, let url = normalizedURL(), !trimmedDid.isEmpty else {
            pushStatus = "Got APNs token — authenticate (with a VTA DID) first, then enable push."
            return
        }
        let gw = gatewayUrl.trimmingCharacters(in: .whitespaces)
        guard let gatewayURL = URL(string: gw), gatewayURL.scheme != nil else {
            pushStatus = "Enter the push gateway URL before enabling push."
            return
        }
        let mediator = mediatorDid.trimmingCharacters(in: .whitespaces)
        do {
            let setup = try await VtaMobileAgent.registerApnsWake(
                apnsToken: hex,
                topic: Bundle.main.bundleIdentifier ?? "org.openvtc.vta.agent",
                environment: .sandbox,  // development builds get a sandbox APNs token
                gatewayURL: gatewayURL,
                controllerVtaDid: trimmedDid,
                vtaURL: url,
                vtaDid: trimmedDid,
                identity: identity,
                accessToken: tokens.accessToken,
                suggestedTriggers: mediator.isEmpty ? [] : [mediator])
            pushEnabled = setup.pushCapable
            persistConnection()
            pushStatus = setup.pushCapable
                ? "✅ Push wake registered — VTA allowlist: "
                    + (setup.allowedTriggers.isEmpty ? "—" : setup.allowedTriggers.joined(separator: ", "))
                : "Push channel cleared."
        } catch {
            pushStatus = "❌ Push registration failed — \(error.localizedDescription)"
        }
    }

    func onApnsRegisterFailed(_ error: Error) {
        pushStatus = "❌ APNs registration failed — \(error.localizedDescription)"
    }

    /// A contentless wake arrived (background push). Establish what we need —
    /// the holder key (keychain) and a session (re-authenticating if the app was
    /// relaunched cold) — connect to the mediator, and drain any queued
    /// approve-requests, ratifying each with the holder key. Returns whether
    /// anything was approved (maps to the background-fetch result).
    func handlePushWake() async -> Bool {
        guard let cfg = Self.loadConnection(), let vtaURLValue = URL(string: cfg.vtaURL) else {
            pushStatus = "Push received, but no saved VTA connection — open the app and authenticate."
            return false
        }
        do {
            let id = try identity ?? HolderIdentity.loadOrCreate()
            identity = id
            // Reuse a live token if we have one; else re-authenticate (the holder
            // key is in the keychain, so a cold launch can still elevate).
            let accessToken: String
            if let tokens {
                accessToken = tokens.accessToken
            } else {
                let issued = try await VtaMobileAgent.authenticate(
                    vtaURL: vtaURLValue, vtaDid: cfg.vtaDid, identity: id)
                tokens = issued
                accessToken = issued.accessToken
            }
            let session = try await id.connectMediator(vtaDid: cfg.vtaDid, mediatorDid: cfg.mediatorDid)
            defer { Task { await session.shutdown() } }
            // Drain what's queued: short receives until nothing more arrives.
            var approvedAny = false
            for _ in 0..<5 {
                let outcome = try await VtaMobileAgent.receiveStepUpOnce(
                    session: session, vtaURL: vtaURLValue, vtaDid: cfg.vtaDid,
                    identity: id, accessToken: accessToken, timeoutSecs: 5)
                guard let outcome else { break }
                approvedAny = true
                stepUpStatus =
                    "✅ Approved (push) — session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")"
            }
            pushStatus = approvedAny ? "✅ Push wake serviced." : "Woken by push — no pending step-up."
            return approvedAny
        } catch {
            pushStatus = "❌ Push-wake drain failed — \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Connection persistence (so a push can re-auth on a cold launch)

    struct ConnectionConfig {
        let vtaURL: String
        let vtaDid: String
        let mediatorDid: String
        let gatewayUrl: String
    }

    private func persistConnection() {
        let d = UserDefaults.standard
        d.set(vtaURL.trimmingCharacters(in: .whitespaces), forKey: "pnm.vtaURL")
        d.set(trimmedDid, forKey: "pnm.vtaDid")
        d.set(mediatorDid.trimmingCharacters(in: .whitespaces), forKey: "pnm.mediatorDid")
        d.set(gatewayUrl.trimmingCharacters(in: .whitespaces), forKey: "pnm.gatewayUrl")
    }

    static func loadConnection() -> ConnectionConfig? {
        let d = UserDefaults.standard
        guard let url = d.string(forKey: "pnm.vtaURL"), !url.isEmpty,
            let did = d.string(forKey: "pnm.vtaDid"), !did.isEmpty,
            let med = d.string(forKey: "pnm.mediatorDid"), !med.isEmpty
        else { return nil }
        return ConnectionConfig(
            vtaURL: url, vtaDid: did, mediatorDid: med,
            gatewayUrl: d.string(forKey: "pnm.gatewayUrl") ?? "")
    }

    /// Prefill the connection fields from the last persisted session, so the UI
    /// (and a manual re-enable) starts where the operator left off.
    func loadPersistedConnection() {
        guard let cfg = Self.loadConnection() else { return }
        if vtaURL.isEmpty { vtaURL = cfg.vtaURL }
        if vtaDid.isEmpty { vtaDid = cfg.vtaDid }
        if mediatorDid.isEmpty { mediatorDid = cfg.mediatorDid }
        if gatewayUrl.isEmpty { gatewayUrl = cfg.gatewayUrl }
    }
}
