import Foundation
import XCTest

@testable import Bex

private struct WritingStyleGenerationCall: Equatable, Sendable {
  let context: ProfileContext
  let provider: LLMProvider
  let model: String
  let ollamaEndpoint: String?
}

private actor WritingStylesGrammarStub: GrammarServicing {

  private var generationDelay: UInt64 = 0
  private var generationCalls: [WritingStyleGenerationCall] = []
  func setGenerationDelay(_ nanoseconds: UInt64) {
    generationDelay = nanoseconds
  }

  func recordedGenerationCalls() -> [WritingStyleGenerationCall] {
    generationCalls
  }

  func check(
    text: String,
    destination: OutboundDestination,
    profilePrompt: String?
  ) async throws -> GrammarResult {
    GrammarResult(corrected: text, explanation: "")
  }

  func rewrite(
    text: String,
    intent: RewriteIntent,
    destination: OutboundDestination
  ) async throws -> String {
    text
  }

  func define(
    text: String,
    destination: OutboundDestination
  ) async throws -> DictionaryLookup {
    throw BexError.invalidResponse
  }

  func classifyStudyPatterns(
    cards: [StudyCard],
    destination: OutboundDestination
  ) async throws -> [String: StudyPattern] {
    [:]
  }

  func generateProfile(
    context: ProfileContext,
    destination: OutboundDestination
  ) async throws -> String {
    generationCalls.append(
      WritingStyleGenerationCall(
        context: context,
        provider: destination.provider,
        model: destination.model,
        ollamaEndpoint: destination.ollamaEndpoint
      )
    )
    if generationDelay > 0 {
      try await Task.sleep(nanoseconds: generationDelay)
    }
    return "Use a concise, friendly tone for \(context.audience)."
  }

  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] {
    [ModelOption(id: provider.defaultModel, name: provider.defaultModel)]
  }
}

@MainActor
final class WritingStylesViewModelTests: XCTestCase {
  func testEmptyAndBexStandardStatesUseWritingStyleTerminology() async throws {
    let fixture = makeFixture()
    defer { fixture.cleanUp() }
    let viewModel = fixture.makeViewModel()
    defer { viewModel.close() }

    XCTAssertEqual(viewModel.contentState, .loading)
    await viewModel.load()
    XCTAssertEqual(viewModel.contentState, .empty)
    XCTAssertEqual(WritingStyleCopy.defaultName, "Bex Standard")
    XCTAssertEqual(WritingStyleCopy.newAction, "New Writing Style")
    XCTAssertEqual(WritingStyleCopy.emptyTitle, "Create a Writing Style")
    XCTAssertTrue(WritingStyleCopy.emptyMessage.contains("Bex Standard"))
    XCTAssertFalse(WritingStyleCopy.emptyMessage.contains("profile"))

    viewModel.createProfile()
    XCTAssertEqual(viewModel.contentState, .editing)
    viewModel.save()
    XCTAssertEqual(viewModel.userVisibleError, "Writing Style name is required.")
  }

  func testNilDefaultIsPresentedAsBexStandardRatherThanMissingSetup() async throws {
    let fixture = makeFixture()
    defer { fixture.cleanUp() }
    let customStyle = Profile(
      id: UUID(),
      name: "Concise",
      prompt: "Prefer short, direct sentences."
    )
    try await fixture.data.saveProfile(customStyle)
    let viewModel = fixture.makeViewModel()
    defer { viewModel.close() }

    await viewModel.load()

    XCTAssertEqual(viewModel.profiles, [customStyle])
    XCTAssertNil(viewModel.defaultProfileID)
    XCTAssertEqual(viewModel.contentState, .bexStandard)
    XCTAssertFalse(viewModel.hasEditor)

    viewModel.edit(customStyle)
    XCTAssertEqual(viewModel.contentState, .editing)
    viewModel.selectBexStandard()
    XCTAssertEqual(viewModel.contentState, .bexStandard)
    XCTAssertFalse(viewModel.hasEditor)
  }

  func testWizardExposesLabeledGeneratingAndErrorStates() async throws {
    let fixture = makeFixture()
    defer { fixture.cleanUp() }
    let viewModel = fixture.makeViewModel()
    defer { viewModel.close() }
    await viewModel.load()
    viewModel.createProfile()
    viewModel.openWizard()

    viewModel.generatePrompt()
    XCTAssertEqual(
      viewModel.wizardStatus,
      .error("Fill in at least one Writing Style context field.")
    )

    let destination = try await fixture.preferences.outboundDestination()
    await fixture.preferences.acceptCurrentOutboundDisclosure(for: destination)
    viewModel.wizardContext.audience = "engineering leaders"
    await fixture.grammar.setGenerationDelay(50_000_000)
    viewModel.generatePrompt()

    XCTAssertEqual(
      viewModel.wizardStatus,
      .generating("Generating Writing Style guidance…")
    )
    await viewModel.waitForCurrentWork()

    XCTAssertEqual(viewModel.wizardStatus, .idle)
    XCTAssertFalse(viewModel.showWizard)
    XCTAssertEqual(
      viewModel.prompt,
      "Use a concise, friendly tone for engineering leaders."
    )
  }

