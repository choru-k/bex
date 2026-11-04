# Codex loopback bounds and lifetime

Source-only hardening against local baseline
`1a2e2b255c442e88176d068a561d5128f069de03` (corresponding reviewed remote baseline
`c4d3e7b8a7dc9e01fc72115749cbee9978b35174`). **UNCOMPILED / UNRUN**: this cloud
container has neither Swift nor Xcode. No sockets, app/provider requests, credentials,
Mac/device actions, application activation, CI or project metadata changes were used.

## Production integration

`CodexLoopbackListener` retains its asynchronous `start`, `waitForCallback`, and
`stop` service API. Its implementation is now one private serial DispatchQueue,
with an explicitly `@unchecked Sendable` owner, rather than an actor that creates
an unbounded Task for every Network callback. All mutable state, transport callbacks,
parsing, admission and continuation ownership run on that queue. Immutable settings
are initialized before publication. Both production and synthetic-transport initializers
require the active attempt's nonoptional `expectedState`, with no default or bypass.
`CodexOAuthService` supplies each newly generated `baseFlow.state` to its listener
factory before calling `start()`. Empty configuration fails closed before any transport
is constructed. No listener can be rebound to another attempt. Deinitialization can
only occur after the last strong owner/queue operation releases the object; it requests cancellation, not drain.

The Network adapter requires `.loopback` interface type. This is an interface
restriction, not an IPv4-only bind. The issuer redirect remains exactly
`http://localhost:1455/auth/callback`; no issuer, scope, PKCE, state, token exchange,
account mutation, or manual-paste service behavior is replaced. Loopback IPv4/IPv6
reachability and SDK/compiler compatibility still need separately authorized native
verification. Source selection is not runtime evidence of either address family.

## Bounds

- At most four delivered or credited-but-not-yet-delivered connections belong to
  one active lifetime. A finite `NWListener.newConnectionLimit` is installed before
  starting. Admission occurs directly inside the queue's new-connection callback,
  before any read; no Task is created for an incoming connection.
- A local ledger counts issued delivery credits until the corresponding callback
  arrives. A new batch is issued only after all earlier credits have been delivered,
  using four minus the number of still-owned connections. This avoids racing a
  read/modify/write with Network's independently decrementing counter. Replenishment
  is intentionally conservative; released capacity may wait for the rest of its batch.
- Each connection has at most one pending receive or one pending response send.
  A cancelled connection keeps its capacity until its `.cancelled` event AND all
  owned receive/send completions have been processed, in either order.
- Each receive requests at most 4,096 delivered bytes. The parser separately rejects
  a larger delivery before iterating or copying it. Such a malformed adapter delivery
  may already have allocated data outside this owner; no systemwide allocation bound
  is claimed.
- The retained header prefix is at most 16,384 logical bytes, including `CRLFCRLF`.
  Every byte is checked before append. Exact-limit complete headers are accepted;
  an exact-limit unterminated header is immediately rejected. The first header
  delimiter ends accumulation, so trailing body/pipeline bytes in the delivered chunk
  are neither appended nor parsed. Subsequent chunks are never requested for that
  connection. Rejected and completed header buffers are promptly cleared.
- These are bounds on application-owned logical payload/state. They do not bound
  Data allocator capacity, fixed parsing copies, TCP buffers, kernel backlog or all
  Network.framework internals. Apple documents that exhausted delivery credits queue
  and eventually block further incoming connections rather than eliminating OS queues.

Overflow of the finite delivery contract is a defensive adapter-fault path: cancel
the unadmitted object and close the owner. It is not a claim to drain a broken adapter
that delivers arbitrarily many objects outside its credits. Production and synthetic
adapters must honor the documented finite-delivery and serial event contracts.

## Parsing

Only complete headers are parsed. Receive errors never promote even a complete-looking
partial payload to a callback. EOF without a delimiter produces a fixed 400 response;
a bounded valid full header with EOF still works. Oversized requests get a fixed 431;
valid non-callback paths/methods get a fixed 404. Responses do not reflect input.

The request line must have exactly three space-separated fields and HTTP/1.0 or 1.1.
The target must be origin form with no authority override, fragment, literal backslash,
spaces or controls. Its parsed authority remains `localhost` and the configured port,
and its encoded path must be exactly `/auth/callback`. HTTP/1.1 requires a single
loopback Host header for the same port; localhost, IPv4 loopback and IPv6 loopback
forms are accepted. HTTP/1.0 can omit Host. Field names/values are syntactically
checked; nonzero Content-Length and Transfer-Encoding are rejected. No request body
or pipeline is served.

Before claiming a callback, the listener independently parses decoded query items.
There must be exactly one nonempty `state` matching the immutable expected state's
UTF-8 bytes; missing, valueless, empty or mismatched state gets a fixed 400 response.
Every duplicate decoded parameter name is also rejected, matching the service's
existing duplicate policy, including percent-encoded duplicates. Percent-encoded
names and values that decode to a unique matching state remain compatible. Rejection
closes only that connection after its response drains; it does not capture a URL,
resume the callback waiter, cancel siblings, close admission, or reset the attempt
deadline. A later valid callback can still complete the same login.

The service retains its own independent query/state/code/error validation before any
token exchange. A unique matching-state OAuth error is delivered to that unchanged
error handler without requiring a code. Manual-paste validation and retry behavior
remain unchanged. State binding prevents unrelated callbacks from consuming the login;
it is not general availability protection against local software, a leaked state,
connection saturation or the already bounded attempt timeout. The fixed outbound token
endpoint and registered redirect URI are unchanged.

