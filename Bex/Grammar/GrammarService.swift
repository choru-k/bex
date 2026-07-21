import Foundation

enum OllamaURL {
  static func normalize(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.host?.isEmpty == false
    else {
      throw BexError.invalidOllamaURL
    }
    components.scheme = scheme
    guard var normalized = components.url?.absoluteString else {
      throw BexError.invalidOllamaURL
    }
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }
}

struct ProviderClientFactory: Sendable {
  let preferences: PreferencesStore
  let keychain: KeychainStore
  let transport: any HTTPTransport

  init(
    preferences: PreferencesStore,
    keychain: KeychainStore,
    transport: any HTTPTransport
  ) {
    self.preferences = preferences
    self.keychain = keychain
    self.transport = transport
  }

  func makeClient(for provider: LLMProvider) async throws -> any LLMProviderClient {
    switch provider {
    case .openAI:
      return OpenAIClient(
        apiKey: try await requiredAPIKey(for: provider),
        transport: transport,
        timeout: 30
      )
    case .openAICodex:
      return OpenAICodexClient(keychain: keychain, transport: transport, timeout: 30)
    case .claude:
      return ClaudeClient(
        apiKey: try await requiredAPIKey(for: provider),
        transport: transport,
        timeout: 30
      )
    case .gemini:
      return GeminiClient(
        apiKey: try await requiredAPIKey(for: provider),
        transport: transport,
        timeout: 30
      )
    case .ollama:
      let baseURL = try OllamaURL.normalize(await preferences.ollamaURL())
      return OllamaClient(baseURL: baseURL, transport: transport, timeout: 60)
    }
  }

  private func requiredAPIKey(for provider: LLMProvider) async throws -> String {
    guard let apiKey = try await keychain.apiKey(for: provider),
      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw BexError.missingSetup(provider)
    }
    return apiKey
  }
}

actor GrammarService: GrammarServicing, PromptGrammarServicing {
  private let factory: ProviderClientFactory

  init(factory: ProviderClientFactory) {
    self.factory = factory
  }

  func check(
    text: String,
    provider: LLMProvider,
    model: String,
    profilePrompt: String?
  ) async throws -> GrammarResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BexError.emptyInput
    }
    let client = try await factory.makeClient(for: provider)
    let effort = await factory.preferences.selectedEffort(for: provider)
    return try await client.check(
      text: text,
      model: resolvedModel(model, provider: provider),
      systemPrompt: GrammarPrompts.buildSystemPrompt(profilePrompt: profilePrompt),
      effort: effort
    )
  }

  func checkPrompt(
    text: String,
    provider: LLMProvider,
    model: String
  ) async throws -> GrammarResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BexError.emptyInput
    }
    let protected = PromptTechnicalSpanProtector().protect(text)
    let client = try await factory.makeClient(for: provider)
    let effort = await factory.preferences.selectedEffort(for: provider)
    let result = try await client.check(
      text: protected.masked,
      model: resolvedModel(model, provider: provider),
      systemPrompt: GrammarPrompts.promptSafeSystem,
      effort: effort
    )
    return GrammarResult(
      corrected: try protected.restore(result.corrected),
      explanation: result.explanation
    )
  }

  func rewrite(
    text: String,
    intent: RewriteIntent,
    provider: LLMProvider,
    model: String
  ) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BexError.emptyInput
    }
    let client = try await factory.makeClient(for: provider)
    let effort = await factory.preferences.selectedEffort(for: provider)
    let output = try await client.generate(
      text: text,
      model: resolvedModel(model, provider: provider),
      systemPrompt: GrammarPrompts.rewriteSystemPrompt(intent: intent),
      effort: effort
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else { throw BexError.invalidResponse }
    return output
  }

  func generateProfile(
    context: ProfileContext,
    provider: LLMProvider,
    model: String
  ) async throws -> String {
    let message = try GrammarPrompts.profileMessage(context: context)
    let client = try await factory.makeClient(for: provider)
    let effort = await factory.preferences.selectedEffort(for: provider)
    let output = try await client.generate(
      text: message,
      model: resolvedModel(model, provider: provider),
      systemPrompt: GrammarPrompts.profileGeneration,
      effort: effort
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else { throw BexError.invalidResponse }
    return output
  }

  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] {
    let client = try await factory.makeClient(for: provider)
    return try await client.fetchModels()
  }

  private func resolvedModel(_ model: String, provider: LLMProvider) -> String {
    model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? provider.defaultModel
      : model
  }
}
