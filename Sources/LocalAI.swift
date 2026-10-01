import Foundation
import UIKit

/// Shared, nonisolated state for the blocking llama.cpp work.
private var llamaBackendReady = false
private var llamaCancelRequested = false

/// A GGUF sitting in the app's own models folder.
struct LocalModelFile: Identifiable, Hashable {
    let name: String
    let bytes: Int64
    var id: String { name }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var isProjector: Bool { name.lowercased().contains("mmproj") }
}

enum KVMode: String, CaseIterable, Identifiable, Codable {
    case f16, q8_0
    var id: String { rawValue }
    var label: String { self == .f16 ? "F16 (best)" : "Q8_0 (smaller)" }
}

enum FlashMode: String, CaseIterable, Identifiable, Codable {
    case auto, on, off
    var id: String { rawValue }
    var label: String { self == .auto ? "Auto" : (self == .on ? "On" : "Off") }
}

/// Every knob here is real: these go straight into llama.cpp's model, context and sampler params.
struct LocalSettings: Codable, Equatable {
    var contextSize = 2048
    var batchSize = 512
    var physicalBatch = 512
    var threads = max(2, ProcessInfo.processInfo.processorCount - 1)
    var gpuLayers = 99
    var flash: FlashMode = .auto
    var kvCache: KVMode = .f16
    var mmap = true
    var offloadKQV = true
    var imageMaxTokens = 512
    var temperature = 0.7
    var topP = 0.95
    var topK = 40
    var repeatPenalty = 1.1
    var maxTokens = 400
    var vision = true

    static var presets: [(String, LocalSettings)] {
        var fast = LocalSettings()
        fast.contextSize = 1536
        fast.threads = 4
        fast.maxTokens = 200
        var long = LocalSettings()
        long.contextSize = 4096
        long.kvCache = .q8_0
        var quiet = LocalSettings()
        quiet.threads = 3
        quiet.offloadKQV = false
        return [("Balanced", LocalSettings()), ("Fast", fast), ("Long context", long), ("Cool & quiet", quiet)]
    }
}

/// On-device inference (llama.cpp + mtmd for vision). Everything runs on the phone;
/// nothing here touches the PC bridge.
@MainActor
final class LocalAI: ObservableObject {
    static let shared = LocalAI()

