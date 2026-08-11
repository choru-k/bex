import Foundation

/// Computes what Study Mode should actually put in front of the owner *right now* — the
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
///     these yet — they can enter rotation whenever — so how many enter *at a time* is a
///     policy knob (`newCardBatchSize`), not a fact derived from the data. Capping it
///     is what makes the badge a small, clearable number instead of "the whole
///     backlog": the visible workload is bounded by policy, and it's the same bound
///     whether the deck has 12 cards or 1200.
///
/// Pure and deterministic like `StudyScheduler`/`LearningBadge`: no `Date()` inside, no
/// RNG, `now` and `calendar` both injected so "which day is it" is never ambient state.
enum StudyDailyPlan {
  /// How many brand-new cards may be on offer at once. Chosen so a cold-start deck (or
  /// any backlog) turns into a small, clearable batch instead of dumping its entire size
  /// on the owner at once — see the file doc comment for why that distinction is the
  /// whole point of this type.
  static let newCardBatchSize = 10

  /// How long after a card enters rotation before its slot frees up for a new one.
  ///
  /// This used to be "per calendar day", which the owner hit immediately: he cleared the
  /// ten, wanted to keep going, and got nothing until the next morning. A cap meant to
  /// stop a backlog from feeling hopeless had turned into a ceiling on wanting to study,
  /// which is the opposite problem.
  ///
  /// An hour keeps the property that actually mattered — never more than
  /// `newCardBatchSize` new cards visible at any moment, so the badge stays small and
  /// reachable — while letting someone who finishes come back to a fresh batch instead of
  /// a locked door. Finishing ten and stopping looks exactly like it did before; the
  /// difference only shows up for someone who wants more.
  static let newCardRefillInterval: TimeInterval = 3600

  /// The actionable Study workload right now, already split into reviews-vs-new and ordered
  /// for presentation.
  struct Plan: Equatable, Sendable {
    /// What to study right now, in order: due reviews first, then this batch's new cards.
    let cardIDs: [String]
    /// How many of `cardIDs` are due cards already in rotation.
    let reviewCount: Int
    /// How many of `cardIDs` are brand-new cards entering rotation now.
    let newCount: Int
    /// The largest whole-day overdue gap across the included reviews, or 0 when
    /// nothing is overdue (including when the plan has no reviews at all). Drives
    /// `StudyDueCount.severity` — see that function for why this, not raw due count,
    /// is the signal worth escalating on.
    let maxOverdueDays: Int
  }

