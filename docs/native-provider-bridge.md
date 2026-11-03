# Native correction transport: renderer contract

`web/src/bridge/nativeTransport.ts` implements a bounded, correlated renderer-side
adapter for a future native correction operation. It is not installed in the React
fixture lab or WKWebView development shell. The existing UI stays fixture-only.
There is no live provider, credential access, or native service wiring in this slice.

## Lifecycle

A trusted packaged app supplies a narrow `NativeEndpoint`: `postMessage(json)` and
`subscribe(listener) -> unsubscribe`. The module does not register window messages,
open sockets, read storage, fetch URLs, discover credentials or select endpoints.
Construction subscribes but sends nothing. Explicit `connect(signal)` sends a hello;
only a validated capability reply enables `check(request, signal)`. Call `close()`
on unmount/navigation or host/account replacement, and construct a fresh adapter.

Every envelope contains bridgeVersion=1, a random per-adapter sessionID, and a
random per-operation requestID. Bridge version is separate from the correction
protocol and host-hook versions. Correct responses must match both IDs and the
expected operation. Unknown or late IDs are ignored. Malformed correlated replies
fail that request with fixed error text and best-effort cancellation.

The hello response has kind=capabilities and capabilities:

```
{ "providerName": "Native provider", "perRequestConsent": true,
  "operations": ["correct", "cancel"] }
```

A correction envelope has kind=correct and the existing validated CorrectionRequest
as request. The response has kind=result and a parsed CorrectionResult as result;
provenance must be provider and original must exactly match the submitted text.
A host failure has kind=error and one of consent-denied, unavailable or
provider-failed as code. Arbitrary error descriptions are not accepted or displayed.

Cancel envelopes contain only version/session/request IDs and kind=cancel, no prompt.
Abort, timeout, close and invalid correlated replies discard local pending work;
cancellation delivery is best effort, never evidence that remote billing stopped.
At most four corrections are pending. Messages are at most 128,000 UTF-8 bytes;
the timeout defaults to 30 seconds and is bounded to 1–120,000 milliseconds.
The adapter copies validated request data before sending and preserves the full
corrected result. Learning-note budgets apply separately in the presentation layer.

## Mandatory native-host boundary before activation

The injected endpoint, capability flags and provider provenance are declarations,
not authentication or proof of actual consent. Renderer checks do not replace:

1. A packaged, immutable UI with exact main-frame/origin validation. Do not expose
   production credentials/services to Vite-hosted development content.
2. Independent native validation of envelope shape, byte/field bounds, supported
   operation, session/request correlation and concurrency. Reject generic URLs,
   commands, paths, provider/model endpoints and credentials from renderer input.
3. Actual per-request native disclosure/consent identifying the provider and text,
   including supplied study excerpts. A renderer boolean cannot grant consent.
4. Existing native credential storage, outbound destination restrictions,
   technical-span masking/restoration/validation, and provider cancellation.
5. Reviewed native provider selection and account transitions. Reconnect the adapter
   when the host/provider changes; current native consent must identify the real
   destination rather than trusting a cached renderer label.
6. Closing the channel on navigation/teardown, rejecting stale completion, retaining
   the UI RequestGate cancellation checks and keeping production defaults unchanged.

Neither parseResult nor this transport proves semantic quality, instruction safety,
source attribution, or technical-token preservation. Those require the existing
native protections and separately authorized provider evaluations. No helper lifecycle,
installed paths, permissions, signing, or native app project files change here.

## Verification scope

The normal Node launchers include native-transport.test.mjs. Tests use an in-memory
endpoint and synthetic text: handshake gating, synchronous response/reentrancy,
malformed/extra fields, consent capability rejection, session/ID isolation, stale
responses, byte bounds, deadlines, cancellation, closure, concurrency and redacted
errors. They do not contact providers, grant consent, compile Swift or run WKWebView.
TypeScript checks the implementation; the fixture app bundle does not import it.
