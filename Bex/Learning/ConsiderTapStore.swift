import Darwin
import Foundation

extension Notification.Name {
  /// Posted when a "Consider" alternative is tapped. Mirrors `.bexLearningLogDidChange`
  /// and `.bexStudyStateDidChange` for the same reason: a tap mints a new Study card, so
  /// the menu-bar badge and the daily reminder need to recompute without the Learning
  /// window knowing anything about either.
  static let bexConsiderTapsDidChange = Notification.Name("com.bex.desktop.considerTapsDidChange")
}

/// One "Consider" alternative the owner chose, recorded by tapping it in the Learning
/// window (docs/learning-mode-plan.md, v7.1 decision 1).
///
/// A tap is the answer to a problem v7 created. The `Consider` section now offers 2-3
/// alternatives and is explicitly forbidden from ranking them, so there is no "correct"
/// side to build a cloze from — until the owner picks one. That pick is also the goal-2
/// uptake signal, replacing the old proxy that guessed at adoption by watching for the
/// phrase to reappear in later writing.
struct ConsiderTap: Codable, Equatable, Sendable {
  /// ISO8601, same format and role as `LearningLogStore.Entry.timestamp` — it orders the
  /// synthesized sample among real log entries.
  let timestamp: String
  /// The full text the suggestion was made about. Required, not decorative:
  /// `StudyCardBuilder.cloze` blanks `phrase` *inside* this string, so a tap with no
  /// source context cannot become a card at all.
  let sourceOriginal: String
  /// The original wording, left of the arrow. Becomes the card's `wrong` side.
  let phrase: String
  /// The alternative the owner chose. Becomes the card's `correct` side.
  let alternative: String
  /// The model's note on how this alternative differs. May be empty.
  let reason: String

  /// Identity for dedup and for the "already tapped" check in the UI. Deliberately
  /// excludes `sourceOriginal` and `reason`: choosing the same rephrasing again, in a
  /// different sentence or with the model wording its note differently, is the same
  /// decision and must not mint a second card. Matches `StudyCard.id`'s reasoning —
  /// see its doc comment for why a composed string beats `hashValue` or `UUID()` here.
  var id: String { "\(phrase)|\(alternative)" }

  /// The two-section explanation this tap is drilled through, in exactly the format
  /// `GrammarPrompts` produces — so `StudyCardBuilder` picks it up with no changes and
  /// the whole spaced-repetition pipeline works on chosen expressions for free. Same
  /// trick `DictionaryLookup.learningLogExplanation` uses for saved vocabulary.
  var learningLogExplanation: String {
    let suffix = reason.isEmpty ? "" : " — \(reason)"
    return """
      Fixed:
      [\(GrammarCategory.expression.rawValue)] "\(phrase)" → "\(alternative)"\(suffix)
      """
  }
}

/// Owner-only persistence for tapped "Consider" alternatives.
///
/// A deliberately separate file from `learning-log.jsonl`, for the same reason
/// `StudyStateStore` is separate: the log is an append-only record of what the owner
/// *wrote*, and a tap is not writing — it is a choice made later, while reviewing. Folding
/// taps into the log would inflate `LearningMetrics`' per-100-words denominators with text
/// he never typed, quietly diluting the very error rates the Learning window exists to
/// show. Keeping them apart means the metrics never see taps, and the deck always does.
///
/// Same privacy posture as the log and the study state (0o700 directory, 0o600 file): a
/// tap embeds the surrounding prompt text in `sourceOriginal`.
actor ConsiderTapStore {
  private let directoryURL: URL
  private let fileURL: URL
  private let now: @Sendable () -> Date
  private var cachedTaps: [String: ConsiderTap]?

  /// Defaults to the same `LearningLog` directory as `LearningLogStore` and
  /// `StudyStateStore`, injectable the same way so tests can point all three at one
  /// temp directory.
  init(
    directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/LearningLog", isDirectory: true),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directoryURL = directoryURL
    self.fileURL = directoryURL.appendingPathComponent("consider-taps.json")
    self.now = now
  }

  /// Every tap recorded so far, oldest first. Loads from disk on first call and caches
  /// for the lifetime of this actor instance, like `StudyStateStore.states()`.
  func taps() -> [ConsiderTap] {
    loadIfNeeded()
    return (cachedTaps ?? [:]).values.sorted { $0.timestamp < $1.timestamp }
  }

  /// The ids of everything tapped, for the Learning window's "already chosen" state.
  /// Cheaper than handing the whole list to the UI just to build this set.
  func tappedIDs() -> Set<String> {
    loadIfNeeded()
    return Set((cachedTaps ?? [:]).keys)
  }

  /// Records one choice. Re-tapping the same `phrase → alternative` pair is a no-op
  /// rather than a re-stamp: the first tap is when the decision was made, and letting a
  /// later tap move the timestamp would reshuffle the card's position in
  /// `StudyDailyPlan`'s oldest-first intake for no reason.
  func record(sourceOriginal: String, phrase: String, alternative: String, reason: String) {
    loadIfNeeded()
    var taps = cachedTaps ?? [:]
    let tap = ConsiderTap(
      timestamp: ISO8601DateFormatter().string(from: now()),
      sourceOriginal: sourceOriginal,
      phrase: phrase,
      alternative: alternative,
      reason: reason
    )
    guard taps[tap.id] == nil else { return }
    taps[tap.id] = tap
    persist(taps)
    NotificationCenter.default.post(name: .bexConsiderTapsDidChange, object: nil)
  }

  /// Clears every tap. Test/"start over" support, mirroring `StudyStateStore.reset()`.
  /// The cards built from these taps disappear with them; their Leitner progress in
  /// `study-state.json` is keyed by card id and survives, so re-tapping restores it.
  func reset() {
    persist([:])
    NotificationCenter.default.post(name: .bexConsiderTapsDidChange, object: nil)
  }

  private func loadIfNeeded() {
    guard cachedTaps == nil else { return }
    cachedTaps = readFromDisk()
  }

  /// Best-effort read, mirroring `StudyStateStore.readFromDisk()`: a missing file (nothing
  /// tapped yet) and a corrupt one both yield empty rather than throwing. Worst case the
  /// owner's chosen expressions stop being drilled, which is safe; nothing else breaks.
  private func readFromDisk() -> [String: ConsiderTap] {
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    guard let decoded = try? JSONDecoder().decode([String: ConsiderTap].self, from: data) else {
      return [:]
    }
    return decoded
  }

  private func persist(_ taps: [String: ConsiderTap]) {
    cachedTaps = taps
    do {
      try ensureDirectory()
      let data = try JSONEncoder().encode(taps)
      try data.write(to: fileURL, options: .atomic)
      chmod(fileURL.path, 0o600)
    } catch {
      // Fire-and-forget, exactly like `StudyStateStore.persist`: a persistence hiccup
      // must never crash the app or block the Learning window.
    }
  }

  private func ensureDirectory() throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directoryURL.path, 0o700)
  }
}
