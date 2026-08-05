import Darwin
import Foundation

extension Notification.Name {
  /// Posted whenever `StudyStateStore` persists a change to any card's review state
  /// (an answer recorded, or a reset). Mirrors `LearningLogStore.append`'s
  /// `.bexLearningLogDidChange` post exactly, for the same reason: it lets
  /// `AppDelegate` recompute the menu-bar badge and reschedule the daily reminder
  /// right after a Study answer changes the due count, without `StudyViewModel` (or
  /// anything else) needing a callback threaded through to it.
  static let bexStudyStateDidChange = Notification.Name("com.bex.desktop.studyStateDidChange")
}

/// Owner-only persistence for Study Mode's per-card Leitner state.
///
/// This lives in the same `LearningLog` directory as `LearningLogStore`'s
/// `learning-log.jsonl`, but as a deliberately separate file, `study-state.json`:
/// the log is an append-only, write-once-per-entry record of what was corrected,
/// while this is small, fully-overwritten, *mutable* state (each review rewrites a
/// card's box/dueAt in place). Mixing the two into one file would mean every review
/// answer touches the append-only log's format, and would make "replay the log to
/// rebuild everything" — the log's whole reason for being append-only — no longer
/// true. Keeping them as separate files means either can be deleted/rebuilt/inspected
/// independently: deleting `study-state.json` just resets scheduling progress and
/// leaves the learning log (and card generation from it) untouched.
///
/// Same privacy posture as `LearningLogStore` and for the same reason: this is
/// state inferred from the user's own logged mistakes, so it stays owner-only
/// (0o700 directory, 0o600 file) even though it contains no raw prompt text itself.
actor StudyStateStore {
  private let directoryURL: URL
  private let fileURL: URL
  private let now: @Sendable () -> Date
  private var cachedStates: [String: StudyReviewState]?

  /// `directoryURL` defaults to the same `LearningLog` directory `LearningLogStore`
  /// uses, injectable exactly the same way so tests can point both at one temp
  /// directory. `now` is stored for parity with `LearningLogStore`'s constructor
  /// shape; `record(cardID:correct:now:)` below takes its own explicit `now` because
  /// the scheduling math it delegates to (`StudyScheduler.advance`) must stay a pure
  /// function of its arguments, never of ambient state.
  init(
    directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/LearningLog", isDirectory: true),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directoryURL = directoryURL
    self.fileURL = directoryURL.appendingPathComponent("study-state.json")
    self.now = now
  }

  /// All review state currently known, keyed by card id. Loads from disk on first
  /// call and caches thereafter for the lifetime of this actor instance.
  func states() -> [String: StudyReviewState] {
    loadIfNeeded()
    return cachedStates ?? [:]
  }

  /// Records one answer for `cardID` via `StudyScheduler.advance` and persists the
  /// whole state map. `cardID` with no prior state is treated by the scheduler as a
  /// brand-new card starting at box 0.
  func record(cardID: String, correct: Bool, now: Date) {
    loadIfNeeded()
    var states = cachedStates ?? [:]
    states[cardID] = StudyScheduler.advance(states[cardID], correct: correct, now: now)
    persist(states)
    NotificationCenter.default.post(name: .bexStudyStateDidChange, object: nil)
  }

  /// Clears all review state. Used by tests and by a future "start over" action —
  /// every card reverts to "never studied" (see `StudyScheduler.isDue`), since an
  /// absent entry is always due.
  func reset() {
    persist([:])
    NotificationCenter.default.post(name: .bexStudyStateDidChange, object: nil)
  }

  private func loadIfNeeded() {
    guard cachedStates == nil else { return }
    cachedStates = readFromDisk()
  }

  /// Best-effort read, mirroring `LearningLogStore.readAll()`'s philosophy: this
  /// state exists to make studying more efficient, not to be a source of truth that
  /// must round-trip perfectly. A missing file (never studied yet) and a corrupt or
  /// truncated file (e.g. a crash mid-write, or manual tampering) both yield an empty
  /// state rather than throwing — worst case, every card looks "never studied" and
  /// scheduling starts fresh, which is safe.
  private func readFromDisk() -> [String: StudyReviewState] {
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    guard let decoded = try? JSONDecoder().decode([String: StudyReviewState].self, from: data) else {
      return [:]
    }
    return decoded
  }

  /// Writes the full state map with `.atomic`, so a crash mid-write leaves either the
  /// old file or the new one intact, never a half-written one. Any failure (disk
  /// full, permissions, etc.) is swallowed exactly like `LearningLogStore.append`:
  /// Study Mode's scheduling is a convenience feature, and a persistence hiccup must
  /// never crash or block the app. The in-memory cache is updated regardless, so the
  /// current process stays consistent even if the write itself failed.
  private func persist(_ states: [String: StudyReviewState]) {
    cachedStates = states
    do {
      try ensureDirectory()
      let data = try JSONEncoder().encode(states)
      try data.write(to: fileURL, options: .atomic)
      chmod(fileURL.path, 0o600)
    } catch {
      // Fire-and-forget: intentionally ignored, see doc comment above.
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
