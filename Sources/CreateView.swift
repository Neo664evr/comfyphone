import SwiftUI
import Foundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct CreateView: View {
    @EnvironmentObject private var app: AppState
    @State private var showAdvanced = false
    @State private var shareItems: [Any] = []
    @State private var sharing = false
    @State private var confirmStop = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var importingFile = false
    @FocusState private var composerFocused: Bool
    @State private var draft: String = ""
    @State private var negDraft: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusBanner()

                    tipsCard

                    engineCard

                    modePicker

                    photoCard

                    styleRow

                    if app.mode != "edit" && !app.models.isEmpty {
                        modelPicker
                    }

                    promptBox

                    Button(action: {
                        if app.phase.isBusy { app.cancel() } else { app.makeImage() }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: app.phase.isBusy ? "stop.fill" : (app.mode == "edit" ? "wand.and.rays" : "sparkles"))
                            Text(app.phase.isBusy ? "Cancel" : (app.mode == "edit" ? "Edit photo" : "Make image"))
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(app.phase.isBusy ? Color.red.opacity(0.85) : Color.accentColor,
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                    }
                    .disabled(!app.phase.isBusy && ((app.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                    && app.activeStyles.isEmpty)
                                                   || (app.mode == "edit" && app.references.isEmpty)))
                    .squishy(0.975)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: app.phase.isBusy)

                    queueCard

                    savedPromptsCard

                    historyCard

                    progressSection

                    if case .failed(let message) = app.phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    results

                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        advancedControls
                    }
                    .font(.subheadline)
                    .tint(.secondary)
                }
                .padding(16)
            }
            .navigationTitle("ComfyPhone")
            .background(AppBackground())
            .scrollDismissesKeyboard(.interactively)
            .toolbar { KeyboardDoneToolbar() }
            .sheet(isPresented: $sharing) {
                ShareSheet(items: shareItems)
            }
        }
    }

    // MARK: pieces

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(app.reachable ? (app.engineUp ? Color.green : Color.orange) : Color.red)
                    .frame(width: 9, height: 9)
                Text(app.engineText)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let free = app.health?.vram_free_gb {
                    Text(String(format: "%.1f GB free", free))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                engineButton("Start", "play.fill", "start", enabled: app.reachable && !app.engineUp)
                engineButton("Stop", "stop.fill", "stop", enabled: app.reachable && app.engineUp)
                engineButton("Restart", "arrow.clockwise", "restart", enabled: app.reachable)
                engineButton("Free VRAM", "memorychip", "free", enabled: app.reachable && app.engineUp)
            }

            if app.engineBusy != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Talking to the PC…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .glassCard()
        .confirmationDialog("Stop the image engine on the PC?", isPresented: $confirmStop,
                            titleVisibility: .visible) {
            Button("Stop engine", role: .destructive) {
                Task { await app.runEngine("stop") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything rendering right now is cancelled and the GPU memory is released. You can start it again from here.")
        }
    }

    private func engineButton(_ label: String, _ icon: String, _ action: String, enabled: Bool) -> some View {
        Button {
            if action == "stop" {
                confirmStop = true
            } else {
                Task { await app.runEngine(action) }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.footnote)
                Text(label).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
        .glassButton()
        .disabled(!enabled || app.engineBusy != nil)
        .opacity(enabled ? 1 : 0.45)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $app.mode) {
            Text("Create").tag("create")
            Text("Edit photo").tag("edit")
        }
        .pickerStyle(.segmented)
        .onChange(of: app.mode) { _, newValue in
            if newValue == "edit" {
                app.steps = app.editInfo?.steps ?? 20
                let side = app.editInfo?.side ?? 1024
                app.width = side
                app.height = side
            } else if let model = app.currentModel {
                app.select(model: model)
            }
        }
    }

    private func pasteReference() {
        let board = UIPasteboard.general
        if let image = board.image, let data = image.jpegData(compressionQuality: 0.92) {
            app.setReference(data)
            return
        }
        if let url = board.url, let data = try? Data(contentsOf: url) {
            app.setReference(data)
            return
        }
        app.toast = "Nothing copied — copy a photo in Photos first, then tap again."
    }

    /// Drops @1 … @4 into the prompt so a photo can be named in the instruction.
    private func insertTag(_ index: Int) {
        let token = "@\(index + 1)"
        if app.prompt.isEmpty || app.prompt.hasSuffix(" ") {
            app.prompt += token + " "
        } else {
            app.prompt += " " + token + " "
        }
        Haptics.tap()
        app.toast = "\(token) added — name it in your instruction"
    }

    private var styleRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Styles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if ai.isSelected {
                    Button {
                        improveWithLocal()
                    } label: {
                        Label(improving ? "Improving…" : "Improve · local",
                              systemImage: "wand.and.sparkles")
                            .font(.caption.weight(.semibold))
                    }
                    .glassButton()
                    .squishy()
                    .disabled(improving || ai.working)
                }
                Button {
                    app.saveCurrentPrompt()
                } label: {
                    Label("Save", systemImage: "bookmark")
                        .font(.caption.weight(.semibold))
                }
                .glassButton()
                .squishy()
                Button {
                    app.enqueue(app.prompt)
                } label: {
                    Label("Queue", systemImage: "text.badge.plus")
                        .font(.caption.weight(.semibold))
                }
                .glassButton()
                .squishy()
                Button {
                    app.prompt = Improviser.enhance(app.prompt)
                    Haptics.soft()
                } label: {
                    Label("Enhance", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                }
                .glassButton()
                .squishy()
                Button {
                    app.prompt = Improviser.roll()
                    Haptics.soft()
                } label: {
                    Label("Surprise me", systemImage: "dice")
                        .font(.caption.weight(.semibold))
                }
                .glassButton()
                .squishy()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StyleChip.all) { chip in
                        let on = app.styles.contains(chip.id)
                        Button {
                            app.toggleStyle(chip)
                        } label: {
                            Text(chip.label)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .foregroundStyle(on ? .white : .primary)
                        }
                        .glassChip(selected: on, corner: 12)
                        .squishy()
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var photoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !app.references.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(app.references.enumerated()), id: \.element.id) { index, ref in
                            RefSlotView(index: index, ref: ref) {
                                insertTag(index)
                            } onRemove: {
                                app.removeReference(at: index)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                }
            }
            HStack(spacing: 16) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label(app.references.isEmpty ? "Camera roll" : "Add photo",
                          systemImage: "photo.badge.plus")
                        .font(.footnote.weight(.semibold))
                }
                .squishy()
                Button {
                    importingFile = true
                } label: {
                    Label("Files", systemImage: "folder")
                        .font(.footnote.weight(.semibold))
                }
                .squishy()
                Button {
                    pasteReference()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.footnote.weight(.semibold))
                }
                .squishy()
                Spacer(minLength: 0)
                if !app.references.isEmpty {
                    Button(role: .destructive) {
                        app.clearReference()
                        pickerItem = nil
                    } label: {
                        Text("Clear").font(.caption)
                    }
                }
            }
            Text("Up to four photos. Tap an **@** badge to drop @1–@4 into your prompt, then say what you want — “put @1 in the jacket from @2”. If the camera-roll picker is empty under LiveContainer, use Files or Paste.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .glassCard()
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    app.setReference(data)
                } else {
                    app.toast = "Couldn't read that file."
                }
            case .failure:
                app.toast = "No file chosen."
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    app.setReference(data)
                } else {
                    app.toast = "Couldn't read that photo."
                }
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model on the PC")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(app.models) { model in
                        let selected = model.id == app.modelID
                        Button {
                            app.select(model: model)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name).font(.footnote.weight(.semibold))
                                if let note = model.note {
                                    Text(note).font(.caption2).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(selected ? .white : .primary)
                        }
                        .glassChip(selected: selected, corner: 13)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var promptBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(app.mode == "edit" ? "What to change" : "Picture")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if composerFocused {
                    Button {
                        composerFocused = false
                    } label: {
                        Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                    }
                    .glassButton()
                    .transition(.opacity)
                }
            }
            ZStack(alignment: .topLeading) {
                if app.prompt.isEmpty {
                    Text(app.mode == "edit" ? "Describe the change…" : "Describe the picture…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $draft)
                    .focused($composerFocused)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
            }
        }
        .padding(10)
        .glassCard()
        .onAppear { draft = app.prompt }
        // The editor keeps its own buffer: writing straight through to the published
        // prompt re-rendered the whole tab on every keystroke and dropped characters.
        .onChange(of: draft) { _, typed in
            if typed != app.prompt { app.prompt = typed }
        }
        .onChange(of: app.prompt) { _, value in
            if value != draft { draft = value }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        switch app.phase {
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                Text("Sending to the PC…").font(.footnote).foregroundStyle(.secondary)
            }
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                if let preview = app.previewImage {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.16)))
                        .opacity(0.92)
                        .animation(.easeOut(duration: 0.25), value: app.progress)
                    Text("Developing on the PC — this is the real latent.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(max(app.progress, 0), 1))
                    .animation(.snappy(duration: 0.5), value: app.progress)
                HStack {
                    Text(app.jobNote.isEmpty ? (app.mode == "edit" ? "Editing your photo" : app.modelDisplayName) : app.jobNote)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(app.progressLine + (app.queueDepth > 1 ? " · \(app.queueDepth) in queue" : ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: app.progressLine)
                }
            }
        case .done:
            HStack {
                Text("Done in \(elapsedText(app.elapsed))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if app.lastSeed != 0 {
                    Text("seed \(app.lastSeed)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var results: some View {
        ForEach(app.images.indices, id: \.self) { index in
            let image = app.images[index]
            VStack(spacing: 10) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))
                    .shimmer(active: app.phase == .done && index == app.images.count - 1)
                    .popIn()
                    .contextMenu {
                        Button {
                            app.save(image)
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            shareItems = [image]
                            sharing = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = app.prompt
                            app.toast = "Prompt copied"
                        } label: {
                            Label("Copy prompt", systemImage: "doc.on.doc")
                        }
                    }
                HStack(spacing: 10) {
                    Button {
                        app.save(image)
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .glassButton()
                    Button {
                        shareItems = [image]
                        sharing = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .glassButton()
                    Spacer()
                }
                .font(.footnote)

                if app.mode == "edit", let before = app.referenceImage {
                    CompareSlider(before: before, after: image)
                        .popIn()
                    Text("Drag to compare your photo with the edit.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        app.rerun(seedShift: 1)
                    } label: {
                        Label("Seed +1", systemImage: "plus").font(.caption.weight(.semibold))
                    }
                    .glassButton()
                    .squishy()
                    Button {
                        app.rerun(seedShift: -1)
                    } label: {
                        Label("Seed −1", systemImage: "minus").font(.caption.weight(.semibold))
                    }
                    .glassButton()
                    .squishy()
                    Button {
                        app.rerun(batch: 4)
                    } label: {
                        Label("4 up", systemImage: "square.grid.2x2").font(.caption.weight(.semibold))
                    }
                    .glassButton()
                    .squishy()
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @AppStorage("seenTips") private var seenTips = false
    @ObservedObject private var ai = LocalAI.shared
    @State private var improving = false

    /// Prompt polish on the phone itself — only offered once a local model is selected.
    private func improveWithLocal() {
        let base = app.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        improving = true
        Haptics.soft()
        var streamed = ""
        Task {
            await ai.chat(messages: [
                ("system", "You rewrite image-generation prompts. Reply with ONLY the improved prompt: one vivid paragraph, concrete details, no preamble, no quotes."),
                ("user", base.isEmpty ? "Invent a striking image prompt." : "Improve this image prompt: \(base)")
            ], images: []) { piece in
                streamed += piece
                app.prompt = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            improving = false
            let final = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
            if final.isEmpty {
                app.toast = "The local model gave nothing back."
                Haptics.error()
            } else {
                app.prompt = final
                Haptics.success()
            }
        }
    }

    @ViewBuilder
    private var tipsCard: some View {
        if !seenTips {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Quick tips", systemImage: "lightbulb.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Got it") {
                        seenTips = true
                        Haptics.tap()
                    }
                    .font(.caption)
                }
                Text("• Tap an @ badge to name a photo in your prompt (@1, @2 …)")
                Text("• Styles stack — two together make a hybrid look")
                Text("• Queue lines prompts up and cooks them back to back")
                Text("• Seed +1 nudges a near-miss without changing anything else")
                Text("• Long-press a result for Save / Share / Copy prompt")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(12)
            .glassCard()
            .popIn()
        }
    }

    @ViewBuilder
    private var queueCard: some View {
        if !app.queue.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Queue · \(app.queue.count) waiting", systemImage: "list.bullet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Clear") { app.clearQueue() }
                        .font(.caption)
                }
                ForEach(app.queue) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.text)
                            .font(.footnote)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button {
                            app.removeQueued(item)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .squishy(0.85)
                    }
                    .padding(.vertical, 2)
                }
                Text("They cook one after another as soon as the current one lands.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .glassCard()
            .popIn()
        }
    }

    @ViewBuilder
    private var savedPromptsCard: some View {
        if !app.savedPrompts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Saved prompts", systemImage: "bookmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(app.savedPrompts.prefix(5)) { item in
                    HStack(spacing: 8) {
                        Button {
                            app.prompt = item.text
                            Haptics.tap()
                            app.toast = "Prompt loaded"
                        } label: {
                            Text(item.title)
                                .font(.footnote)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .squishy()
                        Button {
                            app.enqueue(item.text)
                        } label: {
                            Image(systemName: "text.badge.plus").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .squishy(0.85)
                        Button {
                            app.removeSavedPrompt(item)
                        } label: {
                            Image(systemName: "trash").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .squishy(0.85)
                    }
                }
            }
            .padding(12)
            .glassCard()
        }
    }

    @ViewBuilder
    private var historyCard: some View {
        if !app.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Recent recipes", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { app.clearHistory() }
                        .font(.caption)
                }
                ForEach(app.history.prefix(5)) { recipe in
                    Button {
                        app.apply(recipe)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recipe.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Text(recipe.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                    .squishy()
                }
            }
            .padding(12)
            .glassCard()
        }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(sizePresets) { preset in
                    let selected = app.width == preset.w && app.height == preset.h
                    Button {
                        app.width = preset.w
                        app.height = preset.h
                    } label: {
                        Text(preset.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .glassChip(selected: selected, corner: 11)
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            stepper("Width", value: $app.width, range: 256...2048, step: 64)
            stepper("Height", value: $app.height, range: 256...2048, step: 64)
            stepper("Steps", value: $app.steps, range: 1...60, step: 1)
            if app.mode != "edit" {
                stepper("Images", value: $app.batch, range: 1...4, step: 1)
            }

            Toggle("Random seed", isOn: $app.randomSeed)
                .font(.footnote)
            if !app.randomSeed {
                stepper("Seed", value: Binding(
                    get: { Int(app.seed) },
                    set: { app.seed = Int64($0) }), range: 0...9_999_999, step: 1)
            }

            Text("Negative prompt")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $negDraft)
                .frame(height: 60)
                .padding(6)
                .scrollContentBackground(.hidden)
                .glassCard(corner: 10)
                .onChange(of: negDraft) { _, typed in
                    if typed != app.negative { app.negative = typed }
                }
                .onChange(of: app.negative) { _, value in
                    if value != negDraft { negDraft = value }
                }
                .onAppear { negDraft = app.negative }
        }
        .padding(.top, 6)
    }

    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack {
            Text(label).font(.footnote)
            Spacer()
            Text("\(value.wrappedValue)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
    }

    private var sizePresets: [SizePreset] {
        [SizePreset(label: "Square", w: 1024, h: 1024),
         SizePreset(label: "Tall", w: 832, h: 1216),
         SizePreset(label: "Wide", w: 1216, h: 832),
         SizePreset(label: "Phone", w: 944, h: 2048),
         SizePreset(label: "Fast", w: 768, h: 768)]
    }
}

struct SizePreset: Identifiable {
    let label: String
    let w: Int
    let h: Int
    var id: String { label }
}
