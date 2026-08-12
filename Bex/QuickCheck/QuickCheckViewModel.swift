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
  /// The completed check as the shared review card consumes it (design 4a): original,
  /// editable corrected text, explanation, and the diff derived from both. Replaces the
  /// old separate `result`/`diff`/`provenance` trio — one value, same shape Fix & Send
  /// reviews, so the two surfaces cannot drift.
  @Published private(set) var review: PromptGateReview?
  /// Which alternative the owner picked for this correction, or `nil` for "not yet".
  /// Never pre-set — non-negotiable 5 means there is no default answer to offer.
  @Published private(set) var pickedAlternativeID: String?
  @Published private(set) var isChecking = false
  @Published private(set) var isLookingUp = false
  @Published private(set) var lookup: DictionaryLookup?
  @Published private(set) var lookupSavedToStudy = false
  @Published private(set) var isPreparingOutbound = false
  @Published private(set) var outboundSummary: QuickCheckOutboundSummary?
  @Published private(set) var setupError: String?
  @Published private(set) var userVisibleError: String?
  @Published private(set) var isContextLoaded = false
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
  private let learningLog: LearningLogStore
  private let considerTaps: ConsiderTapStore
  private let onDismiss: @MainActor (QuickCheckDismissalReason) -> Void

  private var contextLoadTask: Task<Void, Never>?
  private var outboundGateTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private var draftTask: Task<Void, Never>?
  private var historyTask: Task<Void, Never>?
  private var studyLogTask: Task<Void, Never>?
  private var considerTapTask: Task<Void, Never>?
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
    learningLog: LearningLogStore = LearningLogStore(),
    considerTaps: ConsiderTapStore = ConsiderTapStore(),
    onDismiss: @escaping @MainActor (QuickCheckDismissalReason) -> Void
  ) {
    self.preferences = preferences
    self.keychain = keychain
    self.data = data
    self.grammar = grammar
    self.pasteboard = pasteboard
    self.learningLog = learningLog
    self.considerTaps = considerTaps
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
    isPreparingOutbound || isChecking || isLookingUp
  }

  var busyLabel: String? {
    if isPreparingOutbound {
      return "Preparing request…"
    }
    if isChecking {
      return "Checking…"
    }
    if isLookingUp {
      return "Looking up…"
    }
    return nil
  }

  var hasPreservedUserWork: Bool {
    !input.isEmpty || isBusy || outboundSummary != nil || review != nil
      || userVisibleError != nil || lookup != nil
  }

  /// Dictionary lookup takes the same preconditions as Check — a term, a configured
  /// provider, nothing already in flight.
  var canLookUp: Bool { canCheck }

  var canCheck: Bool {
    isContextLoaded && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && setupError == nil && !isBusy && outboundSummary == nil
  }

  var accessibleDiffSummary: String {
    guard let review else { return "No differences" }
    return AccessibleDiffSummary.make(from: review.diff)
  }

  /// The unranked expression alternatives this correction offered. Computed from the
  /// review rather than stored, so it cannot drift out of sync with the explanation it
  /// was parsed from — same rule as Fix & Send.
  var alternatives: [PromptGateAlternative] {
    guard let review else { return [] }
    return LearningAggregator.parseConsiderSuggestions(from: review.explanation)
      .compactMap { LearningAggregator.parseSuggestionLine($0) }
      .map {
        PromptGateAlternative(phrase: $0.phrase, alternative: $0.alternative, reason: $0.reason)
      }
  }

  var alternativesPhrase: String {
    alternatives.first?.phrase ?? ""
  }

  /// The grammar rules this correction touched, for the summary beside the redline.
  var changeCategorySummary: String {
    guard let review else { return "" }
    var seen: [String] = []
    for line in LearningAggregator.linesUnderFixed(in: review.explanation) {
      guard let tag = LearningAggregator.leadingTag(in: line) else { continue }
      let name = GrammarCategory(rawValue: tag)?.displayName ?? tag
      if !seen.contains(name) { seen.append(name) }
    }
    return seen.joined(separator: ", ")
  }

  var canCopyCorrection: Bool {
    review?.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      && !isBusy && outboundSummary == nil
  }

  /// Records which alternative the owner would actually say, minting a Study card.
  /// Fire-and-forget like Fix & Send's: picking never makes the panel wait on disk.
  func choose(_ alternative: PromptGateAlternative) {
    guard let review, pickedAlternativeID != alternative.id else { return }
    pickedAlternativeID = alternative.id
    let original = review.original
    considerTapTask = Task { [considerTaps] in
      await considerTaps.record(
        sourceOriginal: original,
        phrase: alternative.phrase,
        alternative: alternative.alternative,
        reason: alternative.reason
      )
    }
  }

  /// Edits to the final message, straight onto the review so the redline follows.
  func updateCorrected(_ value: String) {
    guard var review else { return }
    review.updateCorrected(value)
    self.review = review
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

  func lookUp() {
    guard canLookUp else { return }
    prepareOutbound(.define(DefinePayload(term: input)))
  }

  /// Appends the current lookup to the learning log so `StudyCardBuilder` turns it into a
  /// drill. Deliberate rather than automatic: the log is append-only with no delete UI, so
  /// a word saved by accident cannot be taken back out of the deck without hand-editing
  /// the JSONL file. Looking a word up is not the same as wanting to memorize it.
  func saveLookupToStudy() {
    guard let lookup, !lookupSavedToStudy else { return }
    lookupSavedToStudy = true
    announce("Saved \(lookup.english) to Study.")
    studyLogTask = Task { [learningLog, provider, model] in
      await learningLog.append(
        client: "quick-check-dictionary",
        original: lookup.learningLogOriginal,
        corrected: lookup.english,
        explanation: lookup.learningLogExplanation,
        provider: provider.rawValue,
        model: model
      )
    }
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

  /// Copies the (possibly owner-edited) correction. `closeAfter` is the ⏎ path — copy
  /// and dismiss in one stroke; ⇧⌘C keeps the panel up.
  func copy(closeAfter: Bool) {
    guard let corrected = review?.corrected else { return }
    do {
      try pasteboard.write(corrected)
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
    } else if review != nil {
      guard !isBusy else { return }
      copy(closeAfter: true)
    } else {
      check()
    }
  }

  func backToInput() {
    sessionGeneration &+= 1
    outboundGateTask?.cancel()
    outboundGateTask = nil
    pendingOutbound = nil
    outboundSummary = nil
    isPreparingOutbound = false

    if activeOperationID != nil {
      announce(canceledAnnouncement)
    }
    activeOperationID = nil
    operationTask?.cancel()
    isChecking = false
    isLookingUp = false

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
    await studyLogTask?.value
    await considerTapTask?.value
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
    let generation = sessionGeneration
    outboundGateTask = Task { [weak self, preferences] in
      do {
        let destination = try await preferences.outboundDestination()
        let accepted = await preferences.hasAcceptedCurrentOutboundDisclosure(
          for: destination
        )
        guard !Task.isCancelled, let self, self.sessionGeneration == generation else { return }

        self.provider = destination.provider
        self.model = destination.model
        self.currentDestination = destination
        let configuredOutbound = payload.configured(for: destination)
        if OutboundConfirmationContext.quickCheckExternal.requiresConfirmation(
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
    case .define(let request):
      startDefine(request)
    }
  }

  private func startDefine(_ request: DefineRequest) {
    operationTask?.cancel()
    let operationID = UUID()
    activeOperationID = operationID

    isLookingUp = true
    userVisibleError = nil
    lookup = nil
    lookupSavedToStudy = false
    // A lookup and a grammar check answer different questions about different text; leaving
    // the previous check's review on screen under a dictionary entry would read as if the
    // entry were the correction.
    review = nil
    pickedAlternativeID = nil
    announce("Lookup started.")

    operationTask = Task { [weak self, grammar] in
      guard let self else { return }
      do {
        let entry = try await grammar.define(
          text: request.term,
          destination: request.destination
        )
        try Task.checkCancellation()
        guard self.activeOperationID == operationID else { return }
        self.lookup = entry
        self.finishOperation(operationID, announcement: "Lookup complete.")
      } catch {
        guard self.activeOperationID == operationID else { return }
        if Task.isCancelled || error is CancellationError || error as? BexError == .cancellation {
          self.finishOperation(operationID, announcement: "Lookup canceled.")
        } else {
          self.show(error)
          self.finishOperation(operationID, announcement: "Lookup failed.")
        }
      }
    }
  }

  private func startCheck(_ request: CheckRequest) {
    operationTask?.cancel()
    let operationID = UUID()
    activeOperationID = operationID

    isChecking = true
    userVisibleError = nil
    lookup = nil
    lookupSavedToStudy = false
    review = nil
    pickedAlternativeID = nil
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
        self.review = PromptGateReview(
          original: request.original,
          corrected: checked.corrected,
          explanation: checked.explanation
        )
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

  private func finishOperation(_ operationID: UUID, announcement: String) {
    guard activeOperationID == operationID else { return }
    activeOperationID = nil
    isChecking = false
    isLookingUp = false
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
      announce(canceledAnnouncement)
    }
    activeOperationID = nil
    operationTask?.cancel()
    isChecking = false
    isLookingUp = false

    draftPersistenceGeneration &+= 1
    draftTask?.cancel()
    isSuppressingDraftPersistence = true
    input = ""
    isSuppressingDraftPersistence = false
    draftTask = Task { [preferences] in
      await preferences.deleteSavedQuickDraft()
    }

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
    let generation = historyPersistenceGeneration
    let entry = HistoryEntry(
      id: UUID(),
      original: original,
      corrected: result.corrected,
      explanation: result.explanation,
      provider: provider,
      model: model,
      timestamp: Date(),
      profileName: writingStyleName
    )
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

  /// What to announce when an in-flight operation is torn down, for whichever of the
  /// two kinds is running.
  private var canceledAnnouncement: String {
    isLookingUp ? "Lookup canceled." : "Check canceled."
  }

  private func clearRenderedResult() {
    review = nil
    pickedAlternativeID = nil
    lookup = nil
    lookupSavedToStudy = false
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

  fileprivate struct DefinePayload {
    let term: String
  }

  fileprivate enum OutboundPayload {
    case check(CheckPayload)
    case define(DefinePayload)

    func configured(for destination: OutboundDestination) -> PendingOutbound {
      switch self {
      case .define(let payload):
        return .define(DefineRequest(term: payload.term, destination: destination))
      case .check(let payload):
        return .check(
          CheckRequest(
            original: payload.original,
            destination: destination,
            writingStyle: payload.writingStyle
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

  fileprivate struct DefineRequest {
    let term: String
    let destination: OutboundDestination
  }

  fileprivate enum PendingOutbound {
    case check(CheckRequest)
    case define(DefineRequest)

    var destination: OutboundDestination {
      switch self {
      case .check(let request): request.destination
      case .define(let request): request.destination
      }
    }

    var summary: QuickCheckOutboundSummary {
      switch self {
      case .define(let request):
        return QuickCheckOutboundSummary(
          action: "Look up",
          provider: request.destination.provider.displayName,
          model: request.destination.model,
          writingStyle: nil,
          fullDraft: request.term,
          disclosure:
            "The term shown here will be sent to \(request.destination.disclosureTarget)."
        )
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
      }
    }
  }
}
