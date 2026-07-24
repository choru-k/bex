import Combine
import Foundation

@MainActor
final class PromptGateViewModel: ObservableObject {
  private struct PendingCorrection {
    let sessionID: UUID
    let generation: UUID
    let original: String
    let destination: OutboundDestination
    let protectedText: PromptTechnicalSpanProtector.ProtectedText
    let forcesConfirmation: Bool
  }

  @Published private(set) var phase: PromptGatePhase = .closed
  @Published private(set) var session: PromptGateSession?
  @Published var draft = ""
  @Published private(set) var review: PromptGateReview?
  @Published private(set) var selectedProvider: LLMProvider = .openAI
  @Published private(set) var selectedModel = LLMProvider.openAI.defaultModel
  @Published private(set) var hookClientStatus: HookInstallationStatus = .notInstalled
  @Published private(set) var providerIsSetUp = false
  @Published private(set) var isLoadingSession = false
  @Published private(set) var isAccessibilityTrusted = false
  @Published private(set) var accessibilityStatusMessage: String?
  @Published private(set) var errorMessage: String?
  @Published private(set) var deliveryFailureEffect: PromptDeliveryEffect?
  @Published private(set) var focusRequest: PromptGateFocusRequest?
  @Published private(set) var accessibilityAnnouncement: String?
  @Published private(set) var showsDiscardConfirmation = false
  @Published private(set) var showsCheckpointReplacementConfirmation = false
  private(set) var accessibilityAnnouncementHistory: [String] = []

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
  private var retiredTasks: [Task<Void, Never>] = []
  private var generation = UUID()
  private var activeReceiptID: UUID?
  private var checkpoint: PromptGateReview?
  private var confirmedOutboundDraft: String?
  private var confirmedOutboundDestination: OutboundDestination?
  private var configuredDestination: OutboundDestination?
  private var replacementConfirmedDraft: String?
  private var hasAcceptedDestinationDisclosure = false
  private var confirmsHookOutboundPayloads = true
  private var isClosing = false
  private var pendingCorrection: PendingCorrection?

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

  var providerDisclosureIsAccepted: Bool { hasAcceptedDestinationDisclosure }
  var needsProviderSetup: Bool { !providerIsSetUp }

  var hasTerminalDeliveryFailure: Bool {
    deliveryFailureEffect.map { !$0.isFullRetrySafe } ?? false
  }

  var canEditCorrection: Bool {
    phase == .reviewing && !hasTerminalDeliveryFailure
  }

