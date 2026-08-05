import Foundation

/// Computes what Study Mode should actually put in front of the owner *today* — the
/// fix for the cold-start problem where a deck with zero review history has every
/// single card "due" at once (`StudyScheduler.isDue` treats "never studied" as due).
/// `StudyScheduler.dueCards` answers "which cards are eligible right now", which for a
/// 120-card deck with no history is "all 120" — technically correct, but useless as a
/// workload signal: it never shrinks day to day, so the badge/notification number never
/// visibly moves and the backlog reads as permanent and hopeless.
///
/// The standard spaced-repetition fix is to separate two very different kinds of
/// "eligible" card:
///   - **Reviews**: cards already in rotation whose schedule says they're due. These
///     are few (they only exist once the owner has actually started them) and
///     time-sensitive, so all of them are always included.
///   - **New intake**: cards never studied before. There is no schedule pressure on
///     these yet — they can enter rotation whenever — so how many enter *per day* is a
///     policy knob (`dailyNewCardLimit`), not a fact derived from the data. Capping it
///     is what makes the badge a small, clearable number instead of "the whole
///     backlog": today's workload is bounded by policy, and it's the same bound
///     whether the deck has 12 cards or 1200.
///
/// Pure and deterministic like `StudyScheduler`/`LearningBadge`: no `Date()` inside, no
/// RNG, `now` and `calendar` both injected so "which day is it" is never ambient state.
enum StudyDailyPlan {
  /// How many brand-new cards may enter rotation on any one calendar day. Chosen so a
  /// cold-start deck (or any backlog) turns into a small, steady, clearable daily
  /// batch instead of dumping its entire size on the owner at once — see the file doc
  /// comment for why that distinction is the whole point of this type.
  static let dailyNewCardLimit = 10

  /// Today's actionable Study workload, already split into reviews-vs-new and ordered
  /// for presentation.
  struct Plan: Equatable, Sendable {
    /// What to study right now, in order: due reviews first, then today's new intake.
    let cardIDs: [String]
    /// How many of `cardIDs` are due cards already in rotation.
    let reviewCount: Int
    /// How many of `cardIDs` are brand-new cards introduced today.
    let newCount: Int
    /// The largest whole-day overdue gap across the included reviews, or 0 when
    /// nothing is overdue (including when the plan has no reviews at all). Drives
    /// `StudyDueCount.severity` — see that function for why this, not raw due count,
    /// is the signal worth escalating on.
    let maxOverdueDays: Int
  }

  /// Builds today's plan from the full card list, the persisted review states, and
  /// "now". `cards` is expected in `StudyCardBuilder.cards(from:)`'s oldest-log-entry-
  /// first order — that ordering is what makes "take the first `allowedNew`" mean
  /// "the owner's oldest mistakes get introduced first" rather than an arbitrary pick.
  static func plan(
    cards: [StudyCard],
    states: [String: StudyReviewState],
    now: Date,
    calendar: Calendar = .current
  ) -> Plan {
    // Reviews: every in-rotation (has a state) card that's due. Unconditional — see
    // the file doc comment on why reviews never get capped.
    var reviewIDs: [String] = []
    var maxOverdueDays = 0
    for card in cards {
      guard let state = states[card.id] else { continue }
      guard state.dueAt <= now else { continue }
      reviewIDs.append(card.id)
      let overdueDays = calendar.dateComponents([.day], from: state.dueAt, to: now).day ?? 0
      maxOverdueDays = max(maxOverdueDays, max(0, overdueDays))
    }

    // New intake: cards with no state at all, capped by how many already entered
    // rotation today. A `nil` `firstSeenAt` (state written before this field existed)
    // deliberately does NOT count toward today's intake — we have no evidence it was
    // introduced today, and undercounting here only means the cap is a little more
    // permissive on the day this ships, never a correctness problem.
    let introducedToday = states.values.filter { state in
      guard let firstSeenAt = state.firstSeenAt else { return false }
      return calendar.isDate(firstSeenAt, inSameDayAs: now)
    }.count
    let allowedNew = max(0, dailyNewCardLimit - introducedToday)

    var newIDs: [String] = []
    for card in cards {
      guard newIDs.count < allowedNew else { break }
      guard states[card.id] == nil else { continue }
      newIDs.append(card.id)
    }

    return Plan(
      cardIDs: reviewIDs + newIDs,
      reviewCount: reviewIDs.count,
      newCount: newIDs.count,
      maxOverdueDays: maxOverdueDays
    )
  }
}
