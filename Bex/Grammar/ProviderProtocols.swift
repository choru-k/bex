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
    destination: OutboundDestination,
    profilePrompt: String?
  ) async throws -> GrammarResult
  func rewrite(
    text: String,
    intent: RewriteIntent,
    destination: OutboundDestination
  ) async throws -> String
  func define(
    text: String,
    destination: OutboundDestination
  ) async throws -> DictionaryLookup
  /// Answers one question about a correction or a card. Off the correction path by design —
  /// `ModelJob.ask` gives it a longer budget than an interactive correction gets.
  func answerQuestion(
    question: String,
    context: String,
    destination: OutboundDestination
  ) async throws -> AskAnswer
  func classifyStudyPatterns(
    cards: [StudyCard],
    destination: OutboundDestination
  ) async throws -> [String: StudyPattern.Verdict]
  func refreshWriterLevel(
    samples: [LearningSample],
    destination: OutboundDestination,
    now: Date
  ) async throws -> WriterLevelProfile
  func generateProfile(
    context: ProfileContext,
    destination: OutboundDestination
  ) async throws -> String
  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption]
}

protocol PromptGrammarServicing: Sendable {
  func checkPrompt(
    text: String,
    destination: OutboundDestination,
    profilePrompt: String?
  ) async throws -> GrammarResult
  func checkPrompt(
    protectedText: PromptTechnicalSpanProtector.ProtectedText,
    destination: OutboundDestination,
    profilePrompt: String?
  ) async throws -> GrammarResult
}

extension PromptGrammarServicing {
  func checkPrompt(
    protectedText: PromptTechnicalSpanProtector.ProtectedText,
    destination: OutboundDestination,
    profilePrompt: String? = nil
  ) async throws -> GrammarResult {
    let result = try await checkPrompt(
      text: protectedText.masked,
      destination: destination,
      profilePrompt: profilePrompt
    )
    return GrammarResult(
      corrected: try protectedText.restore(result.corrected),
      explanation: result.explanation
    )
  }
}
