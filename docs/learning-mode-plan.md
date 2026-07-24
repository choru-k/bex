# Bex — Learning Mode Plan (v6.2)

> **v6.2 — Phase 1 corpus-source correction + v1 scope:**
> - **Phase 1 aggregates the LEARNING LOG, not `HistoryViewModel.entries`.** v6.1 moved the primary
>   (terminal) corpus into the separate learning log; the Phase-1 text below still said "history."
>   Corrected: the recurring-grammar aggregation reads the learning log JSONL (and may fold in Quick
>   Check history later, since both now carry the tagged two-section `explanation`). `LearningLogStore`
>   gains a read API; the store is shared via `AppServices` so the Prompt Gate (writer) and the
>   Learning window (reader) use one instance.
> - **Phase 1 v1 = a read-only "Learning" window only.** It shows recurring grammar-tag counts and
>   recent "Consider" suggestions, self-guarding to an empty state until data accrues. This window
>   *is the by-hand gate instrument*: open it after a week and see whether recurrence actually
>   exists. **Deferred to the post-gate build:** the always-on menu-bar badge, the rate-per-100-words
>   metric + complexity floor + 6-week kill-timebox, and automated goal-2 uptake detection. Building
>   the read-only view now is harmless (empty until real data) and avoids building the adherence
>   machinery on faith.

> **v6.1 — owner decisions before implementation:**
> - **Learning log (closes a hole all five reviewers missed):** Prompt Gate corrections — the
>   primary corpus — were never persisted anywhere (only QuickCheck writes history;
>   `QuickCheckViewModel.swift:700` is the sole real construction site, and the README excludes
>   Prompt Gate reviews from history *by design*). Owner decided: persist them to a **separate
>   append-only local learning log** (`~/Library/Application Support/Bex/LearningLog/`, `0600`
>   like receipts), NOT into history/`data.json`. The week-1 gate eyeballs this log; Phase 1 reads
>   it. Privacy trade-off (prompt text on local disk) accepted knowingly.
> - **Explanations in simple English** (immersion; the explanation itself is reading practice).
> - **`corrected` carries grammar fixes only.** Expression alternatives live in the `Consider`
>   text — never auto-applied.
> - Commits go directly to `main`, stepwise, unit tests green before each.

> **v6 changes** after review round on v5 (SLA + product APPROVED; engineer + UX + skeptic
> NEEDS-CHANGES):
> - **Phase 0 is genuinely 0-code again (engineer).** The gate's instrumentation is done by
>   *manual eyeballing* of outputs for one week, not an automated logger. Automated logging is
>   deferred to Phase 1 if ever needed.
> - **Inline is non-blocking; expression lives in the deferred session (UX).** Grammar fixes use the
>   existing Prompt-Gate review the owner already accepts; the "Consider" expression layer never
>   blocks a send and is reviewed later.
> - **The deferred session has a trigger (UX):** the menu-bar badge surfaces it once unreviewed
>   items accrue. The one-tap difficulty reaction moves *into* that session; passive inference is
>   the primary level signal.
> - **Goal 2 gets its one falsifiability check (skeptic + product):** detect whether a
>   previously-suggested expression later reappears in the owner's own writing (uptake). Near-zero
>   uptake = the layer isn't working.
> - **The speaking target gets a check (skeptic):** a one-line owner self-report at the 6-week
>   review — did any captured expression surface in real conversation?
> - **Thresholds reconciled (product):** one condition gates both Phase-1 build and badge
>   activation.
> - **Expression suggestions biased to conversational register (SLA)**, since the corpus skews
>   monologic/imperative (AI-command English).

## The two goals (different in kind → the tool behaves differently)

1. **Fix Broken English** — grammar/spelling errors that mark non-native speech (tense, articles,
   prepositions, agreement, word order, plurals, capitalization, typos). **Binary**, therefore
   **trackable and measurable**.
2. **Better Expression** — naturalness/idiomatic upgrades on already-correct English. A
   **spectrum**, therefore **exposure-based, not tracked**, and **tuned to the owner's level** so
   suggestions are usable *now*, not impressive.

| | Fix Broken English | Better Expression |
| --- | --- | --- |
| Nature | binary right/wrong | spectrum, many valid |
| Tool behavior | correct it + short why | offer alternative + why; owner chooses |
| Level | level-independent | level-tuned (only immediately usable) |
| Tracked / measured? | yes (recurring types, rate) | no metric; one uptake tripwire only |
| Where reviewed | inline (existing gate) | deferred study session |

## The real target behind both: speaking, not writing

