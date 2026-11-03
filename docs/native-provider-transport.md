# Inactive packaged-host provider transport

`NativeProviderTransport` is wired only into the unactivated
`PackagedCorrectionHost`. No composition root constructs that host. No app resource
copy/build phase, account mutation barrier, provider activation, or live-provider
test is added. Existing `URLSessionTransport`, `GrammarService`, provider clients,
and production composition remain unchanged.

## Isolation and recipient binding

The host reconstructs `ProviderClientFactory` with the original native preferences
and Keychain store references and its own transport. It never passes through the
caller's transport. The new transport takes only `OutboundDestination`; there is no
injectable session, configuration, arbitrary transport, or custom-protocol argument.
Session construction reads no credentials and starts no task.

Each transport constructs a fresh ephemeral URLSession with nil cookie storage,
credential storage and URL cache; cookie acceptance and automatic cookie handling
are disabled; cache reads are disabled. Configuration has no extra HTTP headers
and an empty custom protocol list. No global shared store is read, cleared, or
mutated. This does not establish that process-global interception is impossible.

The same immutable native destination used for consent supplies the recipient:

- OpenAI: `https://api.openai.com/v1/chat/completions`
- Claude: `https://api.anthropic.com/v1/messages`
- Gemini: `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
- Ollama: the normalized, disclosed native base URL plus `/api/chat`
- OpenAI Codex: refused, as in the existing structured adapter.

Only POST requests with in-memory bodies to that exact absolute URL are admitted.
Model discovery URLs and URL aliases, queries, fragments, user-info and other
recipients do not qualify. Gemini model names are restricted to ASCII letters,
digits, hyphen, underscore and dot, at most 200 bytes, excluding `.` and `..`.
This deliberately fails closed on unfamiliar naming formats. Ollama paths reject
dot segments, encoded separators, double encoding and control characters. Ports
must be 1 through 65535. Legitimate path/model formats outside these limits require
review before support is expanded, not a fallback to the existing transport.

Manual Cookie, Cookie2, Host and proxy-authentication headers are refused. Explicit
provider API headers remain intact. Every admitted request has cookie handling
disabled, local cache reads disabled, and its main-document context cleared.

The URLSession task delegate refuses **all redirects**, including same-origin and
307/308 redirects, by completing with nil. Response acceptance also requires the
same exact URL and rejects the entire 3xx range. Comparing response URLs alone is
not the prevention mechanism: it would be too late to prevent redirected disclosure.
The delegate leaves server-trust validation to Foundation and cancels all other
authentication challenges, including HTTP, proxy and client-certificate challenges.
No custom trust acceptance, certificate bypass, or proxy-setting change is made.

These controls bind logical URL recipients, not DNS addresses or network routes.
System trust/DNS/proxy behavior, globally registered URL protocols and macOS
URL-loading behavior still need platform verification. Native-configured HTTP
Ollama destinations remain HTTP; session isolation does not add encryption.

## Cancellation and lifetime

Task creation and resume run inside a short admission lock. `close()` permanently
revokes that admission under the same lock before invalidating the session. This
prevents creating a new task after closure has won the race. There is no reopen.

Each request has a separate cancellation slot. Cancellation before task assignment
is remembered, then applied when the task is installed. Later cancellation calls
`URLSessionTask.cancel()` at most once. Cancellation never resumes the request's
continuation: only the URLSession completion handler can finish it. Completion
clears the slot's strong task capture, breaking the temporary task/completion/slot
cycle. Provider-layer code still maps transport cancellation through
`BexError.cancellation`; this change does not claim to fix that inherited error
classification in the structured adapter.

The host closes its coordinator and transport immediately. `closeAndWait()` then
awaits the coordinator and the transport. The transport independently waits for
all admitted task completion handlers and for session invalidation. Invalidation
alone is not a task-drain proof: Apple's invalidation callback may occur immediately
after `invalidateAndCancel()`. Waiters work whether completion/invalidation occurs
before or after registration, and repeated waits do not reopen the transport.

The session delegate holds no reference to the transport, session or host. The
transport's deinitializer requests invalidation if the owner is discarded, including
failed host initialization. Dropping the owner is still not an awaited lifetime
barrier and never authorizes account/settings replacement. Remote computation or
billing may continue after local cancellation.

## Limits and activation gates

The existing account/settings mutation barrier remains unimplemented. The rebuilt
factory still references mutable stores, so revoke admission and await the host's
`closeAndWait()` **before** changing account, keys, provider, model or endpoint.
Session isolation is not immutable credential binding or request consent.

The transport has a 60-second resource timeout, but buffers response data until
URLSession completion. There is **no transport-level byte cap**. The structured
adapter's later JSON limit is not a download/memory cap. No retry loop or new
model discovery flow is introduced. Existing consent, native UI, WebKit and
packaging verification gates remain open.

## Verification status: Swift tests UNEXECUTED

`BexTests/NativeProviderTransportTests.swift` authors deterministic synthetic tests
for configuration, exact recipients, Gemini/Ollama URL syntax, forbidden headers,
POST/body rules, response checks, direct redirect/auth delegate callbacks, close
admission, concurrent close/creation ordering, cancellation before/after task
assignment, capture release, task drain and early/late/multiple invalidation waits.
It also exercises each existing supported provider client's URL construction with
an in-memory transport and fixed synthetic strings. No Keychain/factory credential
read or real provider is used. Synthetic URLSession tasks in delegate tests are
never resumed; the closed-transport test cannot admit a task.

**All newly authored Swift tests are uncompiled and unexecuted in the cloud**, which
has no Swift toolchain or macOS SDK. Policy/state tests and direct delegate calls
are not a network-stack redirect, cookie, cache, authentication, cancellation or
TLS runtime proof. A separately authorized platform validation is still required.
BexTests is application-hosted, so its normal test command may launch Bex and is
not authorized by this document. No Mac, app, credentials, signing, CI, publication
or PR metadata changes were used in preparing this candidate.

## Source and API references

Endpoint/factory compatibility was checked against `choru-k/bex` commit
`49b296eabadbc89f8bd83dad1dc4ae735715af10`, specifically
[GrammarService.swift](https://github.com/choru-k/bex/blob/49b296eabadbc89f8bd83dad1dc4ae735715af10/Bex/Grammar/GrammarService.swift),
[ProviderProtocols.swift](https://github.com/choru-k/bex/blob/49b296eabadbc89f8bd83dad1dc4ae735715af10/Bex/Grammar/ProviderProtocols.swift),
the four supported clients, and `OutboundDestination.swift`. These upstream files
are not modified. The synthetic client test detects endpoint drift only when run.

Apple documents [nil redirect refusal](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)),
[session invalidation](https://developer.apple.com/documentation/foundation/urlsession/invalidateandcancel()),
and [invalidation callback timing](https://developer.apple.com/documentation/foundation/urlsessiondelegate/urlsession(_:didbecomeinvalidwitherror:)).
Those API contracts inform this implementation; they are not evidence that the
uncompiled candidate has passed platform validation.
