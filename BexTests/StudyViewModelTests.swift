import Foundation
import XCTest

@testable import Bex

@MainActor
final class StudyViewModelTests: XCTestCase {
  private func makeStores() -> (
    learningLog: LearningLogStore, studyState: StudyStateStore, directory: URL,
    cleanUp: () -> Void
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("StudyViewModelTests-\(UUID().uuidString)", isDirectory: true)
    let learningLog = LearningLogStore(directoryURL: directory)
    let studyState = StudyStateStore(directoryURL: directory)
    return (learningLog, studyState, directory, { try? FileManager.default.removeItem(at: directory) })
  }

  /// Appends one "Fixed:" correction that `StudyCardBuilder` can turn into a drillable
  /// card: `wrong` must appear as a whole word in the generated `original` sentence.
  private func appendEntry(
    to store: LearningLogStore,
    category: String = "preposition",
    wrong: String,
    correct: String
  ) async {
    await store.append(
      client: "claude-code",
      original: "I will meet you \(wrong) the office.",
      corrected: "I will meet you \(correct) the office.",
      explanation: """
        Fixed:
        [\(category)] "\(wrong)" → "\(correct)" — preposition fix.
        """,
      provider: "openai",
      model: "gpt-5.6-sol"
    )
  }

  private func cardID(category: String = "preposition", wrong: String, correct: String) -> String {
    "\(category)|\(wrong)|\(correct)"
  }

  /// Seeds `study-state.json` directly (bypassing `StudyScheduler.advance`) so a test
  /// can start a card at an arbitrary box/dueAt without replaying every intermediate
  /// review — `StudyStateStore` loads lazily from disk, so this must run before the
  /// store under test is ever asked for its state.
  private func seedState(directory: URL, states: [String: StudyReviewState]) throws {
    let data = try JSONEncoder().encode(states)
    try data.write(to: directory.appendingPathComponent("study-state.json"))
  }

