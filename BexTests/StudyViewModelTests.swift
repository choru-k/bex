import Foundation
import XCTest

@testable import Bex

@MainActor
final class StudyViewModelTests: XCTestCase {
  private func makeStores() -> (
    learningLog: LearningLogStore, considerTaps: ConsiderTapStore,
    studyState: StudyStateStore, directory: URL, cleanUp: () -> Void
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("StudyViewModelTests-\(UUID().uuidString)", isDirectory: true)
    let learningLog = LearningLogStore(directoryURL: directory)
    let considerTaps = ConsiderTapStore(directoryURL: directory)
    let studyState = StudyStateStore(directoryURL: directory)
    return (
      learningLog, considerTaps, studyState, directory,
      { try? FileManager.default.removeItem(at: directory) }
    )
  }

  /// Appends one "Fixed:" correction that `StudyCardBuilder` can turn into a drillable
  /// card: `wrong` must appear as a whole word in the generated `original` sentence.
  private func appendEntry(
    to store: LearningLogStore,
    category: String = "other",
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

  private func cardID(category: String = "other", wrong: String, correct: String) -> String {
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
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.load()

    XCTAssertFalse(viewModel.isLoading)
    XCTAssertFalse(viewModel.isEmpty)
    XCTAssertEqual(viewModel.dueCount, 1)
    XCTAssertEqual(viewModel.sessionTotal, 1)
    XCTAssertEqual(viewModel.currentCard?.id, cardID(wrong: "on", correct: "in"))
  }

  func testLoadIsEmptyForEmptyLog() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.load()

    XCTAssertTrue(viewModel.isEmpty)
    XCTAssertFalse(viewModel.isFinished)
    XCTAssertNil(viewModel.currentCard)
    XCTAssertEqual(viewModel.dueCount, 0)
    XCTAssertEqual(viewModel.sessionTotal, 0)
  }

