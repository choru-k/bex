import Foundation

public enum BexError: LocalizedError, Equatable, Sendable {
  case emptyInput
  case profileContextRequired
  case invalidOllamaURL
  case oauthFailure(String)
  case missingSetup(LLMProvider)
  case unauthorized(LLMProvider)
  case rateLimited
  case timeout
  case connectionFailure(String)
  case modelMissing(String)
  case providerHTTPStatus(Int)
  case invalidResponse
  case storageFailure(String)
  case cancellation

  public var errorDescription: String? {
    switch self {
    case .emptyInput:
      "Enter text to check."
    case .profileContextRequired:
      "Fill in at least one profile context field."
    case .invalidOllamaURL:
      "Enter a valid Ollama URL."
    case .oauthFailure(let message):
      message
    case .missingSetup(let provider):
      switch provider {
      case .openAICodex:
        "OpenAI Codex is not connected. Connect in Settings."
      case .ollama:
        "Enter a valid Ollama URL in Settings."
      default:
        "Add your \(provider.displayName) API key in Settings."
      }
    case .unauthorized(let provider):
      if provider == .openAICodex {
        "OpenAI Codex login expired. Reconnect in Settings."
      } else {
        "\(provider.displayName) rejected the credential. Update it in Settings."
      }
    case .rateLimited:
      "The provider rate limit was reached. Try again shortly."
    case .timeout:
      "The request timed out. Try again."
    case .connectionFailure(let message):
      message
    case .modelMissing(let message):
      message
    case .providerHTTPStatus(let status):
      "The provider returned HTTP \(status). Try again."
    case .invalidResponse:
      "The provider returned an invalid response. Try again."
    case .storageFailure(let message):
      message
    case .cancellation:
      nil
    }
  }
}
