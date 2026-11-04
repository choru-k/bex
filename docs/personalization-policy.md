# Personalization: curated behavior and capability-gated native policy

## Controls implemented

The browser correction screen exposes three general vocabulary preferences, necessary-error
correction with or without separate optional expressions, and Korean/English explanation
language. The complete correction remains minimal in every mode. A broader vocabulary
preference is not permission to rewrite natural text, translate quotations, simplify technical
terms, or infer a CEFR score. Optional expressions remain separate notes, never automatically
applied to corrected text. Existing note budget and learning focus still apply.

The fixture transport now has curated vocabulary alternatives and Korean/English explanations
for its existing samples. These controls visibly change those samples, but they are not a
live model, general rewriting system, language assessment, or evidence of real-provider
quality. Unrecognized free text still receives the existing honest fixture refusal.

Changing settings cancels an in-flight correction and clears its old result. Settings remain
session-only unless the existing explicit remember-settings checkbox is enabled. Reset uses
the actual transport's supported language choices. Native mode does not load browser-stored
preferences. Source excerpts remain separate untrusted data and do not select these settings.

## Protocol compatibility

The request and bridge protocol versions remain 1. `LearningPolicy` and native `BridgeRequest.Policy`
accept either the exact legacy four fields, or those four plus `explanationLanguage: "ko" | "en"`.
Absent language means **provider default**, not an implicit Korean or English request.
Explicit null, unknown language, wrong type and unknown policy fields are rejected. The old
four-field `DEFAULT_POLICY` and legacy wire fixtures remain unchanged.

New native host capabilities additionally advertise `explanationLanguages: ["ko", "en"]`.
The new renderer accepts an absent language capability, or a nonempty unique subset of the
two known languages. It rejects unknown values, duplicates, wrong types and unknown capability
keys. Returned capability arrays are copies, so UI mutation cannot change admitted capabilities.

- **New renderer + legacy host:** displays disabled “provider default” language selection,
  creates the original four-field request, and does not claim a language was selected. An
  explicit unsupported language passed programmatically is rejected before dispatch; it is
  never silently stripped at the transport boundary.
- **New host + legacy request:** accepts the old four-field policy with language absent.
- **New renderer + new host:** shows only advertised choices, carries the selected language
  in the explicit correction request, and still requires native per-request consent.
- **Older strict renderer + new host capabilities:** may reject the added capability field.
  This is fail-closed, not seamless bidirectional version compatibility. Host and renderer
  must be deployed as a reviewed matching package before activation; no released integration
  has been migrated or enabled by this work.

Local capability-aware initialization can select a supported default for the current screen;
it does not alter stored preferences or silently upgrade a legacy host's semantics.

## Native handling

The native decoder independently validates the optional field. The structured provider passes
it as data in the policy and receives fixed prompt instructions for the requested reason
language. The native consent sheet discloses vocabulary, focus, note budget, minimal correction,
optional-expression scope, and selected explanation language (or provider-default absence).
No preference bypasses technical-token protection, result validation, credential isolation,
account/session admission, cancellation ownership, or consent.

The language choice is a provider instruction, not a deterministic language classifier. This
slice does not prove that every real model honors it; semantic compliance requires real-provider
evaluation before activation. It never rejects a correct technical English quotation merely
because the explanation was requested in Korean.

## Verification and limits

Portable tests check 144 curated combinations (4 successful samples × 3 vocabulary choices ×
2 restraint choices × 2 languages × 3 note budgets), plus vocabulary differentiation, strict
policy parsing, safe persistence, prompt separation and source-level native parity. Each
combination verifies the reviewed correction, exact protected spans, selected explanation
strings, optional-expression isolation and visible note budget.

Transport tests cover both legacy and explicit-language requests, unsupported-language refusal
before dispatch, malformed capability arrays and copied capability state. Shared Swift/JS wire
vectors retain old cases and add Korean/English cases. XCTest source adds native legacy/invalid
policy coverage, provider prompt/payload checks and consent disclosure assertions.

React/StrictMode JSDOM tests exercise the actual App controls, pending cancellation, storage/reset,
legacy and new native handshakes, one-language capability and explicit dispatch. Browser
acceptance specs are provided but remain **unrun** under the existing browser restrictions.
Swift/AppKit changes are **uncompiled and unrun** in this cloud environment: no Swift compiler,
Xcode or Mac was used. Source-inspection assertions are not a substitute for those gates.

```sh
node --experimental-strip-types --test web/tests/personalization-quality.test.mjs web/tests/native-transport.test.mjs
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node web/tests/personalization.node.cjs
npm --prefix web run typecheck
npm --prefix web run build
```

The optional React harness uses the same external TypeScript/jsdom test-only environment as
existing lifecycle tests. No app dependency, live provider call, installation, GitHub CI run,
production composition activation or device action is introduced.