  func testLoadPopulatesCurrentCardAndDueCountForDrillableMistakes() async {
    let (learningLog, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")

    let viewModel = StudyViewModel(learningLog: learningLog, studyState: studyState)
    await viewModel.load()

    XCTAssertFalse(viewModel.isLoading)
    XCTAssertFalse(viewModel.isEmpty)
    XCTAssertEqual(viewModel.dueCount, 1)
    XCTAssertEqual(viewModel.sessionTotal, 1)
    XCTAssertEqual(viewModel.currentCard?.id, cardID(wrong: "on", correct: "in"))
  }

  func testLoadIsEmptyForEmptyLog() async {
    let (learningLog, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }

    let viewModel = StudyViewModel(learningLog: learningLog, studyState: studyState)
    await viewModel.load()

    XCTAssertTrue(viewModel.isEmpty)
    XCTAssertFalse(viewModel.isFinished)
    XCTAssertNil(viewModel.currentCard)
    XCTAssertEqual(viewModel.dueCount, 0)
    XCTAssertEqual(viewModel.sessionTotal, 0)
  }

  func testSelectingCorrectChoiceRevealsAnswerAndPersistsPromotion() async {
    let (learningLog, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let viewModel = StudyViewModel(learningLog: learningLog, studyState: studyState, now: { fixedNow })
    await viewModel.load()

    let id = cardID(wrong: "on", correct: "in")
    await viewModel.select("in")

    XCTAssertTrue(viewModel.answerRevealed)
    XCTAssertEqual(viewModel.selectedChoice, "in")
    XCTAssertEqual(viewModel.completedCount, 1)

    let states = await studyState.states()
    XCTAssertEqual(states[id]?.box, 1)
    XCTAssertEqual(states[id]?.timesCorrect, 1)
  }

  func testSelectingWrongChoiceRevealsAndPersistsResetToBoxZero() async throws {
    let (learningLog, studyState, directory, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    let id = cardID(wrong: "on", correct: "in")

    let farPast = Date(timeIntervalSince1970: 0)
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    // Start this card already promoted to box 2 and due, so answering wrong here is a
    // genuine regression to verify, not just "still at its starting box".
    try seedState(
      directory: directory,
      states: [id: StudyReviewState(box: 2, dueAt: farPast, timesSeen: 2, timesCorrect: 2)]
    )

    let viewModel = StudyViewModel(learningLog: learningLog, studyState: studyState, now: { fixedNow })
    await viewModel.load()
    XCTAssertEqual(viewModel.currentCard?.id, id)

    await viewModel.select("on")

    XCTAssertTrue(viewModel.answerRevealed)
    let states = await studyState.states()
    XCTAssertEqual(states[id]?.box, 0)
    XCTAssertEqual(states[id]?.dueAt, fixedNow.addingTimeInterval(86_400))
  }

  func testAdvanceMovesToNextCardAndEventuallyFinishes() async {
    let (learningLog, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    await appendEntry(to: learningLog, wrong: "at", correct: "to")

    let viewModel = StudyViewModel(learningLog: learningLog, studyState: studyState)
    await viewModel.load()
    XCTAssertEqual(viewModel.sessionTotal, 2)

    let firstCardID = viewModel.currentCard?.id
    await viewModel.select(viewModel.choices.first { $0 == viewModel.currentCard?.correct } ?? "")
    viewModel.advance()

    XCTAssertFalse(viewModel.isFinished)
    XCTAssertNotEqual(viewModel.currentCard?.id, firstCardID)

    await viewModel.select(viewModel.choices.first { $0 == viewModel.currentCard?.correct } ?? "")
    viewModel.advance()

    XCTAssertTrue(viewModel.isFinished)
    XCTAssertNil(viewModel.currentCard)
    XCTAssertEqual(viewModel.completedCount, 2)
  }

  func testCardsScheduledInTheFutureAreExcludedFromSession() async throws {
    let (learningLog, studyState, directory, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    await appendEntry(to: learningLog, wrong: "at", correct: "to")
    let futureCardID = cardID(wrong: "on", correct: "in")
    let dueCardID = cardID(wrong: "at", correct: "to")

    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    try seedState(
      directory: directory,
      states: [
        futureCardID: StudyReviewState(
          box: 1, dueAt: fixedNow.addingTimeInterval(86_400 * 3), timesSeen: 1, timesCorrect: 1
        )
      ]
    )

    let viewModel = StudyViewModel(learningLog: learningLog, studyState: studyState, now: { fixedNow })
    await viewModel.load()

    XCTAssertEqual(viewModel.dueCount, 1)
    XCTAssertEqual(viewModel.sessionTotal, 1)
    XCTAssertEqual(viewModel.currentCard?.id, dueCardID)
  }

  func testChoicesAlwaysContainCorrectAnswerAfterPresentation() async {
    let (learningLog, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    for index in 0..<10 {
      await appendEntry(to: learningLog, wrong: "wrong\(index)", correct: "correct\(index)")
    }

    let viewModel = StudyViewModel(learningLog: learningLog, studyState: studyState)
    await viewModel.load()

    for _ in 0..<10 {
      guard let card = viewModel.currentCard else { break }
      XCTAssertTrue(
        viewModel.choices.contains(card.correct),
        "choices \(viewModel.choices) missing correct answer \(card.correct)"
      )
      XCTAssertTrue(viewModel.choices.contains(card.wrong))
      await viewModel.select(card.correct)
      viewModel.advance()
    }
    XCTAssertTrue(viewModel.isFinished)
  }

  func testSessionCapRespectedWhenMoreCardsAreDue() async {
    let (learningLog, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    for index in 0..<25 {
      await appendEntry(to: learningLog, wrong: "wrong\(index)", correct: "correct\(index)")
    }

    let viewModel = StudyViewModel(learningLog: learningLog, studyState: studyState)
    await viewModel.load()

    XCTAssertEqual(viewModel.dueCount, 25)
    XCTAssertEqual(viewModel.sessionTotal, StudyViewModel.sessionCap)
    XCTAssertEqual(viewModel.sessionTotal, 20)
  }
}