  var canReview: Bool {
    phase == .composing
      && providerIsSetUp
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canApprove: Bool {
    phase == .reviewing
      && review?.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      && (deliveryFailureEffect == nil || deliveryFailureEffect?.isFullRetrySafe == true)
  }

  var canSkipHookCheck: Bool {
    phase == .checking
      && session?.hookRequestID != nil
      && session?.knownClient != .ohMyPi
  }

  var isNoChangeReview: Bool {
    review?.hasChanges == false
  }

  var accessibleDiffSummary: String {
    guard let review else { return "No differences" }
    return AccessibleDiffSummary.make(from: review.diff)
  }

  var reviewTitle: String {
    guard let session else { return "Review Correction" }
    switch session.target.kind {
    case .capturedField:
      return "Review Message for \(session.target.applicationName)"
    case .composerPaste, .managedDraft:
      return "Review Correction for \(session.target.applicationName)"
    case .copyOnly:
      return "Review Correction"
    }
  }

  var reviewContextDescription: String {
    guard let session else { return "" }
    let checker = "Checked by \(selectedProvider.displayName) · \(selectedModel)"
    switch session.source {
    case .capturedField:
      return "Captured from \(session.target.applicationName) · \(checker)"
    case .composer:
      return "Created in Bex · \(checker)"
    case .hook:
      let requester = session.knownClient?.displayName ?? session.target.applicationName
      return "Requested by \(requester) · \(checker)"
    }
  }

  var reviewPendingStatus: String {
    switch session?.target.kind {
    case .capturedField:
      return "Nothing has been sent."
    case .composerPaste:
      return "Nothing has been pasted."
    case .copyOnly:
      return "Nothing has been copied."
    case .managedDraft:
      return "Nothing has been staged."
    case nil:
      return ""
    }
  }

  var providerDisclosure: String {
    guard let destination = pendingCorrection?.destination ?? configuredDestination else {
      return "Bex cannot prepare an outbound destination until the provider setup is valid."
    }
    return
      "Bex will send the masked payload below to \(destination.disclosureTarget), model \(destination.model)."
  }

  var protectedSpanDisclosure: String {
    let kinds = PromptTechnicalSpanProtector.userFacingProtectedSpanKinds.joined(separator: ", ")
    let provider =
      (pendingCorrection?.destination ?? configuredDestination)?.provider
      ?? selectedProvider
    return
      "Before the request, Bex replaces recognized \(kinds) with placeholders and restores those recognized spans locally after correction. Unmatched prose and unrecognized sensitive text remain visible to \(provider.displayName)."
  }

  var outboundPayload: String {
    pendingCorrection?.protectedText.masked ?? ""
  }

  var confirmationActionLabel: String {
    let provider =
      (pendingCorrection?.destination ?? configuredDestination)?.provider
      ?? selectedProvider
    return provider == .ollama
      ? "Check with Ollama"
      : "Send to \(provider.displayName) for Check"
  }

  var composerPrimaryActionLabel: String {
    if let checkpoint, checkpoint.original == draft {
      return "Return to Review"
    }
    if checkpoint != nil {
      return "Check Again with \(selectedProvider.displayName)"
    }
    return "Check with \(selectedProvider.displayName)"
  }

  var availableDeliveryActions: [PromptDeliveryAction] {
    guard phase == .reviewing, let target = session?.target else { return [] }
    if hasTerminalDeliveryFailure {
      return []
    }
    return target.availableDeliveryActions
  }

  var primaryDeliveryAction: PromptDeliveryAction? {
    guard let target = session?.target else { return nil }
    if session?.hookRequestID != nil {
      return target.availableDeliveryActions.first
    }
    switch target.kind {
    case .copyOnly:
      return .copyCorrection
    case .composerPaste:
      return .pasteInDestination
    case .capturedField:
      return .pasteInDestination
    case .managedDraft:
      return .pasteInDestination
    }
  }

  var destinationLabel: String {
    session?.target.destinationLabel ?? "destination"
  }

  var permissionGuidance: String {
    guard let session else { return "" }
    if session.hookRequestID != nil {
      if isAccessibilityTrusted, session.target.kind == .composerPaste {
        return
          "This client hook supplied the prompt. Accessibility is used only to paste the approved correction; Bex will not press Return."
      }
      return
        "This client hook supplied the prompt without using Accessibility. You can still review it; Bex will copy the approved correction for manual replacement."
    }
    if isAccessibilityTrusted {
      return
        "Accessibility enables manual capture and replacement in other apps. If access was just granted, invoke Fix & Send again to capture the focused field."
    }
    return
      "Accessibility is required only for manual capture and replacement. Without it, Fix & Send is copy-only. Grant access, then invoke Fix & Send again. Enabled client hooks can still supply prompts without this permission."
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
    checkpoint = nil
    confirmedOutboundDraft = nil
    confirmedOutboundDestination = nil
    configuredDestination = nil
    pendingCorrection = nil
    replacementConfirmedDraft = nil
    isClosing = false
    deliveryFailureEffect = nil
    errorMessage = nil
    accessibilityStatusMessage = nil
    showsDiscardConfirmation = false
    showsCheckpointReplacementConfirmation = false
    accessibilityAnnouncement = nil
    accessibilityAnnouncementHistory = []
    isLoadingSession = true
    phase = .onboarding
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
    guard phase == .onboarding,
      !isLoadingSession,
      providerIsSetUp,
      let session,
      let pendingCorrection,
      pendingCorrection.sessionID == session.id,
      pendingCorrection.generation == generation,
      pendingCorrection.original == draft,
      pendingCorrection.destination == configuredDestination
    else {
      return
    }
    let outboundDraft = pendingCorrection.original
    let destination = pendingCorrection.destination
    let sessionGeneration = generation
    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let setup = await providerIsSetUp(for: destination)
      guard self.isCurrent(sessionID: session.id, generation: sessionGeneration),
        self.draft == outboundDraft,
        self.configuredDestination == destination,
        self.pendingCorrection?.destination == destination,
        self.pendingCorrection?.protectedText.masked == pendingCorrection.protectedText.masked,
        setup
      else {
        if self.isCurrent(sessionID: session.id, generation: sessionGeneration), !setup {
          providerIsSetUp = false
          phase = .composing
          errorMessage =
            "Set up \(destination.provider.displayName) in Settings, then return to Fix & Send."
          requestFocus(keyboard: .recoveryAction, accessibility: .errorHeading)
        }
        self.finishWork(workID)
        return
      }
      await preferences.acceptCurrentOutboundDisclosure(for: destination)
      guard self.isCurrent(sessionID: session.id, generation: sessionGeneration),
        self.draft == outboundDraft,
        self.configuredDestination == destination,
        self.pendingCorrection?.destination == destination
      else {
        self.finishWork(workID)
        return
      }
      hasAcceptedDestinationDisclosure = true
      confirmedOutboundDraft = outboundDraft
      confirmedOutboundDestination = destination
      finishWork(workID)
      gateCorrection(pendingCorrection)
    }
  }

