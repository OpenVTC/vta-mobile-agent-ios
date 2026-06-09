import Combine
import Foundation

/// An in-app log buffer for the **Logs** tab. Captures the process's
/// `stdout`/`stderr` — which is where the Rust engine's `tracing` output and the
/// app's `print`s land — by splicing a pipe onto fds 1 & 2 and **tee-ing** every
/// byte back to the original descriptors, so the Xcode console still works.
///
/// Best-effort and self-contained: if the splice fails the app is unaffected,
/// you just get fewer in-app lines. Capped to the most recent `maxLines`.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    struct Line: Identifiable {
        let id = UUID()
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private let maxLines = 2000
    private var started = false

    /// Saved originals so we can tee back (and avoid double-installing).
    private var savedOut: Int32 = -1
    private var savedErr: Int32 = -1
    private var pending = Data()

    /// Begin capturing. Idempotent; call once from the app on launch.
    func start() {
        guard !started else { return }
        started = true

        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor

        // Keep originals so output is mirrored back to the real console.
        savedOut = dup(STDOUT_FILENO)
        savedErr = dup(STDERR_FILENO)
        // Route stdout + stderr into the pipe.
        dup2(writeFD, STDOUT_FILENO)
        dup2(writeFD, STDERR_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)  // unbuffered so lines appear promptly

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Tee back to the genuine console.
            if let self {
                Task { @MainActor in self.teeBack(data) }
            }
            Task { @MainActor in self?.ingest(data) }
        }
    }

    private func teeBack(_ data: Data) {
        guard savedOut >= 0 else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = write(savedOut, base, raw.count) }
        }
    }

    private func ingest(_ data: Data) {
        pending.append(data)
        // Split into complete lines; keep any trailing partial for next chunk.
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                append(s)
            }
        }
    }

    /// Append an app-originated line directly (used by `AgentModel.log`).
    func append(_ text: String) {
        lines.append(Line(text: text))
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    func clear() { lines.removeAll() }

    var joined: String { lines.map(\.text).joined(separator: "\n") }
}
