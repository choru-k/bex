import Foundation

struct OpenAIClient: LLMProviderClient {
  private static let chatURL = URL(string: "https://api.openai.com/v1/chat/completions")!
  private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
  private static let chatPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]

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
      temperature: 0.3,
      jsonMode: true,
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
      jsonMode: false,
      effort: effort
    )
  }

  func fetchModels() async throws -> [ModelOption] {
    let request = try ProviderRequest.json(
      url: Self.modelsURL,
      method: "GET",
      headers: ["Authorization": "Bearer \(apiKey)"],
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .openAI
    )
    try ProviderResponse.validateStatus(response, data: data, provider: .openAI)
    let object = try ProviderResponse.object(from: data)
    let models = object["data"] as? [[String: Any]] ?? []
    return models.compactMap { model -> ModelOption? in
      guard let id = model["id"] as? String,
        !id.contains(":"),
        Self.chatPrefixes.contains(where: id.hasPrefix)
      else {
        return nil
      }
      return ModelOption(id: id, name: id)
    }.sorted { $0.name < $1.name }
  }

  private func request(
    text: String,
    model: String,
    systemPrompt: String,
    temperature: Double,
    jsonMode: Bool,
    effort: ReasoningEffort
  ) async throws -> String {
    let resolvedModel =
      model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? LLMProvider.openAI.defaultModel
      : model
    var body: [String: Any] = [
      "model": resolvedModel,
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": text],
      ],
      "temperature": temperature,
    ]
    if Self.supportsReasoningEffort(resolvedModel) {
      body["reasoning_effort"] = effort.rawValue
    }
    if jsonMode {
      body["response_format"] = ["type": "json_object"]
    }
    let request = try ProviderRequest.json(
      url: Self.chatURL,
      headers: [
        "Authorization": "Bearer \(apiKey)",
        "Content-Type": "application/json",
      ],
      body: body,
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .openAI
    )
    try ProviderResponse.validateStatus(
      response,
      data: data,
      provider: .openAI,
      model: resolvedModel
    )
    let object = try ProviderResponse.object(from: data)
    guard
      let choices = object["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any]
    else {
      throw BexError.invalidResponse
    }
    return try ProviderResponse.nonempty(message["content"])
  }

  private static func supportsReasoningEffort(_ model: String) -> Bool {
    model.hasPrefix("gpt-5") || model.hasPrefix("o1") || model.hasPrefix("o3")
      || model.hasPrefix("o4")
  }
}
