import Foundation

enum RetentionChoice: String, Codable, CaseIterable, Sendable {
  case undecided
  case enabled
  case disabled
}

enum OutboundConfirmationContext: Equatable, Sendable {
  case quickCheckExternal
  case manualCapturedField
  case ambiguousManual
  case hook
}

extension OutboundConfirmationContext {
  func requiresConfirmation(
    hasAcceptedDisclosure: Bool,
    confirmsHookOutboundPayloads: Bool = true
  ) -> Bool {
    guard hasAcceptedDisclosure else { return true }
    switch self {
    case .quickCheckExternal, .manualCapturedField:
      return false
    case .ambiguousManual:
      return true
    case .hook:
      return confirmsHookOutboundPayloads
    }
  }
}

actor PreferencesStore {
  private enum Key {
    static let selectedProvider = "selectedProvider"
    static let ollamaURL = "ollamaURL"
    static let appearance = "appearance"
    static let activeProfileID = "activeProfileID"
    static let defaultProfileID = "defaultProfileID"
    static let quickDraft = "quickDraft"
    static let draftRetentionChoice = "storage.quickDraft.choice"
    static let historyRetentionChoice = "storage.history.choice"
    static let quickCheckKeyChord = "shortcut.quickCheck"
    static let fixAndSendKeyChord = "shortcut.fixAndSend"
    static let welcomeCompletedVersion = "welcome.completedVersion"
    static let confirmsHookOutboundPayloads = "promptGate.confirmsHookOutboundPayloads"

    static func outboundDisclosureVersion(for destination: OutboundDestination) -> String {
      guard destination.provider == .ollama, let endpoint = destination.ollamaEndpoint else {
        return "outbound.disclosureVersion.\(destination.provider.rawValue)"
      }
      let encodedEndpoint = Data(endpoint.utf8).base64EncodedString()
      return "outbound.disclosureVersion.ollama.endpoint.\(encodedEndpoint)"
    }

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

  static let currentOutboundDisclosureVersion = 1

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

  func outboundDestination() throws -> OutboundDestination {
    let provider = selectedProvider()
    return try OutboundDestination(
      provider: provider,
      model: selectedModel(for: provider),
      ollamaEndpoint: provider == .ollama ? ollamaURL() : nil
    )
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
    guard draftRetentionChoice() == .enabled else { return "" }
    return defaults.string(forKey: Key.quickDraft) ?? ""
  }

  func setQuickDraft(_ draft: String) {
    guard draftRetentionChoice() == .enabled else { return }
    defaults.set(draft, forKey: Key.quickDraft)
  }

  func deleteSavedQuickDraft() {
    defaults.removeObject(forKey: Key.quickDraft)
  }

  func draftRetentionChoice() -> RetentionChoice {
    retentionChoice(forKey: Key.draftRetentionChoice)
  }

  func setDraftRetentionChoice(_ choice: RetentionChoice) {
    defaults.set(choice.rawValue, forKey: Key.draftRetentionChoice)
  }

  func historyRetentionChoice() -> RetentionChoice {
    retentionChoice(forKey: Key.historyRetentionChoice)
  }

  func setHistoryRetentionChoice(_ choice: RetentionChoice) {
    defaults.set(choice.rawValue, forKey: Key.historyRetentionChoice)
  }



  func confirmsHookOutboundPayloads() -> Bool {
    guard defaults.object(forKey: Key.confirmsHookOutboundPayloads) != nil else {
      return true
    }
    return defaults.bool(forKey: Key.confirmsHookOutboundPayloads)
  }

  func setConfirmsHookOutboundPayloads(_ confirms: Bool) {
    defaults.set(confirms, forKey: Key.confirmsHookOutboundPayloads)
  }

  func outboundDisclosureVersion(for destination: OutboundDestination) -> Int {
    defaults.integer(forKey: Key.outboundDisclosureVersion(for: destination))
  }

  func acceptCurrentOutboundDisclosure(for destination: OutboundDestination) {
    defaults.set(
      Self.currentOutboundDisclosureVersion,
      forKey: Key.outboundDisclosureVersion(for: destination)
    )
  }

  func hasAcceptedCurrentOutboundDisclosure(for destination: OutboundDestination) -> Bool {
    outboundDisclosureVersion(for: destination) >= Self.currentOutboundDisclosureVersion
  }

  func quickCheckKeyChord() -> KeyChord {
    keyChord(forKey: Key.quickCheckKeyChord, fallback: .defaultQuickCheck)
  }

  func setQuickCheckKeyChord(_ chord: KeyChord) {
    setKeyChord(chord, forKey: Key.quickCheckKeyChord)
  }

  func fixAndSendKeyChord() -> KeyChord {
    keyChord(forKey: Key.fixAndSendKeyChord, fallback: .defaultFixAndSend)
  }

  func setFixAndSendKeyChord(_ chord: KeyChord) {
    setKeyChord(chord, forKey: Key.fixAndSendKeyChord)
  }

  func welcomeCompletedVersion() -> Int {
    defaults.integer(forKey: Key.welcomeCompletedVersion)
  }

  func setWelcomeCompletedVersion(_ version: Int) {
    defaults.set(version, forKey: Key.welcomeCompletedVersion)
  }

  private func keyChord(forKey key: String, fallback: KeyChord) -> KeyChord {
    guard
      let data = defaults.data(forKey: key),
      let chord = try? JSONDecoder().decode(KeyChord.self, from: data)
    else {
      return fallback
    }
    return chord
  }

  private func setKeyChord(_ chord: KeyChord, forKey key: String) {
    guard let data = try? JSONEncoder().encode(chord) else { return }
    defaults.set(data, forKey: key)
  }

  private func retentionChoice(forKey key: String) -> RetentionChoice {
    guard
      let rawValue = defaults.string(forKey: key),
      let choice = RetentionChoice(rawValue: rawValue)
    else {
      return .undecided
    }
    return choice
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
