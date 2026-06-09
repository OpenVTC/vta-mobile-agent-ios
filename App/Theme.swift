import SwiftUI
import UIKit

// MARK: - Theme model

/// A selectable visual theme. The app ships several and the user picks one in
/// Settings; the choice is persisted and applied app-wide via the environment.
struct AppTheme: Identifiable {
    enum Kind { case vibrant, neon, pastel, minimal }

    let id: String
    let name: String
    let blurb: String
    /// SF Symbol shown next to the theme in the picker.
    let symbol: String
    let kind: Kind
    /// Brand gradient stops (hero header, primary buttons).
    let brandColors: [Color]
    /// Primary accent (global tint).
    let accent: Color

    /// Neon is a dark-canvas theme; the others follow the system appearance.
    var preferredColorScheme: ColorScheme? { kind == .neon ? .dark : nil }

    var brandGradient: LinearGradient {
        LinearGradient(colors: brandColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Readable text/iconography laid over the brand gradient.
    var onBrand: Color { .white }

    /// Card fill, tinted toward an accent so each section reads distinctly.
    func cardFill(_ tint: Color) -> Color {
        switch kind {
        case .vibrant: return tint.opacity(0.10)
        case .pastel: return tint.opacity(0.16)
        case .neon: return Color.white.opacity(0.05)
        case .minimal: return Color(uiColor: .secondarySystemBackground)
        }
    }

    func cardStroke(_ tint: Color) -> Color {
        switch kind {
        case .vibrant: return tint.opacity(0.28)
        case .pastel: return tint.opacity(0.35)
        case .neon: return tint.opacity(0.55)
        case .minimal: return Color(uiColor: .separator)
        }
    }

    var cardStrokeWidth: CGFloat { kind == .neon ? 1.5 : 1 }

    // The shipped set.
    static let vibrant = AppTheme(
        id: "vibrant", name: "Vibrant", blurb: "Indigo → purple → pink gradient",
        symbol: "sparkles", kind: .vibrant,
        brandColors: [.indigo, .purple, .pink], accent: .purple)

    static let neon = AppTheme(
        id: "neon", name: "Neon", blurb: "Dark canvas, glowing accents",
        symbol: "bolt.fill", kind: .neon,
        brandColors: [Color(red: 0, green: 0.9, blue: 1), Color(red: 0.5, green: 0.2, blue: 1),
            Color(red: 1, green: 0.2, blue: 0.7)],
        accent: Color(red: 0, green: 0.85, blue: 1))

    static let pastel = AppTheme(
        id: "pastel", name: "Pastel", blurb: "Soft, friendly, calm",
        symbol: "leaf.fill", kind: .pastel,
        brandColors: [.mint, .teal, .cyan], accent: .teal)

    static let minimal = AppTheme(
        id: "minimal", name: "Minimal", blurb: "Quiet, system-native",
        symbol: "circle.lefthalf.filled", kind: .minimal,
        brandColors: [.gray, Color(uiColor: .systemGray2)], accent: .blue)

    static let all: [AppTheme] = [.vibrant, .neon, .pastel, .minimal]
    static func byId(_ id: String) -> AppTheme { all.first { $0.id == id } ?? .vibrant }
}

// MARK: - Theme manager + environment

/// Holds the selected theme, persisted in `UserDefaults`. A `@StateObject` at the
/// root republishes on change so the whole UI restyles live.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private let key = "pnm.themeId"

    @Published var selectedId: String {
        didSet { UserDefaults.standard.set(selectedId, forKey: key) }
    }

    var theme: AppTheme { AppTheme.byId(selectedId) }

    init() {
        selectedId = UserDefaults.standard.string(forKey: key) ?? AppTheme.vibrant.id
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.vibrant
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Connection phase (status pill)

/// A glanceable connection/auth state, derived in `AgentModel`. Drives the
/// always-visible status pill and the Home hero.
enum ConnectionPhase {
    case notConfigured, connecting, connected, live, offline, error

    var label: String {
        switch self {
        case .notConfigured: return "Set up"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .live: return "Live"
        case .offline: return "Offline"
        case .error: return "Reconnecting…"
        }
    }

    var systemImage: String {
        switch self {
        case .notConfigured: return "gearshape"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.shield.fill"
        case .live: return "dot.radiowaves.left.and.right"
        case .offline: return "moon.zzz.fill"
        case .error: return "arrow.clockwise"
        }
    }

    func color(_ theme: AppTheme) -> Color {
        switch self {
        case .notConfigured: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .live: return theme.accent
        case .offline: return .gray
        case .error: return .orange
        }
    }

    var isBusy: Bool { self == .connecting || self == .error }
}

// MARK: - Reusable components

/// A rounded, theme-tinted content card.
struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var tint: Color?
    @ViewBuilder var content: () -> Content

    init(tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.tint = tint
        self.content = content
    }

    var body: some View {
        let t = tint ?? theme.accent
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.cardFill(t))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(theme.cardStroke(t), lineWidth: theme.cardStrokeWidth)
            )
    }
}

