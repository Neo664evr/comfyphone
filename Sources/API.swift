import Foundation
import UIKit

// MARK: - Wire types (mirror the PC bridge's JSON)

struct HealthResponse: Codable {
    let ok: Bool?
    let server: String?
    let version: String?
    let comfy: String?
    let queue: Int?
    let gpu: String?
    let vram_free_gb: Double?
    let engine_pid: Int?
}

struct EngineResponse: Codable {
    let ok: Bool?
    let comfy: String?
    let pid: Int?
    let gpu: String?
    let vram_free_gb: Double?
    let error: String?
}

struct ModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let note: String?
    let steps: Int
    let side: Int
    let eta_seconds: Int?
}

struct ModelsResponse: Codable {
    let models: [ModelInfo]
    let max_batch: Int?
    let max_side: Int?
    let edit: EditInfo?
}

struct EditInfo: Codable, Hashable {
    let model: String?
    let name: String?
    let max_refs: Int?
    let steps: Int?
    let side: Int?
    let eta_seconds: Int?
}

struct GenerateResponse: Codable {
    let job: String
    let seed: Int64?
    let eta_seconds: Int?
}

struct JobImage: Codable, Identifiable, Hashable {
    let index: Int
    let url: String
    let name: String?
    let bytes: Int?
    var id: Int { index }
}

struct JobResponse: Codable {
    let id: String
    let state: String
    let progress: Double?
    let elapsed: Double?
    let eta_seconds: Int?
    let queue: Int?
    let error: String?
    let images: [JobImage]?
    let step: Int?
    let steps_total: Int?
    let preview: Bool?
    let seed: Int64?
    let width: Int?
    let height: Int?
    let refs: Int?
}

struct GalleryItem: Codable, Identifiable, Hashable {
    let rel: String
    let mtime: Int
    let size: Int
    var id: String { rel }
    var name: String { (rel as NSString).lastPathComponent }
}

struct GalleryResponse: Codable {
    let images: [GalleryItem]
}

struct ProbeResult: Identifiable, Hashable {
    let base: String
    let ok: Bool
    let detail: String
    var id: String { base }
    var shortName: String {
        guard let host = URL(string: base)?.host else { return base }
        if host.contains("ts.net") { return "Tailscale name" }
        if host.hasPrefix("100.") { return "Tailnet IP" }
        return "\(host)"
    }
}

struct ServerError: Codable {
    let error: String?
}

// MARK: - Errors

struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Client

struct Bridge {
    var base: String
    var token: String

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil,
                             timeout: TimeInterval = 30) throws -> URLRequest {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path) else {
            throw BridgeError(message: "That server address isn't a valid URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(token, forHTTPHeaderField: "X-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw BridgeError(message: "Unexpected reply from the PC.")
            }
            if http.statusCode != 200 {
                if let err = try? JSONDecoder().decode(ServerError.self, from: data), let msg = err.error {
                    throw BridgeError(message: msg)
                }
                throw BridgeError(message: "The PC replied with error \(http.statusCode).")
            }
            return data
        } catch let err as BridgeError {
            throw err
        } catch {
            let ns = error as NSError
            throw BridgeError(message: "\(ns.localizedDescription) [\(ns.domain) \(ns.code)] at \(base)")
        }
    }

    private func send(_ path: String, method: String = "GET", body: Data? = nil,
                      timeout: TimeInterval = 30) async throws -> Data {
        try await perform(try makeRequest(path, method: method, body: body, timeout: timeout))
    }

    func health() async throws -> HealthResponse {
        try JSONDecoder().decode(HealthResponse.self, from: await send("/health"))
    }

    func models() async throws -> ModelsResponse {
        try JSONDecoder().decode(ModelsResponse.self, from: await send("/models"))
    }

    func generate(model: String, prompt: String, negative: String, width: Int, height: Int,
                  steps: Int, seed: Int64, batch: Int) async throws -> GenerateResponse {
        var payload: [String: Any] = [
            "model": model, "prompt": prompt, "negative": negative,
            "width": width, "height": height, "steps": steps, "batch": batch,
        ]
        if seed > 0 { payload["seed"] = seed }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(GenerateResponse.self, from: await send("/generate", method: "POST", body: body))
    }

    func job(id: String) async throws -> JobResponse {
        try JSONDecoder().decode(JobResponse.self, from: await send("/job?id=\(id)"))
    }

    /// The latent ComfyUI is drawing right now (a few hundred KB, PC-side only).
    func preview(id: String) async throws -> UIImage {
        let data = try await send("/preview?id=\(id)", timeout: 20)
        guard let image = UIImage(data: data) else {
            throw BridgeError(message: "The preview wasn't an image.")
        }
        return image
    }

    /// Photo(s) + instruction -> edited photo. Any number of references (bridge allows 4).
    func edit(prompt: String, negative: String, photos: [Data],
              width: Int, height: Int, steps: Int, seed: Int64,
              encoder: String) async throws -> GenerateResponse {
        let boundary = "----ComfyPhone\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        part("prompt", prompt)
        part("negative", negative)
        part("width", "\(width)")
        part("height", "\(height)")
        part("steps", "\(steps)")
        part("encoder", encoder)
        if seed > 0 { part("seed", "\(seed)") }
        for (index, photo) in photos.enumerated() {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"ref\(index + 1).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(photo)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var req = try makeRequest("/edit", method: "POST", body: body)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        return try JSONDecoder().decode(GenerateResponse.self, from: try await perform(req))
    }

    func image(id: String, index: Int) async throws -> UIImage {
        let data = try await send("/image?id=\(id)&i=\(index)")
        guard let image = UIImage(data: data) else {
            throw BridgeError(message: "The PC sent something that isn't an image.")
        }
        return image
    }

    func gallery() async throws -> [GalleryItem] {
        try JSONDecoder().decode(GalleryResponse.self, from: await send("/gallery")).images
    }

    func file(rel: String) async throws -> UIImage {
        let escaped = rel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rel
        let data = try await send("/file?rel=\(escaped)")
        guard let image = UIImage(data: data) else {
            throw BridgeError(message: "That file isn't an image.")
        }
        return image
    }

    func cancel() async throws {
        _ = try await send("/cancel", method: "POST", body: Data("{}".utf8))
    }

    func wake() async throws {
        _ = try await send("/wake", method: "POST", body: Data("{}".utf8))
    }

    /// action: "start" | "stop" | "restart" | "free" — the PC-side engine controls.
    func engine(_ action: String) async throws -> EngineResponse {
        try JSONDecoder().decode(EngineResponse.self,
                                 from: await send("/engine/\(action)", method: "POST", body: Data("{}".utf8)))
    }
}
