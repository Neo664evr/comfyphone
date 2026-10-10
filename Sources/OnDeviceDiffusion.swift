import Foundation
import UIKit
import CryptoKit

/// UI state stays on the main actor; a single serial queue owns the blocking C runtime.
/// No bridge URL, PC health request or network operation is used by this engine.
@MainActor final class OnDeviceDiffusion: ObservableObject {
    static let shared = OnDeviceDiffusion()
    private static let worker = DispatchQueue(label: "comfyphone.image-runtime", qos: .userInitiated)
    @Published private(set) var files: [ImageComponent: ImageComponentFile] = [:]
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var status = "Select three image components from Files"
    @Published private(set) var progress: Double = 0
    @Published private(set) var operation = ""
    @Published private(set) var images: [URL] = []
    @Published private(set) var availableMemory: UInt64 = 0
    @Published private(set) var cancelling = false
    private var importTask: Task<ImageComponentFile, Error>?
    private var monitor: Task<Void, Never>?
    private var warningObserver: NSObjectProtocol?
    private var mustUnload = false

    static var modelsDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ImageModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var outputDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("GeneratedImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var manifest: URL { modelsDirectory.appendingPathComponent("components.json") }
    var allComponentsSelected: Bool { ImageComponent.allCases.allSatisfy { files[$0] != nil } }

    private init() {
        if let data = try? Data(contentsOf: Self.manifest), let saved = try? JSONDecoder().decode([ImageComponentFile].self, from: data) {
            for file in saved where file.filename == URL(fileURLWithPath: file.filename).lastPathComponent {
                let path = Self.modelsDirectory.appendingPathComponent(file.filename)
                if FileManager.default.fileExists(atPath: path.path) { files[file.role] = file }
            }
        }
        refreshImages()
        refreshMemory()
        warningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let engine = OnDeviceDiffusion.shared
                engine.mustUnload = true
                if engine.busy { engine.cancel(); engine.status = "iOS memory warning · cancelling, then unloading" }
                else if engine.loaded { await engine.unload() }
            }
        }
    }
    func refreshMemory() { availableMemory = cpd_available_memory() }
    func refreshImages() {
        images = ((try? FileManager.default.contentsOfDirectory(at: Self.outputDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    private func persist() throws {
        let data = try JSONEncoder().encode(Array(files.values))
        try data.write(to: Self.manifest, options: .atomic)
    }

    func importFile(_ url: URL, role: ImageComponent) async {
        guard !busy else { return }
        if loaded { await unload() }
        busy = true; cancelling = false; operation = "Importing \(role.title)"; progress = 0
        status = "Copying from Files and checking SHA-256…"
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let directory = Self.modelsDirectory
        importTask = Task.detached(priority: .userInitiated) {
            try Self.copyComponent(url, role: role, directory: directory) { fraction in
                Task { @MainActor in OnDeviceDiffusion.shared.progress = fraction }
            }
        }
        do {
            guard let importTask else { throw CancellationError() }
            let file = try await importTask.value
            let old = files[role]
            files[role] = file
            do { try persist() }
            catch {
                files[role] = old
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.filename))
                throw error
            }
            if let old { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.filename)) }
            status = "Validated \(role.title) · \(file.originalName)"
            progress = 1
        } catch {
            status = cancelling ? "Import cancelled · previous component preserved" : "Import failed: \(error.localizedDescription)"
        }
        importTask = nil; busy = false; cancelling = false; operation = ""
        refreshMemory()
    }

    nonisolated private static func copyComponent(_ source: URL, role: ImageComponent, directory: URL,
                                                   progress: @escaping (Double) -> Void) throws -> ImageComponentFile {
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
        let expected = Int64(sourceValues.fileSize ?? 0)
        guard expected > 0 else { throw DiffusionFileError(message: "File is empty or unavailable. Download it from iCloud in Files first.") }
        let space = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = space.volumeAvailableCapacityForImportantUsage, free > expected + (256 << 20) else {
            throw DiffusionFileError(message: "Not enough storage to copy this model. Import keeps your original Files document unchanged.")
        }
        let filename = UUID().uuidString + "." + (role == .vae ? "safetensors" : "gguf")
        let destination = directory.appendingPathComponent(filename)
        let partial = directory.appendingPathComponent(filename + ".partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: partial); try? FileManager.default.removeItem(at: destination) } }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: partial)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256(), copied: Int64 = 0
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            hash.update(data: chunk)
            copied += Int64(chunk.count)
            progress(min(0.99, Double(copied) / Double(expected)))
        }
        try output.synchronize()
        guard copied == expected else { throw DiffusionFileError(message: "The source changed or the copy was incomplete") }
        let sha = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let architecture = try DiffusionFiles.validate(role: role, url: partial, bytes: copied, sha: sha)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: destination)
        committed = true
        return ImageComponentFile(role: role, filename: filename, originalName: source.lastPathComponent,
                                  bytes: copied, sha256: sha, architecture: architecture)
    }

    func remove(_ role: ImageComponent) async {
        guard !busy else { return }
        if loaded { await unload() }
        guard let old = files[role] else { return }
        files[role] = nil
        do { try persist(); try FileManager.default.removeItem(at: Self.modelsDirectory.appendingPathComponent(old.filename)) }
        catch { status = "Remove failed: \(error.localizedDescription)" }
    }

    func load(cpuOnly: Bool = false) async {
        guard !busy && allComponentsSelected else { return }
        guard !LocalAI.shared.working else { status = "Stop chat/vision inference before loading image generation"; return }
        LocalAI.shared.unload()
        busy = true; cancelling = false; operation = "Checking image components"; progress = 0
        let snapshot = files
        let directory = Self.modelsDirectory
        do {
            // App Documents is editable through Files. Re-check every digest before handing any
            // selected path to C++; stale selections and overwritten models must fail closed.
            try await Task.detached(priority: .userInitiated) {
                for role in ImageComponent.allCases {
                    guard let file = snapshot[role] else { throw DiffusionFileError(message: "Missing \(role.title)") }
                    let path = directory.appendingPathComponent(file.filename)
                    let (bytes, sha) = try DiffusionFiles.digest(path)
                    guard bytes == file.bytes && sha == file.sha256 else { throw DiffusionFileError(message: "\(role.title) changed after import; import it again") }
                    _ = try DiffusionFiles.validate(role: role, url: path, bytes: bytes, sha: sha)
                }
            }.value
            guard !cancelling else { throw CancellationError() }
            operation = "Loading image runtime"
            startMonitor()
            let denoiser = directory.appendingPathComponent(snapshot[.denoiser]!.filename).path
            let encoder = directory.appendingPathComponent(snapshot[.encoder]!.filename).path
            let vae = directory.appendingPathComponent(snapshot[.vae]!.filename).path
            let result: Int32 = await Self.native { cpd_load(denoiser, encoder, vae, cpuOnly ? 1 : 0) }
            loaded = result != 0
            status = Self.nativeStatus()
        } catch { status = cancelling ? "Load cancelled" : "Load refused: \(error.localizedDescription)" }
        await finish()
    }

    func generate(prompt: String, side: Int, seed: Int64) async {
        guard !busy && loaded else { return }
        guard DiffusionPolicy.validSize(side, side), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Enter a prompt and a supported output size"; return
        }
        busy = true; cancelling = false; operation = "Encoding prompt → 8 Euler steps → PNG"; progress = 0
        let filename = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString + ".png"
        let output = Self.outputDirectory.appendingPathComponent(filename)
        startMonitor()
        let result: Int32 = await Self.native { cpd_generate(prompt, Int32(side), Int32(side), seed, output.path) }
        status = Self.nativeStatus()
        if result == 0 { try? FileManager.default.removeItem(at: output) }
        else {
            let metadata: [String: Any] = ["prompt": prompt, "seed": seed, "width": side, "height": side,
                                          "engine": "on-iphone", "sampler": "euler", "steps": 8, "cfg": 1,
                                          "components": files.mapValues { $0.sha256 }.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value }]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            }
        }
        refreshImages()
        await finish()
    }

    func cancel() {
        guard busy else { return }
        cancelling = true
        importTask?.cancel()
        cpd_cancel()
        status = "Cancellation requested. Native loading/hash checks finish safely before returning; sampling stops cooperatively."
    }
    func unload() async {
        guard !busy else { return }
        busy = true; operation = "Unloading image runtime"
        await Self.native { cpd_unload() }
        loaded = false; busy = false; operation = ""; status = Self.nativeStatus(); refreshMemory()
    }
    private func finish() async {
        monitor?.cancel(); monitor = nil
        if mustUnload || cancelling {
            await Self.native { cpd_unload() }
            loaded = false; mustUnload = false
        }
        busy = false; cancelling = false; operation = ""; refreshMemory()
    }
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.progress = Double(cpd_progress()) / 100
                if !self.cancelling { self.status = Self.nativeStatus() }
                self.refreshMemory()
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }
    nonisolated private static func native<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in worker.async { continuation.resume(returning: work()) } }
    }
    nonisolated private static func nativeStatus() -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        cpd_status(&buffer, Int32(buffer.count))
        return String(cString: buffer)
    }
}
