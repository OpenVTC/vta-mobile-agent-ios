import SwiftUI

import VtaMobileAgent

/// Minimal screen that proves the engine is live on-device by rendering its
/// version summary. The real agent UI (login approvals, AAL step-up prompts)
/// grows from here.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
            Text("VTA Mobile Agent")
                .font(.headline)
            Text(VtaMobileAgent.engineSummary())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
