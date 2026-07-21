import Foundation

struct QuickCheckOutboundWritingStyle: Equatable, Sendable {
  let name: String
  let guidance: String
}

struct QuickCheckOutboundSummary: Equatable, Sendable {
  let action: String
  let provider: String
  let model: String
  let writingStyle: QuickCheckOutboundWritingStyle?
  let fullDraft: String
  let disclosure: String
}

struct QuickCheckAccessibilityAnnouncement: Equatable, Sendable {
  let sequence: Int
  let message: String
}

struct QuickCheckResultProvenance: Equatable, Sendable {
  let provider: LLMProvider
  let model: String
  let writingStyleName: String
  let completedAt: Date
}

@MainActor
final class QuickCheckViewModel: ObservableObject {
  static let historyStorageDisclosure =
    "Quick Check history is stored locally on this Mac: original, correction, explanation, provider, model, Writing Style, and timestamp, up to 500 items. Fix & Send is not stored."
  static let draftStorageDisclosure =
    "When enabled, your unfinished Quick Check draft is stored locally on this Mac."

  @Published var input: String = "" {
    didSet {
      guard input != oldValue else { return }
      draftEditGeneration &+= 1
      guard !isSuppressingDraftPersistence else { return }
      scheduleDraftPersistence()
    }
  }
  @Published private(set) var provider: LLMProvider = .openAI
  @Published private(set) var model: String = LLMProvider.openAI.defaultModel
  @Published private(set) var availableWritingStyles: [Profile] = []
  @Published private(set) var selectedWritingStyleID: UUID?
  @Published private(set) var result: GrammarResult?
  @Published private(set) var resultProvenance: QuickCheckResultProvenance?
  @Published private(set) var diff: [DiffSegment] = []
  @Published private(set) var isChecking = false
  @Published private(set) var rewritingIntent: RewriteIntent?
  @Published private(set) var isPreparingOutbound = false
  @Published private(set) var outboundSummary: QuickCheckOutboundSummary?
  @Published var changesOnly = false
  @Published private(set) var setupError: String?
  @Published private(set) var userVisibleError: String?
  @Published private(set) var isContextLoaded = false
  @Published private(set) var copied = false
  @Published private(set) var draftRetentionChoice: RetentionChoice = .undecided
  @Published private(set) var historyRetentionChoice: RetentionChoice = .undecided
  @Published private(set) var editorFocusRequest = 0
  @Published private(set) var wantsEditorFocus = false
  @Published private(set) var accessibilityAnnouncement: QuickCheckAccessibilityAnnouncement?

  private let preferences: PreferencesStore
  private let keychain: KeychainStore
  private let data: BexDataStore
  private let grammar: any GrammarServicing
  private let pasteboard: any PasteboardWriting
  private let onDismiss: @MainActor (QuickCheckDismissalReason) -> Void

  private var contextLoadTask: Task<Void, Never>?
  private var outboundGateTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private var draftTask: Task<Void, Never>?
  private var copiedTask: Task<Void, Never>?
  private var historyTask: Task<Void, Never>?
  private var historyID: UUID?
  private var pendingOutbound: PendingOutbound?
  private var activeOperationID: UUID?
  private var currentDestination: OutboundDestination?
  private var isSuppressingDraftPersistence = false
  private var sessionGeneration = 0
  private var draftPersistenceGeneration = 0
  private var draftEditGeneration = 0
  private var historyPersistenceGeneration = 0
  private var announcementSequence = 0

  init(
    preferences: PreferencesStore,
    keychain: KeychainStore,
    data: BexDataStore,
    grammar: any GrammarServicing,
    pasteboard: any PasteboardWriting,
    onDismiss: @escaping @MainActor (QuickCheckDismissalReason) -> Void
  ) {
    self.preferences = preferences
    self.keychain = keychain
    self.data = data
    self.grammar = grammar
    self.pasteboard = pasteboard
    self.onDismiss = onDismiss
  }

  var providerLabel: String { provider.displayName }
  var modelLabel: String { model }

  var writingStyleLabel: String {
    selectedWritingStyle?.name ?? "Bex Standard"
  }

