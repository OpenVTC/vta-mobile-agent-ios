import SwiftUI
import VtaMobileAgent

/// The confirmation step between reading a pairing (QR code or Settings) and
/// applying it. Nothing is saved and nothing connects until the operator taps
/// Pair. Presented for `AgentModel.pendingPairing`.
///
/// Shows the identity being trusted — the VTA DID, its verified name and
/// domain — alongside what came with it: the mediator from the VTA's DID
/// document, the push gateway host and the tenant the code states. Replacing
/// a different VTA gets a red banner and device-owner authentication.
struct PairingConfirmSheet: View {
    let review: PairingReview
    @ObservedObject var model: AgentModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if review.replacesDifferentVta, let old = review.replacingVtaDID {
                        replaceBanner(old)
                    }

                    section("VTA") {
                        DidLabel(did: review.vtaDID, caption: "the VTA this phone will approve for")
                        MonoCopyRow(value: review.vtaDID, lineLimit: 4)
                        field("Domain", review.vtaDomain ?? "none (not a did:web or did:webvh)")
                        if review.vtaDID.hasPrefix("did:web:") {
                            warning(
                                "A did:web identity is only as trustworthy as its domain's DNS and TLS.")
                        }
                    }

                    section("Mediator") {
                        DidLabel(did: review.mediatorDID, caption: "from the VTA's DID document")
                    }

                    section("Push gateway") {
                        if let url = review.gatewayURL {
                            field("Host", url.host ?? url.absoluteString)
                            if let gatewayWarning = review.gatewayWarning {
                                warning(
                                    "\(gatewayWarning.localizedDescription) Only continue if you "
                                        + "expect this host to receive this phone's push token.")
                            }
                        } else {
                            Text("None").font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    if let tenant = review.tenant {
                        section("Tenant") {
                            Text(String(tenant.prefix(64)))
                                .font(.footnote)
                                .lineLimit(2)
                            Text("as stated by the pairing code")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Text(
                        "Check these against your operator console before pairing. "
                            + "Once paired, this phone approves requests signed by this VTA."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        Button(role: review.replacesDifferentVta ? .destructive : nil) {
                            Task { await model.confirmPairing(review) }
                        } label: {
                            Label(
                                review.replacesDifferentVta ? "Replace and pair" : "Pair",
                                systemImage: "checkmark.shield.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            model.cancelPairing()
                        } label: {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .disabled(model.busy)
                }
                .padding()
            }
            .navigationTitle(review.replacesDifferentVta ? "Replace VTA?" : "Pair with this VTA?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func replaceBanner(_ old: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Replaces the VTA this phone is paired with", systemImage: "exclamationmark.octagon.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            DidLabel(did: old, caption: "currently paired")
            Text(
                "This phone will stop approving for it. Pending requests are discarded, "
                    + "push wake is turned off, and you'll confirm with your device passcode "
                    + "or biometrics."
            )
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red, lineWidth: 1.5))
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled)
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
