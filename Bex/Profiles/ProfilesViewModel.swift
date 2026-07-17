import Foundation

@MainActor
final class ProfilesViewModel: ObservableObject {
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

  private let data: BexDataStore
  private let preferences: PreferencesStore
  private let grammar: any GrammarServicing
  private var draftID: UUID?
  private var operationTask: Task<Void, Never>?

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

  func load() async {
    do {
      profiles = try await data.loadProfiles()
      defaultProfileID = await preferences.defaultProfileID()
      userVisibleError = nil
    } catch {
      profiles = []
      userVisibleError = error.localizedDescription
    }
  }

  func createProfile() {
    draftID = UUID()
    editingID = nil
    name = ""
    prompt = ""
    isDefault = false
    userVisibleError = nil
  }

  func edit(_ profile: Profile) {
    draftID = profile.id
    editingID = profile.id
    name = profile.name
    prompt = profile.prompt
    isDefault = defaultProfileID == profile.id
    userVisibleError = nil
  }

  func save() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      userVisibleError = "Profile name is required."
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
    showWizard = true
    userVisibleError = nil
  }

  func cancelWizard() {
    operationTask?.cancel()
    isGenerating = false
    showWizard = false
  }

  func generatePrompt() {
    guard wizardContext.hasContent else {
      userVisibleError = "Fill in at least one profile context field."
      return
    }
    operationTask?.cancel()
    let context = wizardContext
    isGenerating = true
    userVisibleError = nil
    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        let provider = await preferences.selectedProvider()
        let model = await preferences.selectedModel(for: provider)
        let generated = try await grammar.generateProfile(
          context: context,
          provider: provider,
          model: model
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
  }

  func close() {
    operationTask?.cancel()
    operationTask = nil
    isGenerating = false
  }

  func waitForCurrentWork() async {
    await operationTask?.value
  }

  private func clearEditor() {
    draftID = nil
    editingID = nil
    name = ""
    prompt = ""
    isDefault = false
    showWizard = false
  }
}
