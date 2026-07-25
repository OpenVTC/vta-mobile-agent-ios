import SwiftUI
import VtaMobileAgent

/// The consent gate: shows *what* an incoming step-up authorizes (and *who* is
/// asking) and lets the operator **Approve** (Face ID fires as the enclave key
/// signs) or **Deny with a reason** (a holder-signed refusal the VTA audits).
/// Presented for the front of `AgentModel.pendingApprovals`.
struct ReviewSheet: View {
    let pending: PendingApproval
    @ObservedObject var model: AgentModel
    /// Total outstanding asks (this one + those queued behind it).
    var remaining: Int = 1

    @State private var showDenyReasons = false

    /// Preset decline reasons (the operator can decline fast; the reason is
    /// carried in the signed refusal for the audit trail).
    private let denyReasons = [
        "Not something I authorized",
        "Wrong amount or scope",
        "Not right now",
        "Looks suspicious",
    ]

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

                    if let context = pending.context {
                        AuthorizationCard(context: context)
                    } else {
                        Text(pending.review.reason)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let rp = pending.review.relyingParty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Requested by").font(.caption2).foregroundStyle(.secondary)
                            // The name, if this DID has one that checks out, over
                            // the DID itself — the operator has to be able to
                            // audit one against the other before approving.
                            DidLabel(did: rp, caption: "verified by your VTA")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(
                        "Only you can authorize this. Approve signs with your device key; "
                            + "Deny sends a signed refusal."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        Button {
                            Task { await model.approve(pending) }
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

                    queuedPreview
                }
                .padding()
            }
            .navigationTitle("Authorize?")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()  // force an explicit Approve/Deny
            .confirmationDialog(
                "Decline this request?", isPresented: $showDenyReasons, titleVisibility: .visible
            ) {
                ForEach(denyReasons, id: \.self) { reason in
                    Button(reason, role: .destructive) {
                        Task { await model.deny(pending, reason: reason) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// A read-only peek at what's queued behind the current ask.
    @ViewBuilder private var queuedPreview: some View {
        let queued = model.pendingApprovals.dropFirst()
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Next in queue")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(queued)) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.caption2).foregroundStyle(.tertiary)
                        Text(item.summary).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }
}