  var selectedWritingStyle: Profile? {
    availableWritingStyles.first { $0.id == selectedWritingStyleID }
  }

  var isBusy: Bool {
    isPreparingOutbound || isChecking || rewritingIntent != nil
  }

  var busyLabel: String? {
    if isPreparingOutbound {
      return "Preparing request…"
    }
    if isChecking {
      return "Checking…"
    }
    if let rewritingIntent {
      return "Applying \(rewritingIntent.label)…"
    }
    return nil
  }

  var hasPreservedUserWork: Bool {
    !input.isEmpty || isBusy || outboundSummary != nil || result != nil
      || userVisibleError != nil
  }

  var canCheck: Bool {
    isContextLoaded && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && setupError == nil && !isBusy && outboundSummary == nil
  }

  var diffAccessibilitySummary: String {
    AccessibleDiffSummary.make(from: diff)
  }

  var processingDisclosure: String {
    let destination = pendingOutbound?.destination ?? currentDestination
    let displayedProvider = destination?.provider ?? provider
    if displayedProvider == .ollama {
      guard let endpoint = destination?.ollamaEndpoint else {
        return "Enter a valid Ollama URL in Settings before checking this draft."
      }
      return OllamaURL.isLoopback(endpoint)
        ? "Processed locally by Ollama at \(endpoint). The draft does not leave this Mac."
        : "The full draft is sent to the external Ollama endpoint at \(endpoint) for processing."
    }
    if displayedProvider == .openAICodex {
      return "The full draft is sent through your ChatGPT Codex subscription."
    }
    return "The full draft is sent to \(displayedProvider.displayName) for processing."
  }

  func loadContext() async {
    await loadContext(didStart: nil)
  }