The owner's aim is **speaking English without broken grammar, using expressions he can deploy
immediately** — not polished prose. Bex only sees his *writing*, so it is scoped honestly:

- **In scope:** build his **repertoire** and **noticing** from captured writing — "what to say,"
  which transfers to speech.
- **Out of scope:** real-time fluency ("how to say it fast"). Needs spoken production; the owner
  deferred it. **No speaking practice, no active-recall drills.**
- **Last mile:** actually using the expressions when he talks is the owner's, and he accepts it.
  Note (SLA): receptively-acquired repertoire generally needs at least *some* self-produced use to
  become productively available — so the last mile is real, not optional polish.
- **The one check that the target is reached:** at the 6-week review, a single owner self-report —
  *did any expression you saw here show up when you actually spoke?* If never, the whole premise is
  failing regardless of the grammar metrics.

## Corpus reality (code-verified)

- **Auto-captured:** **Claude Code** and **Codex** terminals — both route through the single
  Prompt-Gate path → `promptSafeSystem` (`GrammarService.swift:109`; Codex shares the same
  client-agnostic path, verified). The owner's natural-language *conversation to get the AI to work*
  is his rawest self-produced English, at volume, roughly **conversational register**.
- **Not captured:** Claude desktop app, Codex app, claude.ai (web), Cursor/IDE AI — need
  Accessibility capture, deferred. A real chunk of his rawest English is unseen.
- **Slack:** short, manual paste → `system` (`GrammarService.swift:81`); no integration exists.
  Opportunistic, sparse.
- **Honest caveat:** instructing an AI ≠ social conversation. Register overlaps heavily; pragmatics
  differ. Good proxy, not perfect. **Whether the chat is actually "rich" (multi-sentence
  explanatory English) vs terse commands is verified by eyeballing week-1 output — it is an
  assumption until then, not a fact.**

## Delivery — two sections, two moments

Every correction's `explanation` carries two labeled sections:

- **✅ Fixed (broken English):** all grammar/spelling corrections + a short *why*, each tagged with
  a canonical grammar category. Reviewed **inline** through the Prompt-Gate step the owner already
  uses and accepts (the re-read that "doesn't break flow"). Trivial fixes listed minimally.
- **💡 Consider (better expression):** 0–N level-appropriate natural alternatives + *why*, **omitted
  entirely when nothing is genuinely better** (silence is default). **Never blocks a send.** It is
  surfaced for real engagement in the **deferred study session**, not at the shipping moment.

**Non-blocking guarantee:** the inline moment never adds a confirm step beyond the existing gate;
the expression layer in particular is passive and dismissable. Gating the owner's core workflow
(shipping a prompt) is the fastest way to get the tool disabled.

## Deferred study session (the home of expression + calibration)

- **Trigger:** the **menu-bar badge** ("N to review") surfaces it once unreviewed "Consider" items
  (or recurring-grammar data) accrue. On-demand via the badge — no scheduled nag.
- **What it holds:** the accumulated "Consider" suggestions to browse, and (if earned) the passive
  grammar-mistakes view. This is where intermittent, off-flow attention actually lands.
- **The one-tap difficulty reaction ("too hard" / "good") lives HERE**, in-context during review —
  not in-flow, where he'd never tap it.

## Level calibration (goal 2 only)

- **Suggestion constraint (in the prompt):** "Suggest a better expression only if it is one notch
  above the user's phrasing, **common, conversational, and spoken-friendly**, and immediately usable
  at his level. No literary/fancy/advanced upgrades, and prefer interactional phrasing over
  AI-command register." (The register clause counters the monologic/imperative corpus skew.)
- **Primary signal = passive inference** from his writing over time. The one-tap reaction (in the
  deferred session) is a *secondary* tuner, not relied upon.

## Phased plan

### Phase 0 — Prompt-only (today; prompt strings only; genuinely 0 code)

In `Bex/Grammar/GrammarPrompts.swift`, rewrite **both** prompt constants (`system` for manual/Slack
paste; `promptSafeSystem` for Claude Code/Codex) to output the two sections:

- **Fixed:** correct all grammar/spelling; prefix each with a canonical grammar category from a
  fixed list (`[article]`, `[verb-tense]`, `[subject-verb-agreement]`, `[preposition]`,
  `[word-order]`, `[plural]`, `[spelling]`, `[capitalization]`, `[other]`). Canonical from day one.
- **Consider:** apply the level + conversational constraint; omit when nothing is genuinely better.

No schema/parser/UI change. Downstream is safe (verified): `WordDiff`/diff read only
`original`/`corrected`; history search is substring `contains`; `explanation` renders as plain text;
`parseObject` reads only `{corrected, explanation}` (`GrammarResponseParser.swift:50-67`).

