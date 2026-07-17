import Foundation

@MainActor
final class QuickCheckViewModel: ObservableObject {
  @Published var input: String = "" {
    didSet {
      guard input != oldValue else { return }
      scheduleDraftPersistence()
    }
  }
  @Published private(set) var provider: LLMProvider = .openAI
  @Published private(set) var model: String = LLMProvider.openAI.defaultModel
  @Published private(set) var availableProfiles: [Profile] = []
  @Published private(set) var selectedProfileID: UUID?
  @Published private(set) var result: GrammarResult?
  @Published private(set) var diff: [DiffSegment] = []
  @Published private(set) var isChecking = false
  @Published private(set) var rewritingIntent: RewriteIntent?
  @Published var changesOnly = false
  @Published private(set) var setupError: String?
  @Published private(set) var userVisibleError: String?
  @Published private(set) var isContextLoaded = false
  @Published private(set) var copied = false

  private let preferences: PreferencesStore
  private let keychain: KeychainStore
  private let data: BexDataStore
  private let grammar: any GrammarServicing
  private let pasteboard: any PasteboardWriting
  private let onClose: @MainActor () -> Void

  private var operationTask: Task<Void, Never>?
  private var draftTask: Task<Void, Never>?
  private var copiedTask: Task<Void, Never>?
  private var historyTask: Task<Void, Never>?
  private var historyID: UUID?
  private var hasLoadedDraft = false
  private var closePrepared = false

  init(
    preferences: PreferencesStore,
    keychain: KeychainStore,
    data: BexDataStore,
    grammar: any GrammarServicing,
    pasteboard: any PasteboardWriting,
    onClose: @escaping @MainActor () -> Void
  ) {
    self.preferences = preferences
    self.keychain = keychain
    self.data = data
    self.grammar = grammar
    self.pasteboard = pasteboard
    self.onClose = onClose
  }

  var providerLabel: String { provider.displayName }
  var modelLabel: String { model }

  var profileLabel: String {
    selectedProfile?.name ?? "No Profile"
  }

  var selectedProfile: Profile? {
    availableProfiles.first { $0.id == selectedProfileID }
  }

  var isBusy: Bool {
    isChecking || rewritingIntent != nil
  }

  var canCheck: Bool {
    isContextLoaded && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && setupError == nil && !isBusy
  }

  var processingDisclosure: String {
    switch provider {
    case .ollama:
      "Processed locally by Ollama."
    case .openAICodex:
      "Processed through your ChatGPT Codex subscription."
    default:
      "Sent to \(provider.displayName) for processing."
    }
  }

  func loadContext() async {
    closePrepared = false
    operationTask?.cancel()
    isContextLoaded = false
    userVisibleError = nil

    provider = await preferences.selectedProvider()
    model = await preferences.selectedModel(for: provider)
    if !hasLoadedDraft {
      input = await preferences.quickDraft()
      hasLoadedDraft = true
    }

    do {
      availableProfiles = try await data.loadProfiles()
    } catch {
      availableProfiles = []
      show(error)
    }

    let activeID = await preferences.activeProfileID()
    let defaultID = await preferences.defaultProfileID()
    if let activeID, availableProfiles.contains(where: { $0.id == activeID }) {
      selectedProfileID = activeID
    } else if let defaultID, availableProfiles.contains(where: { $0.id == defaultID }) {
      selectedProfileID = defaultID
      await preferences.setActiveProfileID(defaultID)
    } else {
      selectedProfileID = nil
      await preferences.setActiveProfileID(nil)
    }

    await refreshSetupState()
    isContextLoaded = true
  }

