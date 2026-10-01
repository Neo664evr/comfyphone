import Foundation
import Photos
import UIKit

@MainActor
final class AppState: ObservableObject {

    enum Phase: Equatable {
        case idle
        case sending
        case running
        case done
        case failed(String)

        var isBusy: Bool { self == .sending || self == .running }
    }

    // Settings
    @Published var serverURL: String { didSet { store(serverURL, "serverURL") } }
    @Published var token: String { didSet { store(token, "token") } }

    // Mode + reference photos (@1 … @4)
    @Published var mode: String = "create" { didSet { store(mode, "mode") } }
    @Published var references: [RefImage] = []
    @Published var styles: [String] = []
    var referenceImage: UIImage? { references.first?.image }
    var referenceData: Data? { references.first?.data }
    @Published var editInfo: EditInfo?
    @Published var jobNote: String = ""

    // Connection
    @Published var models: [ModelInfo] = []
    @Published var health: HealthResponse?
    @Published var statusLine: String = "Not checked yet"
    @Published var reachable = false
    @Published var activeBase: String = ""
    @Published var probes: [ProbeResult] = []

    // Job inputs
    @Published var modelID: String = "zimage" { didSet { store(modelID, "modelID") } }
    @Published var prompt: String = "" { didSet { store(prompt, "prompt") } }
    @Published var negative: String = "" { didSet { store(negative, "negative") } }
    @Published var width: Int = 768 { didSet { store(width, "width") } }
    @Published var height: Int = 768 { didSet { store(height, "height") } }
    @Published var steps: Int = 8 { didSet { store(steps, "steps") } }
    @Published var batch: Int = 1 { didSet { store(batch, "batch") } }
    @Published var seed: Int64 = 0 { didSet { store(seed, "seed") } }
    @Published var randomSeed = true { didSet { store(randomSeed, "randomSeed") } }

    // Results
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var elapsed: Double = 0
    @Published var queueDepth: Int = 0
    @Published var step: Int?
    @Published var stepsTotal: Int?
    @Published var eta: Int?

    /// "step 7/25 · 1:10 left" — straight from the PC's own step counter.
    var progressLine: String {
        var bits: [String] = []
        if let step, let stepsTotal, stepsTotal > 0 {
            bits.append("step \(step)/\(stepsTotal)")
        }
        if let eta, eta > 0 {
            bits.append("\(elapsedText(Double(eta))) left")
        } else if eta == nil || eta == 0 {
            bits.append("\(elapsedText(elapsed)) elapsed")
        }
        return bits.joined(separator: " · ")
    }
    @Published var images: [UIImage] = []
    @Published var previewImage: UIImage?
    @Published var lastSeed: Int64 = 0
    @Published var gallery: [GalleryItem] = []
    @Published var galleryImages: [String: UIImage] = [:]
    @Published var toast: String?
    @Published var engineBusy: String?          // name of the running engine action, nil when idle