/// A small label + icon header used inside cards.
struct CardHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    var tint: Color? = nil

    var body: some View {
        Label {
            Text(title).font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint ?? theme.accent)
        }
        .padding(.bottom, 2)
    }
}

/// The always-visible connection status pill (nav-bar trailing on every tab).
struct StatusPill: View {
    @Environment(\.theme) private var theme
    let phase: ConnectionPhase

    @State private var pulse = false

    var body: some View {
        let color = phase.color(theme)
        HStack(spacing: 6) {
            ZStack {
                if phase == .live {
                    Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14)
                        .scaleEffect(pulse ? 1.6 : 0.8)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                }
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(phase.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
        .onAppear { if phase == .live { pulse = true } }
        .onChange(of: phase) { newValue in pulse = (newValue == .live) }
    }
}

/// A primary brand-gradient button used for the main action on a screen.
struct BrandButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(theme.onBrand)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(theme.onBrand)
            .background(theme.brandGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: theme.accent.opacity(0.4), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

/// A monospaced, selectable value with a copy button — for DIDs / tokens.
struct MonoCopyRow: View {
    let value: String
    var lineLimit: Int = 2

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = value
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

extension String {
    /// Whitespace/newline-trimmed copy — used pervasively for config fields.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Navigation

/// Lets any tab switch tabs (e.g. Home's "Set up" → Settings).
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: Int = Tab.home
}

enum Tab {
    static let home = 0
    static let test = 1
    static let history = 2
    static let logs = 3
    static let settings = 4
}

// MARK: - Screen scaffold + fields

/// Shared per-tab chrome: a scrolling, theme-backed surface with the navigation
/// title, the always-visible connection pill, interactive keyboard dismissal,
/// and a keyboard Done bar.
struct ScreenScaffold<Content: View>: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var model: AgentModel
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) { content() }
                    .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    StatusPill(phase: model.phase)
                }
            }
            .keyboardDoneToolbar()
        }
    }

    @ViewBuilder private var background: some View {
        if theme.kind == .neon {
            LinearGradient(
                colors: [.black, Color(red: 0.04, green: 0.03, blue: 0.10)],
                startPoint: .top, endPoint: .bottom)
        } else {
            Color(uiColor: .systemGroupedBackground)
        }
    }
}

/// A labelled, themed text field for config screens.
struct ThemedField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var mono: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .font(mono ? .system(.footnote, design: .monospaced) : .body)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(uiColor: .tertiarySystemBackground)))
        }
    }
}

// MARK: - Keyboard

/// Dismiss the keyboard from anywhere (used by tap-to-dismiss + the Done bar).
func hideKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// Adds a keyboard "Done" toolbar so a focused field can always be dismissed.
    func keyboardDoneToolbar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
        }
    }
}
