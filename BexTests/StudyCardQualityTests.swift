import Foundation
import XCTest

@testable import Bex

/// Every case here is a real `wrong → correct` pair from the owner's learning log —
/// these rules exist because he opened the deck and got drilled on his own typos.
final class StudyCardQualityTests: XCTestCase {
  private func priority(_ wrong: String, _ correct: String) -> StudyCardPriority {
    StudyCardQuality.priority(wrong: wrong, correct: correct)
  }

  // MARK: - Junk: keyboard typos

  func testSingleWordTyposAreNotEnglishMistakes() {
    for (wrong, correct) in [
      ("cluade", "Claude"),  // transposition
      ("coudl", "could"),
      ("fisrt", "first"),
      ("stpes", "steps"),
      ("chec", "check"),  // dropped letter
      ("pressue", "pressure"),
      ("compoenent", "component"),  // doubled letter
      ("createing", "creating"),
    ] {
      XCTAssertEqual(priority(wrong, correct), .junk, "\(wrong) → \(correct)")
    }
  }

  /// The other side of the typo rule: a genuine word-form error is far enough away to
  /// stay a card. If this ever starts failing, `typoEditDistance` has been raised too far.
  func testRealWordFormErrorsSurviveTheTypoFilter() {
    XCTAssertEqual(priority("techincal", "technically"), .high)
  }

  /// The regression that forced the letter-containment half of the typo rule. Short
  /// function words are the most valuable corrections in this corpus AND sit at edit
  /// distance 1–2 from each other, so distance alone silently deleted them. These are
  /// exactly the fixtures `StudyViewModelTests` and `StudyCardTests` build cards from.
  func testShortFunctionWordCorrectionsAreNotMistakenForTypos() {
    for (wrong, correct) in [
      ("on", "in"),
      ("at", "to"),
      ("a", "the"),
      ("does", "did"),
      ("go", "went"),
      ("is", "are"),
    ] {
      XCTAssertEqual(priority(wrong, correct), .high, "\(wrong) → \(correct)")
    }
  }

  // MARK: - Junk: punctuation only

  /// `StudyAnswerCheck.normalize` deliberately preserves internal punctuation (one real
  /// card's whole correction is a space before a comma), so these slip past
  /// `isUsableCandidate`'s normalized-equality check and need their own rule.
  func testInternalPunctuationOnlyDiffsAreDropped() {
    for (wrong, correct) in [
      ("yes. but", "Yes, but"),
      ("However I", "However, I"),
      ("bug. maybe", "bug? Maybe"),
      ("use-case", "use case"),
      ("what should i do ?", "What should I do?"),
      ("good quality problem", "good-quality problem"),
    ] {
      XCTAssertEqual(priority(wrong, correct), .junk, "\(wrong) → \(correct)")
    }
  }

  func testLetterlessGarbageIsDropped() {
    XCTAssertEqual(priority("?", "1063\\"), .junk)
  }

  // MARK: - Low: plural morphology

  /// The class the owner named explicitly ("agents" or "agent"): kept, but last in line.
  func testPluralOnlyDiffsAreLowPriority() {
    XCTAssertEqual(priority("3 sonnet sub agent", "3 sonnet sub agents"), .low)
    XCTAssertEqual(priority("without blocker", "without blockers"), .low)
    XCTAssertEqual(priority("it show", "it shows"), .low)
    XCTAssertEqual(priority("the evidences", "the evidence"), .low)
  }

  /// A plural `s` is a one-character edit, so the plural rule has to run before the typo
  /// rule or these get thrown away instead of merely deprioritized.
  func testSingleWordPluralsAreLowNotJunk() {
    XCTAssertEqual(priority("PR", "PRs"), .low)
    XCTAssertEqual(priority("review", "reviews"), .low)
    XCTAssertEqual(priority("artifact", "artifacts"), .low)
  }

  // MARK: - High: the ones worth studying

  func testPhraseLevelStructureIsHighPriority() {
    for (wrong, correct) in [
      ("communication between each other", "communication with each other"),
      ("in the outage", "during an outage"),
      ("Wondering is there a way", "I’m wondering if there is a way"),
      ("the backend team are", "the backend team is"),
      ("test all latency", "test the latency of all of them"),
      ("Just we need", "We just need"),
    ] {
      XCTAssertEqual(priority(wrong, correct), .high, "\(wrong) → \(correct)")
    }
  }

  // MARK: - The gate and the ordering

  func testJunkNeverBecomesACard() {
    XCTAssertFalse(
      StudyCardBuilder.isUsableCandidate(wrong: "cluade", correct: "Claude", category: "spelling"))
    XCTAssertTrue(
      StudyCardBuilder.isUsableCandidate(
        wrong: "in the outage", correct: "during an outage", category: "preposition"))
  }

  /// Why priority exists at all: with only ten new cards a day, intake order decides what
  /// he ever sees. A low-priority card logged first must not take a slot from a
  /// high-priority one logged later.
  func testDailyIntakeTakesHighPriorityCardsFirstEvenWhenLoggedLater() {
    let cards = [
      card("low-first", priority: .low),
      card("high-later", priority: .high),
    ]
    let plan = StudyDailyPlan.plan(
      cards: cards, states: [:], now: Date(timeIntervalSince1970: 1_700_000_000))

    XCTAssertEqual(plan.cardIDs, ["high-later", "low-first"])
  }

  private func card(_ id: String, priority: StudyCardPriority) -> StudyCard {
    StudyCard(
      id: id,
      category: "article",
      wrong: "a",
      correct: "the",
      reason: "reason",
      sentence: "I saw a dog.",
      promptWithBlank: "I saw _____ dog.",
      choices: ["a", "the"],
      answerMode: .typed,
      priority: priority
    )
  }
}
