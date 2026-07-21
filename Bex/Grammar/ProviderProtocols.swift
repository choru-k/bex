import Foundation

protocol LLMProviderClient: Sendable {
  func check(
    text: String,
    model: String,
    systemPrompt: String,
    effort: ReasoningEffort
  ) async throws -> GrammarResult
  func generate(
    text: String,
    model: String,
    systemPrompt: String,
    effort: ReasoningEffort
  ) async throws -> String
  func fetchModels() async throws -> [ModelOption]
}

protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw BexError.invalidResponse
    }
    return (data, response)
  }
}

protocol GrammarServicing: Sendable {
  func check(
    text: String,
    provider: LLMProvider,
    model: String,
    profilePrompt: String?
  ) async throws -> GrammarResult
  func rewrite(
    text: String,
    intent: RewriteIntent,
    provider: LLMProvider,
    model: String
  ) async throws -> String
  func generateProfile(
    context: ProfileContext,
    provider: LLMProvider,
    model: String
  ) async throws -> String
  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption]
}

protocol PromptGrammarServicing: Sendable {
  func checkPrompt(
    text: String,
    provider: LLMProvider,
    model: String
  ) async throws -> GrammarResult
}
