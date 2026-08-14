# Bex — why this app exists

Audience: the owner, and any LLM working on this repo. Not a user guide (that is `README.md`).
This document says what Bex is *for*, so that decisions can be checked against it.

## The purpose, in one sentence

Bex exists so that one Korean-speaking engineer can **speak English without broken grammar, using
expressions he can deploy immediately**. Every feature is instrumentation for that; nothing in the
app is justified on its own.

## Who it is for

**One owner.** Not a product with users, a team, or a market. This is load-bearing, not modesty:

- "The owner decided X" is a complete and final justification. It outranks general best practice.
- No feature is justified by "users might want it". There are no users to want it.
- No onboarding funnels, growth surfaces, analytics, or accounts. MIT-licensed so anyone *may* use
  it; that is permission, not a design constraint.
- The single-owner assumption is why level-tuning, the writer profile, and the study deck can be
  personal and unhedged — they are built from one person's own mistakes, and only have to be right
  for him.

## The real target: speaking, not writing

The aim is spoken English. Bex only ever sees the owner's *writing*, so the scope is drawn honestly:

- **In scope:** building **repertoire** ("what to say") and **noticing**, from writing that already
  happens anyway. Both transfer to speech.
- **Out of scope:** real-time fluency ("how to say it fast"). That needs spoken production. No
  speaking practice, no pronunciation, no conversation simulation.
- **The last mile is the owner's** and he accepts it: receptively-acquired repertoire needs some
  self-produced use before it becomes available in speech. Bex cannot do that part.
- **The premise check:** at the 6-week review, one self-report — *did any expression you saw here
  show up when you actually spoke?* If the answer is always no, the whole thesis is failing,
  regardless of what the grammar numbers say.

## Two goals, different in kind

They are not two features of the same thing; their difference dictates how Bex behaves.

| | **Fix Broken English** | **Better Expression** |
| --- | --- | --- |
| Nature | binary — right or wrong | a spectrum — many valid |
| What Bex does | corrects everything silently; explains only what the owner plausibly **did not know** | always offers 2–3 alternatives and how they differ; **never ranks them** |
| Level | level-independent | tuned so suggestions are usable *now*, not impressive |
| Measured? | yes — recurring categories, rate per 100 words | no metric; only the chosen-alternative signal and the speaking self-report |
| Where it lands | inline, at the correction moment | deferred — reviewed later, never at the shipping moment |

The distinction that took longest to reach, and matters most: **correcting and teaching are separate
jobs, and teaching is the higher priority.** A typo is a finger slip by someone who already knows the
word; drilling it teaches nothing. So `corrected` fixes everything, while the taught list carries
only genuine knowledge gaps — judged by the model from the owner's evident level, not by a fixed rule.

## The insight the whole app is built on

The owner's rawest, highest-volume self-produced English is **the natural language he types at
Claude Code and Codex terminals** — explaining, correcting, and instructing an AI all day. Not
Slack, not documents. That is why:

- the correction moment was placed *there* (Fix & Send, `⇧⌘P`, and the hook integrations), rather
  than in a separate writing app;
- that same stream is the learning corpus — approved corrections are appended to a local learning
  log, which everything downstream reads.

This was an assumption until it was checked. **Gate passed 2026-08-05** on the real log (70 entries
over 10 days): the corpus was rich rather than terse (median ~11 words, only 5 bare commands), and
errors recurred strongly (7 categories at ≥3×). Consequence: capturing Slack and desktop AI apps was
**downgraded** — its entire rationale had been the thin-corpus risk, and that risk did not
materialize.

## One correction surface

**Fix & Send is the only correction workflow.** It accepts a focused-app or integration target and
also opens as a manual standalone composer. The correction and review are the same in either case;
the validated target determines whether approval sends, pastes, or copies the result. Writing Style
adds the active tone, audience, and house-style context without creating another workflow, and Look
Up remains available from the standalone composer.

Standalone draft retention and correction history are separate, optional choices. History may retain
successful standalone and target-bound corrections, but reopening an original always starts a new
standalone Fix & Send review. Neither retention choice changes the append-only learning corpus.

## The loop

    write a prompt → correct it fully → teach only the gaps → always offer unranked alternatives
    → the owner picks one → gaps and picks become drill cards → push them at him → he drills

Two arrows carry hard-won lessons:

