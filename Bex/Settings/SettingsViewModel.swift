import AppKit
import Foundation

enum SettingsSetupOrigin: Equatable, Sendable {
  case quickCheck
  case fixAndSend
}

enum SettingsRouteIntent: Equatable, Sendable {
  case returnToQuickCheck
  case returnToFixAndSendTarget
}

enum ShortcutUpdateOutcome: Equatable {
  case accepted
  case rejected
}

enum ProviderConnectionState: Equatable {
  case notConfigured
  case validating
  case ready
  case failed
}

enum IntegrationReviewState: Equatable {
  case reviewing
  case applying
  case stale
  case partialFailure(completed: [String], restored: [String], failed: [String])
  case applied
}

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
  @Published private(set) var validatedProvider: LLMProvider?
  @Published private(set) var ollamaError: String?
  @Published private(set) var userVisibleError: String?
  @Published private(set) var codexConnected = false
  @Published private(set) var codexExpiry: Date?
  @Published private(set) var codexStatus = "Not connected"
  @Published private(set) var oauthInProgress = false
  @Published private(set) var manualCallbackRequired = false
  @Published var callbackURL = ""
  @Published private(set) var confirmsHookOutboundPayloads = true
  @Published private(set) var accessibilityTrusted = false
  @Published private(set) var hookStatuses: [PromptClient: HookInstallationStatus] = [:]
  @Published private(set) var hookConfigPaths: [PromptClient: String] = [:]
  @Published private(set) var promptGateError: String?
  @Published private(set) var promptOperationClient: PromptClient?
  @Published private(set) var installedIntegrations: [HookIntegrationDescriptor] = []
  @Published private(set) var integrationStatuses: [String: HookInstallationStatus] = [:]
  @Published private(set) var pendingInstallationReview: HookInstallationReview?
  @Published private(set) var integrationApplyInProgress = false
  @Published private(set) var integrationReviewState: IntegrationReviewState?
  @Published var ompExecutablePath = ""
  @Published var ompProfile = "default"
  @Published var ompWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
  @Published private(set) var draftRetentionChoice: RetentionChoice = .undecided
  @Published private(set) var historyRetentionChoice: RetentionChoice = .undecided
  @Published private(set) var quickCheckKeyChord: KeyChord = .defaultQuickCheck
  @Published private(set) var fixAndSendKeyChord: KeyChord = .defaultFixAndSend
  @Published private(set) var shortcutErrors: [BexShortcut: String] = [:]
  @Published private(set) var accessibilityStatusMessage: String?
  @Published private(set) var setupOrigin: SettingsSetupOrigin?
  @Published private(set) var isClearingHistory = false
  @Published private(set) var isDeletingSavedDraft = false
  @Published private(set) var savedDraftDeletionError: String?
  @Published private(set) var isRequestingSetupRoute = false

  static let draftRetentionDisclosure =
    "When enabled, Bex saves the current Quick Check draft in this Mac’s app preferences so it can be restored after Bex relaunches or when Quick Check is temporarily hidden for navigation. Closing or canceling Quick Check deletes the saved draft. Don’t Save and Not Decided never block correction and do not save new drafts."
  static let historyRetentionDisclosure =
    "When enabled, Bex saves the original, correction, explanation, provider, model, Writing Style name, and timestamp in Bex’s local database on this Mac, keeping at most 500 entries. Fix & Send is not stored. Don’t Save and Not Decided never block correction and do not save new history."

  private let preferences: PreferencesStore
  private let keychain: KeychainStore
  private let grammar: any GrammarServicing
  private let codexOAuth: CodexOAuthService
  private let promptTarget: any PromptTargetServicing
  private let hookManager: any HookInstallationManaging
  private let applyAppearance: @MainActor (AppearancePreference) -> Void
  private let updateShortcut: @MainActor (BexShortcut, KeyChord) throws -> Void
  private let onDeleteSavedDraft: @MainActor () async throws -> Void
  private let onClearHistory: @MainActor () async throws -> Void
  private let onSetupRoute: @MainActor (SettingsRouteIntent) -> Void

  private var modelTask: Task<Void, Never>?
  private var ollamaTask: Task<Void, Never>?
  private var oauthTask: Task<Void, Never>?
  private var promptTask: Task<Void, Never>?
  private var preferenceTask: Task<Void, Never>?
  private var clearHistoryTask: Task<Void, Never>?
  private var deleteSavedDraftTask: Task<Void, Never>?
  private var isLoaded = false
  private var isNormalizingOllamaURL = false
  private var connectionValidationGeneration = 0

  init(
    preferences: PreferencesStore,
    keychain: KeychainStore,
    grammar: any GrammarServicing,
    codexOAuth: CodexOAuthService,
    promptTarget: any PromptTargetServicing = PromptTargetService(),
    hookManager: any HookInstallationManaging = HookInstallationManager(),
    applyAppearance: @escaping @MainActor (AppearancePreference) -> Void,
    setupOrigin: SettingsSetupOrigin? = nil,
    updateShortcut: @escaping @MainActor (BexShortcut, KeyChord) throws -> Void = {
      try BexShortcutBridge.update($0, chord: $1)
    },
    onDeleteSavedDraft: @escaping @MainActor () async throws -> Void = {},
    onClearHistory: @escaping @MainActor () async throws -> Void = {},
    onSetupRoute: @escaping @MainActor (SettingsRouteIntent) -> Void = { _ in }
  ) {
    self.preferences = preferences
    self.keychain = keychain
    self.grammar = grammar
    self.codexOAuth = codexOAuth
    self.promptTarget = promptTarget
    self.hookManager = hookManager
    self.applyAppearance = applyAppearance
    self.setupOrigin = setupOrigin
    self.updateShortcut = updateShortcut
    self.onDeleteSavedDraft = onDeleteSavedDraft
    self.onClearHistory = onClearHistory
    self.onSetupRoute = onSetupRoute
    self.ompExecutablePath = Self.defaultOMPExecutablePath()
  }

  var showsCredential: Bool {
    provider == .openAI || provider == .claude || provider == .gemini
  }

  var credentialLabel: String {
    "\(provider.displayName) API Key"
  }

  var providerConnectionState: ProviderConnectionState {
    if isFetchingModels {
      return .validating
    }
    if validatedProvider == provider {
      return .ready
    }
    if modelFetchError != nil {
      return .failed
    }
    return .notConfigured
  }

  var providerConnectionLabel: String {
    switch providerConnectionState {
    case .notConfigured:
      return "\(provider.displayName) needs connection"
    case .validating:
      return "Validating \(provider.displayName)…"
    case .ready:
      return "\(provider.displayName) is ready"
    case .failed:
      return "\(provider.displayName) connection failed"
    }
  }

  var isSelectedProviderConnected: Bool {
    providerConnectionState == .ready
  }

  var setupRouteTitle: String? {
    guard isSelectedProviderConnected else { return nil }
    switch setupOrigin {
    case .quickCheck:
      return "Return to Quick Check"
    case .fixAndSend:
      return "Return to Target and Invoke Fix & Send"
    case nil:
      return nil
    }
  }

  var providerDisclosure: String {
    let destination: String
    if provider == .ollama {
      if let normalizedURL = try? OllamaURL.normalize(ollamaURL),
        OllamaURL.isLoopback(normalizedURL)
      {
        destination = "The configured Ollama endpoint is local to this Mac."
      } else {
        destination =
          "The configured Ollama endpoint is external; Bex sends these payloads to that endpoint."
      }
    } else {
      destination = "Bex sends these payloads to \(provider.displayName)."
    }
    return destination
      + " Quick Check sends the full draft plus any custom Writing Style guidance."
      + " Rewrite sends the corrected draft."
      + " Fix & Send sends the masked prompt; the payload is shown for approval whenever confirmation is required."
      + " Writing Style generation sends the labeled context fields you fill in: Role, Audience,"
      + " Tone, Formality, Domain, and Additional notes."
  }

  var showsAccessibilityRequest: Bool {
    !accessibilityTrusted
  }

  func load() async {
    async let selectedProvider = preferences.selectedProvider()
    async let savedAppearance = preferences.appearance()
    async let savedHookOutboundConfirmation = preferences.confirmsHookOutboundPayloads()
    async let savedDraftRetention = preferences.draftRetentionChoice()
    async let savedHistoryRetention = preferences.historyRetentionChoice()
    async let savedQuickCheckChord = preferences.quickCheckKeyChord()
    async let savedFixAndSendChord = preferences.fixAndSendKeyChord()

    provider = await selectedProvider
    model = await preferences.selectedModel(for: provider)
    effort = await preferences.selectedEffort(for: provider)
    ollamaURL = await preferences.ollamaURL()
    appearance = await savedAppearance
    confirmsHookOutboundPayloads = await savedHookOutboundConfirmation
    draftRetentionChoice = await savedDraftRetention
    historyRetentionChoice = await savedHistoryRetention
    quickCheckKeyChord = await savedQuickCheckChord
    fixAndSendKeyChord = await savedFixAndSendChord
    isLoaded = true
    await refreshCredentialState()
    await refreshCodexState()
    await reloadModels()
    await loadPromptGate()
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
    enqueuePreferenceUpdate { [preferences, provider] in
      await preferences.setSelectedModel(model, for: provider)
    }
  }

  func selectEffort(_ effort: ReasoningEffort) {
    self.effort = effort
    enqueuePreferenceUpdate { [preferences, provider] in
      await preferences.setSelectedEffort(effort, for: provider)
    }
  }

  func selectAppearance(_ appearance: AppearancePreference) {
    self.appearance = appearance
    applyAppearance(appearance)
    enqueuePreferenceUpdate { [preferences] in
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


  func setConfirmsHookOutboundPayloads(_ confirms: Bool) {
    confirmsHookOutboundPayloads = confirms
    enqueuePreferenceUpdate { [preferences] in
      await preferences.setConfirmsHookOutboundPayloads(confirms)
    }
  }

  func selectDraftRetentionChoice(_ choice: RetentionChoice) {
    draftRetentionChoice = choice
    enqueuePreferenceUpdate { [preferences] in
      await preferences.setDraftRetentionChoice(choice)
    }
  }

  func selectHistoryRetentionChoice(_ choice: RetentionChoice) {
    historyRetentionChoice = choice
    enqueuePreferenceUpdate { [preferences] in
      await preferences.setHistoryRetentionChoice(choice)
    }
  }

  func deleteSavedDraft() {
    guard deleteSavedDraftTask == nil else { return }
    savedDraftDeletionError = nil
    isDeletingSavedDraft = true
    deleteSavedDraftTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isDeletingSavedDraft = false
        deleteSavedDraftTask = nil
      }
      await preferenceTask?.value
      do {
        try await onDeleteSavedDraft()
      } catch {
        savedDraftDeletionError =
          "Couldn’t delete the saved draft. \(error.localizedDescription)"
      }
    }
  }

  func clearHistory() {
    guard clearHistoryTask == nil else { return }
    userVisibleError = nil
    isClearingHistory = true
    clearHistoryTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isClearingHistory = false
        clearHistoryTask = nil
      }
      do {
        try await onClearHistory()
      } catch {
        userVisibleError = "Couldn’t clear History. \(error.localizedDescription)"
      }
    }
  }

  func shortcutError(for shortcut: BexShortcut) -> String? {
    shortcutErrors[shortcut]
  }

  func updateKeyChord(
    _ chord: KeyChord,
    for shortcut: BexShortcut
  ) -> ShortcutUpdateOutcome {
    let otherChord =
      shortcut == .quickCheck
      ? fixAndSendKeyChord
      : quickCheckKeyChord
    guard chord != otherChord else {
      return rejectShortcut(
        shortcut,
        message: "That shortcut is already assigned to another Bex command."
      )
    }
    guard chord.isValidGlobalShortcut else {
      return rejectShortcut(
        shortcut,
        message: HotKeyRegistrationError.invalidChord.localizedDescription
      )
    }

    do {
      try updateShortcut(shortcut, chord)
      shortcutErrors[shortcut] = nil
      switch shortcut {
      case .quickCheck:
        quickCheckKeyChord = chord
      case .fixAndSend:
        fixAndSendKeyChord = chord
      }
      enqueuePreferenceUpdate { [preferences] in
        switch shortcut {
        case .quickCheck:
          await preferences.setQuickCheckKeyChord(chord)
        case .fixAndSend:
          await preferences.setFixAndSendKeyChord(chord)
        }
      }
      return .accepted
    } catch {
      return rejectShortcut(
        shortcut,
        message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      )
    }
  }

  private func rejectShortcut(
    _ shortcut: BexShortcut,
    message: String
  ) -> ShortcutUpdateOutcome {
    shortcutErrors[shortcut] = message
    return .rejected
  }

  func setSetupOrigin(_ origin: SettingsSetupOrigin?) {
    setupOrigin = origin
  }

  func requestSetupRoute() async {
    guard setupOrigin != nil, !isRequestingSetupRoute else { return }
    isRequestingSetupRoute = true
    userVisibleError = nil
    defer { isRequestingSetupRoute = false }

    guard await flushOllamaURLForSetupRoute() else { return }
    await modelTask?.value
    await preferenceTask?.value
    guard isSelectedProviderConnected else {
      userVisibleError = "\(provider.displayName) must be connected before returning."
      return
    }

    switch setupOrigin {
    case .quickCheck:
      onSetupRoute(.returnToQuickCheck)
    case .fixAndSend:
      onSetupRoute(.returnToFixAndSendTarget)
    case nil:
      break
    }
  }

  private func flushOllamaURLForSetupRoute() async -> Bool {
    guard provider == .ollama else { return true }
    ollamaTask?.cancel()
    await ollamaTask?.value
    ollamaTask = nil
    do {
      let normalized = try OllamaURL.normalize(ollamaURL)
      isNormalizingOllamaURL = true
      ollamaURL = normalized
      isNormalizingOllamaURL = false
      ollamaError = nil
      await preferences.setOllamaURL(normalized)
      return true
    } catch {
      isNormalizingOllamaURL = false
      ollamaError = "Enter a valid Ollama URL."
      userVisibleError = "Enter a valid Ollama URL before returning."
      return false
    }
  }

  func requestAccessibility() {
    let trusted = promptTarget.requestAccessibilityTrust()
    accessibilityTrusted = trusted
    if trusted {
      accessibilityStatusMessage =
        "Accessibility is enabled. Invoke Fix & Send again to capture the focused field."
      promptGateError = nil
    }
  }

  func refreshAccessibilityState() {
    let wasTrusted = accessibilityTrusted
    accessibilityTrusted = promptTarget.isAccessibilityTrusted
    if accessibilityTrusted, !wasTrusted {
      accessibilityStatusMessage =
        "Accessibility is enabled. Invoke Fix & Send again to capture the focused field."
      promptGateError = nil
    } else if !accessibilityTrusted, wasTrusted {
      accessibilityStatusMessage =
        "Accessibility was revoked. Fix & Send will use copy-only fallback for manual capture."
    }
  }

  func testAccessibility() {
    refreshAccessibilityState()
    promptGateError =
      accessibilityTrusted
      ? nil
      : BexError.accessibilityPermissionRequired.localizedDescription
  }

  func hookStatusLabel(for client: PromptClient) -> String {
    statusLabel(hookStatuses[client] ?? .notInstalled)
  }

  func hookConfigPath(for client: PromptClient) -> String {
    hookConfigPaths[client] ?? "Managed by Bex"
  }

  func hookActionLabel(for client: PromptClient) -> String {
    switch hookStatuses[client] ?? .notInstalled {
    case .notInstalled, .unavailable:
      "Install"
    case .updateAvailable:
      "Update"
    case .needsRepair:
      "Repair"
    case .awaitingCodexTrust, .installedUnconfirmed, .active:
      "Uninstall"
    }
  }

  func performHookAction(for client: PromptClient) {
    prepareHookAction(for: client)
  }

  func integrationStatusLabel(for integrationID: String) -> String {
    statusLabel(integrationStatuses[integrationID] ?? .notInstalled)
  }

  func integrationActionLabel(for integrationID: String) -> String {
    let status = integrationStatuses[integrationID] ?? .notInstalled
    if case .unavailable = status,
      installedIntegrations.contains(where: { $0.id == integrationID })
    {
      return "Uninstall"
    }
    return actionLabel(status)
  }
  func prepareHookAction(for client: PromptClient) {
    let target: HookIntegrationTarget = client == .claudeCode ? .claudeCode : .codex
    prepareIntegration(target: target)
  }

  func prepareOMPIntegration() {
    let executable = URL(
      fileURLWithPath: (ompExecutablePath as NSString).expandingTildeInPath
    )
    let workingDirectory = URL(
      fileURLWithPath: (ompWorkingDirectory as NSString).expandingTildeInPath,
      isDirectory: true
    )
    prepareIntegration(
      target: .ohMyPi(
        executable: executable,
        profile: ompProfile.trimmingCharacters(in: .whitespacesAndNewlines),
        workingDirectory: workingDirectory
      )
    )
  }

  func prepareAction(for descriptor: HookIntegrationDescriptor) {
    prepareDescriptor(
      descriptor,
      currentStatus: integrationStatuses[descriptor.id] ?? .notInstalled
    )
  }

  func cancelPendingInstallationReview() {
    guard let review = pendingInstallationReview else { return }
    pendingInstallationReview = nil
    integrationReviewState = nil
    promptGateError = nil
    Task { await hookManager.cancel(reviewID: review.id) }
  }

  func applyPendingInstallationReview() {
    guard let review = pendingInstallationReview, !integrationApplyInProgress else { return }
    integrationApplyInProgress = true
    integrationReviewState = .applying
    promptGateError = nil
    promptTask?.cancel()
    promptTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await hookManager.apply(reviewID: review.id)
        if result.failed.isEmpty {
          integrationReviewState = .applied
          pendingInstallationReview = nil
          await refreshIntegrationState()
        } else {
          integrationReviewState = .partialFailure(
            completed: result.completed,
            restored: result.restored,
            failed: result.failed
          )
          promptGateError =
            "Apply partially failed. Review completed, restored, and retained paths before retrying."
        }
      } catch {
        promptGateError = error.localizedDescription
        integrationReviewState =
          error.localizedDescription.contains("Nothing changed") ? .stale : .reviewing
      }
      integrationApplyInProgress = false
    }
  }
  func reviewLatestIntegrationChanges() {
    guard let review = pendingInstallationReview, !integrationApplyInProgress else { return }
    promptGateError = nil
    promptTask?.cancel()
    promptTask = Task { [weak self] in
      guard let self else { return }
      await hookManager.cancel(reviewID: review.id)
      do {
        pendingInstallationReview = try await hookManager.prepare(
          review.operation,
          for: review.descriptor
        )
        integrationReviewState = .reviewing
      } catch {
        promptGateError = error.localizedDescription
        integrationReviewState = .stale
      }
    }
  }

  private func prepareIntegration(target: HookIntegrationTarget) {
    guard !integrationApplyInProgress, pendingInstallationReview == nil else { return }
    promptGateError = nil
    promptTask?.cancel()
    promptTask = Task { [weak self] in
      guard let self else { return }
      do {
        let descriptor = try await hookManager.resolve(target)
        let currentStatus = await hookManager.status(for: descriptor.id)
        try await prepareDescriptorNow(
          descriptor,
          currentStatus: currentStatus,
          isOwned: currentStatus != .notInstalled
        )
      } catch {
        promptGateError = error.localizedDescription
      }
    }
  }

  private func prepareDescriptor(
    _ descriptor: HookIntegrationDescriptor,
    currentStatus: HookInstallationStatus
  ) {
    guard !integrationApplyInProgress, pendingInstallationReview == nil else { return }
    promptGateError = nil
    promptTask?.cancel()
    promptTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await prepareDescriptorNow(descriptor, currentStatus: currentStatus, isOwned: true)
      } catch {
        promptGateError = error.localizedDescription
      }
    }
  }

  private func prepareDescriptorNow(
    _ descriptor: HookIntegrationDescriptor,
    currentStatus: HookInstallationStatus,
    isOwned: Bool
  ) async throws {
    let operation: HookInstallationOperation
    switch currentStatus {
    case .awaitingCodexTrust, .installedUnconfirmed, .active:
      operation = .uninstall
    case .updateAvailable:
      operation = .update
    case .needsRepair:
      operation = .repair
    case .notInstalled:
      operation = .install
    case .unavailable:
      operation = isOwned ? .uninstall : .install
    }
    pendingInstallationReview = try await hookManager.prepare(operation, for: descriptor)
    integrationReviewState = .reviewing
  }

  private func refreshIntegrationState() async {
    installedIntegrations = await hookManager.installedDescriptors()
    var statuses: [String: HookInstallationStatus] = [:]
    for descriptor in installedIntegrations {
      statuses[descriptor.id] = await hookManager.status(for: descriptor.id)
    }
    integrationStatuses = statuses
    for client in PromptClient.focusedPickerClients {
      hookStatuses[client] = await hookManager.status(for: client)
    }
  }

  private func actionLabel(_ status: HookInstallationStatus) -> String {
    switch status {
    case .notInstalled, .unavailable:
      "Install"
    case .updateAvailable:
      "Update"
    case .needsRepair:
      "Repair"
    case .awaitingCodexTrust, .installedUnconfirmed, .active:
      "Uninstall"
    }
  }

  private func statusLabel(_ status: HookInstallationStatus) -> String {
    switch status {
    case .notInstalled:
      "Not installed"
    case .updateAvailable:
      "Update available"
    case .awaitingCodexTrust:
      "Installed — approve Bex in /hooks"
    case .installedUnconfirmed:
      "Installed — waiting for first prompt"
    case .active(let lastSeen):
      "Active · last seen \(lastSeen.formatted(.relative(presentation: .named)))"
    case .needsRepair(let detail):
      "Needs repair: \(detail)"
    case .unavailable(let detail):
      "Unavailable: \(detail)"
    }
  }

  private static func defaultOMPExecutablePath() -> String {
    let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appendingPathComponent("omp").path }
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
      ?? "/opt/homebrew/bin/omp"
  }

  private func loadPromptGate() async {
    accessibilityTrusted = promptTarget.isAccessibilityTrusted
    if let manager = hookManager as? HookInstallationManager {
      for client in PromptClient.focusedPickerClients {
        hookConfigPaths[client] = await manager.configuredPath(for: client).path
      }
    }
    await refreshIntegrationState()
  }

  private func runHookOperation(client: PromptClient, install: Bool) {
    guard promptOperationClient == nil else { return }
    promptOperationClient = client
    promptGateError = nil
    promptTask?.cancel()
    promptTask = Task { [weak self] in
      guard let self else { return }
      do {
        if install {
          try await hookManager.install(client)
        } else {
          try await hookManager.uninstall(client)
        }
        hookStatuses[client] = await hookManager.status(for: client)
      } catch {
        promptGateError = error.localizedDescription
        hookStatuses[client] = await hookManager.status(for: client)
      }
      promptOperationClient = nil
    }
  }

  private func enqueuePreferenceUpdate(
    _ operation: @escaping @Sendable () async -> Void
  ) {
    let previousTask = preferenceTask
    preferenceTask = Task {
      await previousTask?.value
      guard !Task.isCancelled else { return }
      await operation()
    }
  }

  func close() {
    modelTask?.cancel()
    ollamaTask?.cancel()
    oauthTask?.cancel()
    promptTask?.cancel()
    Task { [codexOAuth] in
      await codexOAuth.cancel()
    }
  }

  func waitForCurrentWork() async {
    await modelTask?.value
    await ollamaTask?.value
    await oauthTask?.value
    await promptTask?.value
    await preferenceTask?.value
    await clearHistoryTask?.value
    await deleteSavedDraftTask?.value
  }

  private func reloadModels() async {
    let requestedProvider = provider
    connectionValidationGeneration &+= 1
    let validationGeneration = connectionValidationGeneration
    validatedProvider = nil
    isFetchingModels = true
    modelFetchError = nil
    do {
      let fetched = try await grammar.fetchModels(for: requestedProvider)
      guard
        !Task.isCancelled,
        provider == requestedProvider,
        connectionValidationGeneration == validationGeneration
      else { return }
      if !fetched.contains(where: { $0.id == model }),
        let replacement = fetched.first(where: { $0.id == requestedProvider.defaultModel })
          ?? fetched.first
      {
        model = replacement.id
        await preferences.setSelectedModel(replacement.id, for: requestedProvider)
      }
      models = mergedModels(fetched, provider: requestedProvider, selectedModel: model)
      validatedProvider = requestedProvider
      isFetchingModels = false
    } catch {
      guard
        !Task.isCancelled,
        provider == requestedProvider,
        connectionValidationGeneration == validationGeneration
      else { return }
      models = mergedModels([], provider: requestedProvider, selectedModel: model)
      validatedProvider = nil
      modelFetchError = "Connection failed: \(error.localizedDescription)"
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
