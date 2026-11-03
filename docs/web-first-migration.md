# Bex web-first migration: executable first slice

## Goal and scope

Make everyday UI/learning changes testable without rebuilding or reinstalling host hooks.
Keep the working native integration code while moving frequently changing UI and policy
into a browser-testable module. This first PR adds an isolated lab, not a production switch.

## Present boundary

```text
React UI -> core request/policy/presentation -> CorrectionTransport
                                                  |
                                         FixtureTransport only

optional WKWebView development shell (no privileges, no production services)
```

A change to `web/src` does not change BexHook sources, the installed helper path, Codex or
Claude configuration, the Xcode project, or the existing release workflow. This property
of the new lab does **not** fix the existing production helper upgrade mechanism yet.

## Next implementation slices

1. **Complete the verification baseline.** Install dependencies, create a reviewed
   lockfile, pass full typecheck/build and both Playwright projects. Run the isolated
   WKWebView shell on a Mac. Measure the edit/run loop rather than assume it is faster.
2. **Native provider adapter.** Connect one opt-in native correction operation to the
   web request/result contract. Keep credentials and provider networking native.
   Preserve existing outbound consent, masking, technical-token validation and cancellation.
   Render UI with the same modules; do not silently make the prototype production-default.
3. **Stable observation adapter.** Remove language/teaching decisions from the hook
   helper. Keep a versioned event contract and backwards-compatible core. Distinguish
   signed-helper integrity from whether an app upgrade requires replacing it. Add a
   nonblocking learning mode; keep explicit Fix & Send review a separate workflow.
   Real helper/permission changes still require the host's legitimate approval.
4. **Learning material ingestion.** Start with user-provided attributed excerpts.
   Only then add file import, extraction, retrieval and source-grounded suggestions.
5. **Distribution.** Add an app update channel and signed delivery after deciding the
   native shell packaging. No update changes are shipped in this first PR.

## Bridge contract for the next slice

`CorrectionRequest` / `CorrectionResult` in `web/src/core/model.ts` version the **web
correction operation**, not the existing host-hook protocol. Do not reuse host-helper
version numbers as if they were the same protocol.

The adapter must add request IDs, strict origin/main-frame validation, request size
bounds, cancellation, a capability handshake and response correlation. Native code must
validate input independently of renderer validation. Do not accept arbitrary shell
commands, URLs, model endpoints, filesystem paths or tokens from the renderer. Do not
add the provider bridge to the Vite-hosted dev shell with production credentials.

`buildCoachContext` keeps study text separate from system instructions, but this alone
is not an LLM prompt-injection security boundary. Reference material is untrusted.
`parseResult` validates shape and grounding of short feedback phrases; it does not prove
semantic correctness or preservation of every technical token. Preserve the native
mask/restore checks and add a real-corpus eval when enabling actual provider results.

## Acceptance criteria before replacing a production screen

- Complete web build/typecheck and browser E2E are green with a committed lockfile.
- The native shell compiles and renders on the supported macOS baseline.
- Same origin, new-window navigation and native message validation fail safely.
- No raw key, OAuth token, hook-management or general filesystem capability reaches JS.
- Model calls need explicit disclosed consent; imported text is never auto-uploaded.
- Cancellation/new edits cannot display an old response under a new draft.
- Feedback budget does not remove necessary edits from the full corrected output.
- Existing Bex history, preferences, credentials and host configurations remain unchanged.
- A UI/policy-only release does not require replacing the host helper.
- Accessibility keyboard navigation, paste and copy work in both browser and WKWebView.

## Review/run handoff

```sh
node scripts/bex-web.mjs test
node scripts/bex-web.mjs check
node scripts/bex-web.mjs e2e
node scripts/bex-web.mjs desktop
```

No automatic merge, release, production data migration or integration reinstallation is
part of this work. Record actual platform/version and passed checks before promotion.

## Renderer transport follow-up

The opt-in renderer-side native transport and its tested message contract are now
implemented; see [native-provider-bridge.md](native-provider-bridge.md). It is not
installed in the fixture lab or native development shell. Native service wiring,
independent native validation and actual disclosed provider consent remain required
before activation. No live provider connection is claimed.
