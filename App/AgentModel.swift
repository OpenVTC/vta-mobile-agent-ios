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

    private var identity: HolderIdentity?
    private var tokens: AuthTokens?

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

    private func normalizedURL() -> URL? {
        let trimmed = vtaURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        return url
    }
}
