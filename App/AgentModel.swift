import Foundation
import SwiftUI
import UIKit
import UserNotifications
import VtaMobileAgent
import VtaMobileCore

/// UI-facing state for the agent. Owns the device holder identity and drives the
/// messaging approver loop on the `VtaMobileAgent` façade.
///
/// **No REST, no tokens.** The agent reaches its VTA only over the mediator —
/// DIDComm or TSP. The VTA proves the sender cryptographically on every message
/// and derives authorization from that DID (intrinsic-sender auth), so there is
/// no challenge/authenticate exchange, no bearer token and nothing to refresh.
/// "Connected" therefore means *the inbox is open and the VTA answered a
/// `whoami` over it*.
///
/// Design goal: **everything auto and recoverable.** Once configured, the agent
/// auto-connects on launch and supervises the listen loop with
/// exponential-backoff reconnects, so a dropped network/VTA recovers without any
/// user action.
@MainActor
final class AgentModel: ObservableObject {
    /// Shared instance so the `AppDelegate` (APNs callbacks) and the SwiftUI views
    /// drive the same state.
    static let shared = AgentModel()

    // Configuration (persisted; see ConnectionConfig).
    @Published var vtaDid = ""
    @Published var mediatorDid = ""
    /// Push gateway base URL (HTTPS) — where `push/register` is POSTed.
    @Published var gatewayUrl = ""

    // Connection state. `isAuthenticated` now means "the VTA answered over the
    // inbox" — there is no token to hold, so a successful `whoami` is the proof.
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
    private var mediatorSession: MediatorSession?
    private var tspSession: TspMediatorSession?
    /// Correlates VTA replies arriving on the shared TSP inbox back to the
    /// `submit` awaiting them. Owned here because the listen loop (the only
    /// reader of the socket) and `transport` (the sender) must share one.
    private let tspRouter = TspReplyRouter()
    private var listenSupervisor: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var trimmedDid: String { vtaDid.trimmed }

    /// The **enrolled-executor allowlist**: the DIDs allowed to issue signed
    /// step-up / task-consent requests to this device. The engine verifies each
    /// inbound request's Data Integrity proof against this list *before* the
    /// app may show anything to the operator; an issuer outside it surfaces as
    /// `FfiError.UntrustedIssuer` and is logged and dropped without a prompt.
    ///
    /// Today the device is enrolled with exactly one executor — its VTA — so
    /// the list is just the enrolled VTA DID. This helper is the single
    /// extension point for widening it.
    /// TODO(enrolled-executors): include stored per-grant executor DIDs once
    /// the app persists enrollments beyond the VTA (the enrolled-executor
    /// model the browser plugin is growing).
    static func trustedIssuers(vtaDid: String) -> [String] {
        vtaDid.isEmpty ? [] : [vtaDid]
    }

    /// The allowlist for the currently configured VTA.
    private var trustedIssuers: [String] { Self.trustedIssuers(vtaDid: trimmedDid) }

    init() {
        autoConnectEnabled = (UserDefaults.standard.object(forKey: "pnm.autoConnect") as? Bool) ?? true
        pushEnabled = UserDefaults.standard.bool(forKey: "pnm.pushEnabled")
        useTsp = UserDefaults.standard.bool(forKey: "pnm.useTsp")
    }

    // MARK: Derived presentation state

    /// A mediator DID is now as load-bearing as the VTA DID: it is the *only*
    /// way to reach the VTA, where it used to be optional next to a REST URL.
    var isConfigured: Bool { !trimmedDid.isEmpty && !mediatorDid.trimmed.isEmpty }

