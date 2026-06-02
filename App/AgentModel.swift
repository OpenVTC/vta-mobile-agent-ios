import Foundation
import SwiftUI
import VtaMobileAgent
import VtaMobileCore

/// UI-facing state for the authentication demo. Owns the device holder identity
/// and drives the REST auth flow on the `VtaMobileAgent` façade.
@MainActor
final class AgentModel: ObservableObject {
    @Published var vtaURL = ""
    @Published var vtaDid = ""
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
}
