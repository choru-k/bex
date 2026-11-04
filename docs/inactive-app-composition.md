# Inactive packaged correction app composition

**Native status: UNCOMPILED / UNRUN. No native activation is enabled.**

The app now owns the concrete packaged-correction lifecycle instead of leaving
`PackagedCorrectionHost` wholly unowned. This is source integration, not a completed
native feature, a security approval, or authorization to run the application.

## Ownership and activation boundary

`AppServices` creates exactly one `PackagedCorrectionWindowOwner` from its existing
preferences and Keychain stores. That initialization only retains a session factory:
it performs no settings or credential reads, creates no window or WebKit instance,
starts no task, and creates no provider transport. Existing launch behavior is not
rerouted to the new feature.

`PackagedCorrectionNativeWindowSession` is the normally compiled implementation
behind the owner. Its explicit open path creates a hidden window, constructs the
existing host, then attaches and presents that host's view after successful admission.
It has no caller-supplied URL, bundle, destination or renderer factory. The existing
host owns resource validation, settings snapshot/account epoch validation, isolated
provider transport, native consent, trusted-frame checks, revocation and full drain.
The window wrapper does not duplicate or bypass any of those decisions.

The sole `WindowCoordinator.showPackagedCorrection()` hook is inside literal
`#if false`. There is no action in a menu, shortcut, URL route, environment switch,
preference or compiler condition that reaches it. The separate
[resource build phase](native-build-input-integration.md) is disabled by default,
is unrun, and cannot open this host. No packaged assets, signing step or installation
action is added. The offline resource packager is unchanged and still refuses
application destinations. Enabling a future
entry requires a separately reviewed source change after all native security,
resource-copy/provenance, UI and runtime gates have been validated and authorized.

## Exact lifecycle

- Repeated opens during construction coalesce into one request. A repeated open of
  a valid presented session focuses that same window rather than creating a host.
- Close revokes synchronously and cancels the separate preparation task. The owner
  still waits for preparation to return, even when it ignores cancellation, and
  then waits for the session's complete host drain before releasing it.
- A reopen during close retains only the newest explicit intent. No replacement
  window, host or provider session is created before the old drain returns. Closing
  again cancels that pending reopen. A stale close notification cannot cancel a
  newer request or close its replacement.
- A construction error or already-closed session drains and stops without an
  automatic retry. A later explicit open may try again. A successfully returned
  candidate is also rejected and drained if closure/cancellation occurred while
  its construction was suspended.
- Account mutation may revoke a host without closing its visible window. The owner
  consults the host's read-only `isClosed` state and never focuses/reuses that host
  on the next explicit open. Mutation itself never opens a new host. If a new open
  races an active mutation, the host's existing admission check can fail closed;
  the user must explicitly reopen afterward rather than an automatic retry loop.
- A synchronous close callback during presentation still enters the same full
  drain. Cancelling a caller waiting for close cannot cancel the owned cleanup task.
- If an idle open owner's app reference is dropped, its retained session is closed
  and drained by a cleanup task. In-progress preparation/drain retains its owner
  until that operation actually finishes. Neither owner release nor cancellation
  asserts that remote work or billing has stopped.

`AppDelegate.applicationShouldTerminate` first permanently shuts admission and
revokes the owner synchronously. With a dormant owner, it returns `.terminateNow`
without creating a task. With outstanding work, one retained task joins complete
shutdown and only then replies to AppKit. Repeated termination requests do not
start duplicate waiters. A non-cooperative drain can intentionally block quitting;
there is no timeout or cancelled-waiter shortcut. The previous
`applicationWillTerminate` cleanup is unchanged. If external termination is later
cancelled, this owner stays shut down; cancellation never resurrects its hosts.

This guarantee covers these registered packaged hosts only, not existing legacy
`GrammarService` tasks, external processes or bytes already sent upstream.

## Evidence and remaining verification

Cloud Node source-regression checks inspect dormant ownership, disabled activation,
concrete host delegation, drain-before-replacement ordering and the termination
hook. Run with the existing Node runtime, without installing anything:

```sh
node --test scripts/tests/bex-native-composition-source.test.mjs \
  web/tests/packaged-endpoint.test.mjs
```

`PackagedCorrectionWindowOwnerTests` contains thirteen synthetic XCTest cases against
the actual app-owned controller, using continuation-controlled session dependencies.
They cover dormant construction/shutdown, repeated open, close/reopen while preparing,
full-drain replacement, stale callbacks, cancelling a pending reopen, shutdown during
construction, cancellation of close waiters, failed preparation, real cooperative
account-barrier revocation with a fresh epoch, already-closed construction, synchronous
presentation callbacks, a close scheduled as presentation finishes, shutdown before
preparation starts and cleanup after owner release. They do not create a real
window, WebKit, provider, credential store or socket.

Those Swift sources have **not been compiled or run** in cloud. Source regex checks
are not typechecking, actor-isolation/concurrency proof, lifecycle execution, native
sheet/window testing or security validation. The app-hosted test target could launch
Bex when run, so native tests remain paused pending explicit authorization. No Mac,
device, socket, live provider, credential, app launch, CI, build/sign/install or
sandbox-bypass operation was performed for this integration.
