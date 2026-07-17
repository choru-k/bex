import Foundation

struct ClaudeClient: LLMProviderClient {
  private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
  private static let modelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!

  private let apiKey: String
  private let transport: any HTTPTransport
  private let timeout: TimeInterval

  init(apiKey: String, transport: any HTTPTransport, timeout: TimeInterval = 30) {
    self.apiKey = apiKey
    self.transport = transport
    self.timeout = timeout
  }

  func check(
    text: String,
    model: String,
    systemPrompt: String,
    effort: ReasoningEffort = .medium
  ) async throws -> GrammarResult {
    let content = try await request(
      text: text,
      model: model,
      systemPrompt: systemPrompt,
      temperature: nil,
      effort: effort
    )
    return try GrammarResponseParser.parse(content)
  }

  func generate(
    text: String,
    model: String,
    systemPrompt: String,
    effort: ReasoningEffort = .medium
  ) async throws -> String {
    try await request(
      text: text,
      model: model,
      systemPrompt: systemPrompt,
      temperature: 0.7,
      effort: effort
    )
  }

  func fetchModels() async throws -> [ModelOption] {
    let request = try ProviderRequest.json(
      url: Self.modelsURL,
      method: "GET",
      headers: [
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      ],
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .claude
    )
    try ProviderResponse.validateStatus(response, data: data, provider: .claude)
    let object = try ProviderResponse.object(from: data)
    let models = object["data"] as? [[String: Any]] ?? []
    return models.compactMap { model -> ModelOption? in
      guard let id = model["id"] as? String else { return nil }
      return ModelOption(id: id, name: model["display_name"] as? String ?? id)
    }.sorted { $0.name < $1.name }
  }

  private func request(
    text: String,
    model: String,
    systemPrompt: String,
    temperature: Double?,
    effort: ReasoningEffort
  ) async throws -> String {
    let resolvedModel =
      model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? LLMProvider.claude.defaultModel
      : model
    let adaptiveThinking = Self.supportsAdaptiveThinking(resolvedModel)
    let thinkingBudget =
      adaptiveThinking ? nil : Self.supportedThinkingBudget(for: resolvedModel, effort: effort)
    var body: [String: Any] = [
      "model": resolvedModel,
      "max_tokens": adaptiveThinking ? 4_096 : (thinkingBudget ?? 0) + 1_024,
      "system": systemPrompt,
      "messages": [["role": "user", "content": text]],
    ]
    if adaptiveThinking {
      body["thinking"] = ["type": "adaptive", "display": "omitted"]
    } else if let thinkingBudget {
      body["thinking"] = [
        "type": "enabled",
        "budget_tokens": thinkingBudget,
        "display": "omitted",
      ]
    }
    if Self.supportsEffort(resolvedModel) {
      body["output_config"] = ["effort": effort.rawValue]
    }
    if let temperature, !adaptiveThinking, thinkingBudget == nil {
      body["temperature"] = temperature
    }
    let request = try ProviderRequest.json(
      url: Self.messagesURL,
      headers: [
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      ],
      body: body,
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .claude
    )
    try ProviderResponse.validateStatus(
      response,
      data: data,
      provider: .claude,
      model: resolvedModel
    )
    let object = try ProviderResponse.object(from: data)
    guard let content = object["content"] as? [[String: Any]],
      let textBlock = content.first(where: { $0["text"] != nil })
    else {
      throw BexError.invalidResponse
    }
    return try ProviderResponse.nonempty(textBlock["text"])
  }

  private static func supportsAdaptiveThinking(_ model: String) -> Bool {
    let normalized = model.lowercased()
    return normalized.contains("fable-5")
      || normalized.contains("mythos-5")
      || normalized.contains("mythos-preview")
      || normalized.contains("opus-4-8")
      || normalized.contains("opus-4-7")
      || normalized.contains("opus-4-6")
      || normalized.contains("sonnet-5")
      || normalized.contains("sonnet-4-6")
  }

  private static func supportsEffort(_ model: String) -> Bool {
    supportsAdaptiveThinking(model) || model.lowercased().contains("opus-4-5")
  }

  private static func supportedThinkingBudget(
    for model: String,
    effort: ReasoningEffort
  ) -> Int? {
    let normalized = model.lowercased()
    return normalized.contains("opus-4-1")
      || normalized.contains("opus-4-202")
      || normalized.contains("sonnet-4")
      || normalized.contains("haiku-4-5")
      || normalized.contains("sonnet-3-7")
      ? effort.claudeThinkingBudgetTokens
      : nil
  }
}
