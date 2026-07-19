import Foundation
import SwiftUI
import UIKit
import UserNotifications
import VtaMobileAgent
import VtaMobileCore

/// UI-facing state for the agent. Owns the device holder identity and drives the
/// REST auth flow + the live DIDComm approver loop on the `VtaMobileAgent` façade.
///
/// Design goal: **everything auto and recoverable.** Once configured, the agent
/// auto-connects on launch, keeps the session alive (token auto-refresh), and
/// supervises the mediator listen loop with exponential-backoff reconnects, so a
/// dropped network/VTA recovers without any user action.
@MainActor
final class AgentModel: ObservableObject {
    /// Shared instance so the `AppDelegate` (APNs callbacks) and the SwiftUI views
    /// drive the same state.
    static let shared = AgentModel()

    // Configuration (persisted; see ConnectionConfig).
    @Published var vtaURL = ""
    @Published var vtaDid = ""
    @Published var mediatorDid = ""
    /// Push gateway base URL (HTTPS) — where `push/register` is POSTed.
    @Published var gatewayUrl = ""

    // Connection / auth state.
    @Published var isAuthenticated = false
    /// Background connect in progress (distinct from `busy`, which gates explicit
    /// user actions — auto-connect must not lock the whole UI).
    @Published var connecting = false
    @Published var listening = false
    @Published var connectionError: String?
    @Published var busy = false

    // Surfaced detail.
    @Published var holderDid = "(loading…)"
    @Published var status = "Point the agent at your VTA in Settings to get started."
    @Published var whoamiSummary: String?
    @Published var stepUpStatus: String?

    // Push wake (APNs).
    @Published var pushStatus: String?
    @Published var apnsToken: String?
    @Published var pushEnabled = false {
        didSet { UserDefaults.standard.set(pushEnabled, forKey: "pnm.pushEnabled") }
    }

    /// Use TSP (not DIDComm) for the mediator inbox. One transport at a time: the
    /// one-socket-per-DID rule (ADR 0005) means the holder can't hold both
    /// mediator sockets, so this picks which one the listen loop opens — it does
    /// not run alongside DIDComm. Default off; the VTA pushes over DIDComm today,
    /// so flip this on to receive the same step-up / task-consent over TSP.
    /// Takes effect on the next (re)connect of the listener.
    @Published var useTsp = false {
        didSet { UserDefaults.standard.set(useTsp, forKey: "pnm.useTsp") }
    }

    // Test-tab scratch.
    @Published var pastedApproveRequest = ""

    /// Incoming step-ups awaiting the operator's Approve/Deny (AI asks that carry
    /// a structured authorization context — not auto-ratified). A FIFO inbox so
    /// concurrent asks don't clobber each other; the review sheet shows the
    /// front. Empty when nothing is pending.
    @Published var pendingApprovals: [PendingApproval] = []

    /// The ask currently shown for review (the oldest outstanding one).
    var frontApproval: PendingApproval? { pendingApprovals.first }

    /// Outstanding **task-consent** approvals — the device acting as a second
    /// approving device for a privileged Trust Task. Deduped by `payloadDigest`;
    /// the sheet shows the front. Empty when nothing is pending.
    @Published var pendingConsents: [PendingConsent] = []

    /// The task-consent ask currently shown for review (the oldest outstanding).
    var frontConsent: PendingConsent? { pendingConsents.first }

    // Activity history (newest first) for the History tab.
    @Published var events: [AgentEvent] = []

    /// Auto-connect on launch + auto-recover. A manual disconnect clears it; a
    /// manual Connect re-arms it.
    @Published var autoConnectEnabled: Bool {
        didSet { UserDefaults.standard.set(autoConnectEnabled, forKey: "pnm.autoConnect") }
    }

    private var identity: HolderIdentity?
    private var tokens: AuthTokens?
    private var mediatorSession: MediatorSession?
    private var tspSession: TspMediatorSession?
    private var listenSupervisor: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var trimmedDid: String { vtaDid.trimmed }

