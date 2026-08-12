# Bex redesign — what shipped, and why it differs from the design doc

Companion to `Bex Redesign.dc.html` (turns 1–3). Written for the next design pass: it records
what was built, where the build deliberately departs from the mock, and which questions the
implementation could not answer on its own.

Screenshots of the built app are in `docs/redesign-v1-screenshots/`. They are captured from an
isolated fixture (six seeded corrections), not from real data.

Read `docs/purpose.md` first. Several departures below are not preferences — they are the
non-negotiables in that file, which outrank the mock by construction.

---

## The constraints that shaped every screen

Worth knowing before redesigning anything here, because they are not visible in a mock.

1. **A Quick Check has ~2 seconds** (non-negotiable 1). Anything on the correction path must
   not add a round trip. This is why the ask thread, the background agent and the writer
   profile all run off that path, and why models are now chosen per job.
2. **Nothing may block shipping** (non-negotiable 2). Any surface that appears near the send
   moment has to be ignorable. This is the single biggest reason the post-send drill behaves
   differently from the mock.
3. **Nothing leaves the Mac without explicit approval** (non-negotiable 3), and masking is
   best-effort — the limit must be *stated*, not implied.
4. **Alternatives are never ranked and never auto-applied** (non-negotiable 5). There is no
   "recommended" option and no pre-selected row anywhere.
5. **Every count must be able to reach zero** (non-negotiable 6). A number that only grows
   becomes wallpaper.
6. **Measure before designing for a signal** (non-negotiable 8). This blocked one whole feature
   below.
7. **macOS 13 deployment target.** No wrapping stack layout — several places that want a flowing
   row of chips are a vertical run instead. Worth designing around rather than against.

---

## Built, and faithful to the mock

| Ref | Surface | Screenshot |
| --- | --- | --- |
| 3c | Menu-bar hub: "1 min today", pile dots, first due card **answerable in place**, three command rows | `07-menubar-hub.png` |
| 3a | Drill takeover: no sidebar, no tabs, no counters, 28pt sentence, Esc ends | `02-drill-takeover.png` |
| 1b | One window, sidebar (Learn / Quick Check / History / Writing Styles, Settings pinned), Deck / Suggestions / Progress | `01-learn-deck.png` |
| 1c | Alternatives grouped by the phrase they were offered for | `03-learn-suggestions.png` |
| 2c | Writer profile, visible and editable | `04-learn-progress.png` |
| 2e | Models by job | `05-settings-models.png` |
| 2d | Background agent: switch, sources, standing approval, last-run receipt | `06-settings-agent.png` |
| 1e | Masked spans as labelled chips | `08-fixsend-consent.png` |
| 1d | Alternatives-first review, one-line redline, single Details disclosure | `09-fixsend-review.png` |
| 2b | Keep / "Toss — not a gap" | in `02` after answering |
| 3b | One card template across popover, deck and takeover | all three |
| 2a | Ask thread ("never blocks Send") on Fix & Send and on drill cards | `09` |

---

## Where the build departs from the mock, and why

### 1. The post-send drill does not take focus  *(1f)*
The mock reads "Return to check · Esc to skip", which implies the field already has focus.
Giving it focus means pulling the caret out of the terminal the prompt was just sent to — the
exact thing non-negotiable 2 forbids. The panel is now a non-activating HUD in the corner: it
never takes the keyboard, and the copy says so instead of promising keys that would not work.

**Design question:** a panel that cannot claim the keyboard needs a different affordance from
one that can. What should "answer this later, or never" look like?

### 2. Counts changed unit  *(1c)*
The mock shows the Suggestions tab as "· 9" with the panel reading "3 of 9". Those are two
different units, and 9 is a running total that can never reach zero (non-negotiable 6). Both now
count **decisions waiting** — one phrase is one decision, however many alternatives it was
offered. The tab and the panel agree.

### 3. Session capture is listed but off  *(2d)*
The mock has the hourly agent reading `~/.claude/projects` and `~/.codex/sessions` with toggles.
That is a new corpus, and non-negotiable 8 requires the signal to be measured in real data first
— the one corpus gate Bex has actually run (2026-08-05) was run on the learning log, not on
these. Both rows ship **visible, Off, with the reason stated**. A disabled row that explains
itself is more honest than an absent one, and much more honest than a switch that quietly widens
what leaves the Mac.

Consequence: there are no agent-*proposed* cards, so 2b's `✦ New · seen 4× this week`
provenance badge and its "The agent made this card — worth keeping?" framing have nothing to
attach to. Keep/Toss shipped on **every** card instead, which is a weaker claim than the mock's.

