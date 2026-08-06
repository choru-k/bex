import Foundation


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

  func makeClient(
    for destination: OutboundDestination
  ) async throws -> any LLMProviderClient {
    switch destination.provider {
    case .openAI:
      return OpenAIClient(
        apiKey: try await requiredAPIKey(for: destination.provider),
        transport: transport,
        timeout: 30
      )
    case .openAICodex:
      return OpenAICodexClient(keychain: keychain, transport: transport, timeout: 30)
    case .claude:
      return ClaudeClient(
        apiKey: try await requiredAPIKey(for: destination.provider),
        transport: transport,
        timeout: 30
      )
    case .gemini:
      return GeminiClient(
        apiKey: try await requiredAPIKey(for: destination.provider),
        transport: transport,
        timeout: 30
      )
    case .ollama:
      guard let endpoint = destination.ollamaEndpoint else {
        throw BexError.invalidOllamaURL
      }
      return OllamaClient(baseURL: endpoint, transport: transport, timeout: 60)
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
    destination: OutboundDestination,
    profilePrompt: String?
  ) async throws -> GrammarResult {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BexError.emptyInput
    }
    let client = try await factory.makeClient(for: destination)
    let effort = await factory.preferences.selectedEffort(for: destination.provider)
    return try await client.check(
      text: text,
      model: destination.model,
      systemPrompt: GrammarPrompts.buildSystemPrompt(profilePrompt: profilePrompt),
      effort: effort
    )
  }

  func checkPrompt(
    text: String,
    destination: OutboundDestination
  ) async throws -> GrammarResult {
    let protectedText = PromptTechnicalSpanProtector().protect(text)
    return try await checkPrompt(
      protectedText: protectedText,
      destination: destination
    )
  }

  func checkPrompt(
    protectedText: PromptTechnicalSpanProtector.ProtectedText,
    destination: OutboundDestination
  ) async throws -> GrammarResult {
    guard !protectedText.masked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BexError.emptyInput
    }
    let client = try await factory.makeClient(for: destination)
    let effort = await factory.preferences.selectedEffort(for: destination.provider)
    let result = try await client.check(
      text: protectedText.masked,
      model: destination.model,
      systemPrompt: GrammarPrompts.promptSafeSystem,
      effort: effort
    )
    return GrammarResult(
      corrected: try protectedText.restore(result.corrected),
      explanation: result.explanation
    )
  }

  func rewrite(
    text: String,
    intent: RewriteIntent,
    destination: OutboundDestination
  ) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BexError.emptyInput
    }
    let client = try await factory.makeClient(for: destination)
    let effort = await factory.preferences.selectedEffort(for: destination.provider)
    let output = try await client.generate(
      text: text,
      model: destination.model,
      systemPrompt: GrammarPrompts.rewriteSystemPrompt(intent: intent),
      effort: effort
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else { throw BexError.invalidResponse }
    return output
  }

  func define(
    text: String,
    destination: OutboundDestination
  ) async throws -> DictionaryLookup {
    let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { throw BexError.emptyInput }
    let client = try await factory.makeClient(for: destination)
    let effort = await factory.preferences.selectedEffort(for: destination.provider)
    let output = try await client.generate(
      text: term,
      model: destination.model,
      systemPrompt: DictionaryLookup.systemPrompt,
      effort: effort
    )
    return try DictionaryLookup.parse(output)
  }

  /// Labels each of `cards` with the `StudyPattern` it is an example of, in one call.
  ///
  /// Background-only by design. The owner's constraint is that a Quick Check must answer
  /// in about two seconds, so classification is deliberately *not* folded into the
  /// correction prompt — it runs later, off the interactive path, where latency costs
  /// nothing. Callers are expected to pass only cards that have never been classified
  /// (`StudyPatternStore.unclassifiedIDs`), which keeps the steady-state cost at zero.
  func classifyStudyPatterns(
    cards: [StudyCard],
    destination: OutboundDestination
  ) async throws -> [String: StudyPattern.Verdict] {
    guard !cards.isEmpty else { return [:] }
    let client = try await factory.makeClient(for: destination)
    let effort = await factory.preferences.selectedEffort(for: destination.provider)
    let output = try await client.generate(
      text: StudyPattern.classificationMessage(for: cards),
      model: destination.model,
      systemPrompt: StudyPattern.systemPrompt,
      effort: effort
    )
    return try StudyPattern.parseClassification(output, for: cards)
  }

  func generateProfile(
    context: ProfileContext,
    destination: OutboundDestination
  ) async throws -> String {
    let message = try GrammarPrompts.profileMessage(context: context)
    let client = try await factory.makeClient(for: destination)
    let effort = await factory.preferences.selectedEffort(for: destination.provider)
    let output = try await client.generate(
      text: message,
      model: destination.model,
      systemPrompt: GrammarPrompts.profileGeneration,
      effort: effort
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else { throw BexError.invalidResponse }
    return output
  }

  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] {
    let model = await factory.preferences.selectedModel(for: provider)
    let endpoint: String?
    if provider == .ollama {
      endpoint = await factory.preferences.ollamaURL()
    } else {
      endpoint = nil
    }
    let destination = try OutboundDestination(
      provider: provider,
      model: model,
      ollamaEndpoint: endpoint
    )
    let client = try await factory.makeClient(for: destination)
    return try await client.fetchModels()
  }
}