## Terminal ownership

Success claims a single state-matching callback URL and closes admission before any
send or waiter resumption. Its HTTP 200 only acknowledges callback receipt and asks the
user to finish sign-in in Bex; it does not claim successful authorization, token exchange
or committed storage.
It cancels the listening socket and sibling connections, and tracks the
winning response until its send completion requests cancellation. A captured callback
can still be read after the expected listener-cancelled event, unless explicit stop
or task cancellation has terminated the owner. There is no restart/reaccept path.

Startup failure, unexpected listener failure/cancellation, timeout, explicit stop and
start/wait cancellation close admission, cancel every owned connection and resume each
pending start/callback continuation at most once. A duplicate waiter is rejected rather
than replacing the existing continuation. Stop before start creates no Network listener.

`await stop()` means the listener's cancelled event has been processed and every
owned connection has reached its cancelled state with no outstanding owned I/O
operation. Multiple stop waiters share that same frontier. It does not mean a final
callback's stack has already unwound, all Dispatch blocks have been destroyed, browser
rendering succeeded, or bytes already sent have been retracted. Service code already
awaits this barrier before replacement or committing a completed login.

An attempt deadline starts at startup or an earlier wait, bounded to one nanosecond
through five minutes. Headers have a ten-second absolute deadline and response sends
have a five-second deadline. These deadlines request cancellation; they never declare
an unacknowledged connection drained. Missing terminal/I/O callbacks intentionally
keep stop pending. All timers are cancelled on phase/terminal transitions. A stale
queued timer handler holds the owner weakly and checks a phase token before acting.

All transport handlers capture the owner weakly. Pending receive/send handlers retain
only the individual transport for their nil-owner cancellation fallback. A late
accepted object after owner deallocation is cancelled immediately. Dropping the owner
requests cleanup but cannot substitute for the explicit asynchronous stop barrier.

## Authored synthetic coverage

`CodexLoopbackListenerTests` contains 24 socket-free methods covering delimiter split
positions, exact/overflow header bounds, oversized delivered chunks, malformed URL
and HTTP syntax, loopback Host forms, finite queued accepts, conservative credit return,
listener/connection/I/O drain ordering, simultaneous stop waiters, success with pending
siblings/accepts/sends, EOF/errors, header/send/attempt deadlines, stale timer tokens,
duplicate/cancelled waits, stop before start, pre-cancelled start, late-ready events,
listener failure and owner deallocation/weak-handler fallback. Five state-admission
methods cover invalid/missing/empty/duplicate/encoded state and duplicate other keys,
retained waiter and drain ownership, unextended attempt deadline, a valid subsequent
callback, encoded valid state, matching-state OAuth errors, stale previous-attempt
state with another pending connection, and empty configuration before transport creation.
Fakes explicitly hold terminal events and I/O completions so cancellation is never used as an acknowledgement.
Test registration helpers have a bounded yield observation and throw on failure rather
than continuing into a pending operation after a failed registration assertion. Their
scheduling assumptions, including those bounded observation helpers, remain unverified.

`CodexAccountLifecycleTests` contains 33 methods, including three new methods for
factory/start ordering with each generated state, independent service validation even
when a synthetic listener bypasses admission, and unchanged OAuth-error/manual-retry
handling. The two existing stop/pre-cancelled-wait tests still exercise the actual
listener without calling start. The state-binding change was authored against local
baseline `14a7f47ffc44dccc7e71de6a00e363189324e596`. All new tests and changed Swift
remain **UNCOMPILED / UNRUN**. Diff checks, static inspection and any unrelated Node
checks are not Swift compilation, XCTest execution or Network runtime proof. Normal
application-hosted tests can launch the application, so these notes do not authorize
running that workflow or any socket tests.

## Primary API evidence (read-only documentation)

- [Listener delivery limits](https://developer.apple.com/documentation/network/nwlistener/newconnectionlimit)
  decrement per delivered connection and allow queued/blocked incoming connections at zero.
- [Receiving a new connection](https://developer.apple.com/documentation/network/nwlistener/newconnectionhandler)
  requires configuring/starting an accepted connection, or cancelling one to reject it.
- [Listener queue](https://developer.apple.com/documentation/network/nwlistener) and
  [connection queue](https://developer.apple.com/documentation/network/nwconnection/start%28queue%3A%29)
  documentation place their events on the selected queue.
- [Required interface type](https://developer.apple.com/documentation/network/nwparameters/requiredinterfacetype)
  applies to connections and listeners;
  [loopback interface](https://developer.apple.com/documentation/network/nw_interface_type_loopback)
  identifies local loopback networks.
- [Receive completion](https://developer.apple.com/documentation/network/nw_connection_receive_completion_t)
  can include data with an error and delivers errors to outstanding receives on cancellation.
- [Send completion](https://developer.apple.com/documentation/network/nwconnection/sendcompletion/contentprocessed%28_%3A%29)
  describes stack processing, not browser receipt.
- [Listener cancelled](https://developer.apple.com/documentation/network/nwlistener/state-swift.enum/cancelled)
  and [connection cancelled](https://developer.apple.com/documentation/network/nwconnection/state-swift.enum/cancelled)
  describe terminal cancellation states. The adapter treats listener cancellation as
  its final event and does not assume any ordering between connection cancellation and
  pending I/O completions. Native verification of the selected SDK's delivery ordering
  remains required; a newer NetworkListener API's wording is not substituted as proof
  about the existing NWListener implementation.
