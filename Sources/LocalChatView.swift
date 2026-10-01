import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant, system }
    let id = UUID()
    var role: Role
    var text: String
    var images: [UIImage] = []

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Local models + chat, all on the phone. No PC involved.
struct LocalChatView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var ai = LocalAI.shared

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var attachments: [UIImage] = []
    @State private var importingModel = false
    @State private var showAllFiles = false
    private let modelType = UTType(importedAs: "com.neo664evr.gguf-model", conformingTo: .data)
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingModels = true
    @State private var showingSettings = false
    @AppStorage("localSystem") private var systemPrompt =
        "You are a helpful assistant that also rewrites image-generation prompts. Be short and concrete."
    @FocusState private var chatFocused: Bool

    private let quickAsks = ["Improve my prompt", "Describe this image", "Give me 5 ideas",
                             "Make it darker and moodier"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modelCard
                    settingsCard
                    chatArea
                }
                .padding(16)
            }
            .navigationTitle("Local")
            .background(AppBackground())
            .scrollDismissesKeyboard(.interactively)
            .toolbar { KeyboardDoneToolbar() }
            .fileImporter(isPresented: $importingModel,
                          allowedContentTypes: showAllFiles ? [.data] : [modelType],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await ai.importModels(from: urls) }
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            attachments.append(image.downscaled(maxSide: 1024))
                        }
                    }
                    pickerItems = []
                    Haptics.tap()
                }
            }
            .task { ai.refreshModels() }
        }
    }

    // MARK: models

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ai.loaded != nil ? Color.green : (ai.isSelected ? Color.orange : Color.red))
                    .frame(width: 9, height: 9)
                Text(ai.status)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    showingModels.toggle()
                    Haptics.tap()
                } label: {
                    Image(systemName: showingModels ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .squishy(0.85)
            }

            if showingModels {
                HStack(spacing: 8) {
                    Button {
                        importingModel = true
                    } label: {
                        Label("Find model in Files", systemImage: "magnifyingglass")
                            .font(.caption.weight(.semibold))
                    }
                    .glassButton()
                    .squishy()
                    if ai.loaded == nil {
                        Button {
                            Task { await ai.load() }
                        } label: {
                            Label("Load", systemImage: "bolt.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .glassButton()
                        .squishy()
                        .disabled(!ai.isSelected)
                    } else {
                        Button {
                            ai.unload()
                            Haptics.tap()
                        } label: {
                            Label("Unload", systemImage: "eject")
                                .font(.caption.weight(.semibold))
                        }
                        .glassButton()
                        .squishy()
                    }
                    Spacer(minLength: 0)
                }

                if let importing = ai.importing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Copying \(importing)…").font(.caption2).foregroundStyle(.secondary)
                        ProgressView(value: ai.importProgress)
                            .tint(Color.accentColor)
                            .animation(.snappy, value: ai.importProgress)
                    }
                }

                if ai.models.isEmpty {
                    Text("Tap **Find model in Files**, use the search bar in the Files sheet (search \".gguf\"), pick your model — plus its mmproj file if it's a vision model. Multi-select works, and it can reach On My iPhone, iCloud Drive or Downloads.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ai.models) { item in
                        modelRow(item)
                    }
                }

                Toggle("Show every file type in Files", isOn: $showAllFiles)
                    .font(.caption2)
            }
        }
        .padding(12)
        .glassCard()
        .popIn()
    }

    @ViewBuilder
    private func modelRow(_ item: LocalModelFile) -> some View {
        let isSelected = item.isProjector ? ai.projector == item.name : ai.selected == item.name
        HStack(spacing: 8) {
            Button {
                if item.isProjector {
                    ai.selectProjector(isSelected ? nil : item.name)
                } else {
                    ai.select(isSelected ? nil : item.name)
                }
                Haptics.select()
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .squishy(0.85)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text("\(item.sizeText)\(item.isProjector ? " · vision projector" : "")\(ai.loaded == item.name ? " · loaded" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                ai.delete(item)
                Haptics.tap()
            } label: {
                Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
            }
            .squishy(0.85)
        }
    }

    // MARK: settings

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Engine settings", systemImage: "slider.horizontal.3")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 4)
                if ai.settingsDirty {
                    Button {
                        Task { await ai.reload() }
                        Haptics.success()
                    } label: {
                        Label("Apply", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                    }
                    .glassButton()
                    .squishy()
                }
                Button {
                    withAnimation(.snappy) { showingSettings.toggle() }
                    Haptics.tap()
                } label: {
                    Image(systemName: showingSettings ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .squishy(0.85)
            }

            if ai.settingsDirty {
                Text(ai.loaded == nil ? "These apply when you load a model."
                                      : "Changed — tap Apply to rebuild the context.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if showingSettings {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LocalSettings.presets, id: \.0) { name, preset in
                            Button {
                                withAnimation(.snappy) { ai.settings = preset }
                                Haptics.select()
                            } label: {
                                Text(name).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                            }
                            .glassChip(selected: ai.settings == preset, corner: 12)
                            .squishy()
                        }
                    }
                }

                countRow("Context", value: $ai.settings.contextSize, range: 512...8192, step: 512,
                         note: "bigger = more chat memory, more RAM")
                countRow("Batch", value: $ai.settings.batchSize, range: 64...2048, step: 64,
                         note: "prompt chunks fed to the GPU")
                countRow("Physical batch", value: $ai.settings.physicalBatch, range: 32...1024, step: 32)
                countRow("CPU threads", value: $ai.settings.threads,
                         range: 1...(ProcessInfo.processInfo.processorCount + 2), step: 1,
                         note: "this phone has \(ProcessInfo.processInfo.processorCount)")
                countRow("Layers on GPU", value: $ai.settings.gpuLayers, range: 0...199, step: 1,
                         note: "0 = CPU only, 99+ = whole model")
                countRow("Image tokens", value: $ai.settings.imageMaxTokens, range: 64...1024, step: 64,
                         note: "detail kept from each photo")
                countRow("Max reply", value: $ai.settings.maxTokens, range: 50...2000, step: 50)

                floatRow("Temperature", value: $ai.settings.temperature, range: 0...1.5)
                floatRow("Top P", value: $ai.settings.topP, range: 0.1...1)
                floatRow("Repeat penalty", value: $ai.settings.repeatPenalty, range: 1...1.5)

                HStack(spacing: 8) {
                    Text("Top K").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ai.settings.topK)").font(.caption.monospacedDigit())
                    Stepper("", value: $ai.settings.topK, in: 1...200, step: 1)
                        .labelsHidden()
                }

                HStack(spacing: 8) {
                    Text("Flash attention").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $ai.settings.flash) {
                        ForEach(FlashMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                HStack(spacing: 8) {
                    Text("KV cache").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $ai.settings.kvCache) {
                        ForEach(KVMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Memory-map the model file", isOn: $ai.settings.mmap)
                        .font(.caption)
                    Toggle("Offload KQV to GPU", isOn: $ai.settings.offloadKQV)
                        .font(.caption)
                    Toggle("Use the vision projector (images)", isOn: $ai.settings.vision)
                        .font(.caption)
                }

                Text("Every value goes straight into llama.cpp — these are the same knobs PocketPal exposes, and they take effect on the next Load/Apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .glassCard()
    }

    private func countRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                          step: Int, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(value.wrappedValue)").font(.caption.monospacedDigit())
                Stepper("", value: value, in: range, step: step).labelsHidden()
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func floatRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: chat

    private var chatArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        Text("Ask the on-device model for prompt help, or attach a photo and ask what you're looking at. Everything here runs on the phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                    if ai.working {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(ai.streamingText.isEmpty ? "Thinking…" : "Writing…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, image in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 62, height: 62)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Button {
                                    attachments.remove(at: index)
                                    Haptics.tap()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .squishy(0.85)
                                .padding(2)
                            }
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickAsks, id: \.self) { ask in
                        Button {
                            input = ask
                            Haptics.tap()
                        } label: {
                            Text(ask)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 11).padding(.vertical, 7)
                        }
                        .glassChip(selected: false, corner: 12)
                        .squishy()
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItems, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.badge.plus").font(.footnote.weight(.semibold))
                }
                .squishy()
                Button {
                    if let reference = app.referenceImage {
                        attachments.append(reference.downscaled(maxSide: 1024))
                        Haptics.tap()
                    } else {
                        app.toast = "No reference photo attached on the Create tab."
                    }
                } label: {
                    Image(systemName: "photo.on.rectangle").font(.footnote.weight(.semibold))
                }
                .squishy()
                TextField("Ask the local model…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($chatFocused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .glassCard(corner: 14)
                Button {
                    if ai.working { ai.stop() } else { send() }
                } label: {
                    Image(systemName: ai.working ? "stop.fill" : "arrow.up")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(ai.working ? Color.red.opacity(0.85) : Color.accentColor, in: Circle())
                }
                .squishy(0.9)
            }

            HStack(spacing: 8) {
                Button {
                    messages.removeAll()
                    Haptics.tap()
                } label: {
                    Label("Clear chat", systemImage: "trash").font(.caption)
                }
                .squishy()
                Spacer()
                if ai.visionReady {
                    Label("vision ready", systemImage: "eye")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .glassCard()
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 6) {
                if !message.images.isEmpty {
                    ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.footnote)
                    .textSelection(.enabled)
                if message.role == .assistant && !message.text.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            UIPasteboard.general.string = message.text
                            app.toast = "Copied"
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                        }
                        .squishy(0.9)
                        Button {
                            app.prompt = message.text
                            app.showCreate = true
                            Haptics.success()
                        } label: {
                            Label("Use as prompt", systemImage: "arrow.up.forward.app").font(.caption2)
                        }
                        .squishy(0.9)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(message.role == .user ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14))
            if message.role != .user { Spacer(minLength: 30) }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let images = attachments
        input = ""
        attachments = []
        messages.append(ChatMessage(role: .user, text: text, images: images))
        var reply = ChatMessage(role: .assistant, text: "")
        let replyId = reply.id
        messages.append(reply)
        chatFocused = false

        let history: [(role: String, text: String)] =
            [("system", systemPrompt)] +
            messages.filter { !$0.text.isEmpty && $0.id != replyId }
                    .map { (role: $0.role.rawValue, text: $0.text) }

        Task {
            await ai.chat(messages: history, images: images) { piece in
                if let index = messages.firstIndex(where: { $0.id == replyId }) {
                    messages[index].text += piece
                }
            }
            if let index = messages.firstIndex(where: { $0.id == replyId }), messages[index].text.isEmpty {
                messages[index].text = "(no answer — is a model loaded and selected?)"
            }
        }
    }
}
