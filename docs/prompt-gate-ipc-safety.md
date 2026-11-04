# Prompt Gate IPC safety hardening

## Scope and compatibility

This hardens the **existing** native Prompt Gate IPC path. It does not activate the
packaged web host, add a cross-app capability, change helper installation, or change
the helper protocol/runtime contract. The helper still sends URLSession POST JSON
to `http://127.0.0.1:<port>/v1/review` and `/v1/ack`, using protocol version 1 and the
rendezvous body credential. Review outcomes, single-use acknowledgment tokens, and
OMP integration ID, delivery token and `delivered` status retain their meanings.
No prompt, body, token or detailed parser error is logged or echoed in failures.

The original missing snapshot file was hydrated only after verifying its Git blob:
`Bex/PromptGate/PromptGateIPCServer.swift` =
`d0ba9983958ee9eda3a2325db2671d28f39d0c1a` against the supplied full-tree manifest.
The cloud worktree started at `90d70bcd409c332087f197ea6d7243945f33575f`.

## Fixed boundaries

- The original signed `Content-Length` parse could build a negative Data range.
  The new pure-Foundation parser accumulates ASCII decimal digits only within the
  1,048,576-byte body limit, before indexing/copying any body bytes.
- Headers are capped at 16,384 bytes including the delimiter; each delivered chunk
  is capped independently at 16,384. The parser releases buffers on failure and
  after yielding its one complete request. Exact caps remain valid.
- Missing/duplicate/invalid Content-Length, Transfer-Encoding, folded or malformed
  fields, controls, invalid request lines/authority, browser Origin, Expect, and
  bytes beyond the declared single body fail closed. Header names are ASCII HTTP
  tokens. HTTP/1.1 requires a single matching loopback Host; HTTP/1.0 remains
  supported. Incomplete EOF and error-plus-data never dispatch a request.
- `NWParameters.requiredInterfaceType = .loopback` restricts the listener interface.
  This is not a claim that its socket/address-family behavior was tested here.
- Eight finite listener delivery credits include queued accept callbacks. Credits
  are returned only after terminal connection state, outstanding reads/writes,
  request actor dispatch and close-notification callbacks all finish. Request
  bodies therefore cannot form an unbounded actor mailbox after socket drain.
- Absolute startup/read/auth-dispatch/write budgets are 5/10/5/5 seconds. Partial
  input never extends a deadline. Timed-out sends return failure, not successful
  approval or acknowledgment. An authenticated review alone may hold a connection
  for the existing review interval (at most 3,500 seconds).
- An extra one-byte receive detects disconnects during review and rejects further
  data. The unchanged URLSession helper keeps its request connection open while
  awaiting the response. A client that half-closes its send stream immediately
  after its request is not supported by this transport.

## Authentication and lifetimes

Only a full v1 JSON envelope with the nonempty current 64-byte credential may reach
review handlers. Same-length credentials are compared without early mismatch
exit. Loopback/Host/Origin checks supplement this credential; none replaces it.
This is same-user shared-secret authentication, **not** a verified helper identity.
A positive helper PID is used for the existing liveness check, not authorization.

A review is owned by a connection identity and a listener generation, not only a
caller-supplied request UUID. Startup failure retains the old owner through drain;
listener failure after ready withdraws server readiness and rendezvous publication.
Stop closes admission, clears credentials/pending state, resolves outstanding ack
continuations, and waits for transport/callback drain before allowing restart.

Application handler ownership is separate from socket ownership. New reviews are
rejected while an earlier request or invalidation callback is still in flight.
Invalidation after disconnect/timeout is sequenced after late request-handler
completion, so an old handler cannot show UI after its only invalidation. Stop also
waits for that ordering. An application handler that never returns will deliberately
keep its bounded slot and block drain/restart; no forced cancellation or successful
drain is falsely claimed. These callbacks must not recursively await `stop()`.
The current application callbacks just hop to the main actor to show/invalidate UI.

Duplicate completion cannot replace an ack continuation. Ack is claimed once
before an awaited response; request ID, ack token, and OMP delivery identity must
all match. Timeout/cancellation/failure resolves the correct continuation and
clears only its own pending identity. Helper-exit polling uses a monotonic two-second
clock and cannot clear a newer review after stop/restart. An approval response's encoded size is bounded too.

Rendezvous publication keeps the existing private directory/file permissions and
now checks chmod failures and cleans temporary files. Stop checks its own PID/token
before removing the rendezvous, with a bounded read. This is a best-effort ownership
check, not an atomic multi-process publication lock or same-user adversary defense.

## Evidence and explicit limits

Cloud executed:

- `node --test scripts/tests/prompt-gate-framing.test.mjs`: **46 passed**.
  This runs 45 synthetic framing vectors against an independent JavaScript protocol
  oracle plus one source-wiring check. It is **not execution of Swift**, transport,
  actor scheduling, Network.framework or the native application.
- `python3 scripts/check-prompt-gate-parser.py`: **NOT RUN, exit 77**, because Swift
  is not installed. The runner uses the actual Foundation parser source, the actual
  shared protocol byte limit, and the same fixture JSON. It downloads nothing and
  opens no socket. When an authorized Swift toolchain is available it checks the
  vectors and valid request splits, without compiling the app or creating a listener.

Cloud authored but **uncompiled/unrun**:

- `PromptHTTPRequestParserTests`: production parser split/UTF-8, invalid and
  overflow lengths, duplicate framing, header/authority controls, exact caps,
  EOF/error, terminal reuse, buffer release, and credential checks.
- `PromptGateHTTPTransportTests`: synthetic listener/connection/scheduler seams,
  queued accepts, actor dispatch and close callback ownership, both cancellation
  orders, absolute deadlines, stale timers, failed sends, startup failure and
  post-ready listener failure. No real Network transport is selected by these tests.
- `PromptGateIPCSyntheticServerTests`: in-memory rendezvous and synthetic transport
  through the real server actor; late handler invalidation, stop/restart barrier,
  failed startup ownership, terminal withdrawal, unauthenticated requests,
  duplicate completion and OMP identity rejection.

No Swift compile, XCTest result, macOS/device/app/helper/provider invocation,
listener/socket bind, permission/credential setup, CI execution, push or PR change
was performed. Native compile and synthetic XCTest execution remain required before
runtime confidence. Separately authorized native validation should check the actual
URLSession v1 review/ack exchange, IPv4 loopback compatibility, peer close behavior,
and no listening on non-loopback interfaces. This document does not authorize it.
