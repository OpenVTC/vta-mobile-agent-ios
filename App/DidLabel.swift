import SwiftUI
import VtaMobileAgent

/// The one way this app puts a DID on screen.
///
/// Renders the DID's agent name over the shortened DID, resolving the name in the
/// background. Every DID-bearing surface uses this rather than interpolating a raw
/// identifier into a `Text`, which is what keeps two properties true everywhere at
/// once:
///
/// - **The DID stays visible.** A name the operator cannot cross-check against an
///   identifier is a name they cannot audit. The name is the prominent line; the
///   shortened DID sits under it, always, and the full DID is one tap away.
/// - **An unverified claim is never shown as fact.** A DID can put anything in its
///   own `alsoKnownAs`, so a claim that failed the engine's round trip renders with
///   an amber warning and a `[unverified]` tag instead of the green seal.
///
/// Nothing blocks on the lookup: the shortened DID paints immediately and the name
/// replaces it if and when it arrives. A name is an enhancement to an approval
/// prompt, never something the prompt waits for.
struct DidLabel: View {
    /// The DID to render. `nil`-safe callers should not render this view at all.
    let did: String
    /// Optional provenance line under the identifier, e.g. "verified by your VTA"
    /// — describes how the *request* was authenticated, which is a different claim
    /// from whether the *name* round-tripped. Both can appear; they answer
    /// different questions.
    var caption: String?
    /// Compact form for dense rows (history): single line, name preferred, no
    /// caption, no icon.
    var compact: Bool = false

    @State private var resolved: DisplayName?

    var body: some View {
        Group {
            if compact {
                Text(primaryText)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(resolved?.isTrusted == false ? .orange : .secondary)
            } else {
                full
            }
        }
        // Re-resolve if the view is reused for a different DID (history rows,
        // a re-pointed VTA) rather than showing the previous DID's name.
        .task(id: did) { resolved = await NameResolver.shared.name(for: did) }
    }

    private var full: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(symbolTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(.caption.weight(resolved == nil ? .regular : .semibold))
                    .foregroundStyle(resolved?.isTrusted == false ? .orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only a second line when the first one is a name — otherwise this
                // would print the same shortened DID twice.
                if resolved != nil {
                    Text(shortenDid(did))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
                if resolved?.isTrusted == false {
                    Text("this DID claims the name but it did not check out")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // The full DID, for an operator who wants to compare it against an ACL
        // entry — the shortened form is for reading, not for auditing.
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The name when we have one, else the shortened DID. Always `rendered`, so an
    /// unverified name cannot reach the screen untagged.
    private var primaryText: String {
        resolved?.rendered ?? shortenDid(did)
    }

    private var symbol: String {
        guard let resolved else { return "number" }
        return resolved.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var symbolTint: Color {
        guard let resolved else { return .secondary }
        return resolved.isTrusted ? .green : .orange
    }

    /// VoiceOver reads the name *and* the DID: the audit property has to survive
    /// into the accessibility tree, not just the pixels.
    private var accessibilityText: String {
        var parts: [String] = []
        if let resolved {
            parts.append(
                resolved.isTrusted
                    ? "Agent name \(resolved.name), verified"
                    : "Unverified claimed name \(resolved.name)")
        }
        parts.append("DID \(did)")
        if let caption { parts.append(caption) }
        return parts.joined(separator: ". ")
    }
}

/// A DID's agent name as a note under an *editable* DID field.
///
/// Settings fields must keep the raw DID — an operator edits and pastes
/// identifiers there, and substituting a name would make the field unusable. So
/// the name annotates the field instead of replacing its contents, and the view
/// collapses to nothing when the DID has no name (which is every DID today).
struct DidNameNote: View {
    let did: String
    @State private var resolved: DisplayName?

    var body: some View {
        Group {
            if let resolved {
                HStack(spacing: 4) {
                    Image(systemName: resolved.isTrusted
                        ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    Text(resolved.rendered)
                }
                .font(.caption2)
                .foregroundStyle(resolved.isTrusted ? Color.green : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: did) {
            let trimmed = did.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip the half-typed DIDs a text field emits on every keystroke.
            guard trimmed.hasPrefix("did:") else {
                resolved = nil
                return
            }
            resolved = await NameResolver.shared.name(for: trimmed)
        }
    }
}