    init() {
        autoConnectEnabled = (UserDefaults.standard.object(forKey: "pnm.autoConnect") as? Bool) ?? true
        pushEnabled = UserDefaults.standard.bool(forKey: "pnm.pushEnabled")
        useTsp = UserDefaults.standard.bool(forKey: "pnm.useTsp")
    }

    // MARK: Derived presentation state

    var isConfigured: Bool { !vtaURL.trimmed.isEmpty && !trimmedDid.isEmpty }

    /// Glanceable status driving the always-visible pill + Home hero.
    var phase: ConnectionPhase {
        if !isConfigured { return .notConfigured }
        if isAuthenticated { return listening ? .live : .connected }
        if connecting { return .connecting }
        if connectionError != nil { return .error }
        return .offline
    }

    // MARK: Lifecycle

    /// Load (or first-time create) the device holder key, prefill saved config,
    /// and kick off auto-connect. Safe to call repeatedly (onAppear).
    func start() {
        if identity == nil {
            do {
                let id = try HolderIdentity.loadOrCreate()
                identity = id
                holderDid = id.didKey
            } catch {
                holderDid = "(key error)"
                status = "Holder-key error: \(error.localizedDescription)"
            }
        }
        loadPersistedConnection()
        autoConnectIfConfigured()
    }

    func autoConnectIfConfigured() {
        guard autoConnectEnabled, isConfigured, !isAuthenticated, !connecting else { return }
        Task { await connect(auto: true) }
    }

    /// Apply a scanned pairing payload: fill the connection config and connect.
    /// Registering this device as the operator's delegated approver is a
    /// follow-up once connected (needs a live VTA).
    func applyPairing(_ p: PairingPayload) {
        vtaURL = p.vtaURL
        vtaDid = p.vtaDID
        if let m = p.mediatorDID { mediatorDid = m }
        if let g = p.gatewayURL { gatewayUrl = g }
        persistConnection()
        recordEvent(.info, "Paired via QR", p.tenant.map { "tenant · \($0)" } ?? p.vtaDID)
        status = "Paired — connecting…"
        Task { await connect() }
    }

    // MARK: Connect / disconnect (auto + recoverable)

