import Combine
import Foundation

@MainActor
final class PromptGateViewModel: ObservableObject {
  @Published private(set) var phase: PromptGatePhase = .closed
  @Published private(set) var session: PromptGateSession?
  @Published var draft = ""
  @Published private(set) var review: PromptGateReview?
  @Published private(set) var selectedProvider: LLMProvider = .openAI
  @Published private(set) var selectedModel = LLMProvider.openAI.defaultModel
  @Published private(set) var selectedClient: PromptClient = .claudeCode
  @Published private(set) var deliveryMode: PromptDeliveryMode = .sendAfterApproval
  @Published private(set) var selectedClientStatus: HookInstallationStatus = .notInstalled
  @Published private(set) var providerIsSetUp = false
  @Published private(set) var isAccessibilityTrusted = false
  @Published private(set) var errorMessage: String?

  private let preferences: PreferencesStore
  private let keychain: KeychainStore
  private let promptGrammar: any PromptGrammarServicing
  private let targetService: any PromptTargetServicing
  private let approvalStore: PromptApprovalStore
  private let hookManager: any HookInstallationManaging
  private let hookResponder: any HookReviewResponding
  private let closePanel: @MainActor () -> Void
  private let openSettingsCallback: @MainActor () -> Void

  private var currentTask: Task<Void, Never>?
  private var currentWorkID: UUID?
  private var generation = UUID()
  private var activeReceiptID: UUID?

  init(
    preferences: PreferencesStore,
    keychain: KeychainStore,
    promptGrammar: any PromptGrammarServicing,
    targetService: any PromptTargetServicing,
    approvalStore: PromptApprovalStore,
    hookManager: any HookInstallationManaging,
    hookResponder: any HookReviewResponding,
    onClose: @escaping @MainActor () -> Void,
    onOpenSettings: @escaping @MainActor () -> Void
  ) {
    self.preferences = preferences
    self.keychain = keychain
    self.promptGrammar = promptGrammar
    self.targetService = targetService
    self.approvalStore = approvalStore
    self.hookManager = hookManager
    self.hookResponder = hookResponder
    closePanel = onClose
    openSettingsCallback = onOpenSettings
    isAccessibilityTrusted = targetService.isAccessibilityTrusted
  }

