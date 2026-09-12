import SwiftUI
import VtaMobileAgent

/// Everything configuration: where the VTA is, appearance (theme), auto-connect,
/// and the device identity. Connection fields are drafts until Save, which
/// sends them through the same review and confirmation as a scanned pairing
/// code.
struct SettingsTab: View {
    @EnvironmentObject private var model: AgentModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @State private var showScanner = false
    /// A code read by the scanner, staged only once the scanner sheet has fully
    /// dismissed so the confirmation sheet can present.
    @State private var scannedPairing: PairingPayload?
    @State private var draftVtaDid = ""
    @State private var draftGatewayUrl = ""
    @State private var draftsLoaded = false

    var body: some View {
        ScreenScaffold(title: "Settings") {
            vtaCard
            behaviourCard
            appearanceCard
            identityCard
            connectionControls
        }
        .onAppear {
            guard !draftsLoaded else { return }
            draftsLoaded = true
            resetDrafts()
        }
        // The saved configuration only changes through a confirmed pairing or
        // the launch-time load; refresh the drafts when it does.
        .onChange(of: savedConfiguration) { _ in resetDrafts() }
        .sheet(item: $model.pendingPairing) { review in
            PairingConfirmSheet(review: review, model: model)
        }
    }

    private var savedConfiguration: String { "\(model.vtaDid)\n\(model.gatewayUrl)" }

    private var hasDraftChanges: Bool {
        draftVtaDid.trimmed != model.vtaDid.trimmed
            || draftGatewayUrl.trimmed != model.gatewayUrl.trimmed
    }

    /// No point staging an empty DID or a gateway URL that breaks a hard rule.
    private var canSave: Bool {
        guard !draftVtaDid.trimmed.isEmpty, !model.busy else { return false }
        guard !draftGatewayUrl.trimmed.isEmpty else { return true }
        if case .failure = GatewayURLPolicy.validateStructure(draftGatewayUrl) { return false }
        return true
    }

    private func resetDrafts() {
        draftVtaDid = model.vtaDid
        draftGatewayUrl = model.gatewayUrl
    }

    private func saveDrafts() {
        let gateway = draftGatewayUrl.trimmed
        let payload = PairingPayload(
            vtaDID: draftVtaDid.trimmed, gatewayURL: gateway.isEmpty ? nil : gateway)
        Task { await model.stagePairing(payload) }
    }

    private func stageScannedPairing() {
        guard let payload = scannedPairing else { return }
        scannedPairing = nil
        Task { await model.stagePairing(payload) }
    }

    private var vtaCard: some View {
        Card(tint: .blue) {
            CardHeader(title: "Your VTA", systemImage: "server.rack", tint: .blue)

            // Fast path: pair in one scan from the operator's console/CLI.
            Button {
                showScanner = true
            } label: {
                Label("Pair with a QR code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.busy)
            Text("Or enter the VTA's DID and tap Save. Either way you review the VTA, "
                + "its mediator and push gateway before anything changes.")
                .font(.caption).foregroundStyle(.secondary)

            ThemedField(title: "VTA DID", prompt: "did:webvh:… / did:web:…",
                text: $draftVtaDid, mono: true)
            DidNameNote(did: draftVtaDid)

            VStack(alignment: .leading, spacing: 6) {
                Text("Mediator DID (read from the VTA's DID document)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.mediatorDid.trimmed.isEmpty {
                    Text("Filled in when you pair.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    DidLabel(did: model.mediatorDid.trimmed)
                }
            }

            ThemedField(title: "Push gateway URL (optional)", prompt: "https://gw.example",
                text: $draftGatewayUrl, keyboard: .URL, mono: true)
            GatewayURLNote(raw: draftGatewayUrl, vtaDid: draftVtaDid)

            if let error = model.pairingError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(action: saveDrafts) {
                    HStack(spacing: 6) {
                        if model.busy { ProgressView() }
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                if hasDraftChanges {
                    Button("Discard changes", action: resetDrafts)
                        .font(.subheadline)
                }
            }
        }
        .sheet(isPresented: $showScanner, onDismiss: stageScannedPairing) {
            PairingScanner { scannedPairing = $0 }
        }
    }

    private var behaviourCard: some View {
        Card(tint: .green) {
            CardHeader(title: "Behaviour", systemImage: "wand.and.rays", tint: .green)
            Toggle(isOn: $model.autoConnectEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-connect & stay online").font(.subheadline)
                    Text("Connect on launch and recover automatically if the connection drops.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.green)
            .onChange(of: model.autoConnectEnabled) { on in
                if on { model.autoConnectIfConfigured() }
            }
            Toggle(isOn: $model.useTsp) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Receive over TSP").font(.subheadline)
                    Text("Use TSP instead of DIDComm for the mediator inbox. One transport at a time — takes effect immediately.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.green)
            .onChange(of: model.useTsp) { _ in
                Task { await model.restartListeningIfActive() }
            }
            Toggle(isOn: $model.autoApproveSignIns) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-approve sign-ins").font(.subheadline)
                    Text("Approve plain sign-in requests from your VTA without asking, only while "
                        + "the app is open. Requests with details, and anything that arrives in "
                        + "the background, always ask.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.green)
        }
    }

    private var appearanceCard: some View {
        Card(tint: theme.accent) {
            CardHeader(title: "Appearance", systemImage: "paintpalette.fill")
            Text("Pick a theme — it applies instantly.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AppTheme.all) { option in
                        ThemeSwatch(option: option, selected: themeManager.selectedId == option.id)
                            .onTapGesture {
                                withAnimation(.easeInOut) { themeManager.selectedId = option.id }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            Text(theme.blurb).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var identityCard: some View {
        Card(tint: .indigo) {
            CardHeader(title: "Device identity", systemImage: "key.fill", tint: .indigo)
            Text("Holder did:key").font(.caption).foregroundStyle(.secondary)
            MonoCopyRow(value: model.holderDid, lineLimit: 3)
            Text("Enroll once: pnm acl create --did <above> --role admin")
                .font(.caption2).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Engine: \(VtaMobileAgent.engineSummary())")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var connectionControls: some View {
        if model.isAuthenticated {
            Button(role: .destructive) {
                Task { await model.disconnect() }
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        } else if model.isConfigured {
            BrandButton(title: model.phase == .error ? "Retry connection" : "Connect now",
                systemImage: "bolt.fill", busy: model.connecting) {
                Task { await model.connect() }
            }
        }
    }
}

/// Live feedback under the push-gateway field: why the URL will be refused, or
/// a warning when its host is outside the VTA's own domain.
struct GatewayURLNote: View {
    let raw: String
    let vtaDid: String

    var body: some View {
        if let problem {
            Label(
                problem.localizedDescription,
                systemImage: problem.isWarning
                    ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"
            )
            .font(.caption2)
            .foregroundStyle(problem.isWarning ? Color.orange : Color.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var problem: GatewayURLError? {
        guard !raw.trimmed.isEmpty else { return nil }
        if case .failure(let error) = GatewayURLPolicy.validate(raw, vtaDID: vtaDid.trimmed) {
            return error
        }
        return nil
    }
}

/// A tappable theme preview (brand gradient + symbol + name).
struct ThemeSwatch: View {
    let option: AppTheme
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(option.brandGradient)
                    .frame(width: 68, height: 50)
                Image(systemName: option.symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.primary : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, option.accent)
                        .padding(4)
                }
            }
            Text(option.name)
                .font(.caption2.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
        }
    }
}
