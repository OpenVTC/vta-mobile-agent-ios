import SwiftUI
import VtaMobileAgent

/// Renders an ``AuthorizationContext`` — the card the operator reviews before
/// ratifying a step-up. Shows *what* is being authorized (the agent's ask, the
/// scope, the cost) so consent is meaningful, not a blind "approve".
struct AuthorizationCard: View {
    let context: AuthorizationContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RiskBadge(risk: context.risk)
                Text(context.action.kindLabel.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(context.summary)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = context.detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            actionRows

            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(context.domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tenant = context.tenant {
                    Text("· \(tenant)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(context.risk.tint.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder private var actionRows: some View {
        switch context.action {
        case let .share(from, to, fields, capabilities, purpose, ttlSeconds):
            Row("From", from)
            Row("To", to)
            if !fields.isEmpty { Row("Fields", fields.joined(separator: ", ")) }
            if !capabilities.isEmpty { Row("Capabilities", capabilities.joined(separator: ", ")) }
            if !purpose.isEmpty { Row("Purpose", purpose) }
            Row("Valid for", Self.durationLabel(ttlSeconds))
        case let .spend(amountUsd, budgetRemainingUsd, provider, model):
            Row("Amount", String(format: "$%.2f", amountUsd))
            Row("Budget left", String(format: "$%.2f", budgetRemainingUsd))
            Row("Model", "\(provider) · \(model)")
        case let .tool(tool, argumentsSummary, target):
            Row("Tool", tool)
            if !argumentsSummary.isEmpty { Row("Arguments", argumentsSummary) }
            if let target { Row("Target", target) }
        case let .lifecycle(operation, targetDomain):
            Row("Operation", operation)
            Row("Domain", targetDomain)
        case let .custom(schema):
            Row("Schema", schema)
        case .unknown(let kind):
            Row("Kind", kind)
        }
    }

    private static func durationLabel(_ seconds: UInt64) -> String {
        if seconds == 0 { return "—" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) h" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}

/// A label/value row.
private struct Row: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RiskBadge: View {
    let risk: AuthorizationContext.Risk
    var body: some View {
        Text(risk.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(risk.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(risk.tint)
    }
}

extension AuthorizationContext.Risk {
    /// Presentation tint by scrutiny level.
    var tint: Color {
        switch self {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}