  func testFreshDestinationDisclosureFreezesExactLabeledPayloadAndCancelSendsNothing() async throws
  {
    let fixture = makeFixture()
    defer { fixture.cleanUp() }
    let viewModel = fixture.makeViewModel()
    defer { viewModel.close() }
    await viewModel.load()
    viewModel.createProfile()
    viewModel.openWizard()
    viewModel.wizardContext = ProfileContext(
      role: "Product editor",
      audience: "Engineering leaders",
      tone: "Direct",
      formality: "Professional",
      domain: "Infrastructure",
      notes: "Keep product names unchanged"
    )

    let destination = try await fixture.preferences.outboundDestination()
    viewModel.generatePrompt()
    await viewModel.waitForCurrentWork()

    XCTAssertEqual(
      viewModel.outboundSummary,
      WritingStyleOutboundSummary(
        provider: "OpenAI",
        model: LLMProvider.openAI.defaultModel,
        payload: """
          Role: Product editor
          Audience: Engineering leaders
          Tone: Direct
          Formality: Professional
          Domain: Infrastructure
          Additional notes: Keep product names unchanged
          """,
        disclosure: "The labeled Writing Style context shown here will be sent to OpenAI."
      )
    )
    let callsBeforeCancel = await fixture.grammar.recordedGenerationCalls()
    let acceptedBeforeCancel =
      await fixture.preferences.hasAcceptedCurrentOutboundDisclosure(for: destination)
    XCTAssertTrue(callsBeforeCancel.isEmpty)
    XCTAssertFalse(acceptedBeforeCancel)

    viewModel.cancelOutbound()
    XCTAssertNil(viewModel.outboundSummary)
    XCTAssertTrue(viewModel.showWizard)
    let callsAfterCancel = await fixture.grammar.recordedGenerationCalls()
    let acceptedAfterCancel =
      await fixture.preferences.hasAcceptedCurrentOutboundDisclosure(for: destination)
    XCTAssertTrue(callsAfterCancel.isEmpty)
    XCTAssertFalse(acceptedAfterCancel)
  }

  func testConfirmAcceptsScopedDisclosureAndSendsFrozenPreviewContext() async throws {
    let fixture = makeFixture()
    defer { fixture.cleanUp() }
    await fixture.preferences.setSelectedProvider(.claude)
    await fixture.preferences.setSelectedModel("claude-profile-test", for: .claude)
    let claudeDestination = try await fixture.preferences.outboundDestination()
    let viewModel = fixture.makeViewModel()
    defer { viewModel.close() }
    await viewModel.load()
    viewModel.createProfile()
    viewModel.openWizard()
    let context = ProfileContext(
      role: "Support lead",
      audience: "Customers",
      tone: "Warm",
      formality: "Conversational",
      domain: "Billing",
      notes: "Avoid jargon"
    )
    viewModel.wizardContext = context

    viewModel.generatePrompt()
    await viewModel.waitForCurrentWork()
    let frozenSummary = try XCTUnwrap(viewModel.outboundSummary)
    let expectedPayload = try GrammarPrompts.profileMessage(context: context)
    let callsBeforeConfirmation = await fixture.grammar.recordedGenerationCalls()
    XCTAssertEqual(frozenSummary.payload, expectedPayload)
    XCTAssertEqual(frozenSummary.provider, "Claude")
    XCTAssertEqual(frozenSummary.model, "claude-profile-test")
    XCTAssertTrue(callsBeforeConfirmation.isEmpty)

    viewModel.wizardContext.audience = "Changed after preview"
    await fixture.preferences.setSelectedProvider(.openAI)
    viewModel.confirmOutbound()
    await viewModel.waitForCurrentWork()

    let generationCalls = await fixture.grammar.recordedGenerationCalls()
    let acceptedClaude =
      await fixture.preferences.hasAcceptedCurrentOutboundDisclosure(for: claudeDestination)
    let openAIDestination = try await fixture.preferences.outboundDestination()
    let acceptedOpenAI =
      await fixture.preferences.hasAcceptedCurrentOutboundDisclosure(for: openAIDestination)
    XCTAssertEqual(
      generationCalls,
      [
        WritingStyleGenerationCall(
          context: context,
          provider: .claude,
          model: "claude-profile-test",
          ollamaEndpoint: nil
        )
      ]
    )
    XCTAssertTrue(acceptedClaude)
    XCTAssertFalse(acceptedOpenAI)
    XCTAssertFalse(viewModel.showWizard)
  }

