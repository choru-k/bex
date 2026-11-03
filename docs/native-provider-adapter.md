# Structured native provider adapter (unactivated)

`Bex/Grammar/NativeStructuredCorrectionProvider.swift` implements the existing
`NativeCorrectionProviderService` using `ProviderClientFactory.makeClient` and
`LLMProviderClient.generate`. Xcode links the local `native` package into Bex and
BexTests. No composition root constructs the adapter, no consent UI or WKWebView
handler is installed, and the fixture lab remains offline.

Construction stores an immutable destination/model/effort and a factory closure.
It does not read credentials. `correct()` is for the native coordinator only after
its request-specific consent succeeds. Prompt validation/masking and cancellation
checks run before client creation. The test seam supplies the real production
`LLMProviderClient` protocol, not a parallel provider abstraction.

## Mandatory account lifetime gate, not implemented here

The factory captures mutable credential stores, not an immutable account. For API
key providers it snapshots the current key only when invoked. Before installation,
the host must prevent account/provider/settings mutation until it has revoked
admission and awaited `coordinator.closeAndWait()`. All mutation paths must obey
that barrier, including sign-out. The consent UI must identify the actual immutable
`OutboundDestination.disclosureTarget` (including any external Ollama endpoint),
model, exact input and full study source. A frozen label is not account binding.

OpenAI Codex is rejected before factory invocation in this adapter. Its existing
client resolves/refreshes a mutable Keychain session during generation, so this
slice does not assert a bounded immutable-account contract for it. Supporting it
requires a separately reviewed session/account binding design.

## Request and result contract

- Existing `PromptTechnicalSpanProtector` masks input and each source field with
  separate random sentinels. Raw technical spans are not placed in the generated
  request. Source content remains optional untrusted study data, not instructions.
- All policy fields and source title/section/excerpt are serialized in JSON, under
  fixed coaching instructions. The corrected text is always complete; maxNotes
  limits notes only. No alternatives are accepted when disabled. Focus/vocabulary
  guide coaching, not claims of proficiency or guarantees of semantic behavior.
- Provider response contains exactly corrected and notes. Native code restores the
  complete corrected text with the existing sentinel count/order validator and
  supplies exact original/provenance itself.
- Notes never undergo partial sentinel restoration. Sentinel-bearing notes, notes
  intersecting even part of a sentinel, and ambiguous repeated before/correction-
  after quotations reject the entire response. No notes are invented or dropped.
  Alternatives may propose text absent from the corrected text, per wire contract.
- `NativeCorrectionBridge.validateResultJSON` reuses the existing strict result
  decoder and literal UTF-16 correspondence checks. No second security parser is
  introduced. Both bridge completion and adapter use this same validation.
- Payload/result JSON is capped at 128,000 UTF-8 bytes; existing field bounds still
  apply. Invalid/oversized responses fail closed. Errors are redacted at the adapter
  boundary, preserving CancellationError. No persistence, logging, model discovery,
  OAuth sign-in, retry, credential access during construction, or network tests.

Sentinel preservation is not a semantic proof. Prompt injection resistance, teaching
quality, source attribution, and new unmasked technical content are not established
by these structural checks. Existing provider implementations may buffer responses
before returning strings; this adapter's cap is not a transport-level download cap.

## Verification status

Synthetic BexTests cover real adapter/protector/protocol types: inert construction,
Codex fail-closed, masking all source fields, complete policy propagation, exact
Unicode restoration, note budgets, alternative rejection, missing/duplicate/reordered
or foreign sentinels, ambiguous/invalid note spans, schema and size rejection,
cancellation before/after factory, and redacted errors. They use fake clients only.

These tests and the Xcode package linkage are **not compiled or run in this cloud
executor**, which has no Swift toolchain/macOS SDK. Earlier native-core test results
do not validate this change. BexTests is an application-hosted XCTest target; running
it can launch Bex and requires separate authorization. Prefer a reviewed non-running
build-for-testing first. No Mac, app, UI, live provider, credentials, CI, push or PR
metadata was accessed or changed while preparing this patch.
