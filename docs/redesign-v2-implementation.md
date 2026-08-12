# Bex redesign v2 — what shipped, and why it differs from the plan

Companion to `docs/redesign-v2-gap-analysis.md` and successor to
`docs/redesign-v1-implementation.md`, in the same format: what was built, where the build
deliberately departs from the design (turn 4 of `Bex Redesign.dc.html`), and what was not
built. Read `docs/purpose.md` first; the non-negotiables outrank both the mock and this file.

Each step landed as its own commit on `main`, building and passing the unit suite
(`-only-testing:BexTests`). The fixture screenshots in `docs/redesign-v1-screenshots/`
remain the visual baseline for surfaces this pass did not touch; no new screenshots were
captured in this pass.

---

## Built

| Ref | Work item | Where |
| --- | --- | --- |
| P1 | Shared review core extracted from Fix & Send | `Bex/Review/ReviewCardView.swift` |
| P1 / 4a | Quick Check rebuilt on the shared card; footer = Cancel / **Copy Correction ⏎** | `QuickCheck/QuickCheckView.swift`, `QuickCheckViewModel.swift` |
| P2 / 4c | Post-send HUD is click-to-arm: dashed inert slot, whole panel one click target, 30s fade-out, Esc restores the prior app | `Study/StudyMicroDrill.swift` |
| P3 | Keep/Toss retreat: answered state is Next ⏎; Toss visible only on first-ever exposure, always in a per-card overflow (⌘⌫) | `Study/StudyCardView.swift`, `StudyViewModel.swift` |
| P4 / 4e | First-run empty deck (dashed card, the two data-generating actions), one-sentence Suggestions/Progress empty states, hub shows "0 due" and never hides its command rows | `Study/StudyDeckView.swift`, `Learning/LearnView.swift`, `Application/MenuBarHub.swift`, `Study/StudyDueCount.swift` |
| P5 | Per-source card tint on the category label only: correction blue, your pick purple, from your ask yellow | `Study/StudyCard.swift` (`StudyCardSource`), `StudyCardView.swift` |
| P5 | Fix & Send panel disables smart dashes/quotes/text replacement, closing the recorded `--dry-run` → `—dry—run` mask escape | `PromptGate/PlainTextSubstitutions.swift` |

The acceptance line holds: after a check, ⇧⌘G and ⇧⌘P render the same `ReviewCardView` —
same editable final message, same one-line redline, same unranked alternatives panel (picks
mint Study cards through the same `ConsiderTapStore`), same ask thread, same collapsed
Details. The visible differences are exactly the designed ones: Quick Check has no target
row, no provenance line, no Edit Original & Recheck, and its footer is Cancel / Copy
Correction ⏎.

---

## Where the build departs from the plan, and why

### 1. The card's "footer parameter" is the host, not a flag
The gap analysis asked for a footer parameterised by primary-action label/handler plus
presence flags. Fix & Send's footer is irreducibly target-specific (delivery actions vary
per target kind, terminal-failure states, `ViewThatFits` fallback), so flattening it into
label+flags would have meant a second copy of that logic. Instead `ReviewCardView` owns the
card *content* and each host renders its own footer and its own header rows; delivery
guidance enters the card's Details through a `detailsExtra` view slot. Same outcome — the
surfaces differ only where the design says they differ — with no new abstraction. The
`idPrefix` parameter keeps every existing `prompt-gate-*` and `quick-check-*` accessibility
identifier intact (one addition: `DiffSummaryAccessibilityElement` learned an identifier
parameter so the diff summary is `quick-check-diff-summary` on Quick Check).