- **"push them at him"** reverses the original design. The first version was exposure-only: a
  read-only Learning window in the menu bar. He did not open it, so it taught nothing. A passive
  surface that nobody opens equals zero learning — **the tool has to come to him and create
  friction he must clear** (badge, daily notification, and the status bar he actually looks at).
- **"the owner picks one"** exists because unranked alternatives have no right answer by
  construction — which is the point. His pick supplies the answer, turning a choice into a card, and
  gives a direct signal of adoption instead of inferring it.

## Non-negotiables

If a change violates one of these, it is wrong even if it is otherwise better. Stop and ask.

1. **Interactive latency is sacred.** A Fix & Send correction must answer in roughly two seconds.
   Anything expensive — pattern classification, level profiling — runs in the background, off that
   path, and never adds tokens to the correction request. Background work may cost anything.
2. **Never gate the owner's shipping flow.** The inline moment adds no confirmation beyond the gate
   he already accepts. Blocking his real work is the fastest way to get the tool turned off.
3. **Nothing leaves the Mac without explicit approval.** The original text is never sent — only the
   masked payload, shown for approval first. Technical spans are masked and verified before
   delivery. Credentials live in Keychain; prompt text stays in owner-only local files. Masking is
   best-effort and that limit is stated plainly rather than hidden.
4. **Correct everything; teach only what he did not know.** Volume of feedback is not the goal.
5. **Never rank expression alternatives, and never auto-apply one.** Bex describes differences and
   asks *which fits?*. The choice is his — that is what makes him think.
6. **Pressure must be clearable.** Any badge or count must be able to reach zero, and must escalate
   on lateness, not volume. An unclearable signal reads as hopeless and becomes wallpaper.
7. **Never touch another tool's files without a reviewed diff.** Host integrations show exact paths,
   modes, hashes, and signer, and change nothing before an explicit Apply. Prefer fail-closed; where
   a host can fail open, say so instead of implying a guarantee.
8. **Check the signal exists in real data before designing for it.** Two features were killed by
   this rule after measurement (mastery-inferred-from-reuse; ranking-based uptake). Measure the log
   first, on at least two replicates.

## What Bex is deliberately not

- Not a prose polisher or essay tool. Not a translator.
- No speaking, listening, or pronunciation practice.
- No SM-2/FSRS, streaks, XP, or gamification — plain Leitner boxes are enough.
- No multi-user, team, or per-goal configuration infrastructure.
- No cloud sync, no server, no telemetry, no analytics, no crash reporting.
- No metric on expression beyond the pick signal and the speaking self-report. Some things are
  accepted as unmeasurable rather than faked with a number.
- No automatic enforcement of its own kill criteria. Bex *shows* numbers; deciding what they mean
  stays human.

## How we would know it is working

- **The premise:** the 6-week speaking self-report (above). This one outranks the rest.
- **Grammar:** a ≥20% relative drop over 6 weeks in the top two recurring categories, measured as
  rate per 100 words, with median sentence length as an avoidance guard so "improvement" cannot be
  achieved by writing shorter, simpler sentences.
- **Engagement:** the due count reaches zero regularly. If it never does, the deck is too heavy or
  the drill is too costly.
- **Card quality:** cards are knowledge gaps, not typos or punctuation. A deck of junk cards is
  worse than a thin one.
- **Corpus:** already checked and passed; re-check it if capture sources change.

Thresholds calibrated on the pre-v7 corpus need re-baselining before they are read as signal.

## Where the deeper reasoning lives

- `README.md` — what Bex does, and the privacy posture as stated to a user: what is sent, what is
  stored where, what masking does not cover.
- **The commit log is a decision log.** Subjects are written in the owner's voice about intent
  ("Explain only what I didn't know, and always offer a choice", "Count the decisions waiting, not
  the prompts I sent"), so `git log` reads as a history of *why*, not *what*.
- `.claude/rules/releases.md` — every release needs human-readable notes; a generated changelog link
  is not sufficient.
- Code comments carry the rationale for specific choices, including deliberate simplifications and
  their upgrade paths. Where a comment says a decision was the owner's, treat it as binding.

## Using this document

For an LLM working here: read the non-negotiables before proposing anything, prefer the smallest
change that works, and treat the YAGNI list as binding rather than advisory. When this document and
the code disagree, the code is what ships — say so, and ask which one should change.
