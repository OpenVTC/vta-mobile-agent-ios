import SwiftUI
import VtaMobileAgent
import VtaMobileCore

/// The consent gate for a **task-consent** ask — the device acting as a second
/// approving device for a privileged Trust Task (e.g. a delegated `did:webvh`
/// update). Shows what executing the task would do (the VTA's dry-run effects),
/// a match code to compare against the requesting screen, and lets the operator
/// **Approve** (Face ID fires as the enclave key signs) or **Deny with a reason**
/// (a holder-signed refusal the VTA records). Presented for the front of
/// `AgentModel.pendingConsents`.
struct TaskConsentSheet: View {
    let pending: PendingConsent
    @ObservedObject var model: AgentModel
    /// Total outstanding asks (this one + those queued behind it).
    var remaining: Int = 1

    @State private var showDenyReasons = false

    private let denyReasons = [
        "The codes don't match",
        "Not something I authorized",
        "Wrong scope",
        "Not right now",
    ]

    private var request: TaskConsentRequest { pending.request }
    private var isDestructive: Bool { request.sideEffects == "destructive" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if remaining > 1 {
                        Text("\(remaining) pending — reviewing 1 of \(remaining)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    effects
                    matchCode

                    if isDestructive {
                        Label("This cannot be undone.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    requester

                    Text(
                        "Only approve if the code above matches the one shown on the device that "
                            + "requested this change. Approve signs with your device key; Deny sends "
                            + "a signed refusal."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    buttons
                    queuedPreview
                }
                .padding()
            }
            .navigationTitle("Approve change?")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()  // force an explicit Approve/Deny
            .confirmationDialog(
                "Decline this change?", isPresented: $showDenyReasons, titleVisibility: .visible
            ) {
                ForEach(denyReasons, id: \.self) { reason in
                    Button(reason, role: .destructive) {
                        Task { await model.denyConsent(pending, reason: reason) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// What executing the task will do. `effects` when the VTA had a dry-run; the
    /// spec's static `consequences` when it did not; and — when it has neither — an
    /// explicit statement that nobody can say (never rendered as "no effects").
    @ViewBuilder private var effects: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This will:").font(.headline)
            if request.effects.isEmpty && request.consequences.isEmpty {
                Text("This agent could not determine what this task will do.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if request.effects.isEmpty {
                ForEach(request.consequences, id: \.self) { bullet($0) }
            } else {
                ForEach(Array(request.effects.enumerated()), id: \.offset) { _, e in
                    bullet(e.summary)
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The match code — the operator reads it here and compares it against the
    /// requesting screen. A code that doesn't match means the change the
    /// requesting device shows is not the change that would be made.
    @ViewBuilder private var matchCode: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Match code")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(request.matchCode)
                .font(.system(.largeTitle, design: .monospaced))
                .tracking(6)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var requester: some View {
        // The issuer is the *proven* signer of the request's Data Integrity
        // proof (verified on-device before this sheet can exist), so it is
        // always present.
        VStack(alignment: .leading, spacing: 4) {
            Text("Delivered by").font(.caption2).foregroundStyle(.secondary)
            DidLabel(did: request.issuer, caption: "your VTA · proof verified")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.approveConsent(pending) }
            } label: {
                Label("Approve", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(role: .destructive) {
                showDenyReasons = true
            } label: {
                Label("Deny", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .disabled(model.busy)
    }

    @ViewBuilder private var queuedPreview: some View {
        let queued = model.pendingConsents.dropFirst()
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Next in queue")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(queued)) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.caption2).foregroundStyle(.tertiary)
                        Text(item.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }
}
