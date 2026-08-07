import Foundation

actor OpenAICodexClient: LLMProviderClient {
  private static let responsesURL = URL(
    string: "https://chatgpt.com/backend-api/codex/responses"
  )!
  private static let modelsURL = URL(
    string: "https://chatgpt.com/backend-api/codex/models"
  )!
  private static let apiClientVersion = "0.144.1"

  private let keychain: KeychainStore
  private let transport: any HTTPTransport
  private let timeout: TimeInterval
  /// Ask for the priority ("Fast") service tier on every request. Off unless the owner
  /// turned it on in Settings — see `PreferencesStore.codexPriorityTier()` for why it is
  /// opt-in rather than a default.
  private let usesPriorityTier: Bool

  init(
    keychain: KeychainStore,
    transport: any HTTPTransport,
    timeout: TimeInterval = 30,
    usesPriorityTier: Bool = false
  ) {
    self.keychain = keychain
    self.transport = transport
    self.timeout = timeout
    self.usesPriorityTier = usesPriorityTier
  }

  func check(
    text: String,
    model: String,
    systemPrompt: String,
    effort: ReasoningEffort = .medium
  ) async throws -> GrammarResult {
    try GrammarResponseParser.parse(
      try await request(text: text, model: model, systemPrompt: systemPrompt, effort: effort)
    )
  }

  func generate(
    text: String,
    model: String,
    systemPrompt: String,
    effort: ReasoningEffort = .medium
  ) async throws -> String {
    try await request(text: text, model: model, systemPrompt: systemPrompt, effort: effort)
  }

  func fetchModels() async throws -> [ModelOption] {
    let session = try await validSession()
    var components = URLComponents(
      url: Self.modelsURL,
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "client_version", value: Self.apiClientVersion)
    ]
    guard let url = components.url else { throw BexError.invalidResponse }
    let request = try ProviderRequest.json(
      url: url,
      method: "GET",
      headers: [
        "Authorization": "Bearer \(session.accessToken)",
        "chatgpt-account-id": session.accountID,
        "originator": "bex",
        "accept": "application/json",
      ],
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .openAICodex
    )
    try ProviderResponse.validateStatus(
      response,
      data: data,
      provider: .openAICodex
    )
    let object = try ProviderResponse.object(from: data)
    let models = object["models"] as? [[String: Any]] ?? []
    let options = models.compactMap { model -> ModelOption? in
      guard model["visibility"] as? String != "hide",
        let id = model["slug"] as? String,
        !id.isEmpty
      else {
        return nil
      }
      let name = model["display_name"] as? String ?? id
      return ModelOption(id: id, name: name)
    }.sorted { $0.name < $1.name }
    guard !options.isEmpty else { throw BexError.invalidResponse }
    return options
  }

  private func request(
    text: String,
    model: String,
    systemPrompt: String,
    effort: ReasoningEffort
  ) async throws -> String {
    let session = try await validSession()
    let resolvedModel =
      model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? LLMProvider.openAICodex.defaultModel
      : model
    // Verified against the endpoint before shipping: an unknown value is rejected with
    // `400 Unsupported service_tier`, so the backend genuinely parses this rather than
    // ignoring it. Omitted entirely when off, which leaves the account's default tier.
    var body: [String: Any] = [
      "model": resolvedModel,
      "store": false,
      "stream": true,
      "instructions": systemPrompt,
      "input": [
        [
          "role": "user",
          "content": [["type": "input_text", "text": text]],
        ]
      ],
      "reasoning": ["effort": effort.rawValue],
      "text": ["verbosity": "medium"],
    ]
    if usesPriorityTier {
      body["service_tier"] = "priority"
    }
    let request = try ProviderRequest.json(
      url: Self.responsesURL,
      headers: [
        "Authorization": "Bearer \(session.accessToken)",
        "chatgpt-account-id": session.accountID,
        "OpenAI-Beta": "responses=experimental",
        "originator": "bex",
        "accept": "text/event-stream",
        "content-type": "application/json",
      ],
      body: body,
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .openAICodex
    )
    try ProviderResponse.validateStatus(
      response,
      data: data,
      provider: .openAICodex,
      model: resolvedModel
    )
    return try CodexResponseParser.extract(from: data)
  }

  private func validSession() async throws -> CodexSession {
    guard let session = try await keychain.codexSession() else {
      throw BexError.missingSetup(.openAICodex)
    }
    if session.expiresAt.timeIntervalSinceNow > 30 {
      return session
    }
    let refreshed = try await CodexOAuthService.refresh(
      session: session,
      transport: transport,
      timeout: timeout
    )
    try await keychain.saveCodexSession(refreshed)
    return refreshed
  }
}

enum CodexResponseParser {
  static func extract(from data: Data) throws -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      guard object["error"] == nil else { throw BexError.invalidResponse }
      let direct = object["output_text"] as? String ?? ""
      let content = direct.isEmpty ? completedText(from: object) : direct
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw BexError.invalidResponse }
      return trimmed
    }

    guard let raw = String(data: data, encoding: .utf8) else {
      throw BexError.invalidResponse
    }
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    var output = ""
    var completedResponse: [String: Any]?

    for chunk in normalized.components(separatedBy: "\n\n") {
      let payload =
        chunk
        .components(separatedBy: "\n")
        .filter { $0.hasPrefix("data:") }
        .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !payload.isEmpty, payload != "[DONE]",
        let payloadData = payload.data(using: .utf8),
        let event = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
      else {
        continue
      }

      switch event["type"] as? String {
      case "response.output_text.delta":
        if let delta = event["delta"] as? String {
          output += delta
        }
      case "response.output_text.done":
        if output.isEmpty, let text = event["text"] as? String {
          output = text
        }
      case "response.completed", "response.done":
        completedResponse = event["response"] as? [String: Any]
      default:
        break
      }
    }

    if output.isEmpty, let completedResponse {
      output = completedText(from: completedResponse)
    }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw BexError.invalidResponse }
    return trimmed
  }

  private static func completedText(from response: [String: Any]) -> String {
    guard let output = response["output"] as? [[String: Any]] else { return "" }
    var chunks: [String] = []
    for item in output where item["type"] as? String == "message" {
      guard let content = item["content"] as? [[String: Any]] else { continue }
      for part in content where part["type"] as? String == "output_text" {
        if let text = part["text"] as? String {
          chunks.append(text)
        }
      }
    }
    return chunks.joined()
  }
}