    private var pollTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        let stored = d.string(forKey: "serverURL")
        // LiveContainer does not honour the guest app's ATS exceptions, so plain http is blocked
        // outright (-1022). The bridge is now served over https by Tailscale; move old values over.
        if stored == nil
            || stored == AppState.tailnetIPServer
            || stored == AppState.httpServer
            || stored == AppState.lanServer {
            serverURL = AppState.defaultServer
        } else {
            serverURL = stored!
        }
        // Adopt the token baked into a newer build: rotating it on the PC shouldn't leave the app
        // holding a stale value. A build's token is re-adopted only when it actually changes.
        let buildStamp = String(LocalConfig.token.hashValue)
        if !LocalConfig.token.isEmpty, d.string(forKey: "tokenStamp") != buildStamp {
            token = LocalConfig.token
            store(buildStamp, "tokenStamp")
        } else {
            token = d.string(forKey: "token") ?? AppState.defaultToken
        }
        modelID = d.string(forKey: "modelID") ?? "zimage"
        prompt = d.string(forKey: "prompt") ?? ""
        negative = d.string(forKey: "negative") ?? ""
        mode = d.string(forKey: "mode") ?? "create"
        width = d.object(forKey: "width") as? Int ?? 768
        height = d.object(forKey: "height") as? Int ?? 768
        steps = d.object(forKey: "steps") as? Int ?? 8
        batch = d.object(forKey: "batch") as? Int ?? 1
        seed = (d.object(forKey: "seed") as? NSNumber)?.int64Value ?? 0
        randomSeed = d.object(forKey: "randomSeed") as? Bool ?? true
        if let data = d.data(forKey: "history"),
           let saved = try? JSONDecoder().decode([Recipe].self, from: data) {
            history = saved
        }
        if let data = d.data(forKey: "queue"),
           let saved = try? JSONDecoder().decode([QueuedPrompt].self, from: data) {
            queue = saved
        }
        if let data = d.data(forKey: "savedPrompts"),
           let saved = try? JSONDecoder().decode([SavedPrompt].self, from: data) {
            savedPrompts = saved
        }
        if let saved = d.array(forKey: "starred") as? [String] {
            starred = Set(saved)
        }
        autoSave = d.bool(forKey: "autoSave")
        hapticsOn = d.object(forKey: "hapticsOn") as? Bool ?? true
        Haptics.enabled = hapticsOn
    }

    /// Real values are injected at build time by CI from repository secrets into
    /// Sources/LocalConfig.swift (git-ignored). The placeholders below are only the fallback
    /// for a plain local build, so nothing host-specific is ever committed to this public repo.
    static var defaultServer: String {
        LocalConfig.server.isEmpty ? "https://YOUR-MACHINE.YOUR-TAILNET.ts.net" : "https://\(LocalConfig.server)"
    }
    static var httpServer: String {
        LocalConfig.server.isEmpty ? "http://YOUR-MACHINE.YOUR-TAILNET.ts.net" : "http://\(LocalConfig.server)"
    }
    static var tailnetIPServer: String {
        LocalConfig.tailnetIP.isEmpty ? "http://100.x.x.x:8200" : "http://\(LocalConfig.tailnetIP):8200"
    }
    static var lanServer: String {
        LocalConfig.lanIP.isEmpty ? "http://192.168.x.x:8200" : "http://\(LocalConfig.lanIP):8200"
    }
    static var defaultToken: String { LocalConfig.token }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var client: Bridge { Bridge(base: activeBase.isEmpty ? serverURL : activeBase, token: token) }

    /// Every address the PC can be reached on, best first.
    var candidateBases: [String] {
        var list: [String] = []
        let options = [serverURL, AppState.defaultServer, AppState.httpServer,
                       AppState.tailnetIPServer, AppState.lanServer]
        for base in options {
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !list.contains(trimmed) { list.append(trimmed) }
        }
        return list
    }

    private func hostLabel(_ base: String) -> String {
        guard let host = URL(string: base)?.host else { return base }
        if host.hasSuffix(".ts.net") { return "Tailscale name" }
        return host
    }

    var currentModel: ModelInfo? { models.first { $0.id == modelID } }

    var modelDisplayName: String { currentModel?.name ?? modelID }

    // MARK: connection

    func refresh() async {
        var lastError = "Not checked yet"
        var results: [ProbeResult] = []
        for base in candidateBases {
            let probe = Bridge(base: base, token: token)
            do {
                let h = try await probe.health()
                let m = try await probe.models()
                results.append(ProbeResult(base: base, ok: true, detail: "reached the bridge"))
                activeBase = base
                if serverURL != base { serverURL = base }
                health = h
                models = m.models
                editInfo = m.edit
                reachable = true
                let comfy = (h.comfy ?? "?") == "up" ? "engine ready" : "engine asleep"
                var parts = ["PC online", comfy]
                if let gpu = h.gpu { parts.append(gpu) }
                parts.append(hostLabel(base))
                statusLine = parts.joined(separator: " · ")
                probes = results
                if let first = m.models.first, !m.models.contains(where: { $0.id == modelID }) {
                    applyDefaults(for: first)
                }
                return
            } catch {
                let detail = (error as? BridgeError)?.message ?? error.localizedDescription
                results.append(ProbeResult(base: base, ok: false, detail: detail))
                lastError = detail
            }
        }
        reachable = false
        health = nil
        activeBase = ""
        probes = results
        statusLine = lastError
    }

    func applyDefaults(for model: ModelInfo) {
        modelID = model.id
        if steps != model.steps { steps = model.steps }
        width = model.side
        height = model.side
    }

    func select(model: ModelInfo) {
        applyDefaults(for: model)
        if model.id == "qwen" || model.id == "qwen_stock" {
            width = 1024
            height = 1024
        }
    }

    // MARK: reference photo (edit mode)

    func setReference(_ data: Data) {
        addReference(data)
    }

    /// One of up to four references. Each shows as @1 … @4 in the composer.
    func addReference(_ data: Data) {
        guard references.count < 4 else {
            toast = "Four photos is the max — remove one first."
            Haptics.error()
            return
        }
        guard let image = UIImage(data: data) else {
            toast = "That file isn't a photo."
            Haptics.error()
            return
        }
        let shrunk = image.downscaled(maxSide: 1600)
        guard let jpeg = shrunk.jpegData(compressionQuality: 0.92) else { return }
        references.append(RefImage(image: shrunk, data: jpeg))
        mode = "edit"
        steps = editInfo?.steps ?? 20
        let side = editInfo?.side ?? 1024
        width = side
        height = side
        Haptics.success()
    }

    func removeReference(at index: Int) {
        guard references.indices.contains(index) else { return }
        references.remove(at: index)
        Haptics.tap()
    }

    func clearReference() {
        references.removeAll()
    }

    func tag(for index: Int) -> String { "@\(index + 1)" }

    // MARK: style chips (free prompt seasoning)

    func toggleStyle(_ chip: StyleChip) {
        if let at = styles.firstIndex(of: chip.id) {
            styles.remove(at: at)
        } else {
            styles.append(chip.id)
        }
        Haptics.select()
    }

    var activeStyles: [StyleChip] { StyleChip.all.filter { styles.contains($0.id) } }

    /// Prompt as the PC should see it: your words plus any chips you switched on.
    var styledPrompt: String {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = activeStyles.map(\.suffix).joined(separator: ", ")
        guard !suffix.isEmpty else { return base }
        return base.isEmpty ? suffix : base + ", " + suffix
    }

    /// Output size that keeps the reference photo's own aspect, longest side = `longest`.
    func fitted(longest: Int) -> (Int, Int) {
        guard let image = referenceImage, image.size.width > 0, image.size.height > 0 else {
            return (1024, 1024)
        }
        let side = CGFloat(max(256, min(2048, longest)))
        let scale = side / max(image.size.width, image.size.height)
        func snap(_ value: CGFloat) -> Int {
            max(256, min(2048, Int((value * scale / 16).rounded()) * 16))
        }
        return (snap(image.size.width), snap(image.size.height))
    }

    // MARK: history (one-tap remix)

    @Published var history: [Recipe] = []
    @Published var queue: [QueuedPrompt] = []
    @Published var savedPrompts: [SavedPrompt] = []
    @Published var starred: Set<String> = []
    @Published var showCreate = false
    @Published var autoSave = false { didSet { store(autoSave, "autoSave") } }
    @Published var hapticsOn = true {
        didSet {
            store(hapticsOn, "hapticsOn")
            Haptics.enabled = hapticsOn
        }
    }

    private func persist(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: queue (cook several prompts back to back)

    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.append(QueuedPrompt(text: trimmed))
        persist(queue, "queue")
        Haptics.tap()
        toast = "Queued — \(queue.count) waiting"
    }

    func removeQueued(_ item: QueuedPrompt) {
        queue.removeAll { $0.id == item.id }
        persist(queue, "queue")
    }

    func clearQueue() {
        queue.removeAll()
        persist(queue, "queue")
    }

    private func startNextQueued() -> Bool {
        guard !queue.isEmpty else { return false }
        let next = queue.removeFirst()
        persist(queue, "queue")
        prompt = next.text
        phase = .sending
        pollTask = Task { await submit(next.text) }
        return true
    }

    // MARK: saved prompts

    func saveCurrentPrompt() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedPrompts.insert(SavedPrompt(text: trimmed), at: 0)
        if savedPrompts.count > 40 { savedPrompts.removeLast(savedPrompts.count - 40) }
        persist(savedPrompts, "savedPrompts")
        Haptics.success()
        toast = "Prompt saved"
    }

    func removeSavedPrompt(_ item: SavedPrompt) {
        savedPrompts.removeAll { $0.id == item.id }
        persist(savedPrompts, "savedPrompts")
    }

    // MARK: starred gallery images

    func toggleStar(_ item: GalleryItem) {
        if starred.contains(item.name) {
            starred.remove(item.name)
        } else {
            starred.insert(item.name)
        }
        persist(Array(starred), "starred")
        Haptics.select()
    }

    func isStarred(_ item: GalleryItem) -> Bool { starred.contains(item.name) }

    /// Take a picture that already lives on the PC and use it as a reference photo.
    func useAsReference(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        addReference(data)
        showCreate = true
    }

    func remember(_ recipe: Recipe) {
        history.insert(recipe, at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "history")
        }
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "history")
        Haptics.tap()
    }

    /// Drop a past job's whole setup back into the composer.
    func apply(_ recipe: Recipe) {
        prompt = recipe.prompt
        negative = recipe.negative
        modelID = recipe.modelID == "qwen-edit" ? "qwen" : recipe.modelID
        width = recipe.width
        height = recipe.height
        steps = recipe.steps
        seed = recipe.seed
        randomSeed = recipe.seed <= 0
        styles = recipe.styles
        mode = recipe.mode
        Haptics.success()
        toast = "Recipe loaded — hit Generate"
    }

    /// Fire the same setup again, optionally with a different seed or batch.
    func rerun(seedShift: Int64 = 0, batch override: Int? = nil) {
        if let override { batch = override }
        if seedShift != 0 {
            randomSeed = false
            seed = max(0, seed + seedShift)
        }
        makeImage()
    }

    // MARK: generation

    func makeImage() {
        let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = styledPrompt
        guard !typed.isEmpty || !activeStyles.isEmpty else {
            phase = .failed(mode == "edit" ? "Say what to change about the photo."
                                           : "Type what you want to see first.")
            Haptics.error()
            return
        }
        if mode == "edit" && references.isEmpty {
            phase = .failed("Add a photo to edit first.")
            Haptics.error()
            return
        }
        pollTask?.cancel()
        images = []
        progress = 0
        elapsed = 0
        queueDepth = 0
        step = nil
        stepsTotal = nil
        eta = nil
        previewImage = nil
        jobNote = ""
        phase = .sending
        pollTask = Task { await submit(text) }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
        Task { try? await client.cancel() }
    }

    private func submit(_ text: String) async {
        do {
            let sent: GenerateResponse
            if mode == "edit", !references.isEmpty {
                let (w, h) = fitted(longest: max(width, height))
                sent = try await client.edit(prompt: text, negative: negative,
                                             photos: references.map(\.data),
                                             width: w, height: h,
                                             steps: steps, seed: randomSeed ? 0 : seed,
                                             encoder: modelID == "qwen_stock" ? "stock" : "heretic")
            } else {
                sent = try await client.generate(
                    model: modelID, prompt: text, negative: negative,
                    width: width, height: height, steps: steps,
                    seed: randomSeed ? 0 : seed, batch: batch)
            }
            lastSeed = sent.seed ?? 0
            remember(Recipe(prompt: text, negative: negative,
                            modelID: mode == "edit" ? "qwen-edit" : modelID,
                            width: width, height: height, steps: steps,
                            seed: sent.seed ?? 0, styles: styles, mode: mode))
            phase = .running
            await poll(job: sent.job)
        } catch {
            phase = .failed((error as? BridgeError)?.message ?? error.localizedDescription)
        }
    }

    private func poll(job id: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            do {
                let j = try await client.job(id: id)
                progress = j.progress ?? 0
                elapsed = j.elapsed ?? 0
                queueDepth = j.queue ?? 0
                step = j.step
                stepsTotal = j.steps_total
                eta = j.eta_seconds
                if j.preview == true, let shot = try? await client.preview(id: id) {
                    previewImage = shot
                }
                switch j.state {
                case "uploading": jobNote = "Sending the photo to the PC…"
                case "starting":  jobNote = "Waking the PC engine…"
                default:          jobNote = ""
                }
                if j.state == "done" {
                    progress = 1
                    Haptics.success()
                    var loaded: [UIImage] = []
                    for item in j.images ?? [] {
                        if let img = try? await client.image(id: id, index: item.index) {
                            loaded.append(img)
                        }
                    }
                    images = loaded
                    phase = loaded.isEmpty ? .failed("The PC finished but sent no image.") : .done
                    if autoSave {
                        for image in loaded { save(image) }
                    }
                    if startNextQueued() { return }
                    return
                }
                if j.state == "error" {
                    phase = .failed(j.error ?? "The PC reported a failure.")
                    return
                }
            } catch {
                if Task.isCancelled { return }
                phase = .failed((error as? BridgeError)?.message ?? error.localizedDescription)
                return
            }
        }
    }

    // MARK: engine controls (start / stop / restart / free VRAM on the PC)

    var engineUp: Bool { health?.comfy == "up" }

    var engineText: String {
        if engineBusy != nil { return "Working on the PC…" }
        guard reachable else { return "PC not reachable" }
        guard engineUp else { return "Engine stopped" }
        if let pid = health?.engine_pid { return "Engine running (pid \(pid))" }
        return "Engine running"
    }

    func runEngine(_ action: String) async {
        guard engineBusy == nil else { return }
        engineBusy = action
        defer { engineBusy = nil }
        do {
            let result = try await client.engine(action)
            await refresh()
            let ok = result.ok ?? false
            switch action {
            case "start":   toast = ok ? "Engine started" : "The engine didn't start"
            case "stop":    toast = ok ? "Engine stopped" : "The engine is still running"
            case "restart": toast = ok ? "Engine restarted" : "Restart failed"
            case "free":    toast = ok ? "VRAM freed" : "Nothing to free"
            default:        toast = nil
            }
        } catch {
            toast = (error as? BridgeError)?.message ?? error.localizedDescription
        }
    }

    // MARK: photos

    func save(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in self.toast = "Photos access is off. Enable it in Settings." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo,
                                                              data: image.pngData() ?? Data(),
                                                              options: nil)
            } completionHandler: { ok, _ in
                Task { @MainActor in self.toast = ok ? "Saved to Photos" : "Couldn't save to Photos" }
            }
        }
    }

    // MARK: gallery

    func loadGallery() async {
        do {
            gallery = try await client.gallery()
        } catch {
            toast = (error as? BridgeError)?.message ?? error.localizedDescription
        }
    }

    func thumbnail(for item: GalleryItem) async -> UIImage? {
        if let cached = galleryImages[item.rel] { return cached }
        guard let image = try? await client.file(rel: item.rel) else { return nil }
        galleryImages[item.rel] = image
        return image
    }

    func rotateTokenOnPC(_ newValue: String) {
        token = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
