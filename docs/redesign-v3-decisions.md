# Bex v3 — decisions on the v2 report's open questions

Successor to the v2 gap analysis. Decisions recorded even where nothing ships;
`docs/redesign-v3-implementation.md` records what the pass actually built.

## Decisions

1. **Armed micro-drill: one card per send, with a quiet opt-in for more.** Answering the
   armed card shows its result, then the panel closes — unless more cards are due, in which
   case the result footer adds a muted "3 more due · ⌥⏎". ⌥⏎ continues; ⏎ or Esc closes.
   Rationale: the send moment earned one card (non-negotiable 2's spirit); a session is what
   the popover and takeover are for. The opt-in keeps the answer-while-fresh moment without
   turning a receipt into a session by default.
2. **Look Up stays in the Quick Check draft; no new surface.** Post-check, "what does X
   mean" is already an ask — the thread covers it. A dedicated dictionary surface would
   re-grow the surface count v1 cut. No code change.
3. **Empty-deck chord labels stay design literals.** The screen exists only before the
   first card; staleness requires rebinding, which isn't real yet. Recorded, not built.
   Revisit if rebinding ships.
4. **Review-card editor auto-sizes to content.** Screenshots show one-line messages in a
   ~14-line fixed editor on both cards. Min 3 lines, grow with content, max ~60% of the
   panel height, then scroll. Applies to the shared `ReviewCardView` editor, so both
   surfaces get it at once.
5. **Quick Check missing alternatives panel: treat as fixture gap, verify.** The 01
   baseline shows no alternatives. Seed the screenshot fixture with a response that carries
   alternatives; if the panel still doesn't render on Quick Check, that's a real P1 bug in
   the shared-card rebuild — fix before anything else in this list.
