import Foundation
import XCTest

@testable import Bex

actor ScriptedHTTPTransport: HTTPTransport {
  enum Outcome: Sendable {
    case response(Data, Int)
    case urlError(URLError.Code)
    case cancellation
  }

  private var outcomes: [Outcome]
  private var requests: [URLRequest] = []

  init(_ outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard !outcomes.isEmpty else {
      throw URLError(.badServerResponse)
    }
    switch outcomes.removeFirst() {
    case .response(let data, let status):
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (data, response)
    case .urlError(let code):
      throw URLError(code)
    case .cancellation:
      throw CancellationError()
    }
  }

  func recordedRequests() -> [URLRequest] {
    requests
  }
}

struct ModelCatalogGrammarStub: GrammarServicing {
  let catalogs: [LLMProvider: [ModelOption]]

  func check(
    text: String,
    destination: OutboundDestination,
    profilePrompt: String?
  ) async throws -> GrammarResult {
    throw BexError.invalidResponse
  }

  func rewrite(
    text: String,
    intent: RewriteIntent,
    destination: OutboundDestination
  ) async throws -> String {
    throw BexError.invalidResponse
  }

  func define(
    text: String,
    destination: OutboundDestination
  ) async throws -> DictionaryLookup {
    throw BexError.invalidResponse
  }

  func classifyStudyPatterns(

    cards: [StudyCard],

    destination: OutboundDestination

  ) async throws -> [String: StudyPattern.Verdict] {

    [:]

  }

  func refreshWriterLevel(
    samples: [LearningSample],
    destination: OutboundDestination,
    now: Date
  ) async throws -> WriterLevelProfile {
    throw BexError.invalidResponse
  }


  func generateProfile(
    context: ProfileContext,
    destination: OutboundDestination
  ) async throws -> String {
    throw BexError.invalidResponse
  }

  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] {
    catalogs[provider] ?? []
  }
}

final class ProviderOAuthRegressionTests: XCTestCase {
  private let grammarJSON =
    #"{"corrected":"This is a test.","explanation":"Fixed agreement."}"#

