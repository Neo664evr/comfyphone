import Foundation
import CryptoKit

enum ImageComponent: String, CaseIterable, Identifiable, Codable {
    case denoiser, encoder, vae
    var id: String { rawValue }
    var title: String {
        switch self { case .denoiser: return "Turbo image denoiser"; case .encoder: return "Qwen3-VL 8B text encoder"; case .vae: return "Qwen Image 2.1 VAE" }
    }
    var explanation: String {
        switch self {
        case .denoiser: return "Creates image latents. Select AtomicChat Qwen-Image-2.1-Turbo-AD-Q4_K.gguf (4.20 GB)."
        case .encoder: return "Turns your prompt into conditioning. The 5.29 GB AtomicChat Uncensored GGUF is ONLY this component, not an image denoiser. Official Qwen3-VL-8B GGUF also works with this runtime."
        case .vae: return "Decodes latents to pixels. Select qwen_image_2.1_vae_bf16.safetensors (675.5 MB); older Qwen/Wan VAEs are incompatible."
        }
    }
}

struct ImageComponentFile: Codable, Equatable {
    let role: ImageComponent
    let filename: String
    let originalName: String
    let bytes: Int64
    let sha256: String
    let architecture: String
}

struct DiffusionFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Bounded, streaming GGUF metadata parser. Never maps a multi-GB model into Swift Data.
/// Unknown types, impossible counts, missing tensors and truncated headers fail closed.
struct GGUFInspection {
    let architecture: String
    let embeddingLength: UInt64
    let blockCount: UInt64
    let tensorNames: Set<String>
    var isLanguageModel: Bool { !architecture.isEmpty && tensorNames.contains("token_embd.weight") }
    var isQwenImageEncoder: Bool {
        architecture == "qwen3vl" && embeddingLength == 4096 && blockCount == 36 && isLanguageModel
    }

    static func read(_ url: URL) throws -> GGUFInspection {
        let reader = try GGUFReader(url)
        defer { try? reader.file.close() }
        guard try reader.bytes(4) == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw DiffusionFileError(message: "Not a GGUF model. Image diffusion and VAE files belong in On iPhone, not Chat.")
        }
        let version = try reader.integer(4)
        guard version == 2 || version == 3 else { throw DiffusionFileError(message: "Unsupported GGUF version") }
        let tensors = try reader.integer(8), metadata = try reader.integer(8)
        guard tensors > 0 && tensors <= 200_000 && metadata <= 100_000 else {
            throw DiffusionFileError(message: "Invalid GGUF counts")
        }
        var architecture = ""
        var lengths: [String: UInt64] = [:]
        for _ in 0..<metadata {
            let key = try reader.string()
            let type = try reader.integer(4)
            if key == "general.architecture" && type == 8 { architecture = try reader.string() }
            else if (key.hasSuffix(".embedding_length") || key.hasSuffix(".block_count")) && type == 4 { lengths[key] = try reader.integer(4) }
            else { try reader.skipValue(type, depth: 0) }
        }
        var names = Set<String>()
        for _ in 0..<tensors {
            let name = try reader.string()
            let dimensions = try reader.integer(4)
            guard (1...4).contains(dimensions) else { throw DiffusionFileError(message: "Invalid tensor dimensions") }
            for _ in 0..<dimensions {
                let size = try reader.integer(8)
                guard size > 0 && size <= 1_000_000_000 else { throw DiffusionFileError(message: "Invalid tensor shape") }
            }
            _ = try reader.integer(4) // tensor type; native loader performs full tensor validation
            let offset = try reader.integer(8)
            guard offset < reader.size else { throw DiffusionFileError(message: "Tensor points outside the model") }
            names.insert(name)
        }
        guard reader.position < reader.size else { throw DiffusionFileError(message: "GGUF has no tensor data") }
        return GGUFInspection(architecture: architecture, embeddingLength: lengths[architecture + ".embedding_length"] ?? 0,
                              blockCount: lengths[architecture + ".block_count"] ?? 0, tensorNames: names)
    }
}

