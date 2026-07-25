import SwiftUI
import VtaMobileAgent

/// At-a-glance status + the single primary action. When configured the agent
/// runs itself (auto-connect, auto-reconnect, token auto-refresh); this screen
/// just reflects that and offers a one-tap recover if something's off.
struct HomeTab: View {
    @EnvironmentObject private var model: AgentModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.theme) private var theme

    var body: some View {
        ScreenScaffold(title: "VTA Mobile Agent") {
            hero

            if !model.isConfigured {
                Card(tint: .orange) {
                    CardHeader(title: "Let's get set up", systemImage: "wand.and.stars", tint: .orange)
                    Text("Point the agent at your VTA — just its DID, and it fills in the rest. "
                        + "After that it connects automatically every time you open the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                    BrandButton(title: "Set up the agent", systemImage: "arrow.right") {
                        router.tab = Tab.settings
                    }
                    .padding(.top, 6)
                }
            } else if !model.isAuthenticated {
                Card(tint: theme.color(for: model.phase)) {
                    Text(model.phase == .connecting || model.phase == .error
                        ? "Connecting to your VTA — this happens automatically and keeps retrying."
                        : "Tap to bring the agent online. It'll stay connected from now on.")
                        .font(.footnote).foregroundStyle(.secondary)
                    BrandButton(
                        title: model.phase == .error ? "Retry now" : "Connect",
                        systemImage: "bolt.fill",
                        busy: model.connecting
                    ) {
                        Task { await model.connect() }
                    }
                    .padding(.top, 6)
                }
            } else {
                Card(tint: .green) {
                    Label {
                        Text("Running automatically").font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Text(model.listening
                        ? "Connected and listening for approval requests. Step-ups are approved on this device — nothing for you to do."
                        : "Connected. Set a mediator DID in Settings to approve step-ups live.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    // Which VTA this device is actually bound to, named when it
                    // has a name. Worth a line here: everything the agent
                    // approves, it approves for this identity.
                    if !model.vtaDid.trimmed.isEmpty {
                        Divider().padding(.vertical, 2)
                        DidLabel(did: model.vtaDid.trimmed, caption: "your VTA")
                    }
                }
            }

            holderCard
            statusCard
            recentActivity
        }
    }

    // The gradient hero with the big status.
    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(theme.brandGradient)
                .shadow(color: theme.accent.opacity(0.35), radius: 16, y: 8)
            VStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(theme.onBrand)
                Text("VTA Mobile Agent")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(theme.onBrand)
                HStack(spacing: 8) {
                    Image(systemName: model.phase.systemImage)
                    Text(statusHeadline)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.onBrand)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.22)))
                if let sub = statusSubtitle {
                    Text(sub).font(.caption).foregroundStyle(theme.onBrand.opacity(0.9))
                }
            }
            .padding(.vertical, 24)
        }
    }

    private var statusHeadline: String {
        switch model.phase {
        case .notConfigured: return "Not set up yet"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .live: return "Live — approving"
        case .offline: return "Offline"
        case .error: return "Reconnecting…"
        }
    }

    private var statusSubtitle: String? {
        guard model.isAuthenticated else { return nil }
        return model.listening ? "Listening on the mediator" : "Session active"
    }

    private var holderCard: some View {
        Card(tint: theme.accent) {
            CardHeader(title: "This device's identity", systemImage: "key.fill")
            Text("Holder did:key").font(.caption).foregroundStyle(.secondary)
            MonoCopyRow(value: model.holderDid, lineLimit: 2)
            Text("Enroll it in the VTA once:\npnm acl create --did <above> --role admin")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var statusCard: some View {
        Card(tint: .blue) {
            CardHeader(title: "Status", systemImage: "info.circle.fill", tint: .blue)
            Text(model.status).font(.footnote)
            if let step = model.stepUpStatus {
                Divider().padding(.vertical, 4)
                Text(step).font(.footnote)
            }
        }
    }

    @ViewBuilder private var recentActivity: some View {
        if !model.events.isEmpty {
            Card(tint: .purple) {
                HStack {
                    CardHeader(title: "Recent activity", systemImage: "clock.fill", tint: .purple)
                    Spacer()
                    Button("See all") { router.tab = Tab.history }
                        .font(.caption.weight(.semibold))
                }
                ForEach(model.events.prefix(3)) { event in
                    EventRow(event: event).padding(.vertical, 2)
                }
            }
        }
    }
}

extension AppTheme {
    /// Phase tint resolved against this theme — used to color the Home connect card.
    func color(for phase: ConnectionPhase) -> Color { phase.color(self) }
}