**Design question:** if the agent never proposes cards, is Keep/Toss still the right control, or
does the deck need a different quality gesture?

### 4. "View last payload" was dropped  *(2d)*
It would mean writing prompt text to a new file purely to service a debug affordance — new
storage of exactly the material the privacy posture is built around. The last-run receipt
("read 6 corrections · grouped 6 cards") answers the same question without keeping anything.

### 5. Takeover replaces the window rather than collapsing the sidebar  *(3a)*
Implementation detail with a design consequence: routing takeover through the split view's
column visibility made the split view lay out 1345pt tall inside a 560pt window and centre the
overflow, which silently pushed the top bar off the top edge and the progress dots off the
bottom. The drill now swaps the window's root view outright. "Takes over the window" is now
literal, and the toolbar-hiding and column-visibility juggling is gone.

### 6. The hub has a ⚙ overflow the mock does not
3c shows three rows and no settings affordance. Bex is an accessory app: its application menu
only exists while one of its windows has focus, so without this there is a reachable state with
no way to quit. The ⚙ carries Settings / Welcome / About / Quit.

### 7. Smaller ones
- **Working on** chips come from the *measured* per-100-word rates, not from model prose — there
  is already a real number, and a second unmeasured opinion beside a measurement is noise. The
  mock's `↘` trend arrow is not built (no trend is computed yet).
- **Correction** is not a row inside the Models table; it stays the existing Model picker above
  it, because it *is* the provider's selected model rather than a fourth copy of it.
- Source rows in 2d are read-only status (Read / Off) rather than toggles, since two of the three
  cannot be switched on yet.
- The hook consent keeps its existing heading ("Review outbound Prompt Gate payload") rather than
  the mock's "Send to OpenAI for check?" — only the payload rendering changed.

---

## Not built

### Quick Check was not redesigned — the largest gap
2a's actual proposition is that Quick Check and Fix & Send collapse into **one** review card
differing only in the final button. Only Fix & Send was rebuilt. `QuickCheck/` is untouched, so
today it has no ask thread, no alternatives panel, no one-line redline, no collapsed Details and
no masked-span chips. The two surfaces are now *more* divergent than before the redesign, not
less. Merging them is a refactor of two large view models with no new behaviour, which is why it
was not buried inside another change.

**This is the first thing worth designing for the next pass** — it is the surface hit with ⇧⌘G
all day.

### Technical spans are not chips in the final message  *(1d)*
The mock renders `/tmp/a.swift`, `--dry-run` and URLs as blue inline chips *inside the editable
final message*. Only the consent payload got chips (green, locked). The review's message is still
a plain text editor — visible in `09-fixsend-review.png`.

### Per-source card colour  *(3b)*
The mock colours the category label per card source (cloze blue / your pick purple / from your
ask yellow). All three sources exist now and share one template, but all render in one tint.

---

## Defects found by running it, now fixed

Recorded because they say something about the design as much as the code.

- The drill was silently losing its own top bar and progress dots at the default window size —
  the card looked perfect while "Esc ends the session" was off-screen. A takeover mode whose only
  exit affordance can vanish is a trap; the exit is now part of the window's own content.
- The card pile rendered as a rectangle the size of the pane rather than layers behind the card.
- The window opened at the full height of the display.
- ⌘/ was bound to an invisible zero-sized control. The visible hint is now the button.

## Known pre-existing defect, not fixed

The Fix & Send composer has macOS smart dashes enabled. Typing `--dry-run` produces `—dry—run`,
which then no longer matches the flag mask pattern — so a manually edited draft can carry an
unmasked flag. Captured drafts are unaffected. Worth a decision: the composer is a place where
technical text is normal, and system text substitution is actively wrong there.

---

## What the next design pass could most usefully answer

1. **Quick Check.** Same card as Fix & Send, or its own thing? It has no delivery target and no
   "Details" worth collapsing, so a literal copy may be wrong.
2. **A drill that cannot take the keyboard** (the post-send moment) — what is the right shape?
3. **Keep/Toss without agent provenance** — does the gesture still make sense on every card?
4. **Chips inside an editable field.** The consent payload is read-only, so chips were easy. The
   final message is editable; chips there need an interaction model (what happens when you type
   into one?).
5. **Empty and first-run states.** The mocks all show populated decks. A new install has no
   profile, no solid labels, no suggestions and no cards, and that is the state the app opens in
   for its first week.
