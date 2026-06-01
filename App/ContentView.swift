import SwiftUI
import VtaMobileAgent

/// The agent's authentication demo screen: point it at a VTA, enroll this
/// device's holder `did:key` in the VTA ACL, and authenticate over plain REST
/// (the engine signs the Trust Task documents; the key never leaves the device).
struct ContentView: View {
    @StateObject private var model = AgentModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("This device") {
                    LabeledContent("Engine") { Text(VtaMobileAgent.engineSummary()) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Holder did:key").font(.caption).foregroundStyle(.secondary)
                        Text(model.holderDid)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Enroll it in the VTA:\npnm acl create --did <above> --role admin")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("VTA") {
                    TextField("URL (e.g. http://192.168.1.10:8100)", text: $model.vtaURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("VTA DID (did:key:… / did:web:…)", text: $model.vtaDid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button(action: { Task { await model.authenticate() } }) {
                        HStack {
                            Text("Authenticate")
                            if model.busy {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.busy)

                    if model.isAuthenticated {
                        Button("Who am I?") { Task { await model.whoami() } }
                            .disabled(model.busy)
                    }
                }

                if model.isAuthenticated {
                    Section("AAL2 step-up approver") {
                        Button("Step up this session (demo)") {
                            Task { await model.demoStepUp() }
                        }
                        .disabled(model.busy)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("…or ratify a request relayed from another device:")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $model.pastedApproveRequest)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(height: 90)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            Button("Approve pasted request") {
                                Task { await model.approvePasted() }
                            }
                            .disabled(model.busy)
                        }
                        if let stepUp = model.stepUpStatus {
                            Text(stepUp).font(.footnote)
                        }
                    }
                }

                Section("Status") {
                    Text(model.status).font(.footnote)
                    if let whoami = model.whoamiSummary {
                        Text(whoami)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("VTA Mobile Agent")
        }
        .onAppear { model.start() }
    }
}

#Preview {
    ContentView()
}
