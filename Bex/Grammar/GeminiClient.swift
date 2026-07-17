import Foundation

struct GeminiClient: LLMProviderClient {
  private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

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
    var components = URLComponents(string: Self.baseURL)!
    components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
    let request = try ProviderRequest.json(
      url: components.url!,
      method: "GET",
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .gemini
    )
    try ProviderResponse.validateStatus(response, data: data, provider: .gemini)
    let object = try ProviderResponse.object(from: data)
    let models = object["models"] as? [[String: Any]] ?? []
    return models.compactMap { model -> ModelOption? in
      guard
        let methods = model["supportedGenerationMethods"] as? [String],
        methods.contains("generateContent"),
        let rawName = model["name"] as? String
      else {
        return nil
      }
      let id = rawName.hasPrefix("models/") ? String(rawName.dropFirst(7)) : rawName
      return ModelOption(id: id, name: model["displayName"] as? String ?? id)
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
      ? LLMProvider.gemini.defaultModel
      : model
    guard let url = URL(string: "\(Self.baseURL)/\(resolvedModel):generateContent") else {
      throw BexError.modelMissing("Bad request to Gemini. Check your model name and input.")
    }
    let normalizedModel = resolvedModel.lowercased()
    var generationConfig: [String: Any] = [:]
    if !normalizedModel.hasPrefix("gemini-3") {
      generationConfig["temperature"] = temperature
    }
    if let thinkingConfig = Self.thinkingConfig(
      forNormalizedModel: normalizedModel,
      effort: effort
    ) {
      generationConfig["thinkingConfig"] = thinkingConfig
    }
    if jsonMode {
      generationConfig["responseMimeType"] = "application/json"
    }
    let body: [String: Any] = [
      "system_instruction": ["parts": [["text": systemPrompt]]],
      "contents": [["parts": [["text": text]]]],
      "generationConfig": generationConfig,
    ]
    let request = try ProviderRequest.json(
      url: url,
      headers: [
        "content-type": "application/json",
        "x-goog-api-key": apiKey,
      ],
      body: body,
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .gemini
    )
    try ProviderResponse.validateStatus(
      response,
      data: data,
      provider: .gemini,
      model: resolvedModel
    )
    let object = try ProviderResponse.object(from: data)
    guard object["error"] == nil,
      let candidates = object["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let first = parts.first
    else {
      throw BexError.invalidResponse
    }
    return try ProviderResponse.nonempty(first["text"])
  }

  private static func thinkingConfig(
    forNormalizedModel model: String,
    effort: ReasoningEffort
  ) -> [String: Any]? {
    if model.hasPrefix("gemini-3") {
      return ["thinkingLevel": effort.rawValue]
    }
    if model.hasPrefix("gemini-2.5") {
      return ["thinkingBudget": effort.geminiThinkingBudget]
    }
    return nil
  }
}
