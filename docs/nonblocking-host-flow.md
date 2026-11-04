# Nonblocking cross-app learning: executable cloud-first slice

## What works now

The browser lab mounts `HostFlowLab` below the correction workspace. Choose a simulated
ChatGPT, Claude, or other-app target, send a sample original, continue writing, and see a
separate feedback card arrive. The transcript retains the exact original. Free text still
sends to the simulated transcript even when the fixture cannot coach it.

A separate **Review before sending** action produces an unsent preview. Only **Fix & Send ·
confirm simulated send** can commit the corrected text. Closing the review, changing the
text, changing apps/conversations, or changing learning settings invalidates approval.
Review failures do not send the original as a fallback.

This is an executable simulation, not an installed host integration. It reads no app,
intercepts no keystroke, writes no other app, and calls no provider. The `HostFlow`
constructor rejects a native transport, and `App` mounts this surface only with its fixture
transport. Existing native provider consent, account/session fencing, packaged-host
capability checks, helper installation, and release defaults are unchanged.

The study-library panel is separately integrated into the existing correction workspace.
An explicitly selected section updates the prepared correction request and cancels stale
feedback. Study excerpts are not included in the host-flow simulation. Existing fixtures
are fixed examples, not personalized model output.

## User-visible behavior

| Path | Original conversation | Learning/review result | Failure behavior |
| --- | --- | --- | --- |
| Normal send with learning | Original host owns and completes its normal send | Independently attributed feedback after confirmed submission | Drop/skip/timestamp-out feedback; never suppress, replace, or resend the original |
| Explicit review | No send yet; host retains the draft | Preview for the captured exact target and revision | Keep draft; no automatic send |
| Explicit Fix & Send | One conditional host commit | Confirmation is consumed before host invocation | A known rejection stays unsent; an uncertain outcome cannot be retried automatically |

The teaching preferences are captured for each submitted message. Future settings do not
retroactively re-label an old card. Feedback cards retain their originating app, conversation,
and message identity even if another app is now active. Coaching and explicit review have
separate cancellation and timeout state.

## Versioned host event contract

`web/src/host/hostFlow.ts` defines the independent `HOST_EVENT_VERSION = 1`. This is neither
the existing hook wire protocol nor the native provider bridge's protocol version.

A `SentObservation` contains exactly:

- `version: 1` and `type: 'user-message-sent'`.
- Opaque bounded `sessionId`, `appId`, `conversationId`, and `messageId` identifiers.
- The exact original `text`, 1–12,000 UTF-16 code units, without trimming or normalizing.

The observation is emitted **after** a host confirms its original user-message submission.
No timeout callback or disabled coach may decide whether that submission happens. The
observation path has no host send/replace capability. It cannot send instructions, URLs,
credentials, shell commands, or an arbitrary operation name to the host.

Parsing is strict and bounded, but parsing does not authenticate the sender. A future native
adapter must validate origin/frame, capability, host identity, account/session generation,
user opt-in and allowed target before delivering any event. Renderers cannot assert a
trusted host identity simply by choosing these fields. Do not repurpose the provider bridge
as a generic cross-app command bridge.

The simulated inbox holds at most 20 items with four outstanding coaching requests and one
outstanding explicit review per HostFlow instance. Excess coaching is marked skipped and
new reviews are unavailable rather than queued indefinitely. Visible requests time out
after eight seconds and late completions are ignored. A timeout, eviction, or cancellation
requests abort but retains its capacity until the transport promise actually settles, even
when a transport ignores AbortSignal. Coaching and review use independent capacity.
Disposal requests cancellation and clears visible session state; it is not a transport-drain
guarantee. Bounds are per instance, not across remounts or a native app lifetime. Real native
wiring must retain its existing admission/full-drain owner rather than use this simulator
as a native resource-lifetime guarantee. Duplicate observations are suppressed within the
retained inbox. This is not a durable exactly-once event log: a production host must bound
its own replay window, and callbacks must never replay the original send in any case.

## Explicit review contract