  /// Builds the current plan from the full card list, the persisted review states, and
  /// "now". `cards` is expected in `StudyCardBuilder.cards(from:)`'s oldest-log-entry-
  /// first order — that ordering is what makes "take the first `allowedNew`" mean
  /// "the owner's oldest mistakes get introduced first" rather than an arbitrary pick.
  static func plan(
    cards: [StudyCard],
    states: [String: StudyReviewState],
    now: Date,
    calendar: Calendar = .current,
    verdicts: [String: StudyPattern.Verdict] = [:]
  ) -> Plan {
    // Patterns a blank cannot teach are dropped outright — not deprioritized — including
    // for cards already in rotation. See `StudyPattern.isDrillable`; on the real deck this
    // removes 57 of 151 cards, all of them articles and subject-verb agreement.
    let drillable = cards.filter { card in
      // Tossed first, and unconditionally: the owner said this is not a gap, and the whole
      // point of asking is that the answer is respected. A deprioritized "no" comes back.
      guard states[card.id]?.isTossed != true else { return false }
      return isDrillable(card, verdicts: verdicts)
    }

    // Reviews: every in-rotation (has a state) card that's due. Unconditional — see
    // the file doc comment on why reviews never get capped.
    var reviewIDs: [String] = []
    var maxOverdueDays = 0
    for card in drillable {
      guard let state = states[card.id] else { continue }
      guard state.dueAt <= now else { continue }
      reviewIDs.append(card.id)
      let overdueDays = calendar.dateComponents([.day], from: state.dueAt, to: now).day ?? 0
      maxOverdueDays = max(maxOverdueDays, max(0, overdueDays))
    }

    // New intake: cards with no state at all, capped by how many entered rotation inside
    // the last `newCardRefillInterval`. A `nil` `firstSeenAt` (state written before this
    // field existed) deliberately does NOT count against the batch — we have no evidence
    // of when it was introduced, and undercounting here only means the cap is a little
    // more permissive on the day this ships, never a correctness problem.
    let introducedRecently = states.values.filter { state in
      guard let firstSeenAt = state.firstSeenAt else { return false }
      return now.timeIntervalSince(firstSeenAt) < newCardRefillInterval
    }.count
    let allowedNew = max(0, newCardBatchSize - introducedRecently)

    // Higher-priority cards enter rotation first, oldest-first within a tier (both
    // filters preserve `cards`' order). With a capped batch the intake order decides what
    // the owner actually ever sees, so it has to be "the mistakes worth fixing" rather
    // than "whatever was logged first" — an obvious `"sub agent"` → `"sub agents"` tap
    // is not worth one of the ten slots while word order and prepositions wait.
    let unseen: [StudyCard] = drillable.filter { states[$0.id] == nil }

    // A card the classifier examined and found no rule for teaches nothing, so it goes
    // behind every real lesson. This is a stronger signal than `StudyCardQuality`'s
    // letter heuristics can produce and it is worth trusting: measured on the real deck,
    // the classifier labelled 12 cards `unclassified` — fragments of mangled prompts like
    // `"story. use"` → `"story"` and `"frm"` → `"now"` — and because they are (correctly)
    // exempt from grouping, they otherwise filled 6 of the 10 slots in a batch and held it
    // at 5 distinct lessons. Deprioritizing them takes the same batch to 8.
    //
    // `nil` is deliberately NOT treated the same way: it means "not classified yet", not
    // "no rule applies", and penalizing it would push every card to the back of the deck
    // until the background pass has run.
    func teachesNoRule(_ card: StudyCard) -> Bool {
      verdicts[card.id]?.pattern == .unclassified
    }
    let ordered: [StudyCard] =
      unseen.filter { $0.priority == .high && !teachesNoRule($0) }
      + unseen.filter { $0.priority == .low && !teachesNoRule($0) }
      + unseen.filter { teachesNoRule($0) }

    // One card per pattern. 34 of the owner's cards are examples of the same determiner
    // rule, so an unfiltered batch of ten was five or six repeats of two or three lessons:
    // the rule gets taught by the first card and the rest of the batch is spent. Spreading
    // them means a batch is ten different lessons, and the other 33 determiner examples
    // still arrive over following batches — spaced, which is how a rule is actually learned
    // rather than a phrase memorized.
    //
    // Cards whose pattern is unknown are never held back (`groupsCards`): until the
    // background classifier has labelled them their pattern falls back to a
    // `GrammarCategory` tag, and `other`/`spelling` describe no lesson, so treating them as
    // one group would starve the batch down to a single card from the whole remainder.
    var usedPatterns = Set<StudyPattern>()
    var newIDs: [String] = []
    for card in ordered {
      guard newIDs.count < allowedNew else { break }
      let cardPattern = pattern(for: card, verdicts: verdicts)
      if cardPattern.groupsCards {
        guard !usedPatterns.contains(cardPattern) else { continue }
        usedPatterns.insert(cardPattern)
      }
      newIDs.append(card.id)
    }

    return Plan(
      cardIDs: reviewIDs + newIDs,
      reviewCount: reviewIDs.count,
      newCount: newIDs.count,
      maxOverdueDays: maxOverdueDays
    )
  }

  /// A card's pattern: what the classifier assigned, or the `GrammarCategory` tag it falls
  /// back to until the background pass has labelled it.
  private static func pattern(for card: StudyCard, verdicts: [String: StudyPattern.Verdict]) -> StudyPattern {
    verdicts[card.id]?.pattern ?? StudyPattern.fromCategory(card.category)
  }

  /// A card survives two independent gates. The classifier's per-card `isDrillable` is the
  /// authoritative one — it can see whether the blank is answerable, which no rule here
  /// can — and the pattern-level check is the fallback that applies before the background
  /// pass has judged a card. An unjudged card is drillable unless its *pattern* is one a
  /// blank cannot teach, so nothing is removed on a parse failure or a missing entry.
  private static func isDrillable(_ card: StudyCard, verdicts: [String: StudyPattern.Verdict]) -> Bool {
    if let verdict = verdicts[card.id] { return verdict.isDrillable }
    return StudyPattern.fromCategory(card.category).isDrillable
  }
}
