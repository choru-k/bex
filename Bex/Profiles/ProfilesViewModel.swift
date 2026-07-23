import Foundation

enum WritingStylesContentState: Equatable {
  case loading
  case empty
  case bexStandard
  case editing
}

enum WritingStyleWizardStatus: Equatable {
  case idle
  case generating(String)
  case error(String)
}

struct WritingStyleOutboundSummary: Equatable, Sendable {
  let provider: String
  let model: String
  let payload: String
  let disclosure: String
}

enum WritingStyleSidebarSelection: Hashable, Sendable {
  case bexStandard
  case profile(UUID)
}

private struct PendingWritingStyleGeneration: Sendable {
  let context: ProfileContext
  let destination: OutboundDestination
}

enum WritingStyleCopy {
  static let defaultName = "Bex Standard"
  static let newAction = "New Writing Style"
  static let emptyTitle = "Create a Writing Style"
  static let emptyMessage =
    "Writing Styles guide Bex on tone, audience, and grammar. "
    + "Without one, Bex uses Bex Standard."
}

private struct WritingStyleEditorSnapshot: Equatable {
  let name: String
  let prompt: String
  let isDefault: Bool
}

@MainActor
final class ProfilesViewModel: ObservableObject {
  @Published private(set) var isLoading = true

  @Published private(set) var profiles: [Profile] = []
  @Published private(set) var defaultProfileID: UUID?
  @Published private(set) var editingID: UUID?
  @Published var name = ""
  @Published var prompt = ""
  @Published var isDefault = false
  @Published var showWizard = false
  @Published var wizardContext = ProfileContext()
  @Published private(set) var isGenerating = false
  @Published private(set) var userVisibleError: String?
  @Published private(set) var outboundSummary: WritingStyleOutboundSummary?
  @Published private(set) var sidebarSelection: WritingStyleSidebarSelection? = .bexStandard
  @Published private(set) var showsDiscardChangesConfirmation = false

  private let data: BexDataStore
  private let preferences: PreferencesStore
  private let grammar: any GrammarServicing
  private var draftID: UUID?
  private var operationTask: Task<Void, Never>?
  private var pendingGeneration: PendingWritingStyleGeneration?
  private var editorSnapshot: WritingStyleEditorSnapshot?
  private var pendingSidebarSelection: WritingStyleSidebarSelection?

  init(
    data: BexDataStore,
    preferences: PreferencesStore,
    grammar: any GrammarServicing
  ) {
    self.data = data
    self.preferences = preferences
    self.grammar = grammar
  }

  var hasEditor: Bool { draftID != nil }

  var hasUnsavedChanges: Bool {
    guard let editorSnapshot else { return false }
    return editorSnapshot
      != WritingStyleEditorSnapshot(
        name: name,
        prompt: prompt,
        isDefault: isDefault
      )
  }

  var contentState: WritingStylesContentState {
    if isLoading {
      return .loading
    }
    if profiles.isEmpty, !hasEditor {
      return .empty
    }
    return hasEditor ? .editing : .bexStandard
  }

  var wizardStatus: WritingStyleWizardStatus {
    if isGenerating {
      return .generating("Generating Writing Style guidance…")
    }
    if showWizard, let userVisibleError {
      return .error(userVisibleError)
    }
    return .idle
  }

  func load() async {
    isLoading = true
    do {
      profiles = try await data.loadProfiles()
      defaultProfileID = await preferences.defaultProfileID()
      userVisibleError = nil
    } catch {
      profiles = []
      userVisibleError = error.localizedDescription
    }
    isLoading = false
  }

  func createProfile() {
    draftID = UUID()
    editingID = nil
    sidebarSelection = nil
    name = ""
    prompt = ""
    isDefault = false
    editorSnapshot = WritingStyleEditorSnapshot(name: "", prompt: "", isDefault: false)
    pendingSidebarSelection = nil
    showsDiscardChangesConfirmation = false
    userVisibleError = nil
  }

  func edit(_ profile: Profile) {
    let defaultState = defaultProfileID == profile.id
    draftID = profile.id
    editingID = profile.id
    sidebarSelection = .profile(profile.id)
    name = profile.name
    prompt = profile.prompt
    isDefault = defaultState
    editorSnapshot = WritingStyleEditorSnapshot(
      name: profile.name,
      prompt: profile.prompt,
      isDefault: defaultState
    )
    pendingSidebarSelection = nil
    showsDiscardChangesConfirmation = false
    userVisibleError = nil
  }

  func selectBexStandard() {
    selectSidebar(.bexStandard)
  }

  func selectSidebar(_ selection: WritingStyleSidebarSelection?) {
    let requestedSelection = selection ?? .bexStandard
    guard requestedSelection != sidebarSelection else { return }
    guard !hasUnsavedChanges else {
      pendingSidebarSelection = requestedSelection
      showsDiscardChangesConfirmation = true
      return
    }
    applySidebarSelection(requestedSelection)
  }

  func keepEditing() {
    pendingSidebarSelection = nil
    showsDiscardChangesConfirmation = false
  }

  func discardChangesAndSelectPending() {
    guard let selection = pendingSidebarSelection else {
      showsDiscardChangesConfirmation = false
      return
    }
    pendingSidebarSelection = nil
    showsDiscardChangesConfirmation = false
    applySidebarSelection(selection)
  }