  func loadContext(didStart: (@MainActor () -> Void)?) async {
    if isContextLoaded {
      sessionDidShow()
      return
    }
    if let contextLoadTask {
      await contextLoadTask.value
      if isContextLoaded {
        sessionDidShow()
      } else {
        await loadContext()
      }
      return
    }

    let generation = sessionGeneration
    let draftGeneration = draftEditGeneration
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performInitialContextLoad(
        generation: generation,
        draftGeneration: draftGeneration
      )
    }
    contextLoadTask = task
    didStart?()
    await task.value
    if generation == sessionGeneration {
      contextLoadTask = nil
    }
  }

  func refreshConfiguration() async {
    let selectedProvider = await preferences.selectedProvider()
    provider = selectedProvider
    model = await preferences.selectedModel(for: selectedProvider)
    await loadWritingStyles()
    await refreshSetupState()
  }

  func sessionDidShow() {
    wantsEditorFocus = true
    editorFocusRequest &+= 1
  }

  func check() {
    guard canCheck else { return }
    prepareOutbound(
      .check(
        CheckPayload(
          original: input,
          writingStyle: selectedWritingStyle
        )
      )
    )
  }

  func confirmOutbound() {
    guard let pendingOutbound else { return }
    let generation = sessionGeneration
    self.pendingOutbound = nil
    outboundSummary = nil
    isPreparingOutbound = true

    outboundGateTask?.cancel()
    outboundGateTask = Task { [weak self, preferences] in
      await preferences.acceptCurrentOutboundDisclosure(for: pendingOutbound.destination)
      guard !Task.isCancelled, let self, self.sessionGeneration == generation else { return }
      self.setupError = nil
      self.isPreparingOutbound = false
      self.execute(pendingOutbound)
    }
  }

  func cancelOutboundConfirmation() {
    pendingOutbound = nil
    outboundSummary = nil
    isPreparingOutbound = false
    sessionDidShow()
  }

  func rewrite(_ intent: RewriteIntent) {
    guard let current = result, !isBusy, outboundSummary == nil else { return }
    prepareOutbound(
      .rewrite(
        RewritePayload(
          original: input,
          current: current,
          intent: intent
        )
      )
    )
  }

  func selectWritingStyle(id: UUID?) async {
    guard id == nil || availableWritingStyles.contains(where: { $0.id == id }) else { return }
    selectedWritingStyleID = id
    await preferences.setActiveProfileID(id)
  }

  func setDraftRetentionChoice(_ choice: RetentionChoice) async {
    draftPersistenceGeneration &+= 1
    let generation = draftPersistenceGeneration
    draftTask?.cancel()
    draftTask = nil
    await preferences.setDraftRetentionChoice(choice)
    guard generation == draftPersistenceGeneration else { return }
    draftRetentionChoice = choice
    if choice == .enabled {
      await preferences.setQuickDraft(input)
    }
  }

  func setHistoryRetentionChoice(_ choice: RetentionChoice) async {
    historyPersistenceGeneration &+= 1
    let generation = historyPersistenceGeneration
    await preferences.setHistoryRetentionChoice(choice)
    guard generation == historyPersistenceGeneration else { return }
    historyRetentionChoice = choice
  }

  func persistedDraftWasDeleted() {
    draftPersistenceGeneration &+= 1
    draftTask?.cancel()
    draftTask = nil
  }

  func deletePersistedDraft() async {
    persistedDraftWasDeleted()
    await preferences.deleteSavedQuickDraft()
  }

  func copy(closeAfter: Bool) {
    guard let corrected = result?.corrected else { return }
    do {
      try pasteboard.write(corrected)
      copied = true
      copiedTask?.cancel()
      copiedTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        self?.copied = false
      }
      if closeAfter {
        dismiss(.completed)
      }
    } catch {
      show(error)
    }
  }

  func performPrimaryAction() {
    if outboundSummary != nil {
      confirmOutbound()
    } else if result != nil {
      guard !isBusy else { return }
      copy(closeAfter: true)
    } else {
      check()
    }
  }

  func useResultAsInput() {
    guard let corrected = result?.corrected else { return }
    input = corrected
    clearRenderedResult()
    sessionDidShow()
  }

  func recheck() {
    guard !isBusy else { return }
    clearRenderedResult()
    check()
  }

  func backToInput() {
    sessionGeneration &+= 1
    outboundGateTask?.cancel()
    outboundGateTask = nil
    pendingOutbound = nil
    outboundSummary = nil
    isPreparingOutbound = false

    if activeOperationID != nil {
      announce(isChecking ? "Check canceled." : "Rewrite canceled.")
    }
    activeOperationID = nil
    operationTask?.cancel()
    isChecking = false
    rewritingIntent = nil

    copiedTask?.cancel()
    copied = false
    clearRenderedResult()
    userVisibleError = nil
    sessionDidShow()
  }

  func dismiss(_ reason: QuickCheckDismissalReason) {
    applyDismissal(reason)
    onDismiss(reason)
  }

  func panelDidDismiss(_ reason: QuickCheckDismissalReason) {
    applyDismissal(reason)
  }

  func replaceDraft(with text: String) {
    destroySession()
    input = text
    sessionDidShow()
  }

  func waitForCurrentWork() async {
    await contextLoadTask?.value
    await outboundGateTask?.value
    await operationTask?.value
    await historyTask?.value
    await draftTask?.value
  }

  private func performInitialContextLoad(
    generation: Int,
    draftGeneration: Int
  ) async {
    let draftChoice = await preferences.draftRetentionChoice()
    let historyChoice = await preferences.historyRetentionChoice()
    let selectedProvider = await preferences.selectedProvider()
    let selectedModel = await preferences.selectedModel(for: selectedProvider)
    let restoredDraft = await preferences.quickDraft()
    guard generation == sessionGeneration else { return }

    draftRetentionChoice = draftChoice
    historyRetentionChoice = historyChoice
    provider = selectedProvider
    model = selectedModel
    if draftEditGeneration == draftGeneration {
      isSuppressingDraftPersistence = true
      input = restoredDraft
      isSuppressingDraftPersistence = false
    } else if draftChoice == .enabled {
      await preferences.setQuickDraft(input)
      guard generation == sessionGeneration else { return }
    }

    await loadWritingStyles()
    guard generation == sessionGeneration else { return }
    await refreshSetupState()
    guard generation == sessionGeneration else { return }
    isContextLoaded = true
    sessionDidShow()
  }

  private func loadWritingStyles() async {
    do {
      availableWritingStyles = try await data.loadProfiles()
    } catch {
      availableWritingStyles = []
      show(error)
    }

    let activeID = await preferences.activeProfileID()
    let defaultID = await preferences.defaultProfileID()
    if let activeID, availableWritingStyles.contains(where: { $0.id == activeID }) {
      selectedWritingStyleID = activeID
    } else if let defaultID, availableWritingStyles.contains(where: { $0.id == defaultID }) {
      selectedWritingStyleID = defaultID
      await preferences.setActiveProfileID(defaultID)
    } else {
      selectedWritingStyleID = nil
      await preferences.setActiveProfileID(nil)
    }
  }

  private func prepareOutbound(_ payload: OutboundPayload) {
    outboundGateTask?.cancel()
    pendingOutbound = nil
    outboundSummary = nil
    isPreparingOutbound = true
    userVisibleError = nil
    copied = false
    let generation = sessionGeneration
    outboundGateTask = Task { [weak self, preferences] in
      do {
        let destination = try await preferences.outboundDestination()
        let policy = await preferences.outboundConfirmationPolicy()
        let accepted = await preferences.hasAcceptedCurrentOutboundDisclosure(
          for: destination
        )
        guard !Task.isCancelled, let self, self.sessionGeneration == generation else { return }

        self.provider = destination.provider
        self.model = destination.model
        self.currentDestination = destination
        let configuredOutbound = payload.configured(for: destination)
        if policy.requiresConfirmation(
          for: .quickCheckExternal,
          hasAcceptedDisclosure: accepted
        ) {
          self.isPreparingOutbound = false
          self.pendingOutbound = configuredOutbound
          self.outboundSummary = configuredOutbound.summary
        } else {
          guard !Task.isCancelled, self.sessionGeneration == generation else { return }
          self.setupError = nil
          self.isPreparingOutbound = false
          self.execute(configuredOutbound)
        }
      } catch {
        guard !Task.isCancelled, let self, self.sessionGeneration == generation else { return }
        self.isPreparingOutbound = false
        self.setupError = "Provider setup failed: \(error.localizedDescription)"
        self.show(error)
      }
    }
  }

  private func execute(_ outbound: PendingOutbound) {
    switch outbound {
    case .check(let request):
      startCheck(request)
    case .rewrite(let request):
      startRewrite(request)
    }
  }

  private func startCheck(_ request: CheckRequest) {
    operationTask?.cancel()
    let operationID = UUID()
    activeOperationID = operationID

    isChecking = true
    rewritingIntent = nil
    userVisibleError = nil
    copied = false
    result = nil
    resultProvenance = nil
    diff = []
    changesOnly = false
    historyID = nil
    announce("Checking started.")

    operationTask = Task { [weak self, grammar] in
      guard let self else { return }
      do {
        let checked = try await grammar.check(
          text: request.original,
          destination: request.destination,
          profilePrompt: request.writingStyle?.prompt
        )
        try Task.checkCancellation()
        guard self.activeOperationID == operationID else { return }
        self.result = checked
        self.resultProvenance = QuickCheckResultProvenance(
          provider: request.destination.provider,
          model: request.destination.model,
          writingStyleName: request.writingStyle?.name ?? "Bex Standard",
          completedAt: Date()
        )
        self.diff = WordDiff.compute(original: request.original, corrected: checked.corrected)
        self.finishOperation(operationID, announcement: "Check complete.")
        self.saveInitialHistory(
          original: request.original,
          result: checked,
          provider: request.destination.provider,
          model: request.destination.model,
          writingStyleName: request.writingStyle?.name
        )
      } catch {
        guard self.activeOperationID == operationID else { return }
        if Task.isCancelled || error is CancellationError || error as? BexError == .cancellation {
          self.finishOperation(operationID, announcement: "Check canceled.")
        } else {
          self.show(error)
          self.finishOperation(operationID, announcement: "Check failed.")
        }
      }
    }
  }

  private func startRewrite(_ request: RewriteRequest) {
    operationTask?.cancel()
    let operationID = UUID()
    activeOperationID = operationID
    let priorHistoryTask = historyTask

    rewritingIntent = request.intent
    userVisibleError = nil
    copied = false
    announce("\(request.intent.label) rewrite started.")

    operationTask = Task { [weak self, grammar] in
      guard let self else { return }
      do {
        let rewritten = try await grammar.rewrite(
          text: request.current.corrected,
          intent: request.intent,
          destination: request.destination
        )
        try Task.checkCancellation()
        guard self.activeOperationID == operationID else { return }
        let explanation =
          "\(request.current.explanation)\n\nRewrite applied: \(request.intent.label)"
        let rewrittenResult = GrammarResult(
          corrected: rewritten,
          explanation: explanation
        )
        self.result = rewrittenResult
        self.resultProvenance = QuickCheckResultProvenance(
          provider: request.destination.provider,
          model: request.destination.model,
          writingStyleName: self.resultProvenance?.writingStyleName ?? "Bex Standard",
          completedAt: Date()
        )
        self.diff = WordDiff.compute(original: request.original, corrected: rewritten)
        self.finishOperation(operationID, announcement: "Rewrite complete.")
        self.saveRewriteHistory(
          corrected: rewritten,
          explanation: explanation,
          after: priorHistoryTask
        )
      } catch {
        guard self.activeOperationID == operationID else { return }
        if Task.isCancelled || error is CancellationError || error as? BexError == .cancellation {
          self.finishOperation(operationID, announcement: "Rewrite canceled.")
        } else {
          self.show(error)
          self.finishOperation(operationID, announcement: "Rewrite failed.")
        }
      }
    }
  }

  private func finishOperation(_ operationID: UUID, announcement: String) {
    guard activeOperationID == operationID else { return }
    activeOperationID = nil
    isChecking = false
    rewritingIntent = nil
    announce(announcement)
  }

  private func applyDismissal(_ reason: QuickCheckDismissalReason) {
    switch reason.sessionDisposition {
    case .preserve:
      return
    case .discard, .complete:
      destroySession()
    }
  }

  private func destroySession() {
    sessionGeneration &+= 1
    contextLoadTask?.cancel()
    contextLoadTask = nil
    outboundGateTask?.cancel()
    outboundGateTask = nil
    pendingOutbound = nil
    outboundSummary = nil
    isPreparingOutbound = false
    wantsEditorFocus = false

    if activeOperationID != nil {
      announce(isChecking ? "Check canceled." : "Rewrite canceled.")
    }
    activeOperationID = nil
    operationTask?.cancel()
    isChecking = false
    rewritingIntent = nil

    draftPersistenceGeneration &+= 1
    draftTask?.cancel()
    isSuppressingDraftPersistence = true
    input = ""
    isSuppressingDraftPersistence = false
    draftTask = Task { [preferences] in
      await preferences.deleteSavedQuickDraft()
    }

    copiedTask?.cancel()
    copied = false
    clearRenderedResult()
    userVisibleError = nil
  }

  private func scheduleDraftPersistence() {
    draftTask?.cancel()
    guard draftRetentionChoice == .enabled else { return }
    let draft = input
    let generation = draftPersistenceGeneration
    draftTask = Task { [weak self, preferences] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard
        !Task.isCancelled,
        let self,
        self.draftPersistenceGeneration == generation,
        self.draftRetentionChoice == .enabled
      else { return }
      await preferences.setQuickDraft(draft)
    }
  }

  private func refreshSetupState() async {
    do {
      let destination = try await preferences.outboundDestination()
      provider = destination.provider
      model = destination.model
      currentDestination = destination
      let hasSetup: Bool
      if destination.provider == .ollama {
        hasSetup = true
      } else {
        hasSetup = try await keychain.hasSetup(for: destination.provider)
      }
      if hasSetup {
        setupError = nil
      } else {
        setupError = BexError.missingSetup(destination.provider).errorDescription
      }
    } catch {
      currentDestination = nil
      setupError = error.localizedDescription
    }
  }

  private func saveInitialHistory(
    original: String,
    result: GrammarResult,
    provider: LLMProvider,
    model: String,
    writingStyleName: String?
  ) {
    let id = UUID()
    let generation = historyPersistenceGeneration
    let entry = HistoryEntry(
      id: id,
      original: original,
      corrected: result.corrected,
      explanation: result.explanation,
      provider: provider,
      model: model,
      timestamp: Date(),
      profileName: writingStyleName
    )
    historyID = id
    historyTask = Task { [weak self, preferences, data] in
      guard let self, self.historyRetentionChoice == .enabled else { return }
      let storedChoice = await preferences.historyRetentionChoice()
      guard
        !Task.isCancelled,
        self.historyPersistenceGeneration == generation,
        storedChoice == .enabled
      else { return }
      do {
        try await data.appendHistory(entry)
      } catch {
        self.userVisibleError = "Correction complete, but history could not be saved."
      }
    }
  }

  private func saveRewriteHistory(
    corrected: String,
    explanation: String,
    after priorHistoryTask: Task<Void, Never>?
  ) {
    let generation = historyPersistenceGeneration
    guard let historyID else { return }
    historyTask = Task { [weak self, preferences, data] in
      await priorHistoryTask?.value
      guard let self, self.historyRetentionChoice == .enabled else { return }
      let storedChoice = await preferences.historyRetentionChoice()
      guard
        !Task.isCancelled,
        self.historyPersistenceGeneration == generation,
        storedChoice == .enabled
      else { return }
      do {
        try await data.updateHistory(
          id: historyID,
          corrected: corrected,
          explanation: explanation
        )
      } catch {
        self.userVisibleError = "Rewrite complete, but history could not be updated."
      }
    }
  }

  private func clearRenderedResult() {
    result = nil
    resultProvenance = nil
    diff = []
    changesOnly = false
    historyID = nil
  }

  private func announce(_ message: String) {
    announcementSequence &+= 1
    accessibilityAnnouncement = QuickCheckAccessibilityAnnouncement(
      sequence: announcementSequence,
      message: message
    )
  }

  private func show(_ error: Error) {
    if Task.isCancelled || error is CancellationError || error as? BexError == .cancellation {
      return
    }
    userVisibleError = error.localizedDescription
  }
}

