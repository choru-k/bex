import Foundation

enum RetentionChoice: String, Codable, CaseIterable, Sendable {
  case undecided
  case enabled
  case disabled
}

enum OutboundConfirmationContext: Equatable, Sendable {
  case standaloneFixAndSend
  case manualCapturedField
  case hook
}

extension OutboundConfirmationContext {
  func requiresConfirmation(
    hasAcceptedDisclosure: Bool,
    confirmsHookOutboundPayloads: Bool = false
  ) -> Bool {
    guard hasAcceptedDisclosure else { return true }
    switch self {
    case .standaloneFixAndSend, .manualCapturedField:
      return false
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
    static let savedDraft = "fixAndSend.savedDraft"
    static let draftRetentionChoice = "storage.fixAndSendDraft.choice"
    static let historyRetentionChoice = "storage.correctionHistory.choice"
    static let fixAndSendKeyChord = "shortcut.fixAndSend"
    static let welcomeCompletedVersion = "welcome.completedVersion"
    static let confirmsHookOutboundPayloads = "promptGate.confirmsHookOutboundPayloads"
    static let codexPriorityTier = "providers.codexPriorityTier"
    static let lastLearningViewedAt = "learning.lastViewedAt"
    static let backgroundAgentEnabled = "backgroundAgent.enabled"
    static let lastBackgroundRunAt = "backgroundAgent.lastRunAt"
    static let lastBackgroundRunCorrections = "backgroundAgent.lastRunCorrections"
    static let lastBackgroundRunGrouped = "backgroundAgent.lastRunGrouped"

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

  private enum LegacyKey {
    static let savedDraft = "quickDraft"
    static let draftRetentionChoice = "storage.quickDraft.choice"
    static let historyRetentionChoice = "storage.history.choice"
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

  private let backing: PreferencesBacking
  private let coordinator = AccountMutationCoordinator.shared
  private var defaults: UserDefaults { backing.defaults }

  static let currentOutboundDisclosureVersion = 1

  init(defaults: UserDefaults = .standard) {
    self.backing = PreferencesBacking(defaults: defaults)
    // Retention-only legacy cleanup is not an account/configuration change.
    // It shares the synchronous backing lock and never waits for host drain.
    backing.withLock { Self.migrateLegacyRetentionPreferences(in: defaults) }
  }

  // A single-key, MainActor-only startup read. All cooperative appearance
  // writes also commit synchronously on MainActor; no multi-key snapshot here.
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
    return backing.withLock {
      guard
        let rawValue = defaults.string(forKey: Key.selectedProvider),
        let provider = LLMProvider(rawValue: rawValue)
      else {
        return .openAI
      }
      return provider
    }
  }

  func setSelectedProvider(_ provider: LLMProvider) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(provider.rawValue, forKey: Key.selectedProvider)
      }
    }
  }

  func selectedModel(for provider: LLMProvider) -> String {
    return backing.withLock {
      let key = Key.selectedModel(for: provider)
      guard let model = defaults.string(forKey: key), !model.isEmpty else {
        return provider.defaultModel
      }
      if Self.retiredModels[provider]?.contains(model) == true {
        return provider.defaultModel
      }
      return model
    }
  }

  func setSelectedModel(_ model: String, for provider: LLMProvider) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(model, forKey: Key.selectedModel(for: provider))
      }
    }
  }

  func selectedEffort(for provider: LLMProvider) -> ReasoningEffort {
    return backing.withLock {
      let key = Key.selectedEffort(for: provider)
      guard
        let rawValue = defaults.string(forKey: key),
        let effort = ReasoningEffort(rawValue: rawValue)
      else {
        return provider.defaultEffort
      }
      return effort
    }
  }

  func setSelectedEffort(_ effort: ReasoningEffort, for provider: LLMProvider) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(effort.rawValue, forKey: Key.selectedEffort(for: provider))
      }
    }
  }

  func ollamaURL() -> String {
    return backing.withLock {
      defaults.string(forKey: Key.ollamaURL) ?? "http://localhost:11434"
    }
  }

  func setOllamaURL(_ url: String) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(url, forKey: Key.ollamaURL)
      }
    }
  }

  /// The model override set for one job, or `nil` when it inherits.
  ///
  /// `.correction` is the base and has no override of its own — it *is* `selectedModel`.
  func modelOverride(for job: ModelJob, provider: LLMProvider) -> String? {
    return backing.withLock {
      guard job != .correction else { return nil }
      let value = defaults.string(forKey: Key.modelOverride(for: job, provider: provider))
      guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      return value
    }
  }

  /// Passing `nil` clears the override, so the job goes back to following Correction.
  func setModelOverride(_ model: String?, for job: ModelJob, provider: LLMProvider) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        guard job != .correction else {
          // The correction model is the provider's selected model; there is nothing above it to
          // override, and writing a second copy would let the two disagree.
          if let model { defaults.set(model, forKey: Key.selectedModel(for: provider)) }
          return
        }
        let key = Key.modelOverride(for: job, provider: provider)
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
          defaults.set(model, forKey: key)
        } else {
          defaults.removeObject(forKey: key)
        }
      }
    }
  }

  func model(for job: ModelJob, provider: LLMProvider) -> String {
    return backing.withLock {
      modelOverride(for: job, provider: provider) ?? selectedModel(for: provider)
    }
  }

  /// Where a given job's request goes. Defaults to `.correction` so every existing call site
  /// keeps its current behaviour without naming a job.
  func outboundDestination(for job: ModelJob = .correction) throws -> OutboundDestination {
    return try backing.withLock {
      let provider = selectedProvider()
      return try OutboundDestination(
        provider: provider,
        model: model(for: job, provider: provider),
        ollamaEndpoint: provider == .ollama ? ollamaURL() : nil
      )
    }
  }

  /// Coherent under the synchronous backing lock. Reserve admission before this
  /// read and validate that epoch after awaiting it and after host construction.
  func nativeCorrectionConfiguration() throws -> (
    destination: OutboundDestination, effort: ReasoningEffort
  ) {
    return try backing.withLock {
      let destination = try outboundDestination()
      return (destination, selectedEffort(for: destination.provider))
    }
  }

  /// Explicit persistence migration, never invoked by a read. Re-read inside
  /// the transaction so a newer user selection cannot be overwritten.
  func migrateRetiredModels() async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        for (provider, retired) in Self.retiredModels {
          let key = Key.selectedModel(for: provider)
          if let model = defaults.string(forKey: key), retired.contains(model) {
            defaults.set(provider.defaultModel, forKey: key)
          }
        }
      }
    }
  }

  func appearance() -> AppearancePreference {
    return backing.withLock {
      guard
        let rawValue = defaults.string(forKey: Key.appearance),
        let appearance = AppearancePreference(rawValue: rawValue)
      else {
        return .system
      }
      return appearance
    }
  }

  func setAppearance(_ appearance: AppearancePreference) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(appearance.rawValue, forKey: Key.appearance)
      }
    }
  }

  func activeProfileID() -> UUID? {
    return backing.withLock {
      uuid(forKey: Key.activeProfileID)
    }
  }

  func setActiveProfileID(_ id: UUID?) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        Self.setUUID(id, forKey: Key.activeProfileID, in: defaults)
      }
    }
  }

  func defaultProfileID() -> UUID? {
    return backing.withLock {
      uuid(forKey: Key.defaultProfileID)
    }
  }

  func setDefaultProfileID(_ id: UUID?) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        Self.setUUID(id, forKey: Key.defaultProfileID, in: defaults)
      }
    }
  }

  func profileDeleted(id: UUID) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        if defaults.string(forKey: Key.activeProfileID).flatMap(UUID.init(uuidString:)) == id {
          defaults.removeObject(forKey: Key.activeProfileID)
        }
        if defaults.string(forKey: Key.defaultProfileID).flatMap(UUID.init(uuidString:)) == id {
          defaults.removeObject(forKey: Key.defaultProfileID)
        }
      }
    }
  }

  func savedDraft() -> String {
    return backing.withLock {
      guard draftRetentionChoice() == .enabled else { return "" }
      return defaults.string(forKey: Key.savedDraft) ?? ""
    }
  }

  func setSavedDraft(_ draft: String) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        guard defaults.string(forKey: Key.draftRetentionChoice) == RetentionChoice.enabled.rawValue else { return }
        defaults.set(draft, forKey: Key.savedDraft)
      }
    }
  }

  func deleteSavedDraft() async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.removeObject(forKey: Key.savedDraft)
      }
    }
  }

  func draftRetentionChoice() -> RetentionChoice {
    return backing.withLock {
      retentionChoice(forKey: Key.draftRetentionChoice)
    }
  }

  func setDraftRetentionChoice(_ choice: RetentionChoice) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(choice.rawValue, forKey: Key.draftRetentionChoice)
      }
    }
  }

  func historyRetentionChoice() -> RetentionChoice {
    return backing.withLock {
      retentionChoice(forKey: Key.historyRetentionChoice)
    }
  }

  func setHistoryRetentionChoice(_ choice: RetentionChoice) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(choice.rawValue, forKey: Key.historyRetentionChoice)
      }
    }
  }

  func confirmsHookOutboundPayloads() -> Bool {
    return backing.withLock {
      guard defaults.object(forKey: Key.confirmsHookOutboundPayloads) != nil else {
        return false
      }
      return defaults.bool(forKey: Key.confirmsHookOutboundPayloads)
    }
  }

  func setConfirmsHookOutboundPayloads(_ confirms: Bool) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(confirms, forKey: Key.confirmsHookOutboundPayloads)
      }
    }
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
    return backing.withLock {
      guard defaults.object(forKey: Key.codexPriorityTier) != nil else {
        return true
      }
      return defaults.bool(forKey: Key.codexPriorityTier)
    }
  }

  func setCodexPriorityTier(_ enabled: Bool) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(enabled, forKey: Key.codexPriorityTier)
      }
    }
  }

  func outboundDisclosureVersion(for destination: OutboundDestination) -> Int {
    return backing.withLock {
      defaults.integer(forKey: Key.outboundDisclosureVersion(for: destination))
    }
  }

  func acceptCurrentOutboundDisclosure(for destination: OutboundDestination) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(
          Self.currentOutboundDisclosureVersion,
          forKey: Key.outboundDisclosureVersion(for: destination)
        )
      }
    }
  }

  func hasAcceptedCurrentOutboundDisclosure(for destination: OutboundDestination) -> Bool {
    return backing.withLock {
      outboundDisclosureVersion(for: destination) >= Self.currentOutboundDisclosureVersion
    }
  }

  /// Withdraws the standing approval for one destination.
  ///
  /// Non-negotiable 3 says nothing leaves the Mac without explicit approval; an approval that
  /// cannot be taken back is not really a choice. Revoking stops the background agent
  /// immediately (it is gated on this) and puts the interactive flows back to asking per
  /// payload.
  func revokeOutboundDisclosure(for destination: OutboundDestination) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.removeObject(forKey: Key.outboundDisclosureVersion(for: destination))
      }
    }
  }

  /// Whether the hourly agent runs at all.
  ///
  /// Defaults to on because this work already ran before it had a switch — defaulting it off
  /// would silently stop pattern grouping and the writer profile for anyone updating.
  func backgroundAgentEnabled() -> Bool {
    return backing.withLock {
      defaults.object(forKey: Key.backgroundAgentEnabled) as? Bool ?? true
    }
  }

  func setBackgroundAgentEnabled(_ enabled: Bool) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(enabled, forKey: Key.backgroundAgentEnabled)
      }
    }
  }

  /// What the last hourly pass actually did, so "it runs in the background" is inspectable
  /// rather than a claim.
  func lastBackgroundRun() -> BackgroundRunSummary? {
    return backing.withLock {
      guard let date = defaults.object(forKey: Key.lastBackgroundRunAt) as? Date else { return nil }
      return BackgroundRunSummary(
        finishedAt: date,
        correctionsRead: defaults.integer(forKey: Key.lastBackgroundRunCorrections),
        cardsGrouped: defaults.integer(forKey: Key.lastBackgroundRunGrouped)
      )
    }
  }

  func setLastBackgroundRun(_ summary: BackgroundRunSummary) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(summary.finishedAt, forKey: Key.lastBackgroundRunAt)
        defaults.set(summary.correctionsRead, forKey: Key.lastBackgroundRunCorrections)
        defaults.set(summary.cardsGrouped, forKey: Key.lastBackgroundRunGrouped)
      }
    }
  }

  func fixAndSendKeyChord() -> KeyChord {
    return backing.withLock {
      keyChord(forKey: Key.fixAndSendKeyChord, fallback: .defaultFixAndSend)
    }
  }

  func setFixAndSendKeyChord(_ chord: KeyChord) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        Self.setKeyChord(chord, forKey: Key.fixAndSendKeyChord, in: defaults)
      }
    }
  }

  private static func migrateLegacyRetentionPreferences(in defaults: UserDefaults) {
    let directMigrations = [
      (legacy: LegacyKey.savedDraft, destination: Key.savedDraft),
      (legacy: LegacyKey.draftRetentionChoice, destination: Key.draftRetentionChoice),
    ]
    for migration in directMigrations {
      if defaults.object(forKey: migration.destination) == nil,
        let legacyValue = defaults.object(forKey: migration.legacy)
      {
        defaults.set(legacyValue, forKey: migration.destination)
      }
      defaults.removeObject(forKey: migration.legacy)
    }

    if defaults.object(forKey: Key.historyRetentionChoice) == nil,
      defaults.string(forKey: LegacyKey.historyRetentionChoice) == RetentionChoice.disabled.rawValue
    {
      defaults.set(RetentionChoice.disabled.rawValue, forKey: Key.historyRetentionChoice)
    }
    defaults.removeObject(forKey: LegacyKey.historyRetentionChoice)
  }

  func welcomeCompletedVersion() -> Int {
    return backing.withLock {
      defaults.integer(forKey: Key.welcomeCompletedVersion)
    }
  }

  func setWelcomeCompletedVersion(_ version: Int) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(version, forKey: Key.welcomeCompletedVersion)
      }
    }
  }

  /// When the Learning window was last opened — `nil` before it has ever been viewed.
  /// Drives the menu-bar badge count (`LearningBadge`); the app sets this to `Date()`
  /// only when the window actually opens (`WindowCoordinator.showLearning`).
  func lastLearningViewedAt() -> Date? {
    return backing.withLock {
      defaults.object(forKey: Key.lastLearningViewedAt) as? Date
    }
  }

  func setLastLearningViewedAt(_ date: Date) async {
    await coordinator.withMutation { [backing] in
      return backing.withLock {
        let defaults = backing.defaults
        defaults.set(date, forKey: Key.lastLearningViewedAt)
      }
    }
  }

  // Read helpers below are called only from the locked public getters. Static
  // write helpers are called only inside a locked synchronous mutation closure.
  private func keyChord(forKey key: String, fallback: KeyChord) -> KeyChord {
    guard
      let data = defaults.data(forKey: key),
      let chord = try? JSONDecoder().decode(KeyChord.self, from: data)
    else {
      return fallback
    }
    return chord
  }

  private nonisolated static func setKeyChord(_ chord: KeyChord, forKey key: String, in defaults: UserDefaults) {
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

  private nonisolated static func setUUID(_ id: UUID?, forKey key: String, in defaults: UserDefaults) {
    if let id {
      defaults.set(id.uuidString, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

/// An immutable UserDefaults reference plus a process-global recursive lock.
/// Foundation's per-call thread safety is insufficient for multi-key snapshots.
/// Every store read/commit holds this lock only synchronously, NEVER while a
/// mutation waits for host drain. Recursion permits model/outbound getters to
/// compose; the global scope covers different wrappers for the same suite.
private final class PreferencesBacking: @unchecked Sendable {
  private static let lock = NSRecursiveLock()
  let defaults: UserDefaults

  init(defaults: UserDefaults) { self.defaults = defaults }

  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return try body()
  }
}