### 2. Quick Check deletions were scoped to the post-check state
"Delete the retention/setup/disclosure/lookup/management sections" is implemented as: those
sections no longer exist *after a check runs*. The draft state keeps them, deliberately —
the retention rows are a consent flow, the setup error is actionable, the outbound
confirmation is non-negotiable 3, and the dictionary lookup answers a different question
than a check and was never part of the card. The rewrite row (More Formal / Friendlier /
Shorter), Use as Input, Recheck, and the Copy/Copy-and-Close pair were removed outright
with the old result state, not relocated — the design has no home for them and Fix & Send
never had them. ⌘[ still quietly returns to the draft (the panel shortcut survives), which
is "Edit Original & Recheck" as a key, not a control.

### 3. The 30s "slides into today's pile" writes nothing
`StudyScheduler` only moves a card on an answer, so an ignored card is still due and is
already in today's plan for the hub and the deck. The timeout therefore just fades the
panel; there is no state to write, and writing any would invent a new scheduling concept.
The unarmed copy states the fallback and it is true by construction.

### 4. First-exposure is a session snapshot
"Visible only the first time a card is ever shown" is computed from the review-state map at
session load (`states[id] == nil`) and held for the session, so answering a card cannot
flip the Toss control out from under the owner mid-card. A card answered wrong yesterday is
not a first exposure today, which matches the intent: the quality question is asked once.

### 5. The empty deck's shortcut labels are the design's copy, not the live bindings
The hub shows the actually-bound chords because `AppDelegate` feeds it the rebindable
`KeyChord`s. The empty deck's two buttons say "⇧⌘G" / "⇧⌘P" literally, as the design wrote
them. If the owner rebinds the hotkeys, these labels will be stale — threading the chords
through `MainWindowModel` → `LearnView` → `StudyDeckView` was not worth it for a screen
that exists only before the first card. Revisit if rebinding ever becomes real.

### 6. Per-source tint required threading provenance the model did not have
The gap analysis said the source "is already on the card model"; it was not — ask-thread
saves and tapped picks both log as `[expression]`. `LearningSample` gained a defaulted
`source` field (`LearningLogSamples` sets `.ask` for the `bex-ask` client, `.pick` for
consider taps) and `StudyCardBuilder` carries it onto `StudyCard.source`. Provenance is
deliberately excluded from `StudyCard.id`, so no saved review state was orphaned. Saved
dictionary lookups tint as corrections; the design names only three sources.

### 7. Hub at zero: the sentence is gone, the number stays
`StudyDueCount.costLabel(remaining: 0)` now returns "0 due" (was "Nothing due"), and the
hub's zero-due card section is nothing at all — the header already says the true count and
the command rows stay. "Come back tomorrow" prose added nothing the number does not say.

### 8. Smart-substitution fix is a window sweep, not a text-view wrapper
SwiftUI's `TextEditor` exposes no handle to its `NSTextView`, so
`PlainTextSubstitutionsDisabler` is a marker view that walks the Fix & Send panel's view
tree and switches off dash/quote/replacement substitution on every text view it finds, on
mount and on every update. It covers both the composer and the final-message editor (an
em-dashed flag would be delivered to the terminal just as surely as it would dodge the
mask). Quick Check's draft editor was left alone — out of this pass's scope, and trivially
coverable later by attaching the same one view.

---

## Not built (unchanged from the plan's out-of-scope list)

- Chips inside the editable final message. The interaction model stays recorded in the gap
  analysis for a later pass; the consent payload already states the masking limit.
- Session-capture toggles for `~/.claude/projects` / `~/.codex/sessions` — still visible,
  Off, with reasons (non-negotiable 8; the corpus gate was run on the learning log).
- Trend arrows (no trend is computed yet).
- Design 4b "instant mode" cursor panel.

---

## Testing notes

- The unit suite passed after every step and is the CI gate.
- The UI tests were updated to the new Quick Check contract (`testCheckShowsReviewCard…`
  replaces the rewrite/copy-close flow; auxiliary navigation now round-trips through the
  card's context row and returns to the draft with ⌘[), but they could not be *executed*
  in the environment this pass ran in — the XCUITest runner timed out enabling automation
  mode, which is a machine permission, not a test result. Run `BexUITests` locally before
  the next release.
- New unit coverage: alternatives parsing/picking and edited-correction copying on the
  Quick Check view model, first-exposure semantics on the study view model, and
  provenance-to-tint threading in `LearningLogSamplesTests`.

## What the next design pass could most usefully answer

1. **Does the armed micro-drill earn a second card?** Today answering advances into the
   same session; the panel closes only when the queue empties or on Esc. One card per send
   may be the honest scope.
2. **Should Quick Check's draft keep Look Up**, or does the dictionary deserve its own
   surface now that the result state is the shared card?
3. **The empty-deck shortcut labels** — live chords or the design's literals (departure 5).