### Gate — one week, by hand (earn the goal-1 tracking; verify the corpus)

No logger to build — **read the week's outputs by eye** and check, pre-registered:

- **Corpus richness:** are the captured prompts actually multi-sentence explanatory English, or
  terse commands? If terse, the whole corpus premise is weak → rethink before building anything.
- **Recurrence:** do ≥2 grammar categories each recur ≥3× across ≥20 reviewed corrections?
  ("Reviewed" is inherent — each passes through the gate the owner approves.)
- **Proceed to Phase 1 tracking** iff both hold. **Skip the tracking view** if errors are one-off —
  keep correction + why + expression suggestions; already valuable. Expression layer needs no gate.

### Phase 1 — Goal-1 passive tracking + goal-2 uptake check (only if earned)

Grammar tracking is **passive awareness, not drills**.

- **Lazy version — no schema change:** regex the canonical `[tag]` prefixes out of existing
  `explanation` text across `HistoryViewModel.entries` (`:23`). Key any per-error record by the
  stable `HistoryEntry.id` UUID (`Models.swift:100`), never by `explanation` text (`updateHistory`
  rewrites it: `BexDataStore.swift:117`).
- **Grammar surface:** the menu-bar badge → a 60-second view that **shows** recurring grammar
  mistakes ("preposition: 8 → 3 per 100 words") + the rule. It displays; it never quizzes. **One
  threshold:** the same condition that passed the gate (≥20 reviewed, ≥2 categories ≥3×) activates
  the badge — no separate dormancy gap. Never show an empty view.
- **Goal-2 uptake tripwire (the one expression check):** reuse the regex approach to detect whether
  a phrase previously offered under "Consider" later **reappears in his own captured writing**. Near
  the 6-week mark, near-zero uptake ⇒ the expression layer is feel-good input, not learning →
  retune the constraint or accept it as a permanent cost (decided explicitly, below).
- **Grammar metric:** error **rate per 100 words** per category (not absolute count). Avoidance
  guard = **median sentence length** floor (cheap, no parser). **Kill** if the top-2 categories show
  no **≥20% relative drop over 6 weeks** from badge activation. **Expression has no metric** — only
  the uptake tripwire + the speaking self-report.
- **Promote to structured storage only if regex is outgrown:** `issues:[Issue]?` on `GrammarResult`
  and `categories:[String]?` on `HistoryEntry` — **optional, defaulted inits** or construction sites
  break (`GrammarResponseParser.swift:61`, `GrammarService.swift:112`, `QuickCheckViewModel.swift:570`);
  extend `parseObject` (ignores unknown keys, old data safe); **do NOT bump `schemaVersion`**
  (`BexDataStore.swift:180-183`) or old builds go read-only.

## What NOT to build (YAGNI)

- Active recall / quizzing / drills; speaking-practice features (out of scope).
- Any *metric* on expression — only the single uptake tripwire.
- Automated Phase-0 instrumentation (eyeball for a week instead).
- Multi-user infrastructure — only a goal×level knob, assumed to live in Profiles (**verify Profiles
  can carry per-goal state before relying on it**).
- Structured storage before regex is proven insufficient; free-text categories; streaks; SM-2.
- Real Slack / desktop-app / web capture until the terminal corpus proves the loop.

## Open risks (ranked; carried)

1. **Corpus recurrence & richness.** If errors don't repeat by type, or prompts are terse commands,
   the whole thing is thin. The week-1 by-hand gate is the tripwire.
2. **Capture gap.** Desktop/web AI apps + Slack unseen; terminal-only may under-sample.
3. **Register mismatch.** AI-command English ≠ human conversation; mitigated by the conversational
   suggestion constraint, but watch it.
4. **Expression = feel-good input.** No hard kill-switch; the uptake tripwire + speaking self-report
   are its only evidence. Accepted as a bounded permanent cost unless uptake is near zero.
5. **Speaking transfer.** Repertoire/noticing transfer; fluency does not without spoken production.
   The 6-week self-report is the honest check; if it's always "no," the premise is wrong.

## Build order

1. **Phase 0** — rewrite **both** prompt constants into Fixed + Consider. Ship today. (0 code.)
2. **One week** of real use → by-hand gate (corpus richness + recurrence).
3. **Phase 1** (if earned) — regex-`[tag]` grammar aggregation + badge + passive mistakes view +
   goal-2 uptake detection + rate metric. No drills.
4. **Promote to structured storage** only if regex is outgrown.
