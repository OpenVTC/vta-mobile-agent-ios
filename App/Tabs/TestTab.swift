import SwiftUI
import UIKit
import VtaMobileAgent

/// Manual test surfaces for exercising the agent: self step-up, session
/// introspection, live mediator listening, pasted ratification, and push wake.
/// In normal use none of this is needed — the agent runs itself — but it's handy
/// for development and verification.
struct TestTab: View {
    @EnvironmentObject private var model: AgentModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.theme) private var theme

    var body: some View {
        ScreenScaffold(title: "Test") {
            if !model.isAuthenticated {
                Card(tint: .orange) {
                    CardHeader(title: "Connect first", systemImage: "bolt.slash.fill", tint: .orange)
                    Text("These tools need a live session. "
                        + (model.isConfigured ? "Bring the agent online from Home." : "Set up the agent in Settings."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(model.isConfigured ? "Go to Home" : "Go to Settings") {
                        router.tab = model.isConfigured ? Tab.home : Tab.settings
                    }
                    .font(.subheadline.weight(.semibold)).padding(.top, 4)
                }
            } else {
                sessionCard
                listenCard
                pasteCard
                pushCard
            }

            if let step = model.stepUpStatus {
                Card(tint: .blue) {
                    CardHeader(title: "Last result", systemImage: "text.bubble.fill", tint: .blue)
                    Text(step).font(.footnote)
                }
            }
        }
    }

    private var sessionCard: some View {
        Card(tint: .blue) {
            CardHeader(title: "Session", systemImage: "person.crop.circle.badge.checkmark", tint: .blue)
            Button {
                Task { await model.whoami() }
            } label: {
                Label("Who am I?", systemImage: "questionmark.circle")
            }
            .disabled(model.busy)
            if let whoami = model.whoamiSummary {
                Text(whoami)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var listenCard: some View {
        Card(tint: .teal) {
            CardHeader(title: "Live approver", systemImage: "dot.radiowaves.left.and.right", tint: .teal)
            Text(model.listening
                ? "Listening on the mediator. Incoming approve-requests are ratified automatically."
                : "Listen on the mediator and approve step-ups relayed from other devices, live.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await model.toggleMediatorListen() }
            } label: {
                Label(model.listening ? "Stop listening" : "Listen for step-ups",
                    systemImage: model.listening ? "stop.circle.fill" : "play.circle.fill")
            }
            .padding(.top, 4)
        }
    }

    private var pasteCard: some View {
        Card(tint: .indigo) {
            CardHeader(title: "Ratify a pasted request", systemImage: "doc.on.clipboard.fill", tint: .indigo)
            Text("Paste a VTA 403 body or a bare approve-request document.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.pastedApproveRequest)
                .font(.system(.caption2, design: .monospaced))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .tertiarySystemBackground)))
            // When the pasted request carries a structured authorization ask,
            // preview *what* it authorizes before ratifying.
            if let ctx = pastedAuthorizationContext {
                AuthorizationCard(context: ctx)
                    .padding(.top, 4)
            }
            Button {
                Task { await model.approvePasted() }
            } label: {
                Label("Approve pasted request", systemImage: "checkmark.circle.fill")
            }
            .disabled(model.busy).padding(.top, 4)
        }
    }

    /// Decode the structured authorization context from the currently-pasted
    /// approve-request, if it carries one (nil for a plain login step-up or
    /// while the text isn't yet a valid document).
    ///
    /// Preview-only, decoded locally: the engine's `inspect` now *verifies* the
    /// request's proof (async, may resolve the issuer's DID), which is the wrong
    /// shape for a keystroke-live preview. Verification still gates the actual
    /// approval — `approvePasted` goes through the verifying parse.
    private var pastedAuthorizationContext: AuthorizationContext? {
        let text = model.pastedApproveRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
            let data = text.data(using: .utf8),
            var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // A VTA `403` body carries the document under `approveRequest`.
        if let inner = obj["approveRequest"] as? [String: Any] { obj = inner }
        guard let payload = obj["payload"] as? [String: Any],
            let ext = payload["ext"] as? [String: Any],
            let ctx = ext["org.openvtc.authorization-context"],
            let ctxData = try? JSONSerialization.data(withJSONObject: ctx),
            let ctxJson = String(data: ctxData, encoding: .utf8)
        else { return nil }
        return AuthorizationContext.decode(fromJSON: ctxJson)
    }

    private var pushCard: some View {
        Card(tint: .orange) {
            CardHeader(title: "Push wake (APNs)", systemImage: "bell.badge.fill", tint: .orange)
            Text("Be woken by a contentless push instead of holding a connection. "
                + "Set the gateway URL in Settings first.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await model.enablePush() }
            } label: {
                Label(model.pushEnabled ? "Re-register push wake" : "Enable push wake",
                    systemImage: "bell.fill")
            }
            .disabled(model.busy).padding(.top, 4)
            if let push = model.pushStatus {
                Text(push).font(.footnote).padding(.top, 2)
            }
            if let token = model.apnsToken {
                Text("APNs token (for test-wake-apns):")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                MonoCopyRow(value: token, lineLimit: 3)
            }
        }
    }
}
