import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $app.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Token", text: $app.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 6) {
                        Button("Tailscale") { app.serverURL = AppState.defaultServer }
                            .glassButton()
                        Button("Tailnet IP") { app.serverURL = AppState.tailnetIPServer }
                            .glassButton()
                        Button("Home Wi-Fi") { app.serverURL = AppState.lanServer }
                            .glassButton()
                    }
                    .font(.caption)
                } header: {
                    Text("PC")
                } footer: {
                    Text("Tailscale (https, recommended) works anywhere the VPN is on; Tailnet IP and Home Wi-Fi are plain-http fallbacks that LiveContainer may refuse.")
                }

                Section {
                    if app.probes.isEmpty {
                        Text("Tap Test connection to probe every address.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.probes) { probe in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(probe.ok ? Color.green : Color.red)
                                    Text(probe.shortName)
                                        .font(.footnote.weight(.semibold))
                                    Spacer(minLength: 4)
                                    Text(probe.base)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if !probe.ok {
                                    Text(probe.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Connection doctor")
                } footer: {
                    Text("If it still fails, read me this list — it names the exact reason for each address.")
                }

                Section {
                    Button {
                        checking = true
                        Task {
                            await app.refresh()
                            checking = false
                        }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                    Button {
                        Task { await app.runEngine("start") }
                    } label: {
                        Label("Start engine", systemImage: "play.fill")
                    }
                    Button {
                        Task { await app.runEngine("stop") }
                    } label: {
                        Label("Stop engine", systemImage: "stop.fill")
                    }
                    Button {
                        Task { await app.runEngine("free") }
                    } label: {
                        Label("Free VRAM", systemImage: "memorychip")
                    }
                    Button {
                        Task { await app.runEngine("restart") }
                    } label: {
                        Label("Restart engine", systemImage: "arrow.clockwise")
                    }
                    Button("Reload models") {
                        Task { await app.refresh() }
                    }
                } header: {
                    Text("PC engine")
                } footer: {
                    Text(app.engineText)
                }

                Section {
                    Toggle("Save every result to Photos", isOn: $app.autoSave)
                        .font(.footnote)
                    Toggle("Haptics", isOn: $app.hapticsOn)
                        .font(.footnote)
                    if !app.queue.isEmpty {
                        HStack {
                            Label("\(app.queue.count) prompts queued", systemImage: "list.bullet")
                                .font(.footnote)
                            Spacer()
                            Button("Clear") { app.clearQueue() }
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Results")
                } footer: {
                    Text("Queued prompts cook one after another. Photos you save land in your camera roll.")
                }

                Section {
                    LabeledContent("Bridge", value: app.health.map { "comfy-bridge \($0.version ?? "?")" } ?? "comfy-bridge")
                    LabeledContent("Model", value: app.modelDisplayName)
                    LabeledContent("Size", value: "\(app.width) × \(app.height)")
                    LabeledContent("Steps", value: "\(app.steps)")
                    if app.lastSeed != 0 {
                        LabeledContent("Last seed", value: "\(app.lastSeed)")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("The phone only sends the prompt. The PC's ComfyUI does the rendering, so nothing heavy runs on the iPhone.")
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .scrollDismissesKeyboard(.interactively)
            .toolbar { KeyboardDoneToolbar() }
        }
    }
}
