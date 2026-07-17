import Foundation

struct OllamaClient: LLMProviderClient {
  private let baseURL: String
  private let transport: any HTTPTransport
  private let timeout: TimeInterval

  init(baseURL: String, transport: any HTTPTransport, timeout: TimeInterval = 60) {
    self.baseURL = baseURL
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
      jsonMode: false,
      effort: effort
    )
  }

  func fetchModels() async throws -> [ModelOption] {
    guard let url = URL(string: "\(baseURL)/api/tags") else {
      throw BexError.invalidOllamaURL
    }
    let request = try ProviderRequest.json(
      url: url,
      method: "GET",
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .ollama,
      ollamaURL: baseURL
    )
    try ProviderResponse.validateStatus(
      response,
      data: data,
      provider: .ollama,
      ollamaURL: baseURL
    )
    let object = try ProviderResponse.object(from: data)
    let models = object["models"] as? [[String: Any]] ?? []
    return models.compactMap { model -> ModelOption? in
      guard let name = model["name"] as? String else { return nil }
      return ModelOption(id: name, name: name)
    }.sorted { $0.name < $1.name }
  }

  private func request(
    text: String,
    model: String,
    systemPrompt: String,
    jsonMode: Bool,
    effort: ReasoningEffort
  ) async throws -> String {
    let resolvedModel =
      model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? LLMProvider.ollama.defaultModel
      : model
    guard let url = URL(string: "\(baseURL)/api/chat") else {
      throw BexError.invalidOllamaURL
    }
    var body: [String: Any] = [
      "model": resolvedModel,
      "stream": false,
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": text],
      ],
    ]
    if Self.supportsThinking(resolvedModel), effort.enablesOllamaThinking {
      body["think"] = true
    }
    if jsonMode {
      body["format"] = "json"
    }
    let request = try ProviderRequest.json(
      url: url,
      headers: ["content-type": "application/json"],
      body: body,
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .ollama,
      ollamaURL: baseURL
    )
    try ProviderResponse.validateStatus(
      response,
      data: data,
      provider: .ollama,
      model: resolvedModel,
      ollamaURL: baseURL
    )
    let object = try ProviderResponse.object(from: data)
    guard let message = object["message"] as? [String: Any] else {
      throw BexError.invalidResponse
    }
    return try ProviderResponse.nonempty(message["content"])
  }

  private static func supportsThinking(_ model: String) -> Bool {
    let normalized = model.lowercased()
    return normalized.hasPrefix("qwen3")
      || normalized.hasPrefix("deepseek-r1")
      || normalized.hasPrefix("gpt-oss")
      || normalized.hasPrefix("magistral")
  }
}
