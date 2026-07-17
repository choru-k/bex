import AppKit
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
  @Published private(set) var provider: LLMProvider = .openAI
  @Published private(set) var model: String = LLMProvider.openAI.defaultModel
  @Published private(set) var effort: ReasoningEffort = .medium
  @Published private(set) var models: [ModelOption] = []
  @Published var ollamaURL = "http://localhost:11434"
  @Published private(set) var appearance: AppearancePreference = .system
  @Published var credentialInput = ""
  @Published private(set) var credentialStored = false
  @Published private(set) var isFetchingModels = false
  @Published private(set) var modelFetchError: String?
  @Published private(set) var ollamaError: String?
  @Published private(set) var userVisibleError: String?
  @Published private(set) var codexConnected = false
  @Published private(set) var codexExpiry: Date?
  @Published private(set) var codexStatus = "Not connected"
  @Published private(set) var oauthInProgress = false
  @Published private(set) var manualCallbackRequired = false
  @Published var callbackURL = ""

  private let preferences: PreferencesStore
  private let keychain: KeychainStore
  private let grammar: any GrammarServicing
  private let codexOAuth: CodexOAuthService
  private let applyAppearance: @MainActor (AppearancePreference) -> Void

  private var modelTask: Task<Void, Never>?
  private var ollamaTask: Task<Void, Never>?
  private var oauthTask: Task<Void, Never>?
  private var isLoaded = false
  private var isNormalizingOllamaURL = false

  init(
    preferences: PreferencesStore,
    keychain: KeychainStore,
    grammar: any GrammarServicing,
    codexOAuth: CodexOAuthService,
    applyAppearance: @escaping @MainActor (AppearancePreference) -> Void
  ) {
    self.preferences = preferences
    self.keychain = keychain
    self.grammar = grammar
    self.codexOAuth = codexOAuth
    self.applyAppearance = applyAppearance
  }

  var showsCredential: Bool {
    provider == .openAI || provider == .claude || provider == .gemini
  }

  var credentialLabel: String {
    "\(provider.displayName) API Key"
  }

  func load() async {
    provider = await preferences.selectedProvider()
    model = await preferences.selectedModel(for: provider)
    effort = await preferences.selectedEffort(for: provider)
    ollamaURL = await preferences.ollamaURL()
    appearance = await preferences.appearance()
    isLoaded = true
    await refreshCredentialState()
    await refreshCodexState()
    await reloadModels()
  }

  func selectProvider(_ provider: LLMProvider) {
    guard provider != self.provider else { return }
    modelTask?.cancel()
    self.provider = provider
    credentialInput = ""
    userVisibleError = nil
    modelFetchError = nil
    modelTask = Task { [weak self] in
      guard let self else { return }
      await preferences.setSelectedProvider(provider)
      model = await preferences.selectedModel(for: provider)
      effort = await preferences.selectedEffort(for: provider)
      await refreshCredentialState()
      await refreshCodexState()
      await reloadModels()
    }
  }

  func selectModel(_ model: String) {
    self.model = model
    Task { [preferences, provider] in
      await preferences.setSelectedModel(model, for: provider)
    }
  }

  func selectEffort(_ effort: ReasoningEffort) {
    self.effort = effort
    Task { [preferences, provider] in
      await preferences.setSelectedEffort(effort, for: provider)
    }
  }

  func selectAppearance(_ appearance: AppearancePreference) {
    self.appearance = appearance
    applyAppearance(appearance)
    Task { [preferences] in
      await preferences.setAppearance(appearance)
    }
  }

  func updateOllamaURL(_ value: String) {
    guard isLoaded, !isNormalizingOllamaURL else { return }
    ollamaURL = value
    ollamaTask?.cancel()
    ollamaTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled, let self else { return }
      do {
        let normalized = try OllamaURL.normalize(value)
        isNormalizingOllamaURL = true
        ollamaURL = normalized
        isNormalizingOllamaURL = false
        ollamaError = nil
        await preferences.setOllamaURL(normalized)
        if provider == .ollama {
          await reloadModels()
        }
      } catch {
        ollamaError = "Enter a valid Ollama URL."
      }
    }
  }

  func saveCredential() {
    let value = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard showsCredential, !value.isEmpty else {
      userVisibleError = "Enter a credential to save."
      return
    }
    modelTask?.cancel()
    modelTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await keychain.saveAPIKey(value, for: provider)
        credentialInput = ""
        credentialStored = true
        userVisibleError = nil
        await reloadModels()
      } catch {
        userVisibleError = error.localizedDescription
      }
    }
  }

  func removeCredential() {
    guard showsCredential else { return }
    modelTask?.cancel()
    modelTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await keychain.deleteAPIKey(for: provider)
        credentialStored = false
        credentialInput = ""
        userVisibleError = nil
        await reloadModels()
      } catch {
        userVisibleError = error.localizedDescription
      }
    }
  }

  func retryModels() {
    modelTask?.cancel()
    modelTask = Task { [weak self] in
      await self?.reloadModels()
    }
  }

  func connectCodex() {
    oauthTask?.cancel()
    oauthInProgress = true
    manualCallbackRequired = false
    callbackURL = ""
    userVisibleError = nil
    codexStatus = "Starting secure login…"

    oauthTask = Task { [weak self] in
      guard let self else { return }
      do {
        let flow = try await codexOAuth.begin()
        guard !Task.isCancelled else { return }
        guard NSWorkspace.shared.open(flow.authorizationURL) else {
          await codexOAuth.cancel()
          throw BexError.oauthFailure("Bex could not open the OpenAI login page.")
        }
        if flow.loopbackAvailable {
          codexStatus = "Waiting for OpenAI callback…"
          let session = try await codexOAuth.waitForLoopbackCompletion()
          applyConnected(session)
        } else {
          oauthInProgress = false
          manualCallbackRequired = true
          codexStatus = "Callback port unavailable. Paste the complete callback URL."
        }
      } catch {
        oauthInProgress = false
        if error as? BexError != .cancellation {
          userVisibleError = error.localizedDescription
          codexStatus = "Not connected"
        }
      }
    }
  }

  func completeManualCallback() {
    let callback = callbackURL
    guard !callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      userVisibleError = "Paste the complete OpenAI Codex callback URL."
      return
    }
    oauthInProgress = true
    userVisibleError = nil
    oauthTask?.cancel()
    oauthTask = Task { [weak self] in
      guard let self else { return }
      do {
        let session = try await codexOAuth.completeManual(callbackURL: callback)
        applyConnected(session)
        callbackURL = ""
        manualCallbackRequired = false
      } catch {
        oauthInProgress = false
        if error as? BexError != .cancellation {
          userVisibleError = error.localizedDescription
        }
      }
    }
  }

  func disconnectCodex() {
    oauthTask?.cancel()
    Task { [weak self] in
      guard let self else { return }
      do {
        try await codexOAuth.disconnect()
        codexConnected = false
        codexExpiry = nil
        codexStatus = "Not connected"
        oauthInProgress = false
        manualCallbackRequired = false
        callbackURL = ""
        userVisibleError = nil
      } catch {
        userVisibleError = error.localizedDescription
      }
    }
  }

  func close() {
    modelTask?.cancel()
    ollamaTask?.cancel()
    oauthTask?.cancel()
    Task { [codexOAuth] in
      await codexOAuth.cancel()
    }
  }

  func waitForCurrentWork() async {
    await modelTask?.value
    await ollamaTask?.value
    await oauthTask?.value
  }

  private func reloadModels() async {
    let requestedProvider = provider
    isFetchingModels = true
    modelFetchError = nil
    do {
      let fetched = try await grammar.fetchModels(for: requestedProvider)
      guard !Task.isCancelled, provider == requestedProvider else { return }
      if !fetched.contains(where: { $0.id == model }),
        let replacement = fetched.first(where: { $0.id == requestedProvider.defaultModel })
          ?? fetched.first
      {
        model = replacement.id
        await preferences.setSelectedModel(replacement.id, for: requestedProvider)
      }
      models = mergedModels(fetched, provider: requestedProvider, selectedModel: model)
      isFetchingModels = false
    } catch {
      guard !Task.isCancelled, provider == requestedProvider else { return }
      models = mergedModels([], provider: requestedProvider, selectedModel: model)
      modelFetchError = "Could not fetch models. Using provider default."
      isFetchingModels = false
    }
  }

  private func mergedModels(
    _ fetched: [ModelOption],
    provider: LLMProvider,
    selectedModel: String
  ) -> [ModelOption] {
    if !fetched.isEmpty {
      return fetched.sorted { $0.name < $1.name }
    }
    var result = fetched
    for id in [provider.defaultModel, selectedModel] where !id.isEmpty {
      if !result.contains(where: { $0.id == id }) {
        result.append(ModelOption(id: id, name: id))
      }
    }
    return result.sorted { $0.name < $1.name }
  }

  private func refreshCredentialState() async {
    do {
      credentialStored =
        showsCredential
        ? try await keychain.hasSetup(for: provider)
        : false
    } catch {
      credentialStored = false
      userVisibleError = error.localizedDescription
    }
  }

  private func refreshCodexState() async {
    do {
      if let session = try await keychain.codexSession() {
        applyConnected(session)
      } else {
        codexConnected = false
        codexExpiry = nil
        codexStatus = "Not connected"
      }
    } catch {
      codexConnected = false
      codexExpiry = nil
      codexStatus = "Not connected"
      userVisibleError = error.localizedDescription
    }
  }

  private func applyConnected(_ session: CodexSession) {
    codexConnected = true
    codexExpiry = session.expiresAt
    codexStatus = "Connected"
    oauthInProgress = false
    manualCallbackRequired = false
    userVisibleError = nil
  }
}