    /// How Trust Task documents reach the VTA, over whichever inbox is currently
    /// open. `nil` until the listener has connected — which is exactly when the
    /// agent has no way to talk to its VTA.
    ///
    /// The `useTsp` toggle picks the socket (one per DID, ADR 0005), so the
    /// transport follows whichever session the listen loop actually opened
    /// rather than the flag, avoiding a window where they disagree.
    private var transport: VtaTransport? {
        if let session = tspSession {
            return TspTransport(
                session: session, vtaDid: trimmedDid, mediatorDid: mediatorDid.trimmed,
                router: tspRouter)
        }
        if let session = mediatorSession {
            return DidcommTransport(session: session)
        }
        return nil
    }

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
        // `p.vtaURL` is deliberately ignored: the agent no longer speaks REST. The
        // field is optional and only still parsed so codes minted for older
        // clients scan (see `PairingPayload`).
        vtaDid = p.vtaDID
        if let m = p.mediatorDID { mediatorDid = m }
        if let g = p.gatewayURL { gatewayUrl = g }
        persistConnection()
        recordEvent(
            .info, "Paired via QR", p.tenant.map { "tenant · \($0)" }, did: p.vtaDID)
        status = "Paired — connecting…"
        Task { await connect() }
    }

    // MARK: Connect / disconnect (auto + recoverable)

    /// Bring the agent online: open the mediator inbox, confirm the VTA answers
    /// over it, and (if previously enabled) re-arm push. A manual call re-arms
    /// auto-connect; an `auto` call schedules a backoff retry on failure.
    ///
    /// The order matters and is the inverse of the old REST flow: the inbox must
    /// be open *first*, because it is now the only channel — the `whoami` that
    /// verifies the connection travels over it.
    func connect(auto: Bool = false) async {
        guard identity != nil, isConfigured else {
            connectionError = "Enter the VTA DID + mediator DID in Settings first."
            status = connectionError!
            return
        }
        guard !connecting else { return }
        if !auto { autoConnectEnabled = true }
        connecting = true
        connectionError = nil
        if !auto { status = "Connecting to your VTA…" }
        defer { connecting = false }

        await startListening()
        guard let transport, let identity else {
            isAuthenticated = false
            connectionError = "Couldn't open the mediator inbox."
            status = "❌ \(connectionError!)"
            recordEvent(.error, "Connection failed", connectionError)
            if auto || autoConnectEnabled { scheduleReconnect() }
            return
        }
        do {
            // Proves three things at once: the inbox round-trips, the VTA is up,
            // and this device's did:key is enrolled in its ACL. An unenrolled
            // device fails here — the replacement for the old REST 401.
            let info = try await VtaMobileAgent.whoami(
                transport: transport, vtaDid: trimmedDid, identity: identity)
            isAuthenticated = true
            persistConnection()
            let roles = info.roles.isEmpty ? "—" : info.roles.joined(separator: ", ")
            whoamiSummary = "session \(info.sessionId)\nacr \(info.acr ?? "—") · roles: \(roles)"
            status = "✅ Connected over \(useTsp ? "TSP" : "DIDComm") — acr \(info.acr ?? "—")"
            recordEvent(
                .auth, "Connected", "acr \(info.acr ?? "—") · roles: \(roles)",
                did: trimmedDid)
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
        await stopListening()
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

    // Token machinery (`currentAccessToken` / `startKeepAlive` / `refreshSession`)
    // is gone with REST. Intrinsic-sender auth has no token to hold, so there is
    // no expiry to race and nothing to refresh — the holder key is the
    // credential on every single message.

    // MARK: VTA discovery

    /// Resolve the VTA's DID and fill the mediator DID from its DID document, so
    /// the operator enters only the DID. The document's `restBaseUrl` is ignored
    /// — the agent has no REST path to use it on.
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
            if let med = ep.mediatorDid, !med.isEmpty {
                mediatorDid = med
                status = "✅ Filled mediator from the DID."
                persistConnection()
            } else {
                status =
                    "Resolved the DID, but it advertises no #vta-didcomm service — "
                    + "enter the mediator DID manually."
            }
        } catch {
            status = "❌ Couldn't resolve \(did) — \(error.localizedDescription)"
        }
    }

    // MARK: Session introspection

    func whoami() async {
        guard let identity, let transport else {
            whoamiSummary = "Not connected."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let info = try await VtaMobileAgent.whoami(
                transport: transport, vtaDid: trimmedDid, identity: identity)
            let roles = info.roles.isEmpty ? "—" : info.roles.joined(separator: ", ")
            whoamiSummary = "session \(info.sessionId)\nacr \(info.acr ?? "—") · roles: \(roles)"
        } catch {
            whoamiSummary = "whoami failed — \(error.localizedDescription)"
        }
    }

    // MARK: Step-up (test surfaces)

    // `demoStepUp` is gone with REST: it worked by poking an AAL2-gated endpoint
    // so the VTA would answer 403 with an approve-request for our own session — a
    // challenge carried by an HTTP status, which the messaging transports have no
    // equivalent for. Exercise the loop by triggering a delegated step-up at the
    // VTA and letting it push the request here, which is the real sign-in path.

    /// Proxied approver: ratify a step-up whose approve-request was relayed here
    /// from another device (paste the VTA `403` body or the bare document).
    func approvePasted() async {
        guard let identity, let transport, !trimmedDid.isEmpty else {
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
                approveRequest: request, transport: transport, vtaDid: trimmedDid,
                identity: identity, trustedIssuers: trustedIssuers)
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
        doc: String, transport: VtaTransport, did: String, identity: HolderIdentity
    ) async {
        do {
            // `inspect` verifies the request's proof against the enrolled
            // allowlist before returning anything showable.
            let review = try await VtaMobileAgent.inspect(
                approveRequest: doc, trustedIssuers: Self.trustedIssuers(vtaDid: did))
            if VtaMobileAgent.requiresReview(review) {
                // Queue it (dedupe by session so a re-drain doesn't double-add).
                if !pendingApprovals.contains(where: { $0.review.sessionId == review.sessionId }) {
                    pendingApprovals.append(PendingApproval(rawDoc: doc, review: review))
                }
                stepUpStatus = "🔔 Approval requested — \(pendingApprovals.count) pending"
                notifyPendingApproval(review)
            } else {
                let outcome = try await VtaMobileAgent.approveStepUp(
                    approveRequest: doc, transport: transport, vtaDid: did,
                    identity: identity, trustedIssuers: Self.trustedIssuers(vtaDid: did))
                stepUpStatus =
                    "✅ Approved — session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")"
                recordEvent(.approval, "Approved (live)",
                    "session \(outcome.sessionId) → \(outcome.grantedAcr ?? "—")")
            }
        } catch FfiError.UntrustedIssuer(let reason) {
            // Spec rule: an unverifiable request MUST NOT prompt. Log and drop
            // — no notification, no queue entry, no status-line alert.
            log("Dropped an unverifiable step-up (untrusted issuer): \(reason)")
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
        guard let pending, let identity, let transport, !trimmedDid.isEmpty
        else { return }
        busy = true
        defer { busy = false }
        do {
            if approve {
                _ = try await VtaMobileAgent.approveStepUp(
                    approveRequest: pending.rawDoc, transport: transport, vtaDid: trimmedDid,
                    identity: identity, trustedIssuers: trustedIssuers)
                stepUpStatus = "✅ Approved — \(pending.summary)"
                recordEvent(
                    .approval, "Approved", pending.summary,
                    did: pending.review.relyingParty)
            } else {
                _ = try await VtaMobileAgent.denyStepUp(
                    approveRequest: pending.rawDoc, reason: reason, transport: transport,
                    vtaDid: trimmedDid, identity: identity, trustedIssuers: trustedIssuers)
                stepUpStatus = "🚫 Declined — \(pending.summary)"
                recordEvent(
                    .error, "Declined", pending.summary,
                    did: pending.review.relyingParty)
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
    /// Queue an inbound task-consent for the operator. Takes no transport: it
    /// only parses and queues — the signed decision is submitted later by
    /// `resolveConsent`, which picks up whichever inbox is open then.
    private func handleIncomingTaskConsent(doc: String, did: String) async {
        do {
            // `inspectTaskConsent` verifies the request's proof against the
            // enrolled allowlist before returning anything showable.
            let request = try await VtaMobileAgent.inspectTaskConsent(
                request: doc, trustedIssuers: Self.trustedIssuers(vtaDid: did))
            // Dedupe by payloadDigest so a re-drain doesn't double-add.
            if !pendingConsents.contains(where: { $0.request.payloadDigest == request.payloadDigest })
            {
                pendingConsents.append(PendingConsent(rawDoc: doc, request: request))
            }
            stepUpStatus = "🔔 Approval requested — \(pendingConsents.count) task-consent pending"
            notifyPendingConsent(request)
        } catch FfiError.UntrustedIssuer(let reason) {
            // Spec rule: an unverifiable request MUST NOT prompt. Log and drop
            // — no notification, no queue entry, no status-line alert.
            log("Dropped an unverifiable task-consent (untrusted issuer): \(reason)")
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
        guard let pending, let identity, let transport, !trimmedDid.isEmpty
        else { return }
        busy = true
        defer { busy = false }
        do {
            if approve {
                let outcome = try await VtaMobileAgent.approveTaskConsent(
                    request: pending.rawDoc, transport: transport, vtaDid: trimmedDid,
                    identity: identity, trustedIssuers: trustedIssuers)
                stepUpStatus = "✅ Approved — \(pending.summary) (\(outcome.status))"
                recordEvent(
                    .approval, "Approved task", pending.summary,
                    did: pending.request.issuer)
            } else {
                _ = try await VtaMobileAgent.denyTaskConsent(
                    request: pending.rawDoc, reason: reason, transport: transport,
                    vtaDid: trimmedDid, identity: identity, trustedIssuers: trustedIssuers)
                stepUpStatus = "🚫 Declined — \(pending.summary)"
                recordEvent(
                    .error, "Declined task", pending.summary,
                    did: pending.request.issuer)
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
        guard let identity, !trimmedDid.isEmpty else {
            stepUpStatus = "Set the VTA DID in Settings first."
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
                do {
                    // Transport is the operator's choice (one socket per DID —
                    // ADR 0005), so open exactly one inbox. TSP carries the
                    // Trust-Task document directly; DIDComm wraps it in an
                    // envelope. Both surface the same tagged request, so the
                    // dispatch below is identical either way.
                    if useTsp {
                        let session = try await identity.connectMediatorTsp(mediatorDid: mediator)
                        tspSession = session
                        mediatorSession = nil  // `transport` must not see a stale DIDComm session
                        listening = true
                        connectionError = nil
                        stepUpStatus = "👂 Listening for step-up / task-consent over TSP…"
                        backoff = 1
                        // Tell the VTA this device is on TSP now, so its device-push
                        // prefers TSP for us (learn-from-inbound). A receive-only
                        // inbox sends nothing else, so this announce is the only
                        // signal — best-effort, and re-announced below to stay inside
                        // the VTA's reachability TTL.
                        try? await session.announce(vtaDid: did, mediatorDid: mediator)
                        var lastAnnounce = Date()
                        while !Task.isCancelled {
                            // Re-announce well within the VTA's ~300s reachability
                            // TTL so a long-lived inbox doesn't silently decay back to
                            // DIDComm. Checked each loop turn (≤ the 30s recv poll).
                            if Date().timeIntervalSince(lastAnnounce) >= 150 {
                                try? await session.announce(vtaDid: did, mediatorDid: mediator)
                                lastAnnounce = Date()
                            }
                            // `router:` is essential now that we also *send* over
                            // TSP — this loop owns the socket, so it is the only
                            // thing that sees the VTA's replies to our own
                            // submissions. Without it every submit would time out.
                            guard
                                let inbound = try await VtaMobileAgent.nextInboundTsp(
                                    session: session, router: tspRouter)
                            else { continue }  // timeout / reply / other traffic → keep listening
                            guard let transport else { continue }
                            switch inbound {
                            case .stepUp(let doc):
                                await handleIncomingStepUp(
                                    doc: doc, transport: transport, did: did, identity: identity)
                            case .taskConsent(let doc):
                                await handleIncomingTaskConsent(doc: doc, did: did)
                            }
                        }
                        await session.shutdown()
                    } else {
                        let session = try await identity.connectMediator(
                            vtaDid: did, mediatorDid: mediator)
                        mediatorSession = session
                        tspSession = nil  // `transport` must not see a stale TSP session
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
                            guard let transport else { continue }
                            switch inbound {
                            case .stepUp(let doc):
                                await handleIncomingStepUp(
                                    doc: doc, transport: transport, did: did, identity: identity)
                            case .taskConsent(let doc):
                                await handleIncomingTaskConsent(doc: doc, did: did)
                            }
                        }
                        await session.shutdown()
                    }
                } catch {
                    if Task.isCancelled { break }
                    listening = false
                    // Tear the dead session down before opening a replacement.
                    // The throw skipped the `shutdown()` at the end of the inner
                    // loop, and the engine warns loudly about a session dropped
                    // without one — plus the mediator allows a single socket per
                    // DID, so leaving the old one half-open invites the
                    // reconnect to be evicted as a duplicate channel.
                    if let stale = mediatorSession {
                        await stale.shutdown()
                        mediatorSession = nil
                    }
                    if let stale = tspSession {
                        await stale.shutdown()
                        tspSession = nil
                    }
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
        guard let identity, let transport, !trimmedDid.isEmpty else {
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
                transport: transport,
                vtaDid: trimmedDid,
                identity: identity,
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
        guard let cfg = Self.loadConnection() else {
            pushStatus = "Push received, but no saved VTA connection — open the app and connect."
            return false
        }
        // The mediator permits exactly ONE websocket per DID. If the supervised
        // listener still holds it, that loop is already draining this inbox —
        // opening a second socket here would be evicted as a duplicate channel,
        // and the eviction could take out the live listener rather than us.
        if listening, mediatorSession != nil || tspSession != nil {
            log("Push wake ignored — the live inbox already holds this DID's socket.")
            pushStatus = "Woken by push — the live inbox is already draining."
            return false
        }

        do {
            let id = try identity ?? HolderIdentity.loadOrCreate()
            identity = id
            // A background wake is short-lived, so open a dedicated DIDComm
            // session and both drain *and* answer over it. There is no token to
            // fetch first — the holder key authorizes each message on its own,
            // which removes the old wake path's slowest step.
            let session = try await id.connectMediator(
                vtaDid: cfg.vtaDid, mediatorDid: cfg.mediatorDid)
            let wakeTransport = DidcommTransport(session: session)
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
                        doc: doc, transport: wakeTransport, did: cfg.vtaDid, identity: id)
                case .taskConsent(let doc):
                    await handleIncomingTaskConsent(doc: doc, did: cfg.vtaDid)
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

    /// `did` is the identity the entry concerns, when there is one. The log line
    /// keeps the full DID — a log is grepped, not read, so abbreviating there
    /// would lose the thing you grep for.
    private func recordEvent(
        _ kind: AgentEvent.Kind, _ title: String, _ detail: String?, did: String? = nil
    ) {
        events.insert(AgentEvent(kind: kind, title: title, detail: detail, did: did), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        log("[\(kind)] \(title)\(detail.map { " — \($0)" } ?? "")\(did.map { " · \($0)" } ?? "")")
    }

    func log(_ message: String) {
        LogStore.shared.append("[agent] \(message)")
    }

    // MARK: Connection persistence

    struct ConnectionConfig {
        let vtaDid: String
        let mediatorDid: String
        let gatewayUrl: String
    }

    private func persistConnection() {
        let d = UserDefaults.standard
        d.set(trimmedDid, forKey: "pnm.vtaDid")
        d.set(mediatorDid.trimmed, forKey: "pnm.mediatorDid")
        d.set(gatewayUrl.trimmed, forKey: "pnm.gatewayUrl")
    }

    /// Persist the current config without requiring a connection (so edits in
    /// Settings survive even before the first successful auth).
    func saveConfig() { persistConnection() }

    static func loadConnection() -> ConnectionConfig? {
        let d = UserDefaults.standard
        guard let did = d.string(forKey: "pnm.vtaDid"), !did.isEmpty,
            let med = d.string(forKey: "pnm.mediatorDid"), !med.isEmpty
        else { return nil }
        return ConnectionConfig(
            vtaDid: did, mediatorDid: med,
            gatewayUrl: d.string(forKey: "pnm.gatewayUrl") ?? "")
    }

    /// Prefill the connection fields from the last persisted session.
    func loadPersistedConnection() {
        let d = UserDefaults.standard
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
    /// The DID this entry is *about* — the relying party that asked, the VTA that
    /// delivered — carried as a field rather than interpolated into `detail` so the
    /// row can render it through `DidLabel` and pick up its agent name. History
    /// exists to be audited after the fact, and "who asked" is the part worth
    /// naming.
    let did: String?
}
