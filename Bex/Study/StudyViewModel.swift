import Foundation

/// Drives one Study Mode drill session for the Study window. Mirrors
/// `LearningViewModel`'s shape (a `@MainActor` `ObservableObject` that loads once and
/// publishes read models for a SwiftUI view) but adds the interactive pieces Learning
/// doesn't need: a session queue, per-answer grading, and scheduling writes.
///
/// `now` is injected exactly like `StudyStateStore.record(cardID:correct:now:)` and
/// `StudyScheduler` require — no `Date()` here — so a fixed clock in tests makes
/// "which cards are due" and "what did we persist" fully deterministic.
@MainActor
final class StudyViewModel: ObservableObject {
  /// Upper bound on how many due cards one session presents. A backlog of hundreds of
  /// overdue cards (e.g. after not opening Study for weeks) would otherwise turn one
  /// sitting into an unbounded wall of drills.
  //
  // ponytail: a flat cap, not a "review N per day" scheduler with its own persistence.
  // Good enough for a single-user deck where the backlog realistically tops out in the
  // dozens. Revisit only if users report the cap itself feeling arbitrary (e.g. want
  // to always clear everything due today).
  static let sessionCap = 20

  @Published private(set) var isLoading = true
  @Published private(set) var currentCard: StudyCard?
  /// The current card's choices in display order. Shuffled once when the card is
  /// presented (see `presentNextCard()`) and left untouched afterward, so re-renders
  /// while a card is on screen never reshuffle the buttons out from under the user.
  @Published private(set) var choices: [String] = []
  @Published private(set) var selectedChoice: String?
  @Published private(set) var answerRevealed = false
  /// Whether the just-graded answer was correct — the single source of truth the view
  /// reads for feedback in BOTH modes. Choice cards could infer this by comparing
  /// `selectedChoice` to `card.correct`, but typed cards have no such comparison to
  /// reuse (typed answers are graded through `StudyAnswerCheck`, not exact equality),
  /// so this flag exists once, set by the shared grading tail, instead of every call
  /// site re-deriving it its own way.
  @Published private(set) var lastAnswerWasCorrect = false
  /// The `TextField` binding for `.typed` cards. Settable (unlike everything else here)
  /// because SwiftUI needs a two-way binding for text input.
  @Published var typedAnswer: String = ""
  /// Today's actionable workload from `StudyDailyPlan.plan` (due reviews plus today's
  /// capped new intake — see that type) — used to tell "nothing to study" apart from
  /// "there's a plan, but this session only pulled in `sessionCap` of it".
  @Published private(set) var dueCount = 0
  /// Number of cards answered so far this session.
  @Published private(set) var completedCount = 0
  /// Size of this session's queue after applying `sessionCap` — the denominator for a
  /// "3 of 12" progress readout.
  @Published private(set) var sessionTotal = 0

  private let learningLog: LearningLogStore
  private let considerTaps: ConsiderTapStore
  private let studyState: StudyStateStore
  private let now: () -> Date
  private var sessionQueue: [StudyCard] = []

  init(
    learningLog: LearningLogStore,
    considerTaps: ConsiderTapStore,
    studyState: StudyStateStore,
    now: @escaping () -> Date = { Date() }
  ) {
    self.learningLog = learningLog
    self.considerTaps = considerTaps
    self.studyState = studyState
    self.now = now
  }

  /// Nothing is due at all. Distinct from `isFinished`: this drives a "come back
  /// tomorrow" message before any drilling happened, not a "you're done" one.
  var isEmpty: Bool {
    !isLoading && sessionTotal == 0
  }

  /// The session's queue is exhausted after presenting at least one card. Requires
  /// `sessionTotal > 0` so a never-started, nothing-due session reads as `isEmpty`
  /// rather than `isFinished` (both would otherwise show `currentCard == nil`).
  var isFinished: Bool {
    !isLoading && sessionTotal > 0 && currentCard == nil
  }

  /// Reads the learning log, builds this run's drill cards, and assembles the session
  /// queue from whatever is currently due. Safe to call again (e.g. reopening the
  /// window) — it rebuilds the queue from scratch each time.
  func load() async {
    isLoading = true
    let entries = await learningLog.readAll()
    let samples = LearningLogSamples.merged(entries, taps: await considerTaps.taps())
    let cards = StudyCardBuilder.cards(from: samples)
    // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps on a
    // duplicate id, which would turn a card-builder regression in another file into a
    // crash here. `StudyCardBuilder` already dedups by id, so keeping the first is a
    // no-op today — it just refuses to be a crash site if that ever changes.
    let cardsByID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    let states = await studyState.states()
    let planIDs = StudyDailyPlan.plan(cards: cards, states: states, now: now()).cardIDs
    dueCount = planIDs.count

    sessionQueue = planIDs.prefix(Self.sessionCap).compactMap { cardsByID[$0] }
    sessionTotal = sessionQueue.count
    completedCount = 0
    presentNextCard()

    isLoading = false
  }

  /// Records the user's answer for the current card and reveals the result. Correct is
  /// an exact match against `currentCard.correct` — the choices always come from the
  /// card itself, so there's no fuzzy comparison to get wrong. A no-op once the answer
  /// is already revealed (double-clicks, stray Return presses) so one card can't be
  /// graded twice.
  func select(_ choice: String) async {
    guard let currentCard, !answerRevealed else { return }
    selectedChoice = choice
    await finishGrading(correct: choice == currentCard.correct, cardID: currentCard.id)
  }

  /// Grades `typedAnswer` for `.typed` cards via `StudyAnswerCheck.matches` and follows
  /// the same reveal/persist/count path `select(_:)` uses. A no-op when the answer is
  /// already revealed (matches `select`'s double-submit guard) or when `typedAnswer` is
  /// blank after trimming — otherwise a stray Return in an empty field would grade and
  /// advance past a card the user never actually answered.
  func submitTypedAnswer() async {
    guard let currentCard, !answerRevealed else { return }
    guard !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let correct = StudyAnswerCheck.matches(typed: typedAnswer, correct: currentCard.correct)
    await finishGrading(correct: correct, cardID: currentCard.id)
  }

  /// Shared grading tail for both `select(_:)` and `submitTypedAnswer()`: reveal,
  /// persist through `studyState.record(...)`, bump the session's completed count, and
  /// update the single `lastAnswerWasCorrect` flag the view reads for feedback.
  private func finishGrading(correct: Bool, cardID: String) async {
    lastAnswerWasCorrect = correct
    answerRevealed = true
    await studyState.record(cardID: cardID, correct: correct, now: now())
    completedCount += 1
  }

  /// Moves to the next queued card, or clears `currentCard` to signal the session is
  /// finished (see `isFinished`) once the queue is empty.
  func advance() {
    presentNextCard()
  }

  private func presentNextCard() {
    guard !sessionQueue.isEmpty else {
      currentCard = nil
      choices = []
      selectedChoice = nil
      answerRevealed = false
      typedAnswer = ""
      return
    }
    let card = sessionQueue.removeFirst()
    currentCard = card
    // The pure `StudyCard.choices` is alphabetically sorted for determinism (see the
    // `ponytail:` comment on `StudyCardBuilder.choices`) — shuffling belongs at the
    // display edge, done exactly once per card so it doesn't reorder mid-answer.
    choices = card.choices.shuffled()
    selectedChoice = nil
    answerRevealed = false
    typedAnswer = ""
  }
}