  func testClaudeRequestContractAndDefaultModel() async throws {
    let payload = try jsonData([
      "content": [
        ["type": "thinking", "thinking": "summary"],
        ["type": "text", "text": grammarJSON],
      ]
    ])
    let transport = ScriptedHTTPTransport([.response(payload, 200)])
    let client = ClaudeClient(apiKey: "claude-secret", transport: transport)

    let result = try await client.check(
      text: "This are a test.",
      model: "",
      systemPrompt: "system prompt"
    )

    XCTAssertEqual(result.corrected, "This is a test.")
    let recordedRequests = await transport.recordedRequests()
    let request = try XCTUnwrap(recordedRequests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "claude-secret")
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    let body = try requestJSONObject(request)
    XCTAssertEqual(body["model"] as? String, LLMProvider.claude.defaultModel)
    XCTAssertEqual(body["system"] as? String, "system prompt")
    XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
    XCTAssertNil(body["temperature"])
    let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "adaptive")
    XCTAssertNil(thinking["budget_tokens"])
    XCTAssertEqual(thinking["display"] as? String, "omitted")
    let outputConfig = try XCTUnwrap(body["output_config"] as? [String: String])
    XCTAssertEqual(outputConfig["effort"], "medium")
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    XCTAssertEqual(messages, [["role": "user", "content": "This are a test."]])
  }
  func testClaudeAdaptiveModelsOmitUnsupportedSamplingOverrides() async throws {
    let payload = try jsonData([
      "content": [["type": "text", "text": "Rewritten."]]
    ])
    let transport = ScriptedHTTPTransport([.response(payload, 200)])
    let client = ClaudeClient(apiKey: "claude-secret", transport: transport)

    let result = try await client.generate(
      text: "Rewrite me.",
      model: LLMProvider.claude.defaultModel,
      systemPrompt: "system prompt"
    )

    XCTAssertEqual(result, "Rewritten.")
    let recordedRequests = await transport.recordedRequests()
    let request = try XCTUnwrap(recordedRequests.first)
    let body = try requestJSONObject(request)
    XCTAssertNil(body["temperature"])
    XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "adaptive")
    XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "medium")
  }

  func testGeminiRequestContractAndDefaultModel() async throws {
    let payload = try jsonData([
      "candidates": [["content": ["parts": [["text": grammarJSON]]]]]
    ])
    let transport = ScriptedHTTPTransport([.response(payload, 200)])
    let client = GeminiClient(apiKey: "gemini-secret", transport: transport)

    let result = try await client.check(
      text: "This are a test.",
      model: "  ",
      systemPrompt: "system prompt"
    )

    XCTAssertEqual(result.corrected, "This is a test.")
    let recordedRequests = await transport.recordedRequests()
    let request = try XCTUnwrap(recordedRequests.first)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://generativelanguage.googleapis.com/v1beta/models/\(LLMProvider.gemini.defaultModel):generateContent"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-secret")
    let body = try requestJSONObject(request)
    let system = try XCTUnwrap(body["system_instruction"] as? [String: Any])
    let systemParts = try XCTUnwrap(system["parts"] as? [[String: String]])
    XCTAssertEqual(systemParts, [["text": "system prompt"]])
    let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
    let userParts = try XCTUnwrap(contents.first?["parts"] as? [[String: String]])
    XCTAssertEqual(userParts, [["text": "This are a test."]])
    let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
    XCTAssertNil(config["temperature"])
    XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
    let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: String])
    XCTAssertEqual(thinking["thinkingLevel"], "medium")
  }

  func testOllamaRequestContractAndDefaultModel() async throws {
    let payload = try jsonData([
      "message": ["content": grammarJSON]
    ])
    let transport = ScriptedHTTPTransport([.response(payload, 200)])
    let client = OllamaClient(baseURL: "http://localhost:11434", transport: transport)

    let result = try await client.check(
      text: "This are a test.",
      model: "\n",
      systemPrompt: "system prompt"
    )

    XCTAssertEqual(result.corrected, "This is a test.")
    let recordedRequests = await transport.recordedRequests()
    let request = try XCTUnwrap(recordedRequests.first)
    XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/chat")
    let body = try requestJSONObject(request)
    XCTAssertEqual(body["model"] as? String, LLMProvider.ollama.defaultModel)
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual(body["format"] as? String, "json")
    XCTAssertNil(body["think"])
    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
    XCTAssertEqual(
      messages,
      [
        ["role": "system", "content": "system prompt"],
        ["role": "user", "content": "This are a test."],
      ]
    )
  }

  func testOllamaEnablesThinkingForThinkingModels() async throws {
    let payload = try jsonData([
      "message": ["content": grammarJSON]
    ])
    let transport = ScriptedHTTPTransport([.response(payload, 200)])
    let client = OllamaClient(baseURL: "http://localhost:11434", transport: transport)

    _ = try await client.check(
      text: "This are a test.",
      model: "qwen3",
      systemPrompt: "system prompt"
    )

    let recordedRequests = await transport.recordedRequests()
    let request = try XCTUnwrap(recordedRequests.first)
    let body = try requestJSONObject(request)
    XCTAssertEqual(body["model"] as? String, "qwen3")
    XCTAssertEqual(body["think"] as? Bool, true)
  }

  func testCodexRequestContractJSONResponseAndDefaultModel() async throws {
    let keychain = KeychainStore(service: "com.bex.tests.codex.\(UUID())", inMemory: true)
    try await keychain.saveCodexSession(
      CodexSession(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expiresAt: Date().addingTimeInterval(3_600),
        accountID: "account-123"
      )
    )
    let payload = try jsonData(["output_text": grammarJSON])
    let transport = ScriptedHTTPTransport([.response(payload, 200)])
    let client = OpenAICodexClient(keychain: keychain, transport: transport)

    let result = try await client.check(
      text: "This are a test.",
      model: "",
      systemPrompt: "system prompt"
    )

    XCTAssertEqual(result.corrected, "This is a test.")
    let recordedRequests = await transport.recordedRequests()
    let request = try XCTUnwrap(recordedRequests.first)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://chatgpt.com/backend-api/codex/responses"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "account-123")
    XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
    XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "bex")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    let body = try requestJSONObject(request)
    XCTAssertEqual(body["model"] as? String, LLMProvider.openAICodex.defaultModel)
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["instructions"] as? String, "system prompt")
    XCTAssertEqual((body["text"] as? [String: String])?["verbosity"], "medium")
    XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "medium")
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertEqual(input.first?["role"] as? String, "user")
    let content = try XCTUnwrap(input.first?["content"] as? [[String: String]])
    XCTAssertEqual(content, [["type": "input_text", "text": "This are a test."]])
  }

  func testEveryProviderModelCatalogEndpointAndFiltering() async throws {
    let openAITransport = ScriptedHTTPTransport([
      .response(
        try jsonData([
          "data": [
            ["id": "text-embedding-3-small"],
            ["id": "o3-mini"],
            ["id": "gpt-z"],
            ["id": "gpt-fine:tuned"],
          ]
        ]),
        200
      )
    ])
    let openAIModels = try await OpenAIClient(
      apiKey: "openai-secret",
      transport: openAITransport
    ).fetchModels()
    XCTAssertEqual(
      openAIModels,
      [
        ModelOption(id: "gpt-z", name: "gpt-z"),
        ModelOption(id: "o3-mini", name: "o3-mini"),
      ]
    )
    let openAIRequests = await openAITransport.recordedRequests()
    let openAIRequest = try XCTUnwrap(openAIRequests.first)
    XCTAssertEqual(openAIRequest.httpMethod, "GET")
    XCTAssertEqual(openAIRequest.url?.absoluteString, "https://api.openai.com/v1/models")
    XCTAssertEqual(
      openAIRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer openai-secret"
    )

    let claudeTransport = ScriptedHTTPTransport([
      .response(
        try jsonData([
          "data": [
            ["id": "claude-z", "display_name": "Zeta"],
            ["id": "claude-a", "display_name": "Alpha"],
            ["id": "claude-fallback"],
          ]
        ]),
        200
      )
    ])
    let claudeModels = try await ClaudeClient(
      apiKey: "claude-secret",
      transport: claudeTransport
    ).fetchModels()
    XCTAssertEqual(
      claudeModels,
      [
        ModelOption(id: "claude-a", name: "Alpha"),
        ModelOption(id: "claude-z", name: "Zeta"),
        ModelOption(id: "claude-fallback", name: "claude-fallback"),
      ]
    )
    let claudeRequests = await claudeTransport.recordedRequests()
    let claudeRequest = try XCTUnwrap(claudeRequests.first)
    XCTAssertEqual(claudeRequest.httpMethod, "GET")
    XCTAssertEqual(
      claudeRequest.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
    XCTAssertEqual(claudeRequest.value(forHTTPHeaderField: "x-api-key"), "claude-secret")
    XCTAssertEqual(
      claudeRequest.value(forHTTPHeaderField: "anthropic-version"),
      "2023-06-01"
    )

    let geminiTransport = ScriptedHTTPTransport([
      .response(
        try jsonData([
          "models": [
            [
              "name": "models/gemini-z",
              "displayName": "Zeta",
              "supportedGenerationMethods": ["generateContent"],
            ],
            [
              "name": "models/gemini-a",
              "displayName": "Alpha",
              "supportedGenerationMethods": ["generateContent", "countTokens"],
            ],
            [
              "name": "models/embedding-only",
              "supportedGenerationMethods": ["embedContent"],
            ],
          ]
        ]),
        200
      )
    ])
    let geminiModels = try await GeminiClient(
      apiKey: "gemini secret",
      transport: geminiTransport
    ).fetchModels()
    XCTAssertEqual(
      geminiModels,
      [
        ModelOption(id: "gemini-a", name: "Alpha"),
        ModelOption(id: "gemini-z", name: "Zeta"),
      ]
    )
    let geminiRequests = await geminiTransport.recordedRequests()
    let geminiRequest = try XCTUnwrap(geminiRequests.first)
    XCTAssertEqual(geminiRequest.httpMethod, "GET")
    XCTAssertEqual(
      geminiRequest.url?.absoluteString,
      "https://generativelanguage.googleapis.com/v1beta/models?key=gemini%20secret"
    )

    let ollamaTransport = ScriptedHTTPTransport([
      .response(
        try jsonData([
          "models": [
            ["name": "z-model:latest"],
            ["name": "a-model:latest"],
            ["digest": "missing-name"],
          ]
        ]),
        200
      )
    ])
    let ollamaModels = try await OllamaClient(
      baseURL: "http://localhost:11434",
      transport: ollamaTransport
    ).fetchModels()
    XCTAssertEqual(
      ollamaModels,
      [
        ModelOption(id: "a-model:latest", name: "a-model:latest"),
        ModelOption(id: "z-model:latest", name: "z-model:latest"),
      ]
    )
    let ollamaRequests = await ollamaTransport.recordedRequests()
    let ollamaRequest = try XCTUnwrap(ollamaRequests.first)
    XCTAssertEqual(ollamaRequest.httpMethod, "GET")
    XCTAssertEqual(ollamaRequest.url?.absoluteString, "http://localhost:11434/api/tags")

    let codexKeychain = KeychainStore(
      service: "com.bex.tests.dynamic-models",
      inMemory: true
    )
    try await codexKeychain.saveCodexSession(
      CodexSession(
        accessToken: "codex-access",
        refreshToken: "codex-refresh",
        expiresAt: Date().addingTimeInterval(3_600),
        accountID: "codex-account"
      )
    )
    let codexTransport = ScriptedHTTPTransport([
      .response(
        try jsonData([
          "models": [
            [
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6-Sol",
              "visibility": "list",
            ],
            [
              "slug": "gpt-5.4-mini",
              "display_name": "GPT-5.4-Mini",
              "visibility": "list",
            ],
            [
              "slug": "codex-auto-review",
              "display_name": "Codex Auto Review",
              "visibility": "hide",
            ],
            ["display_name": "Missing slug", "visibility": "list"],
          ]
        ]),
        200
      )
    ])
    let codexModels = try await OpenAICodexClient(
      keychain: codexKeychain,
      transport: codexTransport
    ).fetchModels()
    XCTAssertEqual(
      codexModels,
      [
        ModelOption(id: "gpt-5.4-mini", name: "GPT-5.4-Mini"),
        ModelOption(id: "gpt-5.6-sol", name: "GPT-5.6-Sol"),
      ]
    )
    let codexRequests = await codexTransport.recordedRequests()
    let codexRequest = try XCTUnwrap(codexRequests.first)
    XCTAssertEqual(codexRequest.httpMethod, "GET")
    XCTAssertEqual(
      codexRequest.url?.absoluteString,
      "https://chatgpt.com/backend-api/codex/models?client_version=0.144.1"
    )
    XCTAssertEqual(
      codexRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer codex-access"
    )
    XCTAssertEqual(
      codexRequest.value(forHTTPHeaderField: "chatgpt-account-id"),
      "codex-account"
    )
    XCTAssertEqual(codexRequest.value(forHTTPHeaderField: "originator"), "bex")
    XCTAssertEqual(codexRequest.value(forHTTPHeaderField: "Accept"), "application/json")
  }
  func testEveryProviderUsesOnlyFetchedModelsAndReplacesUnavailableSelection() async throws {
    for provider in LLMProvider.allCases {
      let suite = "com.bex.tests.settings-models.\(provider.rawValue).\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
      let preferences = PreferencesStore(defaults: defaults)
      await preferences.setSelectedProvider(provider)
      await preferences.setSelectedModel("unavailable-model", for: provider)
      let replacement = ModelOption(
        id: "\(provider.rawValue)-available",
        name: "\(provider.displayName) Available"
      )

      await Self.assertCatalogReplacement(
        provider: provider,
        preferences: preferences,
        replacement: replacement
      )
    }
  }

  @MainActor
  private static func assertCatalogReplacement(
    provider: LLMProvider,
    preferences: PreferencesStore,
    replacement: ModelOption
  ) async {
    let keychain = KeychainStore(
      service: "com.bex.tests.settings-models.\(UUID())",
      inMemory: true
    )
    let transport = ScriptedHTTPTransport([])
    let viewModel = SettingsViewModel(
      preferences: preferences,
      keychain: keychain,
      grammar: ModelCatalogGrammarStub(catalogs: [provider: [replacement]]),
      codexOAuth: CodexOAuthService(keychain: keychain, transport: transport),
      applyAppearance: { _ in }
    )

    await viewModel.load()

    XCTAssertEqual(viewModel.model, replacement.id)
    XCTAssertEqual(viewModel.models, [replacement])
    let persisted = await preferences.selectedModel(for: provider)
    XCTAssertEqual(persisted, replacement.id)
    viewModel.close()
  }

  func testProviderStatusMatrix() throws {
    let url = URL(string: "https://example.invalid")!
    for provider in LLMProvider.allCases {
      XCTAssertEqual(
        capturedStatusError(status: 401, provider: provider, url: url),
        .unauthorized(provider)
      )
      let expected403: BexError =
        provider == .gemini || provider == .openAICodex
        ? .unauthorized(provider)
        : .providerHTTPStatus(403)
      XCTAssertEqual(
        capturedStatusError(status: 403, provider: provider, url: url),
        expected403
      )
      XCTAssertEqual(
        capturedStatusError(status: 429, provider: provider, url: url),
        .rateLimited
      )
      XCTAssertEqual(
        capturedStatusError(status: 503, provider: provider, url: url),
        .providerHTTPStatus(503)
      )
    }
    XCTAssertEqual(
      capturedStatusError(status: 400, provider: .gemini, url: url),
      .modelMissing("Bad request to Gemini. Check your model name and input.")
    )
    let codexResponse = HTTPURLResponse(
      url: url,
      statusCode: 400,
      httpVersion: nil,
      headerFields: nil
    )!
    let codexDetail = Data(
      #"{"detail":"The selected model is not supported with a ChatGPT account."}"#.utf8
    )
    XCTAssertThrowsError(
      try ProviderResponse.validateStatus(
        codexResponse,
        data: codexDetail,
        provider: .openAICodex
      )
    ) { error in
      XCTAssertEqual(
        error as? BexError,
        .modelMissing("The selected model is not supported with a ChatGPT account.")
      )
    }
  }

  func testEveryProviderMapsTimeoutAndCancellation() async {
    let request = URLRequest(url: URL(string: "https://example.invalid")!)
    for provider in LLMProvider.allCases {
      let timeoutTransport = ScriptedHTTPTransport([.urlError(.timedOut)])
      let timeoutError = await capturedError {
        _ = try await ProviderResponse.data(
          for: request,
          transport: timeoutTransport,
          provider: provider,
          ollamaURL: provider == .ollama ? "http://localhost:11434" : nil
        )
      }
      XCTAssertEqual(timeoutError, .timeout, "timeout mapping for \(provider)")

      let cancellationTransport = ScriptedHTTPTransport([.cancellation])
      let cancellationError = await capturedError {
        _ = try await ProviderResponse.data(
          for: request,
          transport: cancellationTransport,
          provider: provider,
          ollamaURL: provider == .ollama ? "http://localhost:11434" : nil
        )
      }
      XCTAssertEqual(cancellationError, .cancellation, "cancellation mapping for \(provider)")
    }
  }

  func testMissingCredentialAndSessionForEveryAuthenticatedProvider() async {
    let suite = "com.bex.tests.missing.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let keychain = KeychainStore(service: suite, inMemory: true)
    let factory = ProviderClientFactory(
      preferences: PreferencesStore(defaults: defaults),
      keychain: keychain,
      transport: ScriptedHTTPTransport([])
    )

    for provider in [LLMProvider.openAI, .claude, .gemini] {
      let error = await capturedError {
        _ = try await factory.makeClient(
          for: OutboundDestination(provider: provider, model: provider.defaultModel)
        )
      }
      XCTAssertEqual(error, .missingSetup(provider))
    }

    let codex = OpenAICodexClient(keychain: keychain, transport: ScriptedHTTPTransport([]))
    let codexError = await capturedError {
      _ = try await codex.generate(text: "text", model: "", systemPrompt: "system")
    }
    XCTAssertEqual(codexError, .missingSetup(.openAICodex))
  }

  func testEveryProviderRejectsMalformedAndEmptySuccessPayloads() async throws {
    let validSession = CodexSession(
      accessToken: "token",
      refreshToken: "refresh",
      expiresAt: Date().addingTimeInterval(3_600),
      accountID: "account"
    )

    let malformedClients: [any LLMProviderClient] = [
      OpenAIClient(
        apiKey: "key",
        transport: ScriptedHTTPTransport([.response(Data("not-json".utf8), 200)])
      ),
      ClaudeClient(
        apiKey: "key",
        transport: ScriptedHTTPTransport([.response(Data("not-json".utf8), 200)])
      ),
      GeminiClient(
        apiKey: "key",
        transport: ScriptedHTTPTransport([.response(Data("not-json".utf8), 200)])
      ),
      OllamaClient(
        baseURL: "http://localhost:11434",
        transport: ScriptedHTTPTransport([.response(Data("not-json".utf8), 200)])
      ),
      try await codexClient(session: validSession, payload: Data("not-json".utf8)),
    ]
    for client in malformedClients {
      let error = await capturedError {
        _ = try await client.generate(
          text: "text", model: "model", systemPrompt: "system", effort: .medium)
      }
      XCTAssertEqual(error, .invalidResponse)
    }

    let emptyClients: [any LLMProviderClient] = [
      OpenAIClient(
        apiKey: "key",
        transport: ScriptedHTTPTransport([
          .response(try jsonData(["choices": [["message": ["content": ""]]]]), 200)
        ])
      ),
      ClaudeClient(
        apiKey: "key",
        transport: ScriptedHTTPTransport([
          .response(try jsonData(["content": [["text": ""]]]), 200)
        ])
      ),
      GeminiClient(
        apiKey: "key",
        transport: ScriptedHTTPTransport([
          .response(
            Data(
              #"{"candidates":[{"content":{"parts":[{"text":""}]}}]}"#.utf8
            ),
            200
          )
        ])
      ),
      OllamaClient(
        baseURL: "http://localhost:11434",
        transport: ScriptedHTTPTransport([
          .response(try jsonData(["message": ["content": ""]]), 200)
        ])
      ),
      try await codexClient(session: validSession, payload: try jsonData(["output_text": ""])),
    ]
    for client in emptyClients {
      let error = await capturedError {
        _ = try await client.generate(
          text: "text", model: "model", systemPrompt: "system", effort: .medium)
      }
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testCodexPKCEFlowStateMismatchAndIncompleteRefresh() async throws {
    XCTAssertEqual(
      CodexOAuthService.pkceChallenge(
        for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      ),
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    )
    let flow = try CodexOAuthService.makeFlow(loopbackAvailable: false)
    let components = try XCTUnwrap(
      URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false)
    )
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    XCTAssertEqual(query["client_id"], CodexOAuthService.clientID)
    XCTAssertEqual(query["redirect_uri"], CodexOAuthService.redirectURI)
    XCTAssertEqual(query["code_challenge"], CodexOAuthService.pkceChallenge(for: flow.verifier))
    XCTAssertEqual(query["code_challenge_method"], "S256")
    XCTAssertEqual(query["state"], flow.state)

    let keychain = KeychainStore(service: "com.bex.tests.oauth.\(UUID())", inMemory: true)
    let service = CodexOAuthService(
      keychain: keychain,
      transport: ScriptedHTTPTransport([])
    )
    let mismatch = await capturedError {
      _ = try await service.complete(
        flow: flow,
        callbackURL: URL(string: "http://localhost:1455/auth/callback?code=code&state=wrong")!
      )
    }
    XCTAssertEqual(
      mismatch,
      .oauthFailure("State mismatch while completing Codex login.")
    )

    let exchangeTransport = ScriptedHTTPTransport([
      .response(Data("{}".utf8), 200)
    ])
    let exchangeService = CodexOAuthService(
      keychain: keychain,
      transport: exchangeTransport
    )
    let exchangeError = await capturedError {
      _ = try await exchangeService.complete(
        flow: flow,
        callbackURL: URL(
          string: "http://localhost:1455/auth/callback?code=authorization-code&state=\(flow.state)"
        )!
      )
    }
    XCTAssertEqual(
      exchangeError,
      .oauthFailure("Codex OAuth token response was incomplete.")
    )
    let exchangeRequests = await exchangeTransport.recordedRequests()
    let exchangeRequest = try XCTUnwrap(exchangeRequests.first)
    XCTAssertEqual(exchangeRequest.url, CodexOAuthService.tokenURL)
    let exchangeBody = String(
      data: try XCTUnwrap(exchangeRequest.httpBody),
      encoding: .utf8
    )
    XCTAssertTrue(exchangeBody?.contains("grant_type=authorization_code") == true)
    XCTAssertTrue(exchangeBody?.contains("code=authorization-code") == true)
    XCTAssertTrue(exchangeBody?.contains("code_verifier=") == true)
    XCTAssertTrue(exchangeBody?.contains("redirect_uri=") == true)

    let refreshError = await capturedError {
      _ = try await CodexOAuthService.refresh(
        session: CodexSession(
          accessToken: "old",
          refreshToken: "refresh",
          expiresAt: .distantPast,
          accountID: "account"
        ),
        transport: ScriptedHTTPTransport([.response(Data("{}".utf8), 200)])
      )
    }
    XCTAssertEqual(
      refreshError,
      .oauthFailure("Codex refresh response was incomplete.")
    )
  }

  func testCodexRefreshesWithinThirtySecondsAndPersistsSession() async throws {
    let keychain = KeychainStore(service: "com.bex.tests.refresh.\(UUID())", inMemory: true)
    try await keychain.saveCodexSession(
      CodexSession(
        accessToken: "old-access",
        refreshToken: "old-refresh",
        expiresAt: Date().addingTimeInterval(20),
        accountID: "old-account"
      )
    )
    let refreshedToken = try jwt(accountID: "new-account")
    let refreshPayload = try jsonData([
      "access_token": refreshedToken,
      "refresh_token": "new-refresh",
      "expires_in": 3_600,
    ])
    let responsePayload = try jsonData(["output_text": grammarJSON])
    let transport = ScriptedHTTPTransport([
      .response(refreshPayload, 200),
      .response(responsePayload, 200),
    ])
    let client = OpenAICodexClient(keychain: keychain, transport: transport)

    let result = try await client.check(text: "text", model: "", systemPrompt: "system")

    XCTAssertEqual(result.corrected, "This is a test.")
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].url, CodexOAuthService.tokenURL)
    let refreshBody = String(data: try XCTUnwrap(requests[0].httpBody), encoding: .utf8)
    XCTAssertTrue(refreshBody?.contains("grant_type=refresh_token") == true)
    XCTAssertTrue(refreshBody?.contains("refresh_token=old-refresh") == true)
    XCTAssertEqual(
      requests[1].value(forHTTPHeaderField: "Authorization"),
      "Bearer \(refreshedToken)"
    )
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "chatgpt-account-id"), "new-account")
    let storedSession = try await keychain.codexSession()
    let saved = try XCTUnwrap(storedSession)
    XCTAssertEqual(saved.accessToken, refreshedToken)
    XCTAssertEqual(saved.refreshToken, "new-refresh")
    XCTAssertEqual(saved.accountID, "new-account")
    XCTAssertGreaterThan(saved.expiresAt.timeIntervalSinceNow, 3_500)
  }

  func testCodexResponseParserHandlesFragmentedSSEAndCompletedJSON() throws {
    let sse = """
      data: {"type":"response.output_text.delta","delta":"Hel"}

      data: {"type":"response.output_text.delta","delta":"lo"}

      data: [DONE]

      """
    XCTAssertEqual(try CodexResponseParser.extract(from: Data(sse.utf8)), "Hello")

    let completed = try jsonData([
      "output": [
        [
          "type": "message",
          "content": [["type": "output_text", "text": "Completed text"]],
        ]
      ]
    ])
    XCTAssertEqual(try CodexResponseParser.extract(from: completed), "Completed text")
  }

  private func codexClient(
    session: CodexSession,
    payload: Data
  ) async throws -> OpenAICodexClient {
    let keychain = KeychainStore(service: "com.bex.tests.codex-payload.\(UUID())", inMemory: true)
    try await keychain.saveCodexSession(session)
    return OpenAICodexClient(
      keychain: keychain,
      transport: ScriptedHTTPTransport([.response(payload, 200)])
    )
  }

  private func capturedStatusError(
    status: Int,
    provider: LLMProvider,
    url: URL
  ) -> BexError? {
    let response = HTTPURLResponse(
      url: url,
      statusCode: status,
      httpVersion: nil,
      headerFields: nil
    )!
    do {
      try ProviderResponse.validateStatus(response, data: Data(), provider: provider)
      return nil
    } catch let error as BexError {
      return error
    } catch {
      return nil
    }
  }

  private func requestJSONObject(_ request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
  }

  private func jwt(accountID: String) throws -> String {
    let payload = try jsonData([
      CodexOAuthService.accountClaimKey: ["chatgpt_account_id": accountID]
    ])
    let encoded = payload.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
  }
}

private func capturedError(
  _ operation: () async throws -> Void
) async -> BexError? {
  do {
    try await operation()
    return nil
  } catch let error as BexError {
    return error
  } catch is CancellationError {
    return .cancellation
  } catch {
    return nil
  }
}
