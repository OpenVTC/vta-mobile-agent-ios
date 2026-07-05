import SwiftUI
import VtaMobileAgent

/// Everything configuration: where the VTA is, appearance (theme), auto-connect,
/// and the device identity. Edits auto-save, so the agent picks them up on the
/// next (automatic) connect.
struct SettingsTab: View {
    @EnvironmentObject private var model: AgentModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @State private var showScanner = false

    var body: some View {
        ScreenScaffold(title: "Settings") {
            vtaCard
            behaviourCard
            appearanceCard
            identityCard
            connectionControls
        }
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
            Text("Or enter the VTA's DID and tap Resolve to fill the URL and mediator.")
                .font(.caption).foregroundStyle(.secondary)

            ThemedField(title: "VTA DID", prompt: "did:webvh:… / did:web:…",
                text: $model.vtaDid, mono: true)
            Button {
                Task { await model.resolveFromDid() }
            } label: {
                Label("Resolve endpoints from DID", systemImage: "arrow.down.circle")
            }
            .font(.subheadline.weight(.semibold))
            .disabled(model.busy)

            ThemedField(title: "VTA URL", prompt: "http://192.168.1.10:8100",
                text: $model.vtaURL, keyboard: .URL, mono: true)
            ThemedField(title: "Mediator DID (optional, for live approvals)",
                prompt: "did:web:… / did:webvh:…", text: $model.mediatorDid, mono: true)
            ThemedField(title: "Push gateway URL (optional)", prompt: "https://gw.example",
                text: $model.gatewayUrl, keyboard: .URL, mono: true)
        }
        .onChange(of: model.vtaDid) { _ in model.saveConfig() }
        .onChange(of: model.vtaURL) { _ in model.saveConfig() }
        .onChange(of: model.mediatorDid) { _ in model.saveConfig() }
        .onChange(of: model.gatewayUrl) { _ in model.saveConfig() }
        .sheet(isPresented: $showScanner) {
            PairingScanner { model.applyPairing($0) }
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
