import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where completions come from.
enum AIBackendKind: String, Codable, CaseIterable, Identifiable {
    /// Apple's on-device model. No download, no model to manage, and the
    /// memory belongs to the system rather than this app.
    case appleOnDevice
    /// A local Ollama server. Needs installing, but gives a choice of models.
    case ollama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleOnDevice: return "Apple on-device"
        case .ollama:        return "Ollama (local)"
        }
    }

    var detail: String {
        switch self {
        case .appleOnDevice:
            return "Built into macOS 26. Nothing to install, no model download, and the memory is the system's, not this app's."
        case .ollama:
            return "Runs models you choose on localhost. Install separately: brew install ollama"
        }
    }
}

/// One completion request. Deliberately small: every task here is labelling,
/// not conversation, so there is no history to carry.
struct AIRequest {
    var system: String
    var prompt: String
    var maxTokens: Int = 64
}

enum AIError: Error {
    case unavailable(String)
    case failed(String)
}

protocol AIBackend: Sendable {
    func availability() async -> Result<Void, AIError>
    func complete(_ request: AIRequest) async throws -> String
}

// MARK: - Apple on-device

struct AppleOnDeviceBackend: AIBackend {
    func availability() async -> Result<Void, AIError> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .success(())
            case .unavailable(let reason):
                return .failure(.unavailable(Self.describe(reason)))
            @unknown default:
                return .failure(.unavailable("unknown state"))
            }
        }
        return .failure(.unavailable("needs macOS 26 or later"))
        #else
        return .failure(.unavailable("FoundationModels not available in this build"))
        #endif
    }

    func complete(_ request: AIRequest) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // A fresh session per request, deliberately. LanguageModelSession
            // accumulates a transcript, so a long-lived one used for thousands
            // of small classifications would grow without bound — a leak in
            // everything but name. These tasks are stateless anyway.
            let session = LanguageModelSession(instructions: request.system)
            let options = GenerationOptions(maximumResponseTokens: request.maxTokens)
            let response = try await session.respond(to: request.prompt, options: options)
            return response.content
        }
        throw AIError.unavailable("needs macOS 26 or later")
        #else
        throw AIError.unavailable("FoundationModels not available in this build")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:      return "this Mac does not support it"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is off in System Settings"
        case .modelNotReady:          return "the model is still downloading"
        @unknown default:             return "unavailable"
        }
    }
    #endif
}

// MARK: - Ollama

struct OllamaBackend: AIBackend {
    var model: String
    var host = "http://localhost:11434"
    /// How long Ollama keeps the model resident after a request. Short, so an
    /// idle terminal is not holding gigabytes hostage.
    var keepAlive = "2m"

    func availability() async -> Result<Void, AIError> {
        guard let url = URL(string: "\(host)/api/tags") else {
            return .failure(.unavailable("bad host"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let listing = try? JSONDecoder().decode(OllamaTags.self, from: data) else {
                return .failure(.unavailable("unexpected response"))
            }
            guard listing.models.contains(where: { $0.name == model || $0.model == model }) else {
                return .failure(.unavailable("model “\(model)” not pulled — run: ollama pull \(model)"))
            }
            return .success(())
        } catch {
            return .failure(.unavailable("Ollama is not running"))
        }
    }

    func complete(_ request: AIRequest) async throws -> String {
        guard let url = URL(string: "\(host)/api/generate") else {
            throw AIError.failed("bad host")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Generous but bounded: a hung model must not wedge the scheduler.
        urlRequest.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "system": request.system,
            "prompt": request.prompt,
            "stream": false,
            "keep_alive": keepAlive,
            "options": [
                "num_predict": request.maxTokens,
                // Deterministic-ish: these are classifications, not prose.
                "temperature": 0.1,
            ],
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.failed("Ollama returned an error")
        }
        guard let decoded = try? JSONDecoder().decode(OllamaGenerate.self, from: data) else {
            throw AIError.failed("could not parse response")
        }
        return decoded.response
    }
}

struct OllamaTags: Decodable {
    struct Model: Decodable {
        var name: String
        var model: String?
        var size: Int64?
    }
    var models: [Model]
}

private struct OllamaGenerate: Decodable {
    var response: String
}
