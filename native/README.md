# Isolated native correction bridge core

This Foundation-only SwiftPM package implements the native-side wire validation and
request state machine for `web/src/bridge/nativeTransport.ts`. It is not linked into
the Bex app, the WKWebView development shell, or the Vite fixture lab. It has no
credentials, networking, provider calls, OS hooks, project-file edits, or dependencies.

## Test

On an explicitly authorized machine with Swift 5.9 or newer:

```sh
swift test --package-path native
```

The XCTest suite also reads `tests/fixtures/native-bridge-v1.json`, shared with the
renderer tests. Run from a full repository checkout so that this file is present.
Swift was unavailable in the implementation cloud container; these tests have not
been compiled or run there. Node tests of the same fixtures are not Swift evidence.
Exact base commit `4fc57ce` was later verified in a separately authorized isolated
macOS checkout: 12 XCTest methods, Swift 6 library build and development-shell
typechecking passed, without running the app/UI or any provider. The subsequent
coordinator below is new code and is not covered by that base-commit evidence.

## Host contract before any activation

All methods and injected `emit`/`dispatch` callbacks run on the main actor. The host
must verify the immutable packaged main frame and exact allowed origin before calling
`receive`. No origin, consent boolean, URL, endpoint, key, command, or path from the
renderer can establish authorization. Never feed Vite content into this boundary.

Create one instance per document/provider/account lifetime. Provider name is supplied
by trusted native configuration and cannot change. A first valid hello binds a single
session; subsequent hellos never switch it. Close on navigation, teardown, or account
change, then discard the instance. There is no reopen operation.

The host receives these events:

1. `consentRequired(job, request, providerName:)`: Show an actual native disclosure of
   the exact user text, any supplied reference excerpt, and actual provider/destination.
   Schedule a host-owned deadline for the job. Call `resolveConsent(job, granted:)`
   only from the native UI outcome. A capability flag is not consent.
2. `correctionAuthorized(job, request)`: Invoke a separately reviewed native adapter
   implementing the complete learning policy/source contract and technical-span
   masking/restoration/validation. Return bounded provider JSON through `complete` or
   a fixed failure through `fail`. This core does not pretend existing GrammarService
   operations implement the new contract and does not invoke them.
3. `cancellationRequested(job)`: Dismiss matching consent UI and cancel actual provider
   work. Call `acknowledgeCancellation` only when the operation has really terminated.
   Completion/failure from an already-cancelled provider also releases its slot without
   emitting a stale result. Cancellation is not evidence that remote billing stopped.

Call `expire(job)` from a native deadline (recommended 30 seconds) even if the renderer
never sends cancel. The core intentionally owns no timers/tasks and does not perform
consent or provider cancellation itself. Cancelled jobs continue counting toward the
four-job limit until native acknowledgement. This avoids unlimited cancel/retry work.
A noncooperative adapter can occupy all four slots; it cannot cause unbounded admission.
Do not acknowledge cancellation merely because a cancellation request was sent.

State is updated before callbacks, allowing synchronous completions and teardown.
Only host-generated jobs with private nonces can complete the matching operation;
renderer IDs alone cannot grant consent or finish work. Hold callbacks weakly where
needed so embedding closures do not keep a closed bridge alive.

## Validation and bounds

Messages are limited to 128,000 UTF-8 bytes before decoding and after encoding. Input
requires exact keys, version 1, UUID-shaped IDs, supported operations, and independent
nested policy/source validation. Field lengths use UTF-16 units to match JavaScript.
Original-text equality uses UTF-16 code units, not Swift canonical equivalence; note
substrings use literal matching. Request text and excerpts are never trimmed.

Only provider-provenance results are accepted, with original equality, 24,000-unit
corrected text, at most 20 bounded notes, exact before/after checks, and fixed errors.
Result/note extra fields are rejected, deliberately stricter than renderer parseResult.
Schema validation is not proof of semantic correctness or technical-token preservation.
Foundation JSON decoding supplies parser behavior; this is not a new JSON parser.

At most four jobs are retained. All admitted/overloaded request IDs are consumed to
prevent replay. At 4,096 total request IDs per session including hello, the next unseen correction
closes the bridge fail-safe; a trusted host must create a fresh document/channel rather
than allowing renderer hello messages to reset replay accounting. Invalid input and
unknown or late IDs are dropped without reflecting untrusted text.

## Async execution coordinator (still isolated, not activated)

`NativeCorrectionCoordinator` now consumes those core events and actually owns the
consent/provider Tasks, two independent native deadlines (30 seconds each by default),
cancellation and terminal cleanup. Inject a `NativeCorrectionConsentService` and a
`NativeCorrectionProviderService`; there are deliberately no concrete UI, network,
credentials, existing GrammarService calls or production app bindings in this package.
The full validated `BridgeRequest`, including all policy/source fields, is passed
unchanged to both services. Provider JSON is still validated by the core.

The trusted host must authenticate the packaged main frame before forwarding to
`receiveTrustedDocumentMessage`. The method name is not authentication. Consent must
be a real native disclosure and user decision. The provider service must bind its
account/destination immutably for its lifetime, matching the trusted displayed name;
separate class instances or a constant display name do not prove that an implementation
cannot change its own destination. There is no rebinding API on this coordinator.

On navigation, account switch or teardown, call `close()` immediately to revoke
admission/delivery, dismiss/cancel work, and release idle service and emitter references.
Use `await closeAndWait()` before constructing a replacement coordinator. It waits for
all owned async operations to return, even when they ignore cancellation. This is the
required host barrier against accumulating old work across document/account changes.
A service that never terminates deliberately blocks replacement; a deadline revokes
permission to deliver but cannot forcibly terminate an arbitrary service or prove that
remote billing stopped. Dropping the coordinator also requests task cancellation, but
is not proof of quiescence and is not a replacement for the explicit lifecycle barrier.

The service contract requires cancellation-aware dismissal/cancellation and forbids
returning before its own child work has stopped. The coordinator never acknowledges
cancellation just because `Task.cancel()` was sent. All four slots remain occupied by
noncooperative services until their async calls actually return. Native timers are
cooperative `Task.sleep` work, cancelled on every phase transition and terminal path.
Host timeout configuration is bounded to 1 ns through 5 minutes; the internal manual
scheduler seam is only for deterministic tests and is not part of the public API.

The coordinator tests use synthetic continuation-controlled services that intentionally
ignore cancellation, with manual deadlines and task-completion barriers. They cover
full request forwarding, independent phase deadlines, late results/grants, errors,
capacity retention, cancel-before-start, teardown, replay/session rejection and timer
cleanup. Cloud inspection/diff checks are not compilation or XCTest evidence. No Mac,
provider or production-app execution was performed for this coordinator slice.