    /// Authenticate and bring the agent fully online: refresh-keepalive, the
    /// supervised mediator listener, and (if previously enabled) push re-arm. A
    /// manual call re-arms auto-connect; an `auto` call schedules a backoff retry
    /// on failure.
    func connect(auto: Bool = false) async {
        guard let identity, let url = normalizedURL(), isConfigured else {
            connectionError = "Enter the VTA URL + DID in Settings first."
            status = connectionError!
            return
        }
        guard !connecting else { return }
        if !auto { autoConnectEnabled = true }
        connecting = true
        connectionError = nil
        if !auto { status = "Connecting to your VTA…" }
        defer { connecting = false }
        do {
            let issued = try await VtaMobileAgent.authenticate(
                vtaURL: url, vtaDid: trimmedDid, identity: identity)
            tokens = issued
            isAuthenticated = true
            persistConnection()
            status = "✅ Connected — acr \(issued.acr ?? "—"), session valid \(issued.expiresIn)s"
            recordEvent(.auth, "Authenticated", "acr \(issued.acr ?? "—") · token \(issued.expiresIn)s")
            startKeepAlive()
            if !mediatorDid.trimmed.isEmpty { await startListening() }
            if pushEnabled { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            isAuthenticated = false
            connectionError = error.localizedDescription
            status = "❌ Connection failed — \(error.localizedDescription)"
            recordEvent(.error, "Connection failed", error.localizedDescription)
            if auto || autoConnectEnabled { scheduleReconnect() }
        }
    }

    /// Explicit user disconnect: tear everything down and stop auto-recovering
    /// until the next manual Connect.
    func disconnect() async {
        autoConnectEnabled = false
        reconnectTask?.cancel(); reconnectTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        await stopListening()
        tokens = nil
        isAuthenticated = false
        whoamiSummary = nil
        status = "Disconnected. Tap Connect to bring the agent back online."
        recordEvent(.info, "Disconnected", nil)
    }

    /// Background backoff retry after a failed/lost connection.
    private func scheduleReconnect() {
        guard autoConnectEnabled, reconnectTask == nil else { return }
        reconnectTask = Task { [self] in
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 60)
                guard autoConnectEnabled, !isAuthenticated else { break }
                log("Auto-reconnect attempt…")
                await connect(auto: true)
                if isAuthenticated { break }
            }
            reconnectTask = nil
        }
    }

    /// A valid access token, re-authenticating transparently if we don't have one.
    private func currentAccessToken() async -> String? {
        if let t = tokens { return t.accessToken }
        guard let url = normalizedURL(), let identity, !trimmedDid.isEmpty else { return nil }
        if let issued = try? await VtaMobileAgent.authenticate(
            vtaURL: url, vtaDid: trimmedDid, identity: identity)
        {
            tokens = issued
            isAuthenticated = true
            startKeepAlive()
            return issued.accessToken
        }
        return nil
    }

    /// Re-authenticate ahead of token expiry so the session never lapses.
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        guard let exp = tokens?.expiresIn else { return }
        let lead = max(30, Int(Double(exp) * 0.8))
        keepAliveTask = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(lead) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await refreshSession()
        }
    }

    private func refreshSession() async {
        guard let url = normalizedURL(), let identity, !trimmedDid.isEmpty else { return }
        do {
            let issued = try await VtaMobileAgent.authenticate(
                vtaURL: url, vtaDid: trimmedDid, identity: identity)
            tokens = issued
            isAuthenticated = true
            log("Session refreshed (acr \(issued.acr ?? "—"))")
            startKeepAlive()
        } catch {
            log("Session refresh failed: \(error.localizedDescription)")
            scheduleReconnect()
        }
    }

    // MARK: VTA discovery

    /// Resolve the VTA's DID and fill the REST URL + mediator DID from its DID
    /// document, so the operator enters only the DID.
    func resolveFromDid() async {
        let did = trimmedDid
        guard !did.isEmpty else {
            status = "Enter the VTA DID first."
            return
        }
        busy = true
        defer { busy = false }
        status = "Resolving endpoints from \(did)…"
        do {
            let ep = try await resolveVtaEndpoints(did: did)
            var filled: [String] = []
            if let rest = ep.restBaseUrl, !rest.isEmpty {
                vtaURL = rest
                filled.append("URL")
            }
            if let med = ep.mediatorDid, !med.isEmpty {
                mediatorDid = med
                filled.append("mediator")
            }
            status =
                filled.isEmpty
                ? "Resolved the DID, but it advertises no #vta-rest / #vta-didcomm "
                    + "service — enter the URL / mediator manually."
                : "✅ Filled \(filled.joined(separator: " + ")) from the DID."
            if filled.contains("URL") { persistConnection() }
        } catch {
            status = "❌ Couldn't resolve \(did) — \(error.localizedDescription)"
        }
    }

    // MARK: Session introspection

    func whoami() async {
        guard let identity, let url = normalizedURL() else { return }
        guard let token = await currentAccessToken() else {
            whoamiSummary = "Not connected."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let info = try await VtaMobileAgent.whoami(
                vtaURL: url, vtaDid: trimmedDid, identity: identity, accessToken: token)
            let roles = info.roles.isEmpty ? "—" : info.roles.joined(separator: ", ")
            whoamiSummary = "session \(info.sessionId)\nacr \(info.acr ?? "—") · roles: \(roles)"
        } catch {
            whoamiSummary = "whoami failed — \(error.localizedDescription)"
        }
    }

    // MARK: Step-up (test surfaces)

    /// Self-contained demo: provoke + approve a step-up on this device's own
    /// session, then reflect the elevated `acr` via whoami.
    func demoStepUp() async {
        guard let identity, let url = normalizedURL(), !trimmedDid.isEmpty,
            let token = await currentAccessToken()
        else {
            stepUpStatus = "Connect first."
            return
        }
        busy = true
        defer { busy = false }
        stepUpStatus = "Stepping up this session…"
        do {
            let outcome = try await VtaMobileAgent.demoSelfStepUp(
                vtaURL: url, vtaDid: trimmedDid, identity: identity, accessToken: token)
            stepUpStatus = "✅ Elevated to \(outcome.grantedAcr ?? "—")"
            recordEvent(.approval, "Self step-up", "→ \(outcome.grantedAcr ?? "—")")
            await whoami()
        } catch {
            stepUpStatus = "❌ Step-up failed — \(error.localizedDescription)"
        }
    }

    /// Proxied approver: ratify a step-up whose approve-request was relayed here
    /// from another device (paste the VTA `403` body or the bare document).
    func approvePasted() async {
        guard let identity, let url = normalizedURL(), !trimmedDid.isEmpty,
            let token = await currentAccessToken()
        else {
            stepUpStatus = "Connect first."
            return
        }
        let request = pastedApproveRequest.trimmed
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
                identity: identity, accessToken: token)
            stepUpStatus = "✅ Approved — session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")"
            recordEvent(.approval, "Approved (pasted)",
                "session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")")
            pastedApproveRequest = ""
        } catch {
            stepUpStatus = "❌ Approve failed — \(error.localizedDescription)"
        }
    }

    // MARK: Human-in-the-loop review gate

    /// Route an incoming step-up: an AI ask carrying a structured authorization
    /// context is surfaced for the operator's consent; a plain login-elevation
    /// step-up (no context) is auto-ratified.
    private func handleIncomingStepUp(
        doc: String, url: URL, did: String, token: String, identity: HolderIdentity
    ) async {
        do {
            let review = try VtaMobileAgent.inspect(approveRequest: doc)
            if VtaMobileAgent.requiresReview(review) {
                // Queue it (dedupe by session so a re-drain doesn't double-add).
                if !pendingApprovals.contains(where: { $0.review.sessionId == review.sessionId }) {
                    pendingApprovals.append(PendingApproval(rawDoc: doc, review: review))
                }
                stepUpStatus = "🔔 Approval requested — \(pendingApprovals.count) pending"
                notifyPendingApproval(review)
            } else {
                let outcome = try await VtaMobileAgent.approveStepUp(
                    approveRequest: doc, vtaURL: url, vtaDid: did,
                    identity: identity, accessToken: token)
                stepUpStatus =
                    "✅ Approved — session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")"
                recordEvent(.approval, "Approved (live)",
                    "session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")")
            }
        } catch {
            stepUpStatus = "❌ Step-up failed — \(error.localizedDescription)"
        }
    }

    /// Resolve a specific queued ask (by session), or the front one if `sessionId`
    /// isn't found (e.g. a notification action with no target). Approve signs
    /// (Face ID fires as the enclave key signs); Deny sends a holder-signed
    /// refusal the VTA audits. A fresh token is fetched — the ask may have sat.
    func resolveApproval(
        sessionId: String? = nil, approve: Bool, reason: String = "Declined by the operator"
    ) async {
        let pending =
            sessionId.flatMap { sid in pendingApprovals.first { $0.review.sessionId == sid } }
            ?? frontApproval
        guard let pending, let identity, let url = normalizedURL(), !trimmedDid.isEmpty,
            let token = await currentAccessToken()
        else { return }
        busy = true
        defer { busy = false }
        do {
            if approve {
                _ = try await VtaMobileAgent.approveStepUp(
                    approveRequest: pending.rawDoc, vtaURL: url, vtaDid: trimmedDid,
                    identity: identity, accessToken: token)
                stepUpStatus = "✅ Approved — \(pending.summary)"
                recordEvent(.approval, "Approved", pending.summary)
            } else {
                _ = try await VtaMobileAgent.denyStepUp(
                    approveRequest: pending.rawDoc, reason: reason, vtaURL: url,
                    vtaDid: trimmedDid, identity: identity, accessToken: token)
                stepUpStatus = "🚫 Declined — \(pending.summary)"
                recordEvent(.error, "Declined", pending.summary)
            }
            pendingApprovals.removeAll { $0.review.sessionId == pending.review.sessionId }
            // Clear the (possibly still-visible) notification for this ask.
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: ["pending-approval-\(pending.review.sessionId)"])
        } catch {
            stepUpStatus =
                "❌ \(approve ? "Approve" : "Decline") failed — \(error.localizedDescription)"
        }
    }

    /// Convenience for the review sheet's buttons (act on the shown ask).
    func approve(_ pending: PendingApproval) async {
        await resolveApproval(sessionId: pending.review.sessionId, approve: true)
    }
    func deny(_ pending: PendingApproval, reason: String = "Declined by the operator") async {
        await resolveApproval(sessionId: pending.review.sessionId, approve: false, reason: reason)
    }

    // MARK: Actionable approval notification

    static let approvalCategoryId = "CIERGE_APPROVAL"
    static let approveActionId = "CIERGE_APPROVE"
    static let denyActionId = "CIERGE_DENY"

    /// `UNNotification.userInfo` key carrying the ask's session id, so an inline
    /// action resolves the exact ask it was posted for (not merely the front).
    static let sessionUserInfoKey = "cierge.sessionId"

    /// Post a local notification for a pending approval, with inline Approve/Deny
    /// actions (registered by the `AppDelegate`) so the operator can act from the
    /// lock screen without opening the app. One notification per ask (keyed by
    /// session), so concurrent asks each get their own.
    func notifyPendingApproval(_ review: VtaMobileAgent.StepUpReview) {
        let content = UNMutableNotificationContent()
        content.title = "Authorization requested"
        content.body = review.authorizationContext?.summary ?? review.reason
        content.categoryIdentifier = Self.approvalCategoryId
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.userInfo = [Self.sessionUserInfoKey: review.sessionId]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "pending-approval-\(review.sessionId)", content: content, trigger: nil))
    }

    // MARK: Task-consent (second-device approval)

    /// Queue an inbound `task-consent/request` for the operator. Unlike a plain
    /// login step-up there is no auto-ratify path: a privileged Trust Task always
    /// requires the human to see the effects and decide.
    private func handleIncomingTaskConsent(
        doc: String, url: URL, did: String, token: String, identity: HolderIdentity
    ) async {
        do {
            let request = try VtaMobileAgent.inspectTaskConsent(request: doc)
            // Dedupe by payloadDigest so a re-drain doesn't double-add.
            if !pendingConsents.contains(where: { $0.request.payloadDigest == request.payloadDigest })
            {
                pendingConsents.append(PendingConsent(rawDoc: doc, request: request))
            }
            stepUpStatus = "🔔 Approval requested — \(pendingConsents.count) task-consent pending"
            notifyPendingConsent(request)
        } catch {
            stepUpStatus = "❌ Task-consent parse failed — \(error.localizedDescription)"
        }
    }

    /// Resolve a queued task-consent (by `payloadDigest`, else the front one).
    /// Approve signs the decision (Face ID fires as the enclave key signs) and
    /// posts it; Deny sends a signed refusal the VTA records. A fresh token is
    /// fetched — the ask may have sat.
    func resolveConsent(
        payloadDigest: String? = nil, approve: Bool, reason: String = "Declined by the operator"
    ) async {
        let pending =
            payloadDigest.flatMap { d in pendingConsents.first { $0.request.payloadDigest == d } }
            ?? frontConsent
        guard let pending, let identity, let url = normalizedURL(), !trimmedDid.isEmpty,
            let token = await currentAccessToken()
        else { return }
        busy = true
        defer { busy = false }
        do {
            if approve {
                let outcome = try await VtaMobileAgent.approveTaskConsent(
                    request: pending.rawDoc, vtaURL: url, vtaDid: trimmedDid,
                    identity: identity, accessToken: token)
                stepUpStatus = "✅ Approved — \(pending.summary) (\(outcome.status))"
                recordEvent(.approval, "Approved task", pending.summary)
            } else {
                _ = try await VtaMobileAgent.denyTaskConsent(
                    request: pending.rawDoc, reason: reason, vtaURL: url,
                    vtaDid: trimmedDid, identity: identity, accessToken: token)
                stepUpStatus = "🚫 Declined — \(pending.summary)"
                recordEvent(.error, "Declined task", pending.summary)
            }
            pendingConsents.removeAll { $0.request.payloadDigest == pending.request.payloadDigest }
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: ["pending-consent-\(pending.request.payloadDigest)"])
        } catch {
            stepUpStatus =
                "❌ \(approve ? "Approve" : "Decline") failed — \(error.localizedDescription)"
        }
    }

    /// Convenience for the task-consent sheet's buttons.
    func approveConsent(_ pending: PendingConsent) async {
        await resolveConsent(payloadDigest: pending.request.payloadDigest, approve: true)
    }
    func denyConsent(_ pending: PendingConsent, reason: String = "Declined by the operator") async {
        await resolveConsent(
            payloadDigest: pending.request.payloadDigest, approve: false, reason: reason)
    }

    /// Post a time-sensitive notification for a pending task-consent, keyed by
    /// `payloadDigest` so concurrent asks each get their own.
    func notifyPendingConsent(_ request: TaskConsentRequest) {
        let content = UNMutableNotificationContent()
        content.title = "Approval requested"
        content.body =
            request.effects.first?.summary
            ?? request.consequences.first
            ?? "A privileged task needs your approval."
        content.categoryIdentifier = Self.approvalCategoryId
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "pending-consent-\(request.payloadDigest)", content: content,
                trigger: nil))
    }

    // MARK: Live mediator approver (supervised, auto-reconnecting)

    func toggleMediatorListen() async {
        if listening || listenSupervisor != nil {
            await stopListening()
        } else {
            await startListening()
        }
    }

    /// Connect to the holder's mediator and service VTA-pushed step-up
    /// approve-requests as they arrive, auto-reconnecting with backoff on any
    /// drop. Idempotent.
    func startListening() async {
        guard listenSupervisor == nil else { return }
        guard let identity, let url = normalizedURL(), !trimmedDid.isEmpty else {
            stepUpStatus = "Connect first."
            return
        }
        let mediator = mediatorDid.trimmed
        guard !mediator.isEmpty else {
            stepUpStatus = "Set the mediator DID in Settings to listen."
            return
        }
        let did = trimmedDid
        listenSupervisor = Task { [self] in
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                guard let token = await currentAccessToken() else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                do {
                    // Transport is the operator's choice (one socket per DID —
                    // ADR 0005), so open exactly one inbox. TSP carries the
                    // Trust-Task document directly; DIDComm wraps it in an
                    // envelope. Both surface the same tagged request, so the
                    // dispatch below is identical either way.
                    if useTsp {
                        let session = try await identity.connectMediatorTsp(mediatorDid: mediator)
                        tspSession = session
                        listening = true
                        connectionError = nil
                        stepUpStatus = "👂 Listening for step-up / task-consent over TSP…"
                        backoff = 1
                        while !Task.isCancelled {
                            guard let inbound = try await VtaMobileAgent.nextInboundTsp(session: session)
                            else { continue }  // timeout / other traffic → keep listening
                            switch inbound {
                            case .stepUp(let doc):
                                await handleIncomingStepUp(
                                    doc: doc, url: url, did: did, token: token, identity: identity)
                            case .taskConsent(let doc):
                                await handleIncomingTaskConsent(
                                    doc: doc, url: url, did: did, token: token, identity: identity)
                            }
                        }
                        await session.shutdown()
                    } else {
                        let session = try await identity.connectMediator(
                            vtaDid: did, mediatorDid: mediator)
                        mediatorSession = session
                        listening = true
                        connectionError = nil
                        stepUpStatus = "👂 Listening for step-up requests…"
                        backoff = 1
                        while !Task.isCancelled {
                            // Pull the next request WITHOUT acting — so an AI ask that
                            // carries a structured authorization context, or a
                            // task-consent approval, is surfaced for the operator's
                            // Approve/Deny instead of auto-ratified.
                            guard let inbound = try await VtaMobileAgent.nextInbound(session: session)
                            else { continue }  // timeout / other traffic → keep listening
                            switch inbound {
                            case .stepUp(let doc):
                                await handleIncomingStepUp(
                                    doc: doc, url: url, did: did, token: token, identity: identity)
                            case .taskConsent(let doc):
                                await handleIncomingTaskConsent(
                                    doc: doc, url: url, did: did, token: token, identity: identity)
                            }
                        }
                        await session.shutdown()
                    }
                } catch {
                    if Task.isCancelled { break }
                    listening = false
                    stepUpStatus = "Reconnecting to mediator…"
                    log("Mediator listen dropped: \(error.localizedDescription); reconnecting")
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 30)
                }
            }
            listening = false
        }
    }

    func stopListening() async {
        listenSupervisor?.cancel()
        listenSupervisor = nil
        if let session = mediatorSession {
            await session.shutdown()
        }
        mediatorSession = nil
        if let session = tspSession {
            await session.shutdown()
        }
        tspSession = nil
        listening = false
        if isAuthenticated { stepUpStatus = "Stopped listening." }
    }

    /// Re-open the inbox when the operator flips the transport (`useTsp`) while
    /// already listening, so the change takes effect at once. The one-socket-
    /// per-DID rule means we must drop the current mediator socket before
    /// opening the other transport's. No-op when not listening — the next
    /// `startListening` picks up the new transport on its own.
    func restartListeningIfActive() async {
        guard listenSupervisor != nil else { return }
        await stopListening()
        await startListening()
    }

    private func normalizedURL() -> URL? {
        let trimmed = vtaURL.trimmed
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        return url
    }

    // MARK: Push wake-up (APNs)

    /// Ask for notification permission and register for remote notifications. The
    /// APNs device token comes back via the `AppDelegate` → `onApnsToken`.
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
        apnsToken = hex
        print("[vta-agent] APNs device token: \(hex)")
        guard let identity, let url = normalizedURL(), !trimmedDid.isEmpty,
            let token = await currentAccessToken()
        else {
            pushStatus = "Got APNs token — connect to a VTA first, then enable push."
            return
        }
        let gw = gatewayUrl.trimmed
        guard let gatewayURL = URL(string: gw), gatewayURL.scheme != nil else {
            pushStatus = "Set the push gateway URL in Settings before enabling push."
            return
        }
        let mediator = mediatorDid.trimmed
        do {
            let setup = try await VtaMobileAgent.registerApnsWake(
                apnsToken: hex,
                topic: Bundle.main.bundleIdentifier ?? "org.openvtc.vta.agent",
                environment: .sandbox,
                gatewayURL: gatewayURL,
                controllerVtaDid: trimmedDid,
                vtaURL: url,
                vtaDid: trimmedDid,
                identity: identity,
                accessToken: token,
                suggestedTriggers: mediator.isEmpty ? [] : [mediator])
            pushEnabled = setup.pushCapable
            persistConnection()
            pushStatus = setup.pushCapable
                ? "✅ Push wake registered — VTA allowlist: "
                    + (setup.allowedTriggers.isEmpty ? "—" : setup.allowedTriggers.joined(separator: ", "))
                : "Push channel cleared."
            recordEvent(.push, "Push wake registered",
                setup.allowedTriggers.isEmpty ? nil : "triggers: \(setup.allowedTriggers.joined(separator: ", "))")
        } catch {
            pushStatus = "❌ Push registration failed — \(error.localizedDescription)"
        }
    }

    func onApnsRegisterFailed(_ error: Error) {
        pushStatus = "❌ APNs registration failed — \(error.localizedDescription)"
    }

    /// A contentless wake arrived (background push). Re-establish what we need and
    /// drain any queued approve-requests, ratifying each with the holder key.
    func handlePushWake() async -> Bool {
        guard let cfg = Self.loadConnection(), let vtaURLValue = URL(string: cfg.vtaURL) else {
            pushStatus = "Push received, but no saved VTA connection — open the app and connect."
            return false
        }
        do {
            let id = try identity ?? HolderIdentity.loadOrCreate()
            identity = id
            let accessToken: String
            if let tokens {
                accessToken = tokens.accessToken
            } else {
                let issued = try await VtaMobileAgent.authenticate(
                    vtaURL: vtaURLValue, vtaDid: cfg.vtaDid, identity: id)
                tokens = issued
                accessToken = issued.accessToken
            }
            let session = try await id.connectMediator(
                vtaDid: cfg.vtaDid, mediatorDid: cfg.mediatorDid)
            defer { Task { await session.shutdown() } }
            var handledAny = false
            for _ in 0..<5 {
                guard
                    let inbound = try await VtaMobileAgent.nextInbound(
                        session: session, timeoutSecs: 5)
                else { break }
                handledAny = true
                // Same gate as the live listener: surface the ask for consent
                // (posting the actionable notification — ideal for a background
                // wake); a plain login step-up auto-ratifies.
                switch inbound {
                case .stepUp(let doc):
                    await handleIncomingStepUp(
                        doc: doc, url: vtaURLValue, did: cfg.vtaDid,
                        token: accessToken, identity: id)
                case .taskConsent(let doc):
                    await handleIncomingTaskConsent(
                        doc: doc, url: vtaURLValue, did: cfg.vtaDid,
                        token: accessToken, identity: id)
                }
            }
            pushStatus = handledAny ? "✅ Push wake serviced." : "Woken by push — nothing pending."
            return handledAny
        } catch {
            pushStatus = "❌ Push-wake drain failed — \(error.localizedDescription)"
            return false
        }
    }

    // MARK: History + logging

    private func recordEvent(_ kind: AgentEvent.Kind, _ title: String, _ detail: String?) {
        events.insert(AgentEvent(kind: kind, title: title, detail: detail), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        log("[\(kind)] \(title)\(detail.map { " — \($0)" } ?? "")")
    }

    func log(_ message: String) {
        LogStore.shared.append("[agent] \(message)")
    }

    // MARK: Connection persistence

    struct ConnectionConfig {
        let vtaURL: String
        let vtaDid: String
        let mediatorDid: String
        let gatewayUrl: String
    }

    private func persistConnection() {
        let d = UserDefaults.standard
        d.set(vtaURL.trimmed, forKey: "pnm.vtaURL")
        d.set(trimmedDid, forKey: "pnm.vtaDid")
        d.set(mediatorDid.trimmed, forKey: "pnm.mediatorDid")
        d.set(gatewayUrl.trimmed, forKey: "pnm.gatewayUrl")
    }

    /// Persist the current config without requiring a connection (so edits in
    /// Settings survive even before the first successful auth).
    func saveConfig() { persistConnection() }

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

    /// Prefill the connection fields from the last persisted session.
    func loadPersistedConnection() {
        let d = UserDefaults.standard
        if vtaURL.isEmpty, let v = d.string(forKey: "pnm.vtaURL") { vtaURL = v }
        if vtaDid.isEmpty, let v = d.string(forKey: "pnm.vtaDid") { vtaDid = v }
        if mediatorDid.isEmpty, let v = d.string(forKey: "pnm.mediatorDid") { mediatorDid = v }
        if gatewayUrl.isEmpty, let v = d.string(forKey: "pnm.gatewayUrl") { gatewayUrl = v }
    }
}

