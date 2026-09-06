import Foundation
import UIKit

struct ImageCapabilities {
    let understandsImages: Bool
    let generatesImages: Bool
}

protocol ImageUnderstanding {

    func understand(imageData: Data, mimeType: String, prompt: String) async throws -> String
}

struct GeneratedImage {
    var data: Data
    var mimeType: String = "image/png"
}

enum ImageGenerationError: LocalizedError {
    case unavailable
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected provider does not support image generation."
        case .requestFailed(let m): return m
        }
    }
}

protocol ImageGenerating {
    func generate(prompt: String, size: String?) async throws -> GeneratedImage
}

@MainActor
final class ImagePipeline: ImageUnderstanding, ImageGenerating {

    static let shared = ImagePipeline()

    var activeProvider: () -> ProviderConfig? = { nil }

    var apiKeyFor: (ProviderConfig) -> String? = { _ in nil }

    private let llm = LLMService()

    private init() {}

    func capabilities(for config: ProviderConfig) -> ImageCapabilities {

        let understands = config.supportsVision
        let generates = config.apiFormat == .openAI && !config.baseURL.isEmpty
        return ImageCapabilities(understandsImages: understands, generatesImages: generates)
    }

    func understand(imageData: Data, mimeType: String, prompt: String) async throws -> String {
        guard let config = activeProvider(), let key = apiKeyFor(config) else {
            throw ImageGenerationError.unavailable
        }
        guard config.supportsVision else {
            throw ImageGenerationError.unavailable
        }
        let base64 = imageData.base64EncodedString()
        let reply = try await llm.complete(
            config: config,
            apiKey: key,
            history: [
                .system("You are an image analyst. Describe what you see, including any text and UI elements. Be concise."),
                .userVision(text: prompt, imageBase64: base64, mimeType: mimeType)
            ],
            tools: []
        )
        return reply.text ?? ""
    }

    func generate(prompt: String, size: String? = nil) async throws -> GeneratedImage {
        guard let config = activeProvider(), let key = apiKeyFor(config) else {
            throw ImageGenerationError.unavailable
        }
        guard config.apiFormat == .openAI, let url = Self.generationURL(for: config) else {
            throw ImageGenerationError.unavailable
        }

        var body: [String: Any] = [
            "model": config.model,
            "prompt": prompt,
            "n": 1,
            "response_format": "b64_json"
        ]
        if let size { body["size"] = size }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ImageGenerationError.requestFailed("Image endpoint returned HTTP \(status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let first = items.first else {
            throw ImageGenerationError.requestFailed("Unexpected image response.")
        }
        if let b64 = first["b64_json"] as? String, let data = Data(base64Encoded: b64) {
            return GeneratedImage(data: data, mimeType: "image/png")
        }
        if let raw = first["url"] as? String, let url = URL(string: raw),
           let (imgData, _) = try? await URLSession.shared.data(from: url) {
            return GeneratedImage(data: imgData, mimeType: "image/png")
        }
        throw ImageGenerationError.requestFailed("Image response had no usable data.")
    }

    static func generationURL(for config: ProviderConfig) -> URL? {
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/images/generations") { return URL(string: base) }
        if base.hasSuffix("/chat/completions") {
            return URL(string: String(base.dropLast("/chat/completions".count)) + "/images/generations")
        }
        return URL(string: base + "/images/generations")
    }
}
