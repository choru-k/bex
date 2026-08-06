# Bex — Learning Mode Plan (v7)

> **v7 — expression is promoted to the main event (owner decision, 2026-08-06):**
>
> Triggered by a concrete failure. The owner typed *"What is your plan for fixing this issue?"* and
> Bex answered `No changes needed.` — correct (the sentence is fine) and useless. The owner wanted
> to know how it differs from *"What is your plan to fix this issue?"*, and Bex had **no channel to
> say "this is right, and here is what the alternative implies."** It could only change the text or
> stay silent, and nuance is neither.
>
> - **Consider is now ALWAYS present**, reversing v6's "silence is the default." Rationale, in the
>   owner's words: *"consider가 항상 보여야 돼. 그래야 내가 고민을 하지."* The point is not to receive
>   a verdict — it is to be handed a choice worth thinking about.
> - **Consider offers 2-3 candidates and must NOT rank them.** The prompt describes how each
>   alternative differs in meaning, tone, or register, then closes with a `Which fits?` line naming
>   the question the owner should be asking. Bex never names a winner; the owner decides. This is
>   a genuine behavior change, not a volume knob: the old Consider was a *recommendation* engine
>   ("shorter or plainer, never longer or more formal"), the new one is a *comparison* engine.
> - **`Fixed:` now lists only what the owner did not KNOW — not every error.** This is the v7
>   change that matters most, and it is a new *criterion*, not a filter on the old one. Owner:
>   *"중요한건 사소한게 아니라, 내가 모르는 단어, 표현 이런것들이야. 예를 들어 whta 이라고 내가
>   쓴다고, 그건 오타이지 내가 모르는게 아니잖아... 점점 나의 수준을 ai 가 판단해서 아 오타구나라고
>   인지를 해야지."* A typo is a finger slip by someone who knows the word; drilling it teaches
>   nothing. **The model is asked to judge slip-vs-gap from the writer's evident level**, using the
>   whole text as evidence (a word used correctly once was not "unknown" where it was mistyped).
>   A plausible-sounding misspelling of a word never written correctly is still a real gap and is
>   still listed.
> - **`[article]` and `[plural]` are excluded on top of that**, by preference rather than by the
>   knowledge-gap test — Korean has no articles, so they *are* a genuine gap, but the owner does
>   not want lines spent on them: *"관사나 복수형 같은 사소한 실수는 보여주지 않아도 돼. 그냥
>   고치기만 하면 되고."* The word-level diff already shows them.
> - **This trades away measured signal, knowingly** — see "v7 costs" below. v6 tuned these exact
>   rules *down* after a 25-case eval showed noise polluting the Learning counts. v7 accepts more
>   noise in exchange for the expression layer actually being useful. If it turns out to be wrong,
>   the fix is to re-tighten Consider, not to re-silence it.

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
| Tool behavior | correct it silently; explain only what was not known *(v7)* | always offer 2–3 unranked alternatives + how they differ *(v7)*; owner chooses |
| Level | level-independent | level-tuned (only immediately usable) |
| Tracked / measured? | yes (recurring types, rate) — v7 narrows the corpus to knowledge gaps | no metric; the one uptake tripwire is weakened by v7 (see costs) |
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

- **✅ Fixed (broken English):** *(v7)* only the corrections the owner **plausibly did not know**,
  each tagged with a canonical grammar category + a short *why*. Everything else — typos, slips,
  articles, plurals — is corrected in `corrected` but **never listed**; the word-level diff is the
  change log, this section is the study material. Reviewed **inline** through the Prompt-Gate step
  the owner already uses and accepts (the re-read that "doesn't break flow").
- **💡 Consider (better expression):** *(v7)* **always present**, 2–3 level-appropriate alternatives
  for the one phrase whose wording is most open + how each differs in meaning/tone/register, closed
  by a `Which fits?` line. **Deliberately unranked** — Bex never names a winner. **Never blocks a
  send.** It is surfaced for real engagement in the **deferred study session**, not at the shipping
  moment.

**Non-blocking guarantee:** the inline moment never adds a confirm step beyond the existing gate;
the expression layer in particular is passive and dismissable. Gating the owner's core workflow
(shipping a prompt) is the fastest way to get the tool disabled.

## v7.1 — the three alignment decisions (2026-08-06, SHIPPED)

v7 changed what Bex *says*. Reviewing it surfaced that the rest of the pipeline had not moved with
it, and three decisions followed. All three are built, plus the badge fix they unblocked:

| Decision | Landed as |
| --- | --- |
| 1. Tap to choose an alternative | `Bex/Learning/ConsiderTapStore.swift`, `LearningAggregator.parseSuggestionLine`, `LearningLogSamples.merged`, the button in `LearningView.suggestionRow` |
| 2. Background level profile | `Bex/Learning/WriterLevelProfile.swift`, `GrammarService.refreshWriterLevel`, `GrammarPrompts.withWriterLevel`, `AppDelegate.refreshWriterLevelIfNeeded` |
| 3. Prompt Gate keeps always-on `Consider` | no change — `editingRules` stays shared, as intended |
| (unblocked) Badge counts untapped alternatives | `LearningBadge.status(samples:tappedIDs:lastViewedAt:)` |

Deleted rather than kept: `LearningMetrics.uptake`, `UptakeDetail`, `suggestedPhrase`, and their
tests. The reappearance proxy has a replacement now, and leaving a broken metric in place that still
renders a number would be worse than having no number.