/// An incoming step-up awaiting the operator's Approve/Deny — the raw
/// approve-request (to sign the response over) plus its parsed review.
struct PendingApproval: Identifiable {
    let id = UUID()
    let rawDoc: String
    let review: VtaMobileAgent.StepUpReview
    /// The line to show/record — the structured summary, else the reason.
    var summary: String { review.authorizationContext?.summary ?? review.reason }
    /// The structured context, when present (drives the review card).
    var context: AuthorizationContext? { review.authorizationContext }
}

/// One outstanding **task-consent** ask — the device as a second approver.
struct PendingConsent: Identifiable {
    let id = UUID()
    /// The raw `task-consent/request` document (the DIDComm body) — re-parsed and
    /// re-sent verbatim so the decision binds to exactly what was shown.
    let rawDoc: String
    let request: TaskConsentRequest
    /// The line to show/record — the first effect, else static consequence text.
    var summary: String {
        request.effects.first?.summary
            ?? request.consequences.first
            ?? "Execute \(request.taskType)"
    }
}

/// A user-facing activity entry for the History tab.
struct AgentEvent: Identifiable {
    enum Kind: CustomStringConvertible {
        case approval, auth, push, info, error
        var description: String {
            switch self {
            case .approval: return "approval"
            case .auth: return "auth"
            case .push: return "push"
            case .info: return "info"
            case .error: return "error"
            }
        }
    }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let title: String
    let detail: String?
}