  func save() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      userVisibleError = "Writing Style name is required."
      return
    }
    guard let id = draftID else { return }
    let profile = Profile(id: id, name: trimmedName, prompt: prompt)
    operationTask?.cancel()
    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await data.saveProfile(profile)
        if let index = profiles.firstIndex(where: { $0.id == id }) {
          profiles[index] = profile
        } else {
          profiles.append(profile)
        }
        if isDefault {
          await preferences.setDefaultProfileID(id)
          defaultProfileID = id
        } else if defaultProfileID == id {
          await preferences.setDefaultProfileID(nil)
          defaultProfileID = nil
        }
        editingID = id
        draftID = id
        name = profile.name
        sidebarSelection = .profile(id)
        editorSnapshot = WritingStyleEditorSnapshot(
          name: profile.name,
          prompt: profile.prompt,
          isDefault: isDefault
        )
        userVisibleError = nil
      } catch {
        userVisibleError = error.localizedDescription
      }
    }
  }

  func setDefault(_ enabled: Bool) {
    isDefault = enabled
  }

  func delete(id: UUID) {
    operationTask?.cancel()
    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await data.deleteProfile(id: id)
        await preferences.profileDeleted(id: id)
        profiles.removeAll { $0.id == id }
        if defaultProfileID == id {
          defaultProfileID = nil
        }
        if draftID == id {
          clearEditor()
        }
        userVisibleError = nil
      } catch {
        userVisibleError = error.localizedDescription
      }
    }
  }

  func openWizard() {
    wizardContext = ProfileContext()
    pendingGeneration = nil
    outboundSummary = nil
    showWizard = true
    userVisibleError = nil
  }

  func cancelWizard() {
    operationTask?.cancel()
    pendingGeneration = nil
    outboundSummary = nil
    isGenerating = false
    showWizard = false
    userVisibleError = nil
  }

  func generatePrompt() {
    guard wizardContext.hasContent else {
      userVisibleError = "Fill in at least one Writing Style context field."
      return
    }
    guard !isGenerating, outboundSummary == nil else { return }
    let context = wizardContext
    let payload: String
    do {
      payload = try GrammarPrompts.profileMessage(context: context)
    } catch {
      userVisibleError = error.localizedDescription
      return
    }

    operationTask?.cancel()
    pendingGeneration = nil
    isGenerating = true
    userVisibleError = nil
    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        let destination = try await preferences.outboundDestination()
        let accepted = await preferences.hasAcceptedCurrentOutboundDisclosure(
          for: destination
        )
        try Task.checkCancellation()

        let summary = WritingStyleOutboundSummary(
          provider: destination.provider.displayName,
          model: destination.model,
          payload: payload,
          disclosure:
            "The labeled Writing Style context shown here will be sent to \(destination.disclosureTarget)."
        )
        let request = PendingWritingStyleGeneration(
          context: context,
          destination: destination
        )
        if OutboundConfirmationContext.quickCheckExternal.requiresConfirmation(
          hasAcceptedDisclosure: accepted
        ) {
          pendingGeneration = request
          outboundSummary = summary
          isGenerating = false
        } else {
          await submit(request)
        }
      } catch {
        isGenerating = false
        if !Task.isCancelled,
          error as? BexError != .cancellation,
          !(error is CancellationError)
        {
          userVisibleError = error.localizedDescription
        }
      }
    }
  }

  func confirmOutbound() {
    guard let request = pendingGeneration, !isGenerating else { return }
    operationTask?.cancel()
    pendingGeneration = nil
    outboundSummary = nil
    isGenerating = true
    userVisibleError = nil
    operationTask = Task { [weak self] in
      guard let self else { return }
      await preferences.acceptCurrentOutboundDisclosure(for: request.destination)
      guard !Task.isCancelled else { return }
      await submit(request)
    }
  }

  func cancelOutbound() {
    operationTask?.cancel()
    pendingGeneration = nil
    outboundSummary = nil
    isGenerating = false
  }

  func close() {
    operationTask?.cancel()
    operationTask = nil
    pendingGeneration = nil
    outboundSummary = nil
    isGenerating = false
  }

  func waitForCurrentWork() async {
    await operationTask?.value
  }

  private func submit(_ request: PendingWritingStyleGeneration) async {
    do {
      let generated = try await grammar.generateProfile(
        context: request.context,
        destination: request.destination
      )
      try Task.checkCancellation()
      prompt = generated
      isGenerating = false
      showWizard = false
    } catch {
      isGenerating = false
      if !Task.isCancelled,
        error as? BexError != .cancellation,
        !(error is CancellationError)
      {
        userVisibleError = error.localizedDescription
      }
    }
  }

  private func applySidebarSelection(_ selection: WritingStyleSidebarSelection) {
    switch selection {
    case .bexStandard:
      clearEditor()
      userVisibleError = nil
    case .profile(let id):
      guard let profile = profiles.first(where: { $0.id == id }) else {
        clearEditor()
        userVisibleError = nil
        return
      }
      edit(profile)
    }
  }

  private func clearEditor() {
    draftID = nil
    editingID = nil
    sidebarSelection = .bexStandard
    name = ""
    prompt = ""
    isDefault = false
    editorSnapshot = nil
    pendingSidebarSelection = nil
    showsDiscardChangesConfirmation = false
    pendingGeneration = nil
    outboundSummary = nil
    showWizard = false
  }
}