  func requestAccessibility() {
    let wasTrusted = isAccessibilityTrusted
    isAccessibilityTrusted = targetService.requestAccessibilityTrust()
    updateAccessibilityStatus(wasTrusted: wasTrusted)
  }

  func refreshAccessibilityState() {
    let wasTrusted = isAccessibilityTrusted
    isAccessibilityTrusted = targetService.isAccessibilityTrusted
    updateAccessibilityStatus(wasTrusted: wasTrusted)
  }

  func check() {
    guard phase == .composing else { return }
    guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorMessage = BexError.emptyInput.localizedDescription
      requestFocus(keyboard: .draftEditor, accessibility: .errorHeading)
      announce(errorMessage ?? "The prompt is empty.")
      return
    }

    if let checkpoint, checkpoint.original == draft {
      review = checkpoint
      errorMessage = nil
      deliveryFailureEffect = nil
      phase = .reviewing
      focusReview(checkpoint)
      return
    }

    if checkpoint?.hasHumanEdits == true, replacementConfirmedDraft != draft {
      showsCheckpointReplacementConfirmation = true
      requestFocus(keyboard: .primaryAction, accessibility: .discardAlert)
      announce(
        "Replace edited correction? Checking this changed source will replace the human-edited correction checkpoint."
      )
      return
    }

