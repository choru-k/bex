import Foundation
import XCTest

@testable import Bex

/// The micro-drill's exits after the armed card is answered (v3 decision 1): ⏎/Esc close
/// the panel, ⌥⏎ continues only when more cards are due. The closing side is AppKit
/// (restore the prior app, order out); what is testable is the decision the footer makes
/// and what the shared session does on each path.
@MainActor
final class StudyMicroDrillTests: XCTestCase {
  private func makeStores() -> (
    learningLog: LearningLogStore, considerTaps: ConsiderTapStore,
    studyState: StudyStateStore, cleanUp: () -> Void
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("StudyMicroDrillTests-\(UUID().uuidString)", isDirectory: true)
    return (
      LearningLogStore(directoryURL: directory),
      ConsiderTapStore(directoryURL: directory),
      StudyStateStore(directoryURL: directory),
      { try? FileManager.default.removeItem(at: directory) }
    )
  }

  private func appendEntry(
    to store: LearningLogStore, wrong: String, correct: String
  ) async {
    await store.append(
      client: "claude-code",
      original: "I will meet you \(wrong) the office.",
      corrected: "I will meet you \(correct) the office.",
      explanation: """
        Fixed:
        [other] "\(wrong)" → "\(correct)" — preposition fix.
        """,
      provider: "openai",
      model: "gpt-5.6-sol"
    )
  }

  func testContinueIsOfferedOnlyWhenCardsRemain() {
    XCTAssertNil(StudyMicroDrillResultFooter.continueOffer(remaining: 0))
    XCTAssertEqual(
      StudyMicroDrillResultFooter.continueOffer(remaining: 1),
      "1 more due · ⌥⏎"
    )
    XCTAssertEqual(
      StudyMicroDrillResultFooter.continueOffer(remaining: 3),
      "3 more due · ⌥⏎"
    )
  }

  /// The ⌥⏎ path: answering with more cards due offers the continue, and advancing
  /// presents the next card unanswered — the panel stays a drill, not a result.
  func testAnsweringWithMoreDueOffersContinueAndAdvancePresentsTheNextCard() async {
    let (learningLog, considerTaps, studyState, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")
    await appendEntry(to: learningLog, wrong: "at", correct: "to")

    let viewModel = StudyViewModel(
      learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.load()
    await viewModel.select(viewModel.currentCard?.correct ?? "")

    XCTAssertTrue(viewModel.answerRevealed)
    XCTAssertEqual(viewModel.remainingCount, 1)
    XCTAssertNotNil(StudyMicroDrillResultFooter.continueOffer(remaining: viewModel.remainingCount))

    viewModel.advance()
    XCTAssertEqual(viewModel.currentCard?.id, "other|at|to")
    XCTAssertFalse(viewModel.answerRevealed)
  }

  /// The ⏎/Esc path: the last answer leaves nothing to offer, and the answer is already
  /// persisted through the scheduler — closing the panel loses nothing.
  func testAnsweringTheLastCardOffersNoContinueAndTheAnswerIsAlreadyRecorded() async {
    let (learningLog, considerTaps, studyState, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendEntry(to: learningLog, wrong: "on", correct: "in")

    let viewModel = StudyViewModel(
      learningLog: learningLog, considerTaps: considerTaps, studyState: studyState)
    await viewModel.load()
    await viewModel.select(viewModel.currentCard?.correct ?? "")

    XCTAssertTrue(viewModel.answerRevealed)
    XCTAssertEqual(viewModel.remainingCount, 0)
    XCTAssertNil(StudyMicroDrillResultFooter.continueOffer(remaining: viewModel.remainingCount))

    let states = await studyState.states()
    XCTAssertEqual(states["other|on|in"]?.timesSeen, 1)
    XCTAssertEqual(states["other|on|in"]?.timesCorrect, 1)
  }
}
