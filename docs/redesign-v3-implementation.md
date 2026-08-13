# Bex redesign v3 — what shipped, and how it differs from the decisions

Companion to `docs/redesign-v3-decisions.md` (the spec) and successor to
`docs/redesign-v2-implementation.md`, in the same format. A small pass: three work items,
each its own commit, unit suite green after each.

---

## Built

| Decision | What shipped | Where |
| --- | --- | --- |
| 5 | Verified alternatives render on Quick Check — **no bug existed**; the v2 baseline's fixture response simply carried no Consider section. The screenshot fixture now returns two unranked alternatives, the capture test *asserts* the panel exists before photographing, and `01-quickcheck-review-card.png` shows it | `UITestingServices.swift`, `BexUITests.swift`, baseline 01 |
| 4 | The shared card's final-message editor sizes to its content: three-line floor, 60%-of-panel ceiling, scrolls beyond. Both surfaces at once; baselines 01/02 recaptured | `Review/ReviewCardView.swift` (`ReviewCardLayout`) |
| 1 | Micro-drill: answering the armed card shows the result and offers only exits — ⏎/Esc/close-box close (Esc still restores the prior app), and a muted "N more due · ⌥⏎" appears only when cards remain; ⌥⏎ continues, still armed | `Study/StudyMicroDrill.swift`, `StudyCardView.swift` |

## Where the build departs from the decisions, and why

- **"Min 3 lines" is a 64pt constant, not a computed metric.** Three body lines plus the
  editor's insets, named in `ReviewCardLayout.minimumEditorHeight` with the clamp
  unit-tested. The sizing mirror's insets approximate the editor's — a few points off only
  moves the moment scrolling starts, never the text (`ponytail:` note in place). The old
  `PromptGateLayout.finalEditorHeight` contract and its tests were replaced, not kept
  alongside.
- **"Unit-test the three exits" is tested at its testable joints.** The continue-offer
  decision (`nil` at zero remaining — never a button to nothing) and the session effects of
  each path (⌥⏎ presents the next card unanswered; the last answer is persisted through the
  scheduler before any exit, so closing loses nothing) are unit-tested in
  `StudyMicroDrillTests`. Esc-restores-the-prior-app is AppKit
  (`NSRunningApplication.activate`) and stays verified by inspection, as in v2.
- **The card template gained a `showsAnsweredControls` flag** so the micro-drill can
  suppress the shared Next/overflow row and supply its own exits. One flag, defaulted on,
  every other surface unchanged.

## Not built, recorded (decisions 2 and 3)

- **Look Up stays in the Quick Check draft** — post-check questions are what the ask
  thread is for. No code change.
- **Empty-deck chord labels stay the design's literals** (⇧⌘G / ⇧⌘P) — staleness requires
  rebinding, which does not exist yet. Revisit if rebinding ships.

## Noticed while verifying, for the next pass

- The alternatives panel's shared footnote says "⌘⏎ **sends** as-is"; on Quick Check ⌘⏎
  *copies*. One string serving two footers — now visible in baseline 01. Cosmetic, but the
  card's one claim is that only the footer differs; wording is part of that.