### 1. `Consider` gets a per-alternative "I'd use this" tap → it becomes the deck's real source

**The misalignment this fixes.** `StudyCardBuilder` reads `Fixed:` lines only
(`Bex/Study/StudyCard.swift:92`), so the deck drills **grammar errors exclusively**. But the owner's
v7 statement of what matters is *"내가 모르는 단어, 표현"* — and expressions live only in
`Consider:`, which never becomes a card. Vocabulary reaches the deck only through a manual **Save to
Study** on a Look Up. So the deck was drilling the owner's own lowest priority.

One affordance fixes two separate holes, which is why it wins over either fix alone:

- **A card needs a right answer.** Three unranked alternatives have none by construction — that is
  the whole point of v7's Consider. The tap supplies it: the alternative the owner chose *is* the
  answer, so the existing cloze machinery works unchanged.
- **`uptake` needs ground truth.** `LearningMetrics.uptake` currently *infers* adoption by watching
  for the phrase to reappear in later writing — a proxy that v7 broke (see costs, below). A tap is
  a direct signal and does not care how the suggestion was phrased.

Note this reverses the v6.1 rule that expression alternatives are *"never auto-applied"* only in
part: tapping records a choice and creates a card, it still must **not** rewrite `corrected`.

### 2. The level judgment gets a background profile (implements the "점점")

v7's prompt asks the model to judge slip-vs-gap from *"the writer's evident level"* — but it sees
**one text at a time**, so it can only use evidence inside that text. The owner's word was **점점**
(*gradually*), which means accumulation the current prompt structurally cannot do. A word learned
last month is still treated as new.

Build it where `StudyPattern` classification already runs: a **background job over the learning
log** producing a compact profile ("already reliable on X; still misses Y"), injected into the
system prompt as pre-computed text. **The latency constraint is absolute and decides the design** —
owner: *"the quick check latency is most important; if something is running in the background, we
can do anything and we don't care about latency."* So the correction request itself never does the
analysis and never pays for it; it only carries a summary computed earlier, exactly like
`GrammarService.classifyStudyPatterns`.

### 3. Prompt Gate keeps always-on `Consider` too — one shared prompt, deliberately

Considered splitting `editingRules` so the ⌘⇧P send path stayed lean. **Rejected.** The terminal
prompts are the main corpus (see "Corpus reality"), so suppressing Consider there would starve the
expression layer of most of its material to protect a flow the owner is not complaining about.
`system` and `promptSafeSystem` stay unsplit, as their doc comment intends.

## v7 costs (accepted knowingly — none of these are bugs)

v7 buys usefulness with measurability. Recording what it spends, so nobody "fixes" these later
without knowing they were chosen:

1. **The goal-2 uptake tripwire is largely spent.** `LearningMetrics.uptake` counts every `Consider`
   line as a suggestion and asks whether the phrase later reappears in the owner's own writing.
   That test assumed suggestions were *recommendations*. v7's are *unranked alternatives* — when
   three are offered, at most one can be adopted, and often none should be. The denominator inflates
   and the adoption rate collapses **for reasons unrelated to whether the layer works**, so
   "near-zero uptake ⇒ feel-good input" no longer follows. **RESOLVED by v7.1 decision 1** — the
   tap replaces the reappearance proxy with a direct signal. Until it ships, treat the uptake number
   in the Learning window as meaningless rather than alarming.
2. **The Learning badge would have fired on nearly every check — FIXED with v7.1.** It counted
   whole entries, and v7 puts a `Consider` section on nearly all of them, so it degraded into a
   count of prompts sent. It now counts distinct *untapped* alternatives, so it measures a real
   backlog and can reach zero. Same lesson v0.6's daily plan already learned: an unclearable
   pressure signal reads as hopeless rather than motivating.
   **Still carried:** the activation *volume* gate (`substantiveCount >= 20`) accepts an entry
   carrying only a suggestion, which before v7 was a meaningful distinction and now means it is
   close to "≥20 prompts sent". Deliberately left alone — the recurrence gate is the load-bearing
   half, and retuning a threshold baselined on the pre-v7 corpus belongs to the re-baselining pass
   in item 3, not to a badge fix.
3. **The Study deck gets thinner and harder.** `StudyCardBuilder` builds only from `Fixed:` lines.
   Dropping typos, articles, and plurals removes what is plausibly most of the current card volume.
   That is the intent — those cards taught nothing — but the deck may be near-empty for a while, and
   the v6 recurrence gate (≥2 categories recurring ≥3× across ≥20 corrections) was calibrated on the
   *old*, noisier corpus. **Re-baseline it before reading it as a signal.**
4. **Slip-vs-gap is a model judgment with no ground truth.** There is no way to verify Bex called a
   typo correctly, it will vary by provider, and small local Ollama models will likely do it badly.
   Accepted: the alternative (a rule the owner writes by hand) cannot track their level, which was
   the whole point of asking the model to judge.

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

> **Superseded by v7.** Both bullets above describe the shipped v6 prompt and are kept for
> history. Live behavior: `Fixed:` lists only knowledge gaps and emits neither `[article]` nor
> `[plural]`, so the prompt's tag list is now a deliberate **subset** of `GrammarCategory`. The enum
> keeps all cases regardless — `LearningAggregator` and `StudyCardBuilder` still parse logs written
> before v7, and `.vocabulary` is written directly by `DictionaryLookup`, never by this prompt.
> Deleting a case would break old data, not just new output. `Consider:` is always present.

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