  func check() {
    guard canCheck else { return }
    operationTask?.cancel()
    let original = input
    let selectedProvider = provider
    let selectedModel = model
    let profile = selectedProfile

    isChecking = true
    rewritingIntent = nil
    userVisibleError = nil
    copied = false
    result = nil
    diff = []
    changesOnly = false
    historyID = nil

    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        let checked = try await grammar.check(
          text: original,
          provider: selectedProvider,
          model: selectedModel,
          profilePrompt: profile?.prompt
        )
        try Task.checkCancellation()
        result = checked
        diff = WordDiff.compute(original: original, corrected: checked.corrected)
        isChecking = false
        saveInitialHistory(
          original: original,
          result: checked,
          provider: selectedProvider,
          model: selectedModel,
          profileName: profile?.name
        )
      } catch {
        isChecking = false
        show(error)
      }
    }
  }

  func rewrite(_ intent: RewriteIntent) {
    guard let current = result, !isBusy else { return }
    operationTask?.cancel()
    let original = input
    let selectedProvider = provider
    let selectedModel = model
    let historyID = historyID
    let priorHistoryTask = historyTask

    rewritingIntent = intent
    userVisibleError = nil
    copied = false

    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        let rewritten = try await grammar.rewrite(
          text: current.corrected,
          intent: intent,
          provider: selectedProvider,
          model: selectedModel
        )
        try Task.checkCancellation()
        let explanation = "\(current.explanation)\n\nRewrite applied: \(intent.label)"
        let rewrittenResult = GrammarResult(
          corrected: rewritten,
          explanation: explanation
        )
        result = rewrittenResult
        diff = WordDiff.compute(original: original, corrected: rewritten)
        rewritingIntent = nil

        guard let historyID else { return }
        historyTask = Task { [weak self] in
          await priorHistoryTask?.value
          guard let self else { return }
          do {
            try await data.updateHistory(
              id: historyID,
              corrected: rewritten,
              explanation: explanation
            )
          } catch {
            userVisibleError = "Rewrite complete, but history could not be updated."
          }
        }
      } catch {
        rewritingIntent = nil
        show(error)
      }
    }
  }

  func selectProfile(id: UUID?) async {
    guard id == nil || availableProfiles.contains(where: { $0.id == id }) else { return }
    selectedProfileID = id
    await preferences.setActiveProfileID(id)
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
        close()
      }
    } catch {
      show(error)
    }
  }

  func useResultAsInput() {
    guard let corrected = result?.corrected else { return }
    input = corrected
    clearRenderedResult()
  }

  func recheck() {
    guard !isBusy else { return }
    clearRenderedResult()
    check()
  }

  func close() {
    prepareForClose()
    onClose()
  }

  func panelDidClose() {
    prepareForClose()
  }

  func replaceDraft(with text: String) {
    input = text
    clearRenderedResult()
    Task { [preferences] in
      await preferences.setQuickDraft(text)
    }
  }

  func waitForCurrentWork() async {
    await operationTask?.value
    await historyTask?.value
  }

  private func prepareForClose() {
    guard !closePrepared else { return }
    closePrepared = true
    operationTask?.cancel()
    operationTask = nil
    draftTask?.cancel()
    let draft = input
    Task { [preferences] in
      await preferences.setQuickDraft(draft)
    }
    isChecking = false
    rewritingIntent = nil
    copiedTask?.cancel()
    copied = false
    clearRenderedResult()
    userVisibleError = nil
  }

  private func scheduleDraftPersistence() {
    draftTask?.cancel()
    let draft = input
    draftTask = Task { [preferences] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      await preferences.setQuickDraft(draft)
    }
  }

  private func refreshSetupState() async {
    do {
      if provider == .ollama {
        _ = try OllamaURL.normalize(await preferences.ollamaURL())
        setupError = nil
      } else if try await keychain.hasSetup(for: provider) {
        setupError = nil
      } else {
        setupError = BexError.missingSetup(provider).errorDescription
      }
    } catch {
      setupError = error.localizedDescription
    }
  }

  private func saveInitialHistory(
    original: String,
    result: GrammarResult,
    provider: LLMProvider,
    model: String,
    profileName: String?
  ) {
    let id = UUID()
    historyID = id
    let entry = HistoryEntry(
      id: id,
      original: original,
      corrected: result.corrected,
      explanation: result.explanation,
      provider: provider,
      model: model,
      timestamp: Date(),
      profileName: profileName
    )
    historyTask = Task { [weak self, data] in
      do {
        try await data.appendHistory(entry)
      } catch {
        self?.userVisibleError = "Correction complete, but history could not be saved."
      }
    }
  }

  private func clearRenderedResult() {
    result = nil
    diff = []
    changesOnly = false
    historyID = nil
  }

  private func show(_ error: Error) {
    if Task.isCancelled || error is CancellationError || error as? BexError == .cancellation {
      return
    }
    userVisibleError = error.localizedDescription
  }
}