private final class GGUFReader {
    let file: FileHandle
    let size: UInt64
    var position: UInt64 = 0
    private var buffer = Data()
    private var bufferStart: UInt64 = 0
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        size = try file.seekToEnd()
        try file.seek(toOffset: 0)
    }
    func bytes(_ count: Int) throws -> Data {
        guard count >= 0 && UInt64(count) <= size - min(position, size), position < 64 << 20 else {
            throw DiffusionFileError(message: "GGUF header is truncated or too large")
        }
        if position < bufferStart || position + UInt64(count) > bufferStart + UInt64(buffer.count) {
            try file.seek(toOffset: position)
            bufferStart = position
            buffer = try file.read(upToCount: max(64 << 10, count)) ?? Data()
        }
        let start = Int(position - bufferStart)
        guard start + count <= buffer.count else { throw DiffusionFileError(message: "Truncated GGUF") }
        let data = buffer.subdata(in: start..<(start + count))
        position += UInt64(count)
        return data
    }
    func integer(_ count: Int) throws -> UInt64 {
        let data = try bytes(count)
        return data.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
    func string() throws -> String {
        let count = try integer(8)
        guard count <= 1 << 20 else { throw DiffusionFileError(message: "Invalid GGUF string length") }
        guard let string = String(data: try bytes(Int(count)), encoding: .utf8) else { throw DiffusionFileError(message: "Invalid GGUF text") }
        return string
    }
    func skip(_ count: UInt64) throws {
        guard count <= size - min(position, size), position + count <= 64 << 20 else { throw DiffusionFileError(message: "GGUF header exceeds safe bounds") }
        position += count
    }
    func skipValue(_ type: UInt64, depth: Int) throws {
        guard depth < 3 else { throw DiffusionFileError(message: "Invalid nested GGUF metadata") }
        switch type {
        case 0, 1, 7: try skip(1)
        case 2, 3: try skip(2)
        case 4, 5, 6: try skip(4)
        case 10, 11, 12: try skip(8)
        case 8:
            let length = try integer(8)
            guard length <= 1 << 20 else { throw DiffusionFileError(message: "Invalid metadata string") }
            try skip(length)
        case 9:
            let element = try integer(4), count = try integer(8)
            guard count <= 2_000_000, element != 9 else { throw DiffusionFileError(message: "Invalid metadata array") }
            // Strings (including tokenizer vocabulary) are skipped one at a time; no huge arrays are allocated.
            for _ in 0..<count { try skipValue(element, depth: depth + 1) }
        default: throw DiffusionFileError(message: "Unknown GGUF metadata type")
        }
    }
}

enum DiffusionFiles {
    static let turboSHA = "4bb73c53cbe284bbd6d69b9fdc59539c531f0389dd2aa567663d777f8130bc59"
    static let vaeSHA = "bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9"
    static let atomicEncoderSHA = "8123f36d2b3e562deef164dffdae33bdb1d152797ad10bb630827eaa7bce795d"

    static func validate(role: ImageComponent, url: URL, bytes: Int64, sha: String) throws -> String {
        switch role {
        case .denoiser:
            guard sha == turboSHA && bytes == 4_201_694_944 else {
                if sha == atomicEncoderSHA { throw DiffusionFileError(message: "This AtomicChat Uncensored file is a TEXT ENCODER. Import it in the encoder slot; you still need the Turbo image denoiser.") }
                throw DiffusionFileError(message: "Wrong or incomplete denoiser. This Turbo preset requires the exact AtomicChat Turbo AD Q4_K image weights (SHA-256 checked), not a chat model or regular Qwen Image.")
            }
            _ = try GGUFInspection.read(url)
            return "Qwen Image 2.1 Turbo AD"
        case .encoder:
            let info = try GGUFInspection.read(url)
            guard info.isQwenImageEncoder else {
                throw DiffusionFileError(message: "Expected a Qwen3-VL 8B GGUF text encoder (4096-wide, 36 layers). Diffusion weights, a projector alone, and Qwen2.5 are not valid here.")
            }
            return info.architecture
        case .vae:
            guard sha == vaeSHA && bytes == 675_509_688 else {
                throw DiffusionFileError(message: "Wrong or incomplete VAE. Choose the Qwen Image 2.1 BF16 VAE, not the older Qwen/Wan VAE. SHA-256 validation failed.")
            }
            return "Qwen Image 2.1 VAE"
        }
    }

    static func digest(_ url: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var hash = SHA256(), count: Int64 = 0
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
            count += Int64(data.count)
            if size > 0 { progress(Double(count) / Double(size)) }
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