  func testSidebarSelectionTracksEditorAndRemainsDistinctFromDefaultMarker() async throws {
    let fixture = makeFixture()
    defer { fixture.cleanUp() }
    let defaultStyle = Profile(
      id: UUID(),
      name: "Executive",
      prompt: "Write concise summaries."
    )
    try await fixture.data.saveProfile(defaultStyle)
    await fixture.preferences.setDefaultProfileID(defaultStyle.id)
    let viewModel = fixture.makeViewModel()
    defer { viewModel.close() }

    await viewModel.load()
    XCTAssertEqual(viewModel.sidebarSelection, .bexStandard)
    XCTAssertEqual(viewModel.defaultProfileID, defaultStyle.id)
    XCTAssertFalse(viewModel.hasEditor)

    viewModel.selectSidebar(.profile(defaultStyle.id))
    XCTAssertEqual(viewModel.sidebarSelection, .profile(defaultStyle.id))
    XCTAssertEqual(viewModel.editingID, defaultStyle.id)
    XCTAssertEqual(viewModel.defaultProfileID, defaultStyle.id)

    viewModel.selectSidebar(.bexStandard)
    XCTAssertEqual(viewModel.sidebarSelection, .bexStandard)
    XCTAssertNil(viewModel.editingID)
    XCTAssertEqual(viewModel.defaultProfileID, defaultStyle.id)

    viewModel.createProfile()
    XCTAssertNil(viewModel.sidebarSelection)
    XCTAssertTrue(viewModel.hasEditor)
  }

  func testDirtyNativeSelectionRequiresDiscardBeforeChangingEditor() async throws {
    let fixture = makeFixture()
    defer { fixture.cleanUp() }
    let first = Profile(id: UUID(), name: "First", prompt: "First guidance")
    let second = Profile(id: UUID(), name: "Second", prompt: "Second guidance")
    try await fixture.data.saveProfile(first)
    try await fixture.data.saveProfile(second)
    await fixture.preferences.setDefaultProfileID(first.id)
    let viewModel = fixture.makeViewModel()
    defer { viewModel.close() }
    await viewModel.load()
    viewModel.selectSidebar(.profile(first.id))
    viewModel.name = "Unsaved name"
    viewModel.prompt = "Unsaved guidance"
    viewModel.isDefault = false

    viewModel.selectSidebar(.profile(second.id))

    XCTAssertTrue(viewModel.hasUnsavedChanges)
    XCTAssertTrue(viewModel.showsDiscardChangesConfirmation)
    XCTAssertEqual(viewModel.sidebarSelection, .profile(first.id))
    XCTAssertEqual(viewModel.editingID, first.id)
    XCTAssertEqual(viewModel.name, "Unsaved name")
    XCTAssertEqual(viewModel.prompt, "Unsaved guidance")
    XCTAssertFalse(viewModel.isDefault)

    viewModel.keepEditing()
    XCTAssertFalse(viewModel.showsDiscardChangesConfirmation)
    XCTAssertEqual(viewModel.sidebarSelection, .profile(first.id))
    XCTAssertEqual(viewModel.name, "Unsaved name")

    viewModel.selectSidebar(.bexStandard)
    XCTAssertTrue(viewModel.showsDiscardChangesConfirmation)
    XCTAssertEqual(viewModel.sidebarSelection, .profile(first.id))
    viewModel.discardChangesAndSelectPending()

    XCTAssertFalse(viewModel.showsDiscardChangesConfirmation)
    XCTAssertEqual(viewModel.sidebarSelection, .bexStandard)
    XCTAssertNil(viewModel.editingID)
    XCTAssertFalse(viewModel.hasEditor)
    XCTAssertEqual(viewModel.defaultProfileID, first.id)
  }

  func testSavingDefaultWritingStylePersistsSelection() async throws {
    let fixture = makeFixture()
    defer { fixture.cleanUp() }
    let viewModel = fixture.makeViewModel()
    defer { viewModel.close() }
    await viewModel.load()
    viewModel.createProfile()
    viewModel.name = "Executive Brief"
    viewModel.prompt = "Use concise, formal language."
    viewModel.isDefault = true

    viewModel.save()
    await viewModel.waitForCurrentWork()

    let persistedDefaultID = await fixture.preferences.defaultProfileID()
    let saved = try await fixture.data.loadProfiles()
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved[0].name, "Executive Brief")
    XCTAssertEqual(viewModel.defaultProfileID, saved[0].id)
    XCTAssertEqual(persistedDefaultID, saved[0].id)
    XCTAssertEqual(viewModel.sidebarSelection, .profile(saved[0].id))
    XCTAssertFalse(viewModel.hasUnsavedChanges)
  }

  private func makeFixture() -> WritingStylesFixture {
    let identifier = UUID().uuidString
    let suite = "com.bex.desktop.tests.writing-styles.\(identifier)"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexWritingStylesTests-\(identifier)")
    return WritingStylesFixture(
      suite: suite,
      directory: directory,
      data: BexDataStore(fileURL: directory.appendingPathComponent("data.json")),
      preferences: PreferencesStore(defaults: UserDefaults(suiteName: suite)!),
      grammar: WritingStylesGrammarStub()
    )
  }
}

@MainActor
private struct WritingStylesFixture {
  let suite: String
  let directory: URL
  let data: BexDataStore
  let preferences: PreferencesStore
  let grammar: WritingStylesGrammarStub

  func makeViewModel() -> ProfilesViewModel {
    ProfilesViewModel(data: data, preferences: preferences, grammar: grammar)
  }

  func cleanUp() {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}
