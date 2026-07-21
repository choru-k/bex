import Foundation

actor PreferencesStore {
  private enum Key {
    static let selectedProvider = "selectedProvider"
    static let ollamaURL = "ollamaURL"
    static let appearance = "appearance"
    static let activeProfileID = "activeProfileID"
    static let defaultProfileID = "defaultProfileID"
    static let quickDraft = "quickDraft"
    static let promptDeliveryMode = "promptGate.deliveryMode"
    static let promptLastClient = "promptGate.lastClient"
    static let promptDisclosureAccepted = "promptGate.disclosureAccepted"

    static func selectedModel(for provider: LLMProvider) -> String {
      "selectedModel.\(provider.rawValue)"
    }

    static func selectedEffort(for provider: LLMProvider) -> String {
      "selectedEffort.\(provider.rawValue)"
    }
  }

  private static let retiredModels: [LLMProvider: Set<String>] = [
    .openAICodex: [
      "gpt-5.6",
      "gpt-5.3-codex",
      "gpt-5.2-codex",
      "gpt-5.1-codex-max",
      "gpt-5.1-codex-mini",
      "gpt-5.1",
      "gpt-5.2",
    ],
    .claude: ["claude-opus-4-1-20250805"],
    .gemini: ["gemini-3-pro-preview"],
  ]

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  @MainActor
  static func standardAppearance() -> AppearancePreference {
    guard
      let rawValue = UserDefaults.standard.string(forKey: Key.appearance),
      let appearance = AppearancePreference(rawValue: rawValue)
    else {
      return .system
    }
    return appearance
  }

  func selectedProvider() -> LLMProvider {
    guard
      let rawValue = defaults.string(forKey: Key.selectedProvider),
      let provider = LLMProvider(rawValue: rawValue)
    else {
      return .openAI
    }
    return provider
  }

  func setSelectedProvider(_ provider: LLMProvider) {
    defaults.set(provider.rawValue, forKey: Key.selectedProvider)
  }

  func selectedModel(for provider: LLMProvider) -> String {
    let key = Key.selectedModel(for: provider)
    guard let model = defaults.string(forKey: key), !model.isEmpty else {
      return provider.defaultModel
    }
    if Self.retiredModels[provider]?.contains(model) == true {
      defaults.set(provider.defaultModel, forKey: key)
      return provider.defaultModel
    }
    return model
  }

  func setSelectedModel(_ model: String, for provider: LLMProvider) {
    defaults.set(model, forKey: Key.selectedModel(for: provider))
  }

  func selectedEffort(for provider: LLMProvider) -> ReasoningEffort {
    let key = Key.selectedEffort(for: provider)
    guard
      let rawValue = defaults.string(forKey: key),
      let effort = ReasoningEffort(rawValue: rawValue)
    else {
      return .medium
    }
    return effort
  }

  func setSelectedEffort(_ effort: ReasoningEffort, for provider: LLMProvider) {
    defaults.set(effort.rawValue, forKey: Key.selectedEffort(for: provider))
  }

  func ollamaURL() -> String {
    defaults.string(forKey: Key.ollamaURL) ?? "http://localhost:11434"
  }

  func setOllamaURL(_ url: String) {
    defaults.set(url, forKey: Key.ollamaURL)
  }

  func appearance() -> AppearancePreference {
    guard
      let rawValue = defaults.string(forKey: Key.appearance),
      let appearance = AppearancePreference(rawValue: rawValue)
    else {
      return .system
    }
    return appearance
  }

  func setAppearance(_ appearance: AppearancePreference) {
    defaults.set(appearance.rawValue, forKey: Key.appearance)
  }

  func activeProfileID() -> UUID? {
    uuid(forKey: Key.activeProfileID)
  }

  func setActiveProfileID(_ id: UUID?) {
    setUUID(id, forKey: Key.activeProfileID)
  }

  func defaultProfileID() -> UUID? {
    uuid(forKey: Key.defaultProfileID)
  }

  func setDefaultProfileID(_ id: UUID?) {
    setUUID(id, forKey: Key.defaultProfileID)
  }

  func profileDeleted(id: UUID) {
    if activeProfileID() == id {
      defaults.removeObject(forKey: Key.activeProfileID)
    }
    if defaultProfileID() == id {
      defaults.removeObject(forKey: Key.defaultProfileID)
    }
  }

  func quickDraft() -> String {
    defaults.string(forKey: Key.quickDraft) ?? ""
  }

  func setQuickDraft(_ draft: String) {
    defaults.set(draft, forKey: Key.quickDraft)
  }

  func preferredPromptClient() -> PromptClient {
    guard
      let rawValue = defaults.string(forKey: Key.promptLastClient),
      let client = PromptClient(rawValue: rawValue)
    else {
      return .claudeCode
    }
    return client
  }

  func setPreferredPromptClient(_ client: PromptClient) {
    defaults.set(client.rawValue, forKey: Key.promptLastClient)
  }

  func promptDeliveryMode() -> PromptDeliveryMode {
    guard
      let rawValue = defaults.string(forKey: Key.promptDeliveryMode),
      let mode = PromptDeliveryMode(rawValue: rawValue)
    else {
      return .sendAfterApproval
    }
    return mode
  }

  func setPromptDeliveryMode(_ mode: PromptDeliveryMode) {
    defaults.set(mode.rawValue, forKey: Key.promptDeliveryMode)
  }

  func promptGateDisclosureAccepted() -> Bool {
    defaults.bool(forKey: Key.promptDisclosureAccepted)
  }

  func setPromptGateDisclosureAccepted(_ accepted: Bool) {
    defaults.set(accepted, forKey: Key.promptDisclosureAccepted)
  }

  private func uuid(forKey key: String) -> UUID? {
    defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
  }

  private func setUUID(_ id: UUID?, forKey key: String) {
    if let id {
      defaults.set(id.uuidString, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}