    prepareCorrection()
  }

  func confirmCheckpointReplacement() {
    guard showsCheckpointReplacementConfirmation, phase == .composing else { return }
    showsCheckpointReplacementConfirmation = false
    replacementConfirmedDraft = draft
    prepareCorrection()
  }

  func keepCheckpoint() {
    showsCheckpointReplacementConfirmation = false
    requestFocus(keyboard: .draftEditor, accessibility: .composerHeading)
  }

  func approve() {
    guard let action = primaryDeliveryAction else { return }
    performDelivery(action)
  }

  func skipCheckAndSendOriginal() {
    guard canSkipHookCheck, let session, let requestID = session.hookRequestID else { return }

    retireCurrentTask()
    let sessionGeneration = generation
    phase = .delivering
    errorMessage = nil
    isClosing = true
    announce("Skipping the check and sending the original prompt.")

    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await hookResponder.complete(
          requestID: requestID,
          outcome: .bypassed,
          awaitAcknowledgement: false
        )
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          self.finishWork(workID)
          return
        }
        finishWork(workID)
        closeCurrentSession()
      } catch {
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          self.finishWork(workID)
          return
        }
        isClosing = false
        phase = .invalidated
        errorMessage =
          "Bex could not send the original prompt because the hook request is no longer active."
        finishWork(workID)
        requestFocus(keyboard: .recoveryAction, accessibility: .statusHeading)
        announce(errorMessage ?? "The hook request is no longer active.")
      }
    }
  }

  func performDelivery(_ action: PromptDeliveryAction) {
    guard phase == .reviewing,
      let session,
      let review,
      !review.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      availableDeliveryActions.contains(action)
    else {
      if phase == .reviewing,
        self.review?.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
      {
        errorMessage = BexError.emptyInput.localizedDescription
      }
      return
    }

    let correction = review.corrected
    let sessionGeneration = generation
    deliveryFailureEffect = nil
    phase = .delivering
    errorMessage = nil
    announce("Delivering the correction to \(session.target.destinationLabel).")
    showsDiscardConfirmation = false

    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var issuedReceipt: UUID?
      do {
        if session.hookRequestID != nil {
          guard let client = session.knownClient else {
            throw PromptDeliveryFailure(
              effect: .none,
              underlyingError: BexError.promptDeliveryFailed(
                "Bex could not authorize this corrected prompt."
              )
            )
          }
          let context = session.target.hookContext
          let status = await hookStatus(for: session)
          guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
            self.finishWork(workID)
            return
          }
          hookClientStatus = status
          guard status.permitsReceipt else {
            throw PromptDeliveryFailure(
              effect: .none,
              underlyingError: BexError.promptDeliveryFailed(
                "Bex could not authorize this corrected prompt."
              )
            )
          }
          if context?.client != .ohMyPi {
            issuedReceipt = try await approvalStore.issue(
              client: client,
              integrationID: context?.integrationID,
              text: correction,
              sessionID: context?.sessionID,
              cwd: context?.cwd
            )
            activeReceiptID = issuedReceipt
          }
          if let requestID = session.hookRequestID {
            do {
              try await hookResponder.complete(
                requestID: requestID,
                outcome: .approved,
                awaitAcknowledgement: true,
                approvedPrompt: correction,
                integrationID: context?.integrationID
              )
            } catch {
              throw PromptDeliveryFailure(effect: .unknown, underlyingError: error)
            }
          }
        }
        try Task.checkCancellation()
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          throw CancellationError()
        }

        let outcome = try await targetService.deliver(
          correction,
          to: session.target,
          action: action
        )
        activeReceiptID = nil
        finishWork(workID)
        announce(successAnnouncement(for: outcome, target: session.target))
        closeCurrentSession()
      } catch is CancellationError {
        if let issuedReceipt {
          try? await approvalStore.revoke(id: issuedReceipt)
        }
        guard !self.isClosing else { return }
        if self.isCurrent(sessionID: session.id, generation: sessionGeneration),
          phase != .invalidated
        {
          activeReceiptID = nil
          phase = .reviewing
          finishWork(workID)
          focusReview(review)
        }
      } catch {
        if let issuedReceipt {
          try? await approvalStore.revoke(id: issuedReceipt)
        }
        guard !self.isClosing else { return }
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          self.finishWork(workID)
          return
        }
        activeReceiptID = nil
        let failure =
          error as? PromptDeliveryFailure
          ?? PromptDeliveryFailure(effect: .none, underlyingError: error)
        deliveryFailureEffect = failure.effect
        phase = .reviewing
        errorMessage = recoveryMessage(for: failure, action: action, target: session.target)
        requestFocus(keyboard: .recoveryAction, accessibility: .errorHeading)
        announce(errorMessage ?? "Delivery failed.")
        finishWork(workID)
      }
    }
  }

  func finishAfterPartialDelivery() {
    guard phase == .reviewing,
      let effect = deliveryFailureEffect,
      !effect.isFullRetrySafe
    else { return }
    closeCurrentSession()
  }

  func backToEdit() {
    guard phase == .reviewing, !hasTerminalDeliveryFailure, let review else { return }
    checkpoint = review
    draft = review.original
    self.review = nil
    errorMessage = nil
    deliveryFailureEffect = nil
    phase = .composing
    requestFocus(keyboard: .draftEditor, accessibility: .composerHeading)
    announce("Back to the prompt editor. The correction is checkpointed.")
  }

  func cancel() {
    guard session != nil, phase != .closed, phase != .delivering else { return }
    if hasTerminalDeliveryFailure {
      finishAfterPartialDelivery()
      return
    }
    if hasUndeliveredHumanEdits {
      showsDiscardConfirmation = true
      requestFocus(keyboard: .primaryAction, accessibility: .discardAlert)
      announce(
        "Discard your correction edits? The AI correction will remain available only if you keep editing."
      )
      return
    }
    discardCurrentSession()
  }

  func confirmDiscard() {
    guard showsDiscardConfirmation, phase != .delivering, !hasTerminalDeliveryFailure else {
      return
    }
    showsDiscardConfirmation = false
    discardCurrentSession()
  }

  func keepEditing() {
    showsDiscardConfirmation = false
    if phase == .reviewing, let review {
      focusReview(review)
    } else {
      requestFocus(keyboard: .draftEditor, accessibility: .composerHeading)
    }
  }

  func invalidateHookRequest(id: UUID) {
    guard session?.hookRequestID == id, phase != .closed else { return }
    retireCurrentTask()
    let receiptID = activeReceiptID
    activeReceiptID = nil
    generation = UUID()
    phase = .invalidated
    errorMessage =
      "This hook request is no longer active. The original prompt remained blocked; invoke the client action again."
    currentWorkID = nil
    currentTask = nil
    requestFocus(keyboard: .recoveryAction, accessibility: .statusHeading)
    announce(errorMessage ?? "The hook request is no longer active.")
    if let receiptID {
      Task { try? await approvalStore.revoke(id: receiptID) }
    }
  }

  func waitForCurrentWork() async {
    while currentTask != nil || !retiredTasks.isEmpty {
      if let task = currentTask {
        await task.value
      }
      let retiredCount = retiredTasks.count
      for task in retiredTasks.prefix(retiredCount) {
        await task.value
      }
      retiredTasks.removeFirst(min(retiredCount, retiredTasks.count))
    }
  }

  func updateCorrected(_ value: String) {
    guard phase == .reviewing, var review else { return }
    review.updateCorrected(value)
    self.review = review
    errorMessage =
      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? BexError.emptyInput.localizedDescription
      : nil
  }


  func openSettings() {
    openSettingsCallback()
  }

  func refreshConfigurationAfterSettings() async {
    guard let session, phase != .closed else { return }
    let sessionID = session.id
    let sessionGeneration = generation
    let provider = await preferences.selectedProvider()
    let model = await preferences.selectedModel(for: provider)
    let hookOutboundConfirmation = await preferences.confirmsHookOutboundPayloads()
    let destination: OutboundDestination?
    let destinationErrorMessage: String?
    do {
      destination = try await preferences.outboundDestination()
      destinationErrorMessage = nil
    } catch {
      destination = nil
      destinationErrorMessage = error.localizedDescription
    }
    let acceptedDisclosure =
      if let destination {
        await preferences.hasAcceptedCurrentOutboundDisclosure(for: destination)
      } else {
        false
      }
    let setup =
      if let destination {
        await providerIsSetUp(for: destination)
      } else {
        false
      }
    let clientStatus = await hookStatus(for: session)
    guard isCurrent(sessionID: sessionID, generation: sessionGeneration) else { return }

    let destinationChanged = configuredDestination != destination
    let wasAccessibilityTrusted = isAccessibilityTrusted
    selectedProvider = destination?.provider ?? provider
    selectedModel = destination?.model ?? model
    configuredDestination = destination
    hookClientStatus = clientStatus
    hasAcceptedDestinationDisclosure = acceptedDisclosure
    confirmsHookOutboundPayloads = hookOutboundConfirmation
    providerIsSetUp = setup
    isAccessibilityTrusted = targetService.isAccessibilityTrusted
    if destinationChanged {
      confirmedOutboundDraft = nil
      confirmedOutboundDestination = nil
      pendingCorrection = nil
    }
    if let destinationErrorMessage {
      if phase == .onboarding {
        phase = .composing
      }
      errorMessage = destinationErrorMessage
      requestFocus(keyboard: .recoveryAction, accessibility: .errorHeading)
    } else if destinationChanged, phase == .onboarding,
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let destination
    {
      let pending = PendingCorrection(
        sessionID: session.id,
        generation: sessionGeneration,
        original: draft,
        destination: destination,
        protectedText: PromptTechnicalSpanProtector().protect(draft),
        forcesConfirmation: true
      )
      pendingCorrection = pending
      gateCorrection(pending)
    }
    if wasAccessibilityTrusted != isAccessibilityTrusted {
      updateAccessibilityStatus(wasTrusted: wasAccessibilityTrusted)
    }
  }

  func deliveryActionLabel(_ action: PromptDeliveryAction) -> String {
    guard let session else { return "Deliver Correction" }
    let targetLabel = session.target.label(for: action)
    return session.hookRequestID == nil ? targetLabel : "Acknowledge & \(targetLabel)"
  }

  var deliveryGuidanceIntroduction: String {
    guard let target = session?.target else { return "" }
    if target.kind == .capturedField {
      return
        "Bex will verify that the same \(target.applicationName) field still contains your original draft before replacing it."
    }
    return target.guidance
  }

  func deliveryEffectDescription(for action: PromptDeliveryAction) -> String {
    guard let target = session?.target else { return "" }
    switch action {
    case .copyCorrection:
      return "Copies the correction to the Clipboard. Nothing is pasted or submitted."
    case .pasteInDestination:
      switch target.kind {
      case .capturedField:
        return "Replaces the captured draft in \(target.applicationName) without sending."
      case .managedDraft:
        return "Stages the correction in \(target.applicationName) without sending."
      case .composerPaste, .copyOnly:
        return "Pastes the correction in \(target.applicationName). Bex will not press Return."
      }
    case .pasteAndSubmit:
      return
        "Replaces the captured draft, verifies the pasted text, then presses Return once in \(target.applicationName)."
    }
  }

  private var hasUndeliveredHumanEdits: Bool {
    let hasHumanEdits = review?.hasHumanEdits == true || checkpoint?.hasHumanEdits == true
    let hasMeaningfulDeliveryEffect = deliveryFailureEffect.map { $0 != .none } ?? false
    return hasHumanEdits && !hasMeaningfulDeliveryEffect
  }

  private func hookStatus(for session: PromptGateSession) async -> HookInstallationStatus {
    if let integrationID = session.target.hookContext?.integrationID {
      return await hookManager.status(for: integrationID)
    }
    if let client = session.knownClient {
      return await hookManager.status(for: client)
    }
    return .notInstalled
  }

  private func providerIsSetUp(for destination: OutboundDestination) async -> Bool {
    if destination.provider == .ollama {
      return true
    }
    return (try? await keychain.hasSetup(for: destination.provider)) ?? false
  }

  private func loadSession(sessionID: UUID, generation: UUID, workID: UUID) async {
    let provider = await preferences.selectedProvider()
    let model = await preferences.selectedModel(for: provider)
    let hookOutboundConfirmation = await preferences.confirmsHookOutboundPayloads()
    let destination: OutboundDestination?
    let destinationErrorMessage: String?
    do {
      destination = try await preferences.outboundDestination()
      destinationErrorMessage = nil
    } catch {
      destination = nil
      destinationErrorMessage = error.localizedDescription
    }
    let acceptedDisclosure =
      if let destination {
        await preferences.hasAcceptedCurrentOutboundDisclosure(for: destination)
      } else {
        false
      }
    let setup =
      if let destination {
        await providerIsSetUp(for: destination)
      } else {
        false
      }
    guard isCurrent(sessionID: sessionID, generation: generation), let session else {
      finishWork(workID)
      return
    }

    selectedProvider = destination?.provider ?? provider
    selectedModel = destination?.model ?? model
    configuredDestination = destination
    hookClientStatus = await hookStatus(for: session)
    hasAcceptedDestinationDisclosure = acceptedDisclosure
    confirmsHookOutboundPayloads = hookOutboundConfirmation
    providerIsSetUp = setup
    guard isCurrent(sessionID: sessionID, generation: generation) else {
      finishWork(workID)
      return
    }
    isLoadingSession = false
    finishWork(workID)

    if let destinationErrorMessage {
      phase = .composing
      errorMessage = destinationErrorMessage
      requestFocus(keyboard: .recoveryAction, accessibility: .errorHeading)
    } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      phase = .composing
      requestFocus(keyboard: .draftEditor, accessibility: .composerHeading)
    } else if let destination {
      prepareCorrection(using: destination)
    }
  }

  private func prepareCorrection(
    using frozenDestination: OutboundDestination? = nil,
    forcesConfirmation: Bool = false
  ) {
    guard let session else { return }
    let original = draft
    guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      phase = .composing
      errorMessage = BexError.emptyInput.localizedDescription
      return
    }

    let sessionGeneration = generation
    retireCurrentTask()
    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let destination =
          if let frozenDestination {
            frozenDestination
          } else {
            try await preferences.outboundDestination()
          }
        let acceptedDisclosure = await preferences.hasAcceptedCurrentOutboundDisclosure(
          for: destination
        )
        let setup = await providerIsSetUp(for: destination)
        guard self.currentWorkID == workID,
          self.isCurrent(sessionID: session.id, generation: sessionGeneration),
          self.draft == original
        else {
          self.finishWork(workID)
          return
        }

        selectedProvider = destination.provider
        selectedModel = destination.model
        configuredDestination = destination
        hasAcceptedDestinationDisclosure = acceptedDisclosure
        providerIsSetUp = setup
        let pending = PendingCorrection(
          sessionID: session.id,
          generation: sessionGeneration,
          original: original,
          destination: destination,
          protectedText: PromptTechnicalSpanProtector().protect(original),
          forcesConfirmation: forcesConfirmation
        )
        pendingCorrection = pending
        finishWork(workID)
        gateCorrection(pending)
      } catch {
        guard self.currentWorkID == workID,
          self.isCurrent(sessionID: session.id, generation: sessionGeneration),
          self.draft == original
        else {
          self.finishWork(workID)
          return
        }
        configuredDestination = nil
        pendingCorrection = nil
        providerIsSetUp = false
        phase = .composing
        errorMessage = error.localizedDescription
        finishWork(workID)
        requestFocus(keyboard: .recoveryAction, accessibility: .errorHeading)
      }
    }
  }

  private func gateCorrection(_ pending: PendingCorrection) {
    guard let session,
      pending.sessionID == session.id,
      pending.generation == generation,
      pending.original == draft,
      pending.destination == configuredDestination
    else {
      return
    }

    guard providerIsSetUp else {
      phase = .composing
      errorMessage =
        "Set up \(pending.destination.provider.displayName) in Settings, then return to Fix & Send."
      requestFocus(keyboard: .recoveryAction, accessibility: .errorHeading)
      announce(errorMessage ?? "Correction provider setup is required.")
      return
    }

    let requiresConfirmation =
      pending.forcesConfirmation
      || session.source.outboundConfirmationContext.requiresConfirmation(
        hasAcceptedDisclosure: hasAcceptedDestinationDisclosure,
        confirmsHookOutboundPayloads: confirmsHookOutboundPayloads
      )
    if requiresConfirmation,
      confirmedOutboundDraft != pending.original
        || confirmedOutboundDestination != pending.destination
    {
      phase = .onboarding
      errorMessage = nil
      requestFocus(keyboard: .primaryAction, accessibility: .disclosureHeading)
      announce(
        "Review the outbound payload for \(pending.destination.disclosureTarget), model \(pending.destination.model). \(protectedSpanDisclosure)"
      )
      return
    }
    startCorrection(pending)
  }

  private func startCorrection(_ pending: PendingCorrection) {
    guard let session,
      pending.sessionID == session.id,
      pending.generation == generation,
      pending.original == draft,
      pending.destination == configuredDestination
    else {
      return
    }

    let destination = pending.destination
    let sessionGeneration = pending.generation
    phase = .checking
    errorMessage = nil
    deliveryFailureEffect = nil
    review = nil
    announce("Checking the prompt with \(destination.provider.displayName).")

    let workID = UUID()
    currentWorkID = workID
    currentTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await promptGrammar.checkPrompt(
          protectedText: pending.protectedText,
          destination: destination
        )
        try Task.checkCancellation()
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration),
          phase == .checking
        else {
          self.finishWork(workID)
          return
        }
        let completedReview = PromptGateReview(
          original: pending.original,
          corrected: result.corrected,
          explanation: result.explanation
        )
        checkpoint = nil
        replacementConfirmedDraft = nil
        review = completedReview
        phase = .reviewing
        finishWork(workID)
        focusReview(completedReview)
      } catch is CancellationError {
        self.finishWork(workID)
      } catch {
        guard self.isCurrent(sessionID: session.id, generation: sessionGeneration) else {
          self.finishWork(workID)
          return
        }
        phase = .composing
        errorMessage = message(for: error)
        finishWork(workID)
        requestFocus(keyboard: .draftEditor, accessibility: .errorHeading)
        announce(errorMessage ?? "Prompt check failed.")
      }
    }
  }

  private func focusReview(_ review: PromptGateReview) {
    let changeCount = DiffChange.make(from: review.diff).count
    requestFocus(keyboard: .correctedEditor, accessibility: .finalMessageHeading)
    if changeCount == 0 {
      announce("Review ready. No changes. Focus is in the final message editor.")
    } else {
      announce(
        "Review ready. \(changeCount) changes. Focus is in the final message editor."
      )
    }
  }

  private func discardCurrentSession() {
    guard let session, phase != .closed, !isClosing else { return }
    isClosing = true
    currentTask?.cancel()
    generation = UUID()
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

  private func updateAccessibilityStatus(wasTrusted: Bool) {
    if isAccessibilityTrusted {
      accessibilityStatusMessage =
        wasTrusted
        ? "Accessibility is enabled."
        : "Accessibility is enabled. Invoke Fix & Send again to capture the focused field."
    } else {
      accessibilityStatusMessage =
        "Accessibility has not been granted. After granting it in System Settings, return to the target and invoke Fix & Send again."
    }
  }

  private func recoveryMessage(
    for failure: PromptDeliveryFailure,
    action: PromptDeliveryAction,
    target: PromptTarget
  ) -> String {
    let detail = failure.errorDescription ?? "Delivery failed."
    switch failure.effect {
    case .none:
      return
        "\(detail) Nothing was delivered. It is safe to try \(target.label(for: action)) again."
    case .copied:
      return
        "The correction is on the Clipboard, but it was not pasted into \(target.applicationName). Paste it manually. Bex will not repeat the delivery."
    case .pastedNotSubmitted:
      return
        "The correction is already in \(target.applicationName), but it was not submitted. Press Return there to submit it. Bex will not paste it again."
    case .submitted:
      return
        "\(target.applicationName) may already have submitted the correction. Check the destination before continuing; Bex will not retry."
    case .unknown:
      return
        "Bex cannot determine how much reached \(target.applicationName). Check the destination and Clipboard before continuing; automatic retry is disabled."
    }
  }

  private func retireCurrentTask() {
    guard let task = currentTask else { return }
    task.cancel()
    retiredTasks.append(task)
    currentTask = nil
  }

  private func successAnnouncement(
    for outcome: PromptDeliveryOutcome,
    target: PromptTarget
  ) -> String {
    switch outcome {
    case .copied:
      "Correction copied to the Clipboard."
    case .pasted:
      "Correction pasted in \(target.applicationName). Return was not pressed."
    case .submitted:
      "Correction pasted and submitted in \(target.applicationName)."
    case .staged:
      "Correction staged in \(target.applicationName). Press Enter there unchanged to send it."
    }
  }

  private func requestFocus(
    keyboard: PromptGateKeyboardFocus?,
    accessibility: PromptGateAccessibilityFocus?
  ) {
    focusRequest = PromptGateFocusRequest(keyboard: keyboard, accessibility: accessibility)
  }

  private func announce(_ message: String) {
    accessibilityAnnouncementHistory.append(message)
    accessibilityAnnouncement = message
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
    checkpoint = nil
    confirmedOutboundDraft = nil
    confirmedOutboundDestination = nil
    configuredDestination = nil
    pendingCorrection = nil
    replacementConfirmedDraft = nil
    isClosing = false
    isLoadingSession = false
    deliveryFailureEffect = nil
    errorMessage = nil
    showsDiscardConfirmation = false
    showsCheckpointReplacementConfirmation = false
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
