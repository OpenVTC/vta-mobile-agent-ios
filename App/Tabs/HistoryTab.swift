import SwiftUI

/// A chronological record of what the agent has done — authentications,
/// approvals (live / pasted / push), and errors — so a step-up that happened
/// while you weren't looking is auditable after the fact.
struct HistoryTab: View {
    @EnvironmentObject private var model: AgentModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScreenScaffold(title: "History") {
            if model.events.isEmpty {
                Card(tint: .gray) {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("No activity yet")
                            .font(.headline)
                        Text("Authentications, approvals, and push wakes will show up here as they happen.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else {
                Card {
                    ForEach(Array(model.events.enumerated()), id: \.element.id) { index, event in
                        EventRow(event: event, showTime: true)
                            .padding(.vertical, 6)
                        if index < model.events.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

/// A single activity entry, color-coded by kind.
struct EventRow: View {
    let event: AgentEvent
    var showTime: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.subheadline.weight(.medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if showTime {
                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch event.kind {
        case .approval: return "checkmark.seal.fill"
        case .auth: return "person.badge.shield.checkmark.fill"
        case .push: return "bell.badge.fill"
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .approval: return .green
        case .auth: return .blue
        case .push: return .orange
        case .info: return .gray
        case .error: return .red
        }
    }
}