extension QuickCheckViewModel {
  fileprivate struct CheckPayload {
    let original: String
    let writingStyle: Profile?
  }

  fileprivate struct RewritePayload {
    let original: String
    let current: GrammarResult
    let intent: RewriteIntent
  }

  fileprivate enum OutboundPayload {
    case check(CheckPayload)
    case rewrite(RewritePayload)

    func configured(for destination: OutboundDestination) -> PendingOutbound {
      switch self {
      case .check(let payload):
        return .check(
          CheckRequest(
            original: payload.original,
            destination: destination,
            writingStyle: payload.writingStyle
          )
        )
      case .rewrite(let payload):
        return .rewrite(
          RewriteRequest(
            original: payload.original,
            current: payload.current,
            intent: payload.intent,
            destination: destination
          )
        )
      }
    }
  }

  fileprivate struct CheckRequest {
    let original: String
    let destination: OutboundDestination
    let writingStyle: Profile?
  }

  fileprivate struct RewriteRequest {
    let original: String
    let current: GrammarResult
    let intent: RewriteIntent
    let destination: OutboundDestination
  }

  fileprivate enum PendingOutbound {
    case check(CheckRequest)
    case rewrite(RewriteRequest)

    var destination: OutboundDestination {
      switch self {
      case .check(let request): request.destination
      case .rewrite(let request): request.destination
      }
    }

    var summary: QuickCheckOutboundSummary {
      switch self {
      case .check(let request):
        return QuickCheckOutboundSummary(
          action: "Check draft",
          provider: request.destination.provider.displayName,
          model: request.destination.model,
          writingStyle: request.writingStyle.map {
            QuickCheckOutboundWritingStyle(name: $0.name, guidance: $0.prompt)
          },
          fullDraft: request.original,
          disclosure:
            "The full draft shown here will be sent to \(request.destination.disclosureTarget)."
        )
      case .rewrite(let request):
        return QuickCheckOutboundSummary(
          action: "Apply \(request.intent.label)",
          provider: request.destination.provider.displayName,
          model: request.destination.model,
          writingStyle: nil,
          fullDraft: request.current.corrected,
          disclosure:
            "The full corrected draft shown here will be sent to \(request.destination.disclosureTarget)."
        )
      }
    }
  }
}