`ReviewHost.snapshot()` provides a host-owned `DraftSnapshot`: session/app/conversation,
monotonic revision, and exact text. A preview is bound to that snapshot and a unique review
operation identifier. Model output can change neither target nor operation identifier.

`confirmFixAndSend(host, shownReviewId)` consumes that precise preview before invoking
`ReviewHost.compareAndSend(expectedSnapshot, correctedText, operationId)`. The host must
perform an atomic conditional commit against its current snapshot. A renderer-side
preflight is insufficient: the target may change between inspection and the commit.

`compareAndSend` returns:

- `sent`: the host confirmed this specific operation committed.
- `not-sent`: the host guarantees that operation did not commit.
- `unknown`: the outcome cannot be established. A thrown commit or malformed acknowledgement
  is also unknown, and neither original nor corrected text is automatically retried.

Snapshot validation failure before an attempt is a known rejection, not an uncertain send.
Unknown delivery stays locked even if a review is cancelled or its settings change. This
simulator has no reconciliation UI or durable receipt storage. Real integration must retain
and reconcile an uncertain operation across reconnect/reload before allowing a retry.

Do not implement the atomic operation as “replace whichever textbox has focus, then press
Enter.” If a host cannot provide a stable target, revision comparison, and reliable send
result, offer explicit copy/manual use instead of enabling Fix & Send. Keep existing native
protected-token and semantic validation before showing a real provider result; the portable
shape validator alone is not proof that a correction preserves code or meaning.

## Actual implementation and verification

- `web/src/host/hostFlow.ts`: strict event parsing, bounded independent coaching, review
  coordinator, and memory-only compare-and-send adapter.
- `web/src/host/HostFlowLab.tsx` + `hostFlow.css`: working simulated transcript, independent
  inbox, review/confirm/cancel actions, and explicit simulation labels.
- `web/src/App.tsx`: fixture-only mounting, reset, and study-library request integration.
- `web/tests/host-flow.test.mjs`: portable contract and race tests, no dependency installation.
- `web/tests/host-flow.node.cjs`: real React/StrictMode lifecycle and parent integration checks
  in JSDOM using the existing cloud harness. These are not browser or device checks.
- `web/tests/host-flow.spec.ts`: browser acceptance for original-send separation, failure,
  explicit send, cancellation, editing, app switching, session reset, privacy and mobile fit.

Commands from repository root:

```sh
node --experimental-strip-types --test web/tests/host-flow.test.mjs
npm --prefix web run typecheck
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node web/tests/host-flow.node.cjs
npm --prefix web run test:e2e -- host-flow.spec.ts study-materials.spec.ts
```

The JSDOM command needs the existing optional harness's TypeScript and jsdom packages.
The normal browser test command needs the project Playwright browser runtimes. In this
cloud executor those bundled Chromium/WebKit executables were absent. An installed Chromium
launch was also rejected by the sandbox (`socket() failed: Operation not permitted`), so the
browser run was stopped and not retried/escalated. No browser rendering, layout, accessibility
or macOS/WKWebView result is claimed from the JSDOM tests.

## Remaining activation gates

1. A verified app-specific observation mechanism for ChatGPT, Claude and each supported app.
   No DOM scraping, Accessibility capture, Electron/native hook or browser extension is wired here.
2. Explicit per-target learning opt-in and sensitive-field exclusions. Observe only confirmed
   user messages, not password fields, surrounding private conversations, drafts or assistant text.
3. Independent native provider admission and consent for post-send coaching. Simulation does
   not authorize uploading message contents or study excerpts; no native transport is auto-used.
4. Host-owned session/revision identity, atomic compare-and-send or a copy-only fallback,
   idempotent delivery receipts and uncertain-outcome reconciliation across reconnections.
5. Real signed-host installation, permission checks, app-version compatibility, packaged-resource
   audit, macOS compile, WKWebView rendering, and interrupted multi-app device validation.
6. Browser visual/accessibility verification and real-provider coaching-quality evaluation.

A successful cloud test is evidence for portable logic only. It is not evidence that any
external conversation was captured, corrected, sent, or left untouched by a real hook.
