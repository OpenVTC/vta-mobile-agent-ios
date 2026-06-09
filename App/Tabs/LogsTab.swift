import SwiftUI
import UIKit

/// A live view of the engine + app logs (captured from stdout/stderr), for
/// diagnosing on-device network/DIDComm issues without Xcode attached. Copy or
/// clear from the toolbar; the view auto-scrolls to the newest line.
struct LogsTab: View {
    @EnvironmentObject private var model: AgentModel
    @StateObject private var logs = LogStore.shared
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if logs.lines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No logs yet").font(.headline)
                        Text("Engine and app logs stream here once the agent does something.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(logs.lines) { line in
                                    Text(line.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(color(for: line.text))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.id)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: logs.lines.count) { _ in
                            if let last = logs.lines.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            .background(background.ignoresSafeArea())
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    StatusPill(phase: model.phase)
                }
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        UIPasteboard.general.string = logs.joined
                    } label: { Image(systemName: "doc.on.doc") }
                        .disabled(logs.lines.isEmpty)
                    Button(role: .destructive) {
                        logs.clear()
                    } label: { Image(systemName: "trash") }
                        .disabled(logs.lines.isEmpty)
                }
            }
        }
    }

    @ViewBuilder private var background: some View {
        if theme.kind == .neon {
            Color.black
        } else {
            Color(uiColor: .systemBackground)
        }
    }

    /// Tint obvious warn/error lines so problems stand out in the stream.
    private func color(for text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("❌") || lower.contains(" err ") {
            return .red
        }
        if lower.contains("warn") {
            return .orange
        }
        if text.hasPrefix("[agent]") {
            return theme.accent
        }
        return .primary
    }
}
