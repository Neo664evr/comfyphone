import Foundation

@main struct DiffusionFileTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func uint(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8((value >> ($0 * 8)) & 255) }) }
        func string(_ value: String) -> Data { let bytes = Data(value.utf8); return uint(UInt64(bytes.count), 8) + bytes }
        func fixture(_ arch: String, embedding: UInt64 = 4096, name: String = "token_embd.weight") -> Data {
            var data = Data("GGUF".utf8) + uint(3, 4) + uint(1, 8) + uint(5, 8)
            data += string("general.architecture") + uint(8, 4) + string(arch)
            data += string(arch + ".embedding_length") + uint(4, 4) + uint(embedding, 4)
            data += string(arch + ".block_count") + uint(4, 4) + uint(36, 4)
            data += string(arch + ".vision.block_count") + uint(4, 4) + uint(24, 4)
            data += string("tokenizer.ggml.tokens") + uint(9, 4) + uint(8, 4) + uint(2, 8) + string("one") + string("two")
            data += string(name) + uint(2, 4) + uint(4096, 8) + uint(1, 8) + uint(0, 4) + uint(0, 8)
            data += Data(repeating: 0, count: 32)
            return data
        }
        let encoder = folder.appendingPathComponent("encoder.gguf")
        try fixture("qwen3vl").write(to: encoder)
        let info = try GGUFInspection.read(encoder)
        precondition(info.isQwenImageEncoder && info.isLanguageModel)
        let (size, digest) = try DiffusionFiles.digest(encoder)
        let actualSize = try Data(contentsOf: encoder).count
        precondition(size == Int64(actualSize) && digest.count == 64)
        let validatedArchitecture = try DiffusionFiles.validate(role: .encoder, url: encoder, bytes: size, sha: digest)
        precondition(validatedArchitecture == "qwen3vl")
        func mustReject(_ block: () throws -> Void) {
            do { try block(); preconditionFailure("Invalid component was accepted") }
            catch { precondition(error is DiffusionFileError) }
        }
        mustReject { _ = try DiffusionFiles.validate(role: .denoiser, url: encoder, bytes: 5_287_517_120, sha: DiffusionFiles.atomicEncoderSHA) }
        mustReject { _ = try DiffusionFiles.validate(role: .vae, url: encoder, bytes: size, sha: digest) }
        mustReject { _ = try DiffusionFiles.validate(role: .denoiser, url: encoder, bytes: 4_201_694_943, sha: DiffusionFiles.turboSHA) }
        let wrong = folder.appendingPathComponent("wrong.gguf")
        try fixture("qwen3vl", embedding: 12288).write(to: wrong)
        mustReject { _ = try DiffusionFiles.validate(role: .encoder, url: wrong, bytes: size, sha: digest) }
        try fixture("qwen2vl").write(to: wrong)
        mustReject { _ = try DiffusionFiles.validate(role: .encoder, url: wrong, bytes: size, sha: digest) }
        try fixture("", name: "double_blocks.0.img_attn.qkv.weight").write(to: wrong)
        let diffusionInfo = try GGUFInspection.read(wrong)
        precondition(!diffusionInfo.isLanguageModel, "Diffusion weights must not enter chat")
        try Data("GGUF".utf8).write(to: wrong)
        mustReject { _ = try GGUFInspection.read(wrong) }
        try Data("not a model".utf8).write(to: wrong)
        mustReject { _ = try GGUFInspection.read(wrong) }
        let empty = folder.appendingPathComponent("empty.gguf")
        try Data().write(to: empty)
        mustReject { _ = try GGUFInspection.read(empty) }
        print("Component tests passed: bounded GGUF parser, encoder architecture/shape, role mismatch, digest, truncation and chat exclusion")
    }
}