    @Published private(set) var models: [LocalModelFile] = []
    @Published private(set) var selected: String?
    @Published private(set) var projector: String?
    @Published private(set) var loaded: String?
    @Published private(set) var visionReady = false
    @Published private(set) var status = "No model loaded"
    @Published private(set) var working = false
    @Published private(set) var streamingText = ""
    @Published private(set) var importing: String?
    @Published private(set) var importProgress: Double = 0
    @Published private(set) var settingsDirty = false
    @Published private(set) var lastRun = ""
    @Published var settings = LocalSettings() {
        didSet {
            settingsDirty = usedSettings != nil && usedSettings != settings
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: "localSettings")
            }
        }
    }

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var mtmdCtx: OpaquePointer?
    private var usedSettings: LocalSettings?

    init() {
        if let data = UserDefaults.standard.data(forKey: "localSettings"),
           let decoded = try? JSONDecoder().decode(LocalSettings.self, from: data) {
            settings = decoded
        }
    }

    // MARK: - storage

    nonisolated static var modelsDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func refreshModels() {
        let dir = Self.modelsDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: [.fileSizeKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        models = files.filter { $0.pathExtension.lowercased() == "gguf" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return LocalModelFile(name: url.lastPathComponent, bytes: Int64(size))
            }
            .sorted { $0.name < $1.name }

        let d = UserDefaults.standard
        selected = d.string(forKey: "localModel")
        projector = d.string(forKey: "localProjector")
        if let selected, !models.contains(where: { $0.name == selected }) { self.selected = nil }
        if let projector, !models.contains(where: { $0.name == projector }) { self.projector = nil }
    }

    func path(for name: String) -> URL { Self.modelsDir.appendingPathComponent(name) }

    // MARK: - import

    /// Copy one or more GGUFs the user found in Files into the app's models folder.
    func importModels(from urls: [URL]) async {
        for url in urls { await importModel(from: url) }
        refreshModels()
    }

    func importModel(from url: URL) async {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = Self.modelsDir.appendingPathComponent(name)
        importing = name
        importProgress = 0
        defer { importing = nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        if size > 0, let free = Self.freeSpace(), free < size + (64 << 20) {
            status = "Not enough space for \(name) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))."
            Haptics.error()
            return
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try await Task.detached(priority: .userInitiated) {
                try Self.copyWithProgress(from: url, to: dest) { fraction in
                    Task { @MainActor in LocalAI.shared.importProgress = fraction }
                }
            }.value
            refreshModels()
            if name.lowercased().contains("mmproj") {
                selectProjector(name)
            } else {
                select(name)
            }
            status = "Imported \(name) — tap Load"
            Haptics.success()
        } catch {
            Haptics.error()
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    nonisolated private static func copyWithProgress(from source: URL, to destination: URL,
                                                     onProgress: @escaping (Double) -> Void) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        let expected = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        var copied: Int64 = 0
        while true {
            guard let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            if expected > 0 { onProgress(Double(copied) / Double(expected)) }
        }
    }

    nonisolated private static func freeSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func delete(_ item: LocalModelFile) {
        try? FileManager.default.removeItem(at: path(for: item.name))
        if loaded == item.name { unload() }
        refreshModels()
    }

    func select(_ name: String?) {
        selected = name
        UserDefaults.standard.set(name, forKey: "localModel")
        if loaded != nil && loaded != name { unload() }
    }

    func selectProjector(_ name: String?) {
        projector = name
        UserDefaults.standard.set(name, forKey: "localProjector")
    }

    var selectedFile: LocalModelFile? { models.first { $0.name == selected } }
    var projectorFile: LocalModelFile? { models.first { $0.name == projector } }
    var isSelected: Bool { selected != nil }

    // MARK: - lifecycle

    func load() async {
        guard let name = selected else {
            status = "Pick a model first."
            return
        }
        guard loaded != name || usedSettings != settings else { return }
        unload()
        working = true
        let snapshot = settings
        status = "Loading \(name)…"
        let modelPath = path(for: name).path
        let projPath = snapshot.vision ? projector.map { path(for: $0).path } : nil
        let result = await Self.loadModel(modelPath: modelPath, projPath: projPath, settings: snapshot)
        self.model = result.model
        self.ctx = result.ctx
        self.mtmdCtx = result.mtmd
        self.visionReady = result.mtmd != nil
        self.loaded = result.model != nil ? name : nil
        self.usedSettings = result.model != nil ? snapshot : nil
        self.settingsDirty = false
        self.status = result.model != nil
            ? "Loaded \(name)\(result.mtmd != nil ? " + vision" : "") · ctx \(result.contextSize)\(result.note.isEmpty ? "" : " · \(result.note)")"
            : "Couldn't load \(name) — try a smaller context"
        working = false
        Haptics.perform(result.model != nil ? .success : .error)
    }

    /// Apply changed settings to a model that's already loaded.
    func reload() async {
        guard loaded != nil else {
            await load()
            return
        }
        let name = loaded
        unload()
        selected = name
        await load()
    }

    func unload() {
        if let ctx { llama_free(ctx) }
        if let mtmdCtx { mtmd_free(mtmdCtx) }
        if let model { llama_model_free(model) }
        ctx = nil
        mtmdCtx = nil
        model = nil
        loaded = nil
        visionReady = false
        usedSettings = nil
        settingsDirty = false
        lastRun = ""
        status = "No model loaded"
    }

    func stop() { llamaCancelRequested = true }

    // MARK: - chat

    /// Stream a reply. `onDelta` is called on the main actor as text arrives.
    func chat(messages: [(role: String, text: String)], images: [UIImage],
              onDelta: @escaping (String) -> Void) async {
        if loaded == nil || usedSettings != settings { await load() }
        guard let ctx, let model else {
            status = "No model loaded"
            return
        }
        guard let vocab = llama_model_get_vocab(model) else { return }
        llamaCancelRequested = false
        working = true
        streamingText = ""

        let snapshot = settings
        let imagePaths = images.compactMap { Self.writeTempJPEG($0) }
        let mtmdHandle = mtmdCtx
        let useVision = mtmdHandle != nil && !imagePaths.isEmpty
        let marker = mtmd_default_marker().map { String(cString: $0) } ?? "<__media__>"

        var turns = messages
        if useVision, let lastUser = turns.lastIndex(where: { $0.role == "user" }) {
            let markers = String(repeating: marker + "\n", count: imagePaths.count)
            turns[lastUser].text = markers + turns[lastUser].text
        }

        let template = llama_model_chat_template(model, nil).map { String(cString: $0) }
        let prompt = Self.renderChat(messages: turns, template: template)

        let result = await Task.detached(priority: .userInitiated) {
            Self.run(ctx: ctx, vocab: vocab, mtmd: useVision ? mtmdHandle : nil,
                     prompt: prompt, imagePaths: imagePaths, settings: snapshot,
                     onDelta: { piece in
                Task { @MainActor in
                    LocalAI.shared.streamingText += piece
                    onDelta(piece)
                }
            })
        }.value

        working = false
        lastRun = result.note
        status = result.text.isEmpty ? "No answer — try again or raise max tokens" : "Done · \(result.note)"
        for path in imagePaths { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: - llama.cpp glue (blocking work, off the main actor)

    nonisolated private static func loadModel(modelPath: String, projPath: String?,
                                              settings: LocalSettings)
        -> (model: OpaquePointer?, ctx: OpaquePointer?, mtmd: OpaquePointer?,
            contextSize: Int, note: String) {
        if !llamaBackendReady {
            llama_backend_init()
            llamaBackendReady = true
        }
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = Int32(settings.gpuLayers)
        mparams.load_mode = settings.mmap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE
        guard let model = llama_model_load_from_file(modelPath, mparams) else {
            return (nil, nil, nil, 0, "")
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(settings.contextSize)
        cparams.n_batch = UInt32(settings.batchSize)
        cparams.n_ubatch = UInt32(settings.physicalBatch)
        cparams.n_threads = Int32(settings.threads)
        cparams.n_threads_batch = Int32(settings.threads)
        cparams.offload_kqv = settings.offloadKQV
        switch settings.flash {
        case .auto: cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        case .on: cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        case .off: cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        }
        switch settings.kvCache {
        case .f16:
            cparams.type_k = GGML_TYPE_F16
            cparams.type_v = GGML_TYPE_F16
        case .q8_0:
            cparams.type_k = GGML_TYPE_Q8_0
            cparams.type_v = GGML_TYPE_Q8_0
        }
        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            return (nil, nil, nil, 0, "")
        }
        let realCtx = Int(llama_n_ctx(ctx))
        var note = realCtx != settings.contextSize ? "asked ctx \(settings.contextSize), got \(realCtx)" : ""

        var mtmd: OpaquePointer?
        if let projPath, !projPath.isEmpty {
            var tparams = mtmd_context_params_default()
            tparams.use_gpu = true
            tparams.print_timings = false
            tparams.n_threads = Int32(settings.threads)
            tparams.image_max_tokens = Int32(settings.imageMaxTokens)
            switch settings.flash {
            case .auto: tparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
            case .on: tparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
            case .off: tparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
            }
            mtmd = mtmd_init_from_file(projPath, model, tparams)
            if mtmd == nil {
                note = note.isEmpty ? "mmproj didn't load" : note + " · mmproj didn't load"
            }
        }
        return (model, ctx, mtmd, realCtx, note)
    }

    nonisolated private static func renderChat(messages: [(role: String, text: String)],
                                               template: String?) -> String {
        guard let template else {
            // No template baked into the GGUF: fall back to a plain layout.
            return messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n") + "\nassistant:"
        }
        let count = messages.count
        let raw = UnsafeMutablePointer<llama_chat_message>.allocate(capacity: count)
        var keep: [UnsafeMutablePointer<CChar>] = []
        for (index, message) in messages.enumerated() {
            let role = strdup(message.role)!
            let text = strdup(message.text)!
            keep.append(role)
            keep.append(text)
            raw[index] = llama_chat_message(role: role, content: text)
        }
        defer {
            keep.forEach { free($0) }
            raw.deallocate()
        }
        var buffer = [CChar](repeating: 0, count: 1 << 20)
        let written = llama_chat_apply_template(template, raw, count, true, &buffer, Int32(buffer.count))
        guard written > 0 else {
            return messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        }
        return String(cString: buffer)
    }

    nonisolated private static func writeTempJPEG(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ref-\(UUID().uuidString).jpg")
        try? data.write(to: url)
        return url.path
    }

    nonisolated private static func run(ctx: OpaquePointer, vocab: OpaquePointer,
                                        mtmd: OpaquePointer?, prompt: String,
                                        imagePaths: [String], settings: LocalSettings,
                                        onDelta: @escaping (String) -> Void)
        -> (text: String, note: String) {
        var output = ""
        var nPast: Int32 = 0
        var promptTokens = 0
        let started = Date()
        let ubatch = Int32(max(32, settings.physicalBatch))

        let chainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(chainParams) else { return ("", "") }
        if settings.repeatPenalty > 1.0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64,
                                                                        Float(settings.repeatPenalty), 0.0, 0.0))
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(settings.topK)))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(settings.topP), 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(settings.temperature)))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        defer { llama_sampler_free(chain) }

        if let mtmd, !imagePaths.isEmpty {
            var bitmaps: [OpaquePointer?] = []
            for path in imagePaths {
                let wrapper = mtmd_helper_bitmap_init_from_file(mtmd, path, false,
                                                                mtmd_helper_init_opt_default())
                if let bitmap = wrapper.bitmap { bitmaps.append(bitmap) }
            }
            defer { for bitmap in bitmaps { if let bitmap { mtmd_bitmap_free(bitmap) } } }

            var inputText = mtmd_input_text(text: strdup(prompt), text_len: prompt.utf8.count,
                                            add_special: true, parse_special: true)
            guard let chunks = mtmd_input_chunks_init() else { return ("", "") }
            defer { mtmd_input_chunks_free(chunks) }
            let tokenized = bitmaps.withUnsafeBufferPointer { buffer in
                mtmd_tokenize(mtmd, chunks, &inputText, buffer.baseAddress, buffer.count)
            }
            free(UnsafeMutableRawPointer(mutating: inputText.text))
            if tokenized == 0 {
                promptTokens = Int(mtmd_helper_get_n_tokens(chunks))
                var newPast: Int32 = 0
                let evaluated = mtmd_helper_eval_chunks(mtmd, ctx, chunks, nPast, 0, ubatch, true, &newPast)
                if evaluated == 0 { nPast = newPast }
            }
        } else {
            var tokens = [llama_token](repeating: 0, count: 1 << 15)
            var count = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens,
                                       Int32(tokens.count), true, true)
            if count < 0 { return ("", "") }
            let room = Int32(max(64, settings.contextSize - settings.maxTokens))
            if count > room {
                tokens.removeFirst(Int(count - room))
                count = room
            }
            let slice = Array(tokens[0..<Int(count)])
            promptTokens = slice.count
            nPast = decode(ctx: ctx, tokens: slice, nPast: nPast, batch: ubatch)
        }

        var buffer = [CChar](repeating: 0, count: 256)
        var generated = 0
        for _ in 0..<settings.maxTokens {
            if llamaCancelRequested { break }
            let token = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
            if written > 0 {
                let piece = String(cString: buffer)
                output += piece
                generated += 1
                onDelta(piece)
            }
            nPast = decode(ctx: ctx, tokens: [token], nPast: nPast, batch: 1)
        }

        let seconds = Date().timeIntervalSince(started)
        let note = "\(promptTokens) in + \(generated) out tok · \(String(format: "%.1f", seconds))s"
        return (output, note)
    }

    nonisolated private static func decode(ctx: OpaquePointer, tokens: [llama_token],
                                           nPast: Int32, batch limit: Int32) -> Int32 {
        var position = nPast
        var index = 0
        while index < tokens.count {
            let size = min(Int(limit), tokens.count - index)
            let slice = Array(tokens[index..<(index + size)])
            var batch = llama_batch_init(Int32(slice.count), 0, 1)
            for (offset, token) in slice.enumerated() {
                batch.token[offset] = token
                batch.pos[offset] = position
                batch.n_seq_id[offset] = 1
                batch.seq_id[offset]?[0] = 0
                batch.logits[offset] = (offset == slice.count - 1) ? 1 : 0
                position += 1
            }
            batch.n_tokens = Int32(slice.count)
            _ = llama_decode(ctx, batch)
            llama_batch_free(batch)
            index += size
        }
        return position
    }
}

extension Haptics {
    enum Kind { case success, error }
    static func perform(_ kind: Kind) {
        switch kind {
        case .success: success()
        case .error: error()
        }
    }
}
