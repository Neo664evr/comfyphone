import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CreateDestinationView: View {
    @AppStorage("generationDestination") private var destination = "iphone"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Generation runs", selection: $destination) {
                Text("On iPhone").tag("iphone")
                Text("PC").tag("pc")
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
            if destination == "iphone" { OnDeviceCreateView() }
            else { CreateView() }
        }
    }
}

struct OnDeviceCreateView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var engine = OnDeviceDiffusion.shared
    @State private var prompt = ""
    @State private var side = 512
    @State private var seed = ""
    @State private var cpuOnly = false
    @State private var importRole: ImageComponent = .denoiser
    @State private var importing = false
    @State private var sharedURL: URL?
    @State private var showingShare = false
    @State private var showingLibrary = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("ON IPHONE · QWEN IMAGE 2.1 TURBO", systemImage: "iphone").font(.caption.weight(.bold))
                        Text("Your image.\nNo PC required.").font(.largeTitle.bold())
                        Text("Native diffusion runs locally after you import all three components. No weights are bundled. Keep ComfyPhone in the foreground; start at 512 × 512.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Device memory fit and speed are not guaranteed. iOS may terminate an app that exceeds its memory allowance; the native engine uses disk-offloaded weights, segmented execution and tiled VAE decoding.")
                            .font(.caption).foregroundStyle(.orange)
                    }.padding(16).glassCard()

                    ForEach(ImageComponent.allCases) { role in componentCard(role) }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Image runtime").font(.headline)
                            Spacer()
                            Text(engine.loaded ? "Loaded" : "Unloaded").font(.caption).foregroundStyle(engine.loaded ? .green : .secondary)
                        }
                        Text("Current app memory available: \(ByteCountFormatter.string(fromByteCount: Int64(engine.availableMemory), countStyle: .memory))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Toggle("CPU compatibility mode (very slow)", isOn: $cpuOnly).font(.caption)
                            .disabled(engine.busy || engine.loaded)
                        HStack {
                            Button("Load image components") { focused = false; Task { await engine.load(cpuOnly: cpuOnly) } }
                                .buttonStyle(.borderedProminent).disabled(engine.busy || !engine.allComponentsSelected || engine.loaded)
                            Button("Unload") { Task { await engine.unload() } }
                                .buttonStyle(.bordered).disabled(engine.busy || !engine.loaded)
                        }
                        Text("Loading unloads chat/vision first to avoid competing for RAM. Files are copied into ImageModels and validated before the native loader receives them.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(16).glassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Prompt").font(.headline)
                        TextEditor(text: $prompt).frame(minHeight: 120).focused($focused).scrollContentBackground(.hidden)
                            .padding(8).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                            .disabled(engine.busy)
                        Picker("Output size", selection: $side) {
                            Text("512 × 512 · first run").tag(512)
                            Text("768 × 768 · more memory").tag(768)
                        }.disabled(engine.busy)
                        TextField("Seed (blank = random)", text: $seed).keyboardType(.numbersAndPunctuation).disabled(engine.busy)
                        Text("Euler · 8 Turbo steps · CFG 1 · model-card custom sigmas · shift 1 · batch 1. Text-to-image only; photo editing remains on PC.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            focused = false
                            if engine.busy { engine.cancel() }
                            else {
                                guard seed.isEmpty || Int64(seed) != nil else { return }
                                let actualSeed = Int64(seed) ?? Int64.random(in: 0...Int64.max)
                                seed = String(actualSeed)
                                Task { await engine.generate(prompt: prompt, side: side, seed: actualSeed) }
                            }
                        } label: {
                            Label(engine.busy ? (engine.cancelling ? "Stopping safely…" : "Cancel operation") : "Generate on iPhone",
                                  systemImage: engine.busy ? "stop.fill" : "sparkles")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.borderedProminent)
                            .disabled(engine.cancelling || (!engine.busy && (!engine.loaded || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!seed.isEmpty && Int64(seed) == nil))))
                        if !seed.isEmpty && Int64(seed) == nil { Text("Seed must be a signed 64-bit integer.").font(.caption).foregroundStyle(.orange) }
                    }.padding(16).glassCard()

                    VStack(alignment: .leading, spacing: 8) {
                        if engine.busy {
                            Text(engine.operation).font(.subheadline.bold())
                            ProgressView(value: engine.progress)
                            Text("\(Int(engine.progress * 100))%").font(.caption.monospacedDigit())
                        }
                        Text(engine.status).font(.footnote).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(16).glassCard()

                    if let latest = engine.images.first, let image = UIImage(contentsOfFile: latest.path) {
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                        Button { sharedURL = latest; showingShare = true } label: { Label("Share / save PNG", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button { showingLibrary = true } label: { Label("On-iPhone PNG library", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.bordered)
                    Text("Results and prompt/seed metadata are saved in Files → ComfyPhone → GeneratedImages. The PC Gallery tab is separate.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }
            .navigationTitle("Create · On iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .background(AppBackground())
            .scrollDismissesKeyboard(.interactively)
            .toolbar { KeyboardDoneToolbar() }
            .onAppear { prompt = app.prompt; engine.refreshImages(); engine.refreshMemory() }
            .onChange(of: prompt) { _, value in if app.prompt != value { app.prompt = value } }
            .onChange(of: app.prompt) { _, value in if prompt != value { prompt = value } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { Task { await engine.importFile(url, role: importRole) } }
            }
            .sheet(isPresented: $showingShare) { if let sharedURL { ShareSheet(items: [sharedURL]) } }
            .sheet(isPresented: $showingLibrary) {
                NavigationStack {
                    List(engine.images, id: \.path) { url in
                        VStack(alignment: .leading, spacing: 8) {
                            if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit() }
                            Text(url.lastPathComponent).font(.caption2).lineLimit(1)
                            ShareLink(item: url) { Label("Share PNG", systemImage: "square.and.arrow.up") }
                        }
                    }.navigationTitle("On-iPhone results")
                        .toolbar { Button("Done") { showingLibrary = false } }
                }
            }
        }
    }

    private func componentCard(_ role: ImageComponent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role.title).font(.headline)
            Text(role.explanation).font(.caption).foregroundStyle(.secondary)
            if let file = engine.files[role] {
                Label(file.originalName, systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)) · SHA-256 validated")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { Text("Not selected").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(engine.files[role] == nil ? "Choose from Files" : "Replace from Files") { importRole = role; importing = true }
                    .buttonStyle(.bordered).disabled(engine.busy)
                if engine.files[role] != nil {
                    Button("Remove", role: .destructive) { Task { await engine.remove(role) } }.disabled(engine.busy)
                }
            }
        }.padding(16).glassCard()
    }
}