  var clientIsLocked: Bool { session?.knownClient != nil }
  var canReview: Bool {
    phase == .composing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var canApprove: Bool {
    phase == .reviewing
      && review?.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
  var providerDisclosure: String {
    selectedProvider == .ollama
      ? "Ollama processes the original draft locally."
      : "Cloud correction sends the original draft to \(selectedProvider.displayName)."
  }

  @discardableResult
  func begin(_ session: PromptGateSession) -> Bool {
    guard phase == .closed else { return false }

    currentTask?.cancel()
    generation = UUID()
    let sessionGeneration = generation
    self.session = session
    draft = session.initialDraft
    review = nil
    errorMessage = nil
    phase = .composing
    isAccessibilityTrusted = targetService.isAccessibilityTrusted

    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      await self?.loadSession(
        sessionID: session.id,
        generation: sessionGeneration,
        workID: workID
      )
    }
    return true
  }

  func acceptDisclosure() {
    guard phase == .onboarding, let session else { return }
    let sessionGeneration = generation
    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await preferences.setPromptGateDisclosureAccepted(true)
      guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
        self.finishWork(workID)
        return
      }
      self.finishWork(workID)
      if self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        self.phase = .composing
      } else {
        self.startCorrection()
      }
    }
  }

  func requestAccessibility() {
    isAccessibilityTrusted = targetService.requestAccessibilityTrust()
  }

  func check() {
    guard phase == .composing else { return }
    guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorMessage = BexError.emptyInput.localizedDescription
      return
    }
    startCorrection()
  }

  func approve() {
    guard phase == .reviewing,
      let session,
      let review,
      !review.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      if phase == .reviewing {
        errorMessage = BexError.emptyInput.localizedDescription
      }
      return
    }

    let correction = review.corrected
    let client = session.knownClient ?? selectedClient
    let sessionGeneration = generation
    phase = .delivering
    errorMessage = nil

    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var issuedReceipt: UUID?
      do {
        let status = await hookManager.status(for: client)
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          self.finishWork(workID)
          return
        }
        selectedClientStatus = status

        if session.hookRequestID != nil {
          guard status.permitsReceipt else {
            throw BexError.promptDeliveryFailed(
              "Bex could not authorize this corrected prompt."
            )
          }
          let context = session.target.hookContext
          issuedReceipt = try await approvalStore.issue(
            client: client,
            text: correction,
            sessionID: context?.sessionID,
            cwd: context?.cwd
          )
          activeReceiptID = issuedReceipt
        }

        if let requestID = session.hookRequestID {
          try await hookResponder.complete(
            requestID: requestID,
            outcome: .approved,
            awaitAcknowledgement: true
          )
        }
        try Task.checkCancellation()
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          throw CancellationError()
        }

        let pressReturn = deliveryMode == .sendAfterApproval
          && session.target.supportsAutomaticSubmit
        _ = try await targetService.deliver(
          correction,
          to: session.target,
          pressReturn: pressReturn
        )
        activeReceiptID = nil
        finishWork(workID)
        closeCurrentSession()
      } catch is CancellationError {
        if let issuedReceipt {
          try? await approvalStore.revoke(id: issuedReceipt)
        }
        if self.isCurrent(sessionID: session.id, generation: sessionGeneration),
          phase != .invalidated
        {
          activeReceiptID = nil
          phase = .reviewing
          finishWork(workID)
        }
      } catch {
        if let issuedReceipt {
          try? await approvalStore.revoke(id: issuedReceipt)
        }
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          self.finishWork(workID)
          return
        }
        activeReceiptID = nil
        phase = .reviewing
        errorMessage = self.message(for: error)
        finishWork(workID)
      }
    }
  }

  func backToEdit() {
    guard phase == .reviewing, let review else { return }
    draft = review.original
    self.review = nil
    errorMessage = nil
    phase = .composing
  }

  func cancel() {
    guard let session, phase != .closed else { return }
    currentTask?.cancel()
    let receiptID = activeReceiptID
    activeReceiptID = nil
    let sessionGeneration = generation
    phase = .delivering

    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if let receiptID {
        try? await approvalStore.revoke(id: receiptID)
      }
      if let requestID = session.hookRequestID {
        try? await hookResponder.complete(
          requestID: requestID,
          outcome: .cancelled,
          awaitAcknowledgement: false
        )
      }
      guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
        self.finishWork(workID)
        return
      }
      finishWork(workID)
      closeCurrentSession()
    }
  }

  func invalidateHookRequest(id: UUID) {
    guard session?.hookRequestID == id, phase != .closed else { return }
    currentTask?.cancel()
    let receiptID = activeReceiptID
    activeReceiptID = nil
    generation = UUID()
    phase = .invalidated
    errorMessage = "Bex could not review this prompt. The original was blocked."
    currentWorkID = nil
    currentTask = nil
    if let receiptID {
      Task { try? await approvalStore.revoke(id: receiptID) }
    }
  }

  func waitForCurrentWork() async {
    while let task = currentTask {
      await task.value
      await Task.yield()
    }
  }

  func updateCorrected(_ value: String) {
    guard phase == .reviewing, var review else { return }
    review.updateCorrected(value)
    self.review = review
    errorMessage = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? BexError.emptyInput.localizedDescription
      : nil
  }

  func setSelectedClient(_ client: PromptClient) {
    guard !clientIsLocked, phase == .composing || phase == .reviewing else { return }
    selectedClient = client
    Task { await preferences.setPreferredPromptClient(client) }
  }

  func openSettings() {
    openSettingsCallback()
  }

  private func loadSession(sessionID: UUID, generation: UUID, workID: UUID) async {
    let provider = await preferences.selectedProvider()
    let model = await preferences.selectedModel(for: provider)
    let preferredClient = await preferences.preferredPromptClient()
    let mode = await preferences.promptDeliveryMode()
    let disclosureAccepted = await preferences.promptGateDisclosureAccepted()
    let setup = (try? await keychain.hasSetup(for: provider)) ?? false
    guard isCurrent(sessionID: sessionID, generation: generation), let session else {
      finishWork(workID)
      return
    }

    selectedProvider = provider
    selectedModel = model
    selectedClient = session.knownClient ?? preferredClient
    deliveryMode = mode
    providerIsSetUp = setup
    selectedClientStatus = await hookManager.status(for: selectedClient)
    guard isCurrent(sessionID: sessionID, generation: generation) else {
      finishWork(workID)
      return
    }
    finishWork(workID)

    if !disclosureAccepted {
      phase = .onboarding
    } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      phase = .composing
    } else {
      startCorrection()
    }
  }

  private func startCorrection() {
    guard let session else { return }
    let original = draft
    guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      phase = .composing
      errorMessage = BexError.emptyInput.localizedDescription
      return
    }

    let provider = selectedProvider
    let model = selectedModel
    let sessionGeneration = generation
    phase = .checking
    errorMessage = nil
    review = nil

    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await promptGrammar.checkPrompt(
          text: original,
          provider: provider,
          model: model
        )
        try Task.checkCancellation()
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration),
          phase == .checking
        else {
          self.finishWork(workID)
          return
        }
        review = PromptGateReview(
          original: original,
          corrected: result.corrected,
          explanation: result.explanation
        )
        phase = .reviewing
        finishWork(workID)
      } catch is CancellationError {
        self.finishWork(workID)
      } catch {
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          self.finishWork(workID)
          return
        }
        phase = .composing
        errorMessage = self.message(for: error)
        finishWork(workID)
      }
    }
  }

  private func isCurrent(sessionID: UUID, generation: UUID) -> Bool {
    self.generation == generation && session?.id == sessionID && phase != .closed
  }

  private func finishWork(_ workID: UUID) {
    guard currentWorkID == workID else { return }
    currentWorkID = nil
    currentTask = nil
  }

  private func closeCurrentSession() {
    guard let session else { return }
    targetService.discard(session.target)
    generation = UUID()
    currentWorkID = nil
    currentTask = nil
    activeReceiptID = nil
    self.session = nil
    draft = ""
    review = nil
    errorMessage = nil
    phase = .closed
    closePanel()
  }

  private func message(for error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription,
      !description.isEmpty
    {
      return description
    }
    return BexError.promptDeliveryFailed(error.localizedDescription).localizedDescription
  }
}