  func testSelectingCorrectChoiceRevealsAnswerAndPersistsPromotion() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState, now: { fixedNow })
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
    let (learningLog, considerTaps, studyState, directory, cleanUp) = makeStores()
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

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState, now: { fixedNow })
    await viewModel.load()
    XCTAssertEqual(viewModel.currentCard?.id, id)

    await viewModel.select("on")

    XCTAssertTrue(viewModel.answerRevealed)
    let states = await studyState.states()
    XCTAssertEqual(states[id]?.box, 0)
    XCTAssertEqual(states[id]?.dueAt, fixedNow.addingTimeInterval(86_400))
  }

  func testSubmittingCorrectTypedAnswerRevealsAnswerAndPersistsPromotion() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState, now: { fixedNow })
    await viewModel.load()
    XCTAssertEqual(viewModel.currentCard?.answerMode, .typed)

    let id = cardID(wrong: "on", correct: "in")
    viewModel.typedAnswer = " In. "
    await viewModel.submitTypedAnswer()

    XCTAssertTrue(viewModel.answerRevealed)
    XCTAssertTrue(viewModel.lastAnswerWasCorrect)
    XCTAssertEqual(viewModel.completedCount, 1)

    let states = await studyState.states()
    XCTAssertEqual(states[id]?.box, 1)
    XCTAssertEqual(states[id]?.timesCorrect, 1)
  }

  func testSubmittingWrongTypedAnswerRevealsAndPersistsResetToBoxZero() async throws {
    let (learningLog, considerTaps, studyState, directory, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    let id = cardID(wrong: "on", correct: "in")

    let farPast = Date(timeIntervalSince1970: 0)
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    try seedState(
      directory: directory,
      states: [id: StudyReviewState(box: 2, dueAt: farPast, timesSeen: 2, timesCorrect: 2)]
    )

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState, now: { fixedNow })
    await viewModel.load()

    viewModel.typedAnswer = "on"
    await viewModel.submitTypedAnswer()

    XCTAssertTrue(viewModel.answerRevealed)
    XCTAssertFalse(viewModel.lastAnswerWasCorrect)
    let states = await studyState.states()
    XCTAssertEqual(states[id]?.box, 0)
    XCTAssertEqual(states[id]?.dueAt, fixedNow.addingTimeInterval(86_400))
  }

  func testBlankTypedSubmitIsNoOp() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.load()

    viewModel.typedAnswer = "   "
    await viewModel.submitTypedAnswer()

    XCTAssertFalse(viewModel.answerRevealed)
    XCTAssertEqual(viewModel.completedCount, 0)
    let states = await studyState.states()
    XCTAssertTrue(states.isEmpty)
  }

  func testTypedAnswerClearsBetweenCards() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    await appendEntry(to: learningLog, wrong: "at", correct: "to")

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.load()

    viewModel.typedAnswer = "in"
    await viewModel.submitTypedAnswer()
    XCTAssertFalse(viewModel.typedAnswer.isEmpty)

    viewModel.advance()

    XCTAssertEqual(viewModel.typedAnswer, "")
  }

  func testAdvanceMovesToNextCardAndEventuallyFinishes() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    await appendEntry(to: learningLog, wrong: "at", correct: "to")

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
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
    let (learningLog, considerTaps, studyState, directory, cleanUp) = makeStores()
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

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState, now: { fixedNow })
    await viewModel.load()

    XCTAssertEqual(viewModel.dueCount, 1)
    XCTAssertEqual(viewModel.sessionTotal, 1)
    XCTAssertEqual(viewModel.currentCard?.id, dueCardID)
  }

  func testChoicesAlwaysContainCorrectAnswerAfterPresentation() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    for index in 0..<10 {
      await appendEntry(to: learningLog, wrong: "wrong\(index)", correct: "correct\(index)")
    }

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
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

  /// `StudyDailyPlan` always includes every due review (unlike new intake, which it
  /// caps at `StudyDailyPlan.newCardBatchSize` at a time), so a big backlog of cards
  /// already in rotation is exactly the scenario `sessionCap` exists to bound: this
  /// seeds 25 already-in-rotation, already-due cards (not new ones) so `dueCount`
  /// reflects the full backlog while `sessionTotal` still gets truncated to
  /// `sessionCap` for one sitting.
  func testSessionCapRespectedWhenMoreDueReviewsThanCap() async throws {
    let (learningLog, considerTaps, studyState, directory, cleanUp) = makeStores()
    defer { cleanUp() }
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    var states: [String: StudyReviewState] = [:]
    for index in 0..<25 {
      await appendEntry(to: learningLog, wrong: "wrong\(index)", correct: "correct\(index)")
      let id = cardID(wrong: "wrong\(index)", correct: "correct\(index)")
      states[id] = StudyReviewState(
        box: 1,
        dueAt: fixedNow.addingTimeInterval(-86_400),
        timesSeen: 1,
        timesCorrect: 1,
        firstSeenAt: fixedNow.addingTimeInterval(-86_400 * 30)
      )
    }
    try seedState(directory: directory, states: states)

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState, now: { fixedNow })
    await viewModel.load()

    XCTAssertEqual(viewModel.dueCount, 25)
    XCTAssertEqual(viewModel.sessionTotal, StudyViewModel.sessionCap)
    XCTAssertEqual(viewModel.sessionTotal, 20)
  }

  /// THE headline behaviour this whole change exists for: a cold-start deck (here, 30
  /// never-studied cards — standing in for the owner's real 120) must not dump its
  /// entire size on one session. Today's plan caps new intake at
  /// `StudyDailyPlan.newCardBatchSize`, so the session — and the badge/notification
  /// count behind it — reads as a small, clearable 10, not an overwhelming 30.
  func testColdStartSessionCapsNewCardsAtDailyLimitNotWholeDeck() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    for index in 0..<30 {
      await appendEntry(to: learningLog, wrong: "wrong\(index)", correct: "correct\(index)")
    }

    let viewModel = StudyViewModel(learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.load()

    XCTAssertEqual(viewModel.dueCount, StudyDailyPlan.newCardBatchSize)
    XCTAssertEqual(viewModel.sessionTotal, StudyDailyPlan.newCardBatchSize)
    XCTAssertEqual(viewModel.sessionTotal, 10)
  }

  /// The menu-bar hub and the Learn deck share one instance, and both call
  /// `loadIfNeeded()` every time they appear. If that reloaded mid-session it would reset
  /// `completedCount` and reshuffle the queue — rewinding the progress dots and
  /// re-presenting the card the owner is looking at.
  func testLoadIfNeededPreservesAnInFlightSession() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    await appendEntry(to: learningLog, wrong: "at", correct: "to")

    let viewModel = StudyViewModel(
      learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.loadIfNeeded()
    XCTAssertEqual(viewModel.sessionTotal, 2)
    XCTAssertEqual(viewModel.remainingCount, 2)

    await viewModel.select(viewModel.currentCard?.correct ?? "")
    viewModel.advance()
    let cardMidSession = viewModel.currentCard?.id
    XCTAssertEqual(viewModel.completedCount, 1)
    XCTAssertEqual(viewModel.remainingCount, 1)

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.completedCount, 1, "reopening a surface must not rewind progress")
    XCTAssertEqual(viewModel.currentCard?.id, cardMidSession)
  }

  /// The other half of the guard: once the session is spent, reopening either surface
  /// should pick up anything that has come due since rather than showing "done" forever.
  func testLoadIfNeededRebuildsAFinishedSession() async {
    let (learningLog, considerTaps, studyState, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")

    let viewModel = StudyViewModel(
      learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.loadIfNeeded()
    await viewModel.select(viewModel.currentCard?.correct ?? "")
    viewModel.advance()
    XCTAssertTrue(viewModel.isFinished)

    await appendEntry(to: learningLog, wrong: "at", correct: "to")
    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.completedCount, 0)
    XCTAssertEqual(viewModel.currentCard?.id, cardID(wrong: "at", correct: "to"))
  }
}
