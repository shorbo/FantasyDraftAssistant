import Foundation
import Observation

// OpenRouter's public model catalog and API-key validation, used by the
// setup screen and the in-draft advisor to let the user browse/search
// models and confirm their key works before they're mid-draft.
enum OpenRouterAPI {
    private static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    private static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

    struct ModelInfo: Identifiable, Sendable, Hashable {
        let id: String
        let name: String?
        let contextLength: Int?
        let supportsReasoning: Bool

        // "1M ctx", "200K ctx", or the raw number for odd sizes.
        var contextLengthLabel: String? {
            guard let contextLength else { return nil }
            if contextLength >= 1_000_000, contextLength.isMultiple(of: 1_000_000) {
                return "\(contextLength / 1_000_000)M ctx"
            }
            if contextLength >= 1_000 {
                return "\(contextLength / 1_000)K ctx"
            }
            return "\(contextLength) ctx"
        }
    }

    static func fetchModelList() async throws -> [ModelInfo] {
        let (data, response) = try await URLSession.shared.data(from: modelsURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Decodable {
            struct Model: Decodable {
                let id: String
                let name: String?
                let contextLength: Int?
                let supportedParameters: [String]?

                enum CodingKeys: String, CodingKey {
                    case id, name
                    case contextLength = "context_length"
                    case supportedParameters = "supported_parameters"
                }
            }
            let data: [Model]
        }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        return decoded.data
            .map {
                ModelInfo(
                    id: $0.id,
                    name: $0.name,
                    contextLength: $0.contextLength,
                    supportsReasoning: $0.supportedParameters?.contains("reasoning") ?? false
                )
            }
            .sorted { $0.id < $1.id }
    }

    enum KeyValidation: Sendable {
        case valid(label: String?)
        case invalid(String)
    }

    // GET /key with the bearer token returns account info for a valid key
    // and 401 for an invalid one — used purely as a validity check.
    static func validateKey(_ apiKey: String) async throws -> KeyValidation {
        var request = URLRequest(url: keyURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 {
            return .invalid("Invalid OpenRouter API key.")
        }
        guard (200..<300).contains(status) else {
            return .invalid("Could not validate key (HTTP \(status)).")
        }

        struct Envelope: Decodable {
            struct Info: Decodable { let label: String? }
            let data: Info
        }
        let label = (try? JSONDecoder().decode(Envelope.self, from: data))?.data.label
        return .valid(label: label)
    }
}

// Fetched once and shared across the setup screen and the in-draft advisor,
// so both can show model metadata (context window, reasoning support)
// without each re-fetching the catalog.
@MainActor
@Observable
final class OpenRouterModelCache {
    static let shared = OpenRouterModelCache()

    private(set) var models: [OpenRouterAPI.ModelInfo] = []
    private var loadTask: Task<Void, Never>?

    private init() {}

    func ensureLoaded() async {
        if !models.isEmpty { return }
        if let loadTask { await loadTask.value; return }
        let task = Task {
            self.models = (try? await OpenRouterAPI.fetchModelList()) ?? []
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func info(for modelId: String) -> OpenRouterAPI.ModelInfo? {
        models.first { $0.id == modelId }
    }
}
