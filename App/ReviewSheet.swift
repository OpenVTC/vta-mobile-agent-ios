import SwiftUI
import VtaMobileAgent

/// The consent gate: shows *what* an incoming step-up authorizes and lets the
/// operator **Approve** (Face ID fires as the enclave key signs) or **Deny** (a
/// holder-signed refusal the VTA audits). Presented whenever
/// `AgentModel.pendingApproval` is set — from the live listener or a push wake.
struct ReviewSheet: View {
    let pending: PendingApproval
    @ObservedObject var model: AgentModel
    /// Total outstanding asks (this one + those queued behind it).
    var remaining: Int = 1

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
                            Task { await model.deny(pending) }
                        } label: {
                            Label("Deny", systemImage: "xmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .disabled(model.busy)
                }
                .padding()
            }
            .navigationTitle("Authorize?")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()  // force an explicit Approve/Deny
        }
    }
}
