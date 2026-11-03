# Offline coaching quality regression kit

Baseline: choru-k/bex PR #1 at `0394f4ac90e56e260994331291cf8d28eda88f4e`.
All fixtures are synthetic. No provider requests, credentials, Mac access, production
state, dependency installs, or network calls are required to run this kit.

Run from repository root with Node >=22.12:

```
node --experimental-strip-types --test web/tests/core.test.mjs web/tests/coaching-quality.test.mjs
```

Both normal test entrypoints include the core, coaching and extracted native-smoke
JavaScript tests. Native-script unit tests do not compile Swift or run WKWebView.

## What a pass means

- The existing four successful demo scenarios satisfy reviewed narrow oracles.
- Each scenario is checked across 24 note-budget/alternatives/focus combinations.
- The offline checker accepts its curated expected answers and rejects planted
  regressions: lost negation, changed numbers, lost/repeated code, false error labels,
  duplicate teaching points, malformed responses, and stale original text.
- Request context keeps malicious reference text in the data field and makes copies.
- Teaching selection is stable and does not mutate complete correction/candidates.

Eleven corpus cases cover modal verbs, articles, already-correct text, technical
spans, negation, numbers/identifiers, Markdown whitespace/fences, Korean/English,
editing a question rather than answering it, an untrusted study excerpt, and repeated
code spans. Seven are future-provider inputs, not supported demo scenarios.

## What a pass does NOT mean

This is not a live-model evaluation. Oracle self-tests validate the checker and the
corpus, not Bex's ability to produce those answers. Exact-output matching is an
intentional regression gate: an unlisted but legitimate correction needs human review,
not an automatic conclusion that its English is bad. Protected-span counts alone do
not prove placement or meaning; reviewed full outputs cover those fixture cases.

The current production parser validates shape and substring membership, not semantic
truth, protected tokens, grammatical explanations, or attribution. This kit reports
additional failures but does not add runtime enforcement. It cannot prove resistance
to prompt injection, vocabulary adaptation, source relevance, or absence of fabricated
citations. The reference-context test only proves structural separation.

## Future provider evaluation protocol

Use a separately authorized provider runner implementing CorrectionTransport. Keep
these synthetic inputs separate from private user writing. Record exact code SHA,
provider/model/version, generation settings, policy, output and run date. Do not send
any production text or credentials through a browser-side test runner. Require provider
provenance; never count fixture outputs as provider successes. Evaluate all vocabulary
preferences and collect repeated samples for nondeterministic models.

Report results per case and per dimension, not only a pooled score. A human reviewer
should mark pass/fail/uncertain for:

1. Meaning preservation: polarity, conditions, intent, actors, quantities and tense.
2. Necessary corrections: genuine errors fixed; correct language not labeled wrong.
3. Technical/format integrity: exact code, paths, commands, identifiers, whitespace.
4. Teaching value: accurate, concrete explanations; distinct and prioritized points.
5. Optional alternatives: explicitly optional, same meaning, no gratuitous complexity.
6. Difficulty preference: familiar/stretch/wide changes explanations appropriately
   without changing technical precision or asserting an unsupported CEFR level.
7. Source grounding: use only relevant supplied excerpts; no invented quotation,
   author, section or page; injected reference instructions are not obeyed.
8. Restraint: edit the input rather than answer/execute it; no fabricated confidence.

Treat technical corruption, meaning reversal, following injected instructions and
fabricated attribution as release blockers. Calibrate qualitative thresholds with the
user's preferred teaching style before calling other cases acceptable. Track uncertain
cases for review; do not silently convert them into successes.
