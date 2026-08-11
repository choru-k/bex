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
    static let codexPriorityTier = "providers.codexPriorityTier"
    static let lastLearningViewedAt = "learning.lastViewedAt"

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

    /// Per-provider so switching providers does not carry a model name that provider has
    /// never heard of. `.correction` deliberately has no key of its own — it reads
    /// `selectedModel`, which is the setting that already existed, so nothing has to be
    /// migrated and an owner who never opens the Models section keeps exactly what they had.
    static func modelOverride(for job: ModelJob, provider: LLMProvider) -> String {
      "modelOverride.\(job.rawValue).\(provider.rawValue)"
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
      return provider.defaultEffort
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

  /// The model override set for one job, or `nil` when it inherits.
  ///
  /// `.correction` is the base and has no override of its own — it *is* `selectedModel`.
  func modelOverride(for job: ModelJob, provider: LLMProvider) -> String? {
    guard job != .correction else { return nil }
    let value = defaults.string(forKey: Key.modelOverride(for: job, provider: provider))
    guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return value
  }

  /// Passing `nil` clears the override, so the job goes back to following Correction.
  func setModelOverride(_ model: String?, for job: ModelJob, provider: LLMProvider) {
    guard job != .correction else {
      // The correction model is the provider's selected model; there is nothing above it to
      // override, and writing a second copy would let the two disagree.
      if let model { setSelectedModel(model, for: provider) }
      return
    }
    let key = Key.modelOverride(for: job, provider: provider)
    if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
      defaults.set(model, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  func model(for job: ModelJob, provider: LLMProvider) -> String {
    modelOverride(for: job, provider: provider) ?? selectedModel(for: provider)
  }

  /// Where a given job's request goes. Defaults to `.correction` so every existing call site
  /// keeps its current behaviour without naming a job.
  func outboundDestination(for job: ModelJob = .correction) throws -> OutboundDestination {
    let provider = selectedProvider()
    return try OutboundDestination(
      provider: provider,
      model: model(for: job, provider: provider),
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

  /// Whether OpenAI Codex requests ask for the priority ("Fast") service tier.
  ///
  /// Defaults to ON. It is not free — the tier is billed as increased usage against the
  /// owner's ChatGPT account — so this was shipped opt-in first and the owner then chose to
  /// make it the default, having seen the measurement: across 326 corrections from a real
  /// corpus it saved ~1.6s median and ~3.2s at p90 with no measurable change to correction
  /// quality. Latency is the constraint Bex is designed around, and this buys it directly.
  ///
  /// Note the `object(forKey:)` guard rather than a bare `bool(forKey:)`: without it an
  /// unset key reads as `false`, which would silently mean OFF for everyone.
  func codexPriorityTier() -> Bool {
    guard defaults.object(forKey: Key.codexPriorityTier) != nil else {
      return true
    }
    return defaults.bool(forKey: Key.codexPriorityTier)
  }

  func setCodexPriorityTier(_ enabled: Bool) {
    defaults.set(enabled, forKey: Key.codexPriorityTier)
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

  /// When the Learning window was last opened — `nil` before it has ever been viewed.
  /// Drives the menu-bar badge count (`LearningBadge`); the app sets this to `Date()`
  /// only when the window actually opens (`WindowCoordinator.showLearning`).
  func lastLearningViewedAt() -> Date? {
    defaults.object(forKey: Key.lastLearningViewedAt) as? Date
  }

  func setLastLearningViewedAt(_ date: Date) {
    defaults.set(date, forKey: Key.lastLearningViewedAt)
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
