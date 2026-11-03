# Independent Accessibility agent: dormant source implementation

## Status and boundaries

This change adds actual read-only Accessibility service, client, capture registry and asynchronous manual-Copy adapter source, plus a separately built `BexAccessibility.app` host. It is **not a completed production migration**: `AppServices`, `WindowCoordinator`, the synchronous `PromptTargetServicing` implementation and prompt-gate production composition remain unchanged. The current safe manual path continues to work. No runtime selector or fallback silently switches to the new agent.

The helper is not embedded in Bex.app, is not a dependency of Bex's build target and has no automatic installer/updater. The new standalone scheme builds only the independent host. Normal Bex UI/policy updates therefore have no source path that replaces, registers or reconfigures this separate app. Existing terminal `bex-hook` compatibility/reuse is a different lifecycle and is unchanged here.

**Permission persistence is unverified.** A stable independent bundle, identifier and code-signing requirement are architecture groundwork, not evidence that macOS will attribute or preserve Accessibility permission across updates. This cloud-only work did not compile Swift, sign/run either app, register/activate a service, request/change Accessibility permission, touch a Mac/device, run GitHub CI, install an app or replace any user configuration.

## Components

- `BexAccessibilityShared`: bounded versioned wire contract, exact signing identity, per-connection capture store, read-only AX observer and NSXPC listener.
- `BexAccessibilityHost`: standalone AppKit setup window and separate `--agent` entry point for launchd.
- `Bex/Application/AccessibilityAgentClient.swift`: lazy authenticated client. Construction performs no connection, registration or permission request.
- `Bex/Application/IndependentAccessibilityTargetService.swift`: actual asynchronous capture, validation, one-shot Copy, discard and stop implementation. It is deliberately not selected by production and does not pretend to conform to the existing synchronous capture interface.
- `Config/com.bex.accessibility.agent.plist`: host-owned per-user Aqua LaunchAgent, copied only into the standalone host's `Contents/Library/LaunchAgents` directory. `BundleProgram` resolves to that host's own executable, with `--agent`; no arbitrary executable path, RunAtLoad, KeepAlive or privileged service is specified.

The normal host launch shows setup only. Registration, unregistration and the Accessibility prompt require separate explicit buttons, a valid production signature and the canonical `/Applications/BexAccessibility.app` path. Registration can bootstrap the background service and must be treated as an activation step during a future authorized validation/release. No such button was invoked during this work. The current setup status reports trust for the setup process; it does not claim proof of the launchd process's TCC attribution.

## Trust boundary

Both participants use `NSXPCConnection.setCodeSigningRequirement` before resume. Requirements are fixed, parsed before use and contain all of:

- Apple generic anchor;
- exact identifier: client `com.bex.desktop`, helper `com.bex.accessibility`;
- exact configured Team ID `ESURPGU29C`, matching the existing project.

Each process additionally validates its own identity before creating its connection/listener. Missing or ad-hoc signing is rejected; there is no PID-only, Team-only, unsigned or debug bypass. A future team/identifier change requires an explicit reviewed source/build contract update. The listener additionally rejects root/different-user peers and uses only the per-user namespace. Identity requirements trust correctly signed code with those exact identifiers, not an arbitrary same-team application. They do not defend against a compromised authorized signed app or injected code already inside that process.

Apple's requirement API authenticates received messages, not the first outgoing message. The initial hello therefore carries only protocol constants and a random challenge. The helper's reply carries a matching challenge and random connection session, with no text or permission state. No capture/token request is sent until the authenticated reply has completed and its contract, challenge and session are checked. A malformed/incompatible reply invalidates the connection; there is no downgrade or automatic retry.

## Read-only and capability semantics

The helper can perform only hello, status, capture, validate, consume and discard. There is no IPC operation for permission changes, installation, paths, provider calls, caller-selected target process, AX mutation, paste, submit or keystrokes. No replacement text is sent to the helper. AX object references never leave it.

Capture is explicit and observes the current frontmost external app. The helper binds an opaque UUID token to its XPC session, PID, launch date, bundle ID, exact AX element, text-field/text-area role, non-secure subrole and original UTF-8 bytes. Capture excludes the caller and helper processes. Validation checks trust, application lifetime, focus/role/editability and exact unchanged bytes. Observed drift or trust revocation revokes the affected capabilities. Validation is point-in-time: it cannot provide an atomic transaction over another app's editor, which is why replacement and submission remain manual.

The app adapter binds its local review to the exact returned capture session, complete immutable target identity, generation and expiry. Async returns are checked again after suspension. Copy reserves the local capability before awaiting the one-shot remote consume. Cancellation, stop, discard, replacement session or expiry suppresses a late clipboard write. The local capability is consumed before one synchronous clipboard side effect. An uncertain clipboard error is terminal and never retried. Concurrent approvals cannot copy twice. Existing standalone/manual and host-managed staging use the safe existing implementation; remote capture failure does not silently fall back to main-app capture.

## Bounds and teardown

- JSON message maximum: 524,288 bytes; captured original maximum: 262,144 UTF-8 bytes. JSON escaping may make a smaller original exceed the wire limit, in which case it is rejected.
- Four connections, eight pending requests per connection, 64 retained captures per connection, one-hour expiry.
- Silent pre-handshake connection deadline: five seconds. Authenticated idle sessions close after the capture lifetime plus five seconds.
- Client exchange timeout: five seconds; cancellation or transport/protocol failure invalidates the connection with no retry.
- One monotonic three-second observation deadline is shared from server queue admission through capture and final revalidation. Each AX messaging endpoint additionally has a 0.5-second timeout. The budget is checked between messages; an in-flight AX call can extend past the budget by its timeout. This is not a hard real-time guarantee for local framework work, IPC delivery or native shutdown.
- Invalidation revokes the session and drains admitted work plus MainActor capture-store cleanup. Server stop resolves only after those drain callbacks complete. Client stop is terminal and waits for local invalidation callbacks; it does not claim remote-process exit acknowledgement. A connection lifetime guard invalidates before deallocation.

Capture/validation reads may finish after cancellation while the already-running AX call returns, but stopped sessions suppress their reply and drain cleanup. There are no post-cancellation AX writes because there are no AX writes at all.

## Verification delivered

Portable source/build-graph regression checks: `node --test scripts/tests/bex-accessibility-agent-source.test.mjs`. These parse the OpenStep project graph, verify independent target ownership and production non-selection, inspect authentication ordering, bounded wire/read-only surface, shared request budget, drain checks, session binding and Copy ordering. They are source assertions, not Swift compilation or runtime tests.

Native test source is provided in `AccessibilityCaptureStoreTests.swift` and `IndependentAccessibilityTargetServiceTests.swift`. Fakes exercise handshake and session ownership, size/capacity/expiry, drift/revocation, shared budget, complete target identity, manual-only behavior, cancellation/discard/stop during suspended operations, connection replacement, concurrent Copy and uncertain clipboard outcome. They do not register or connect to a real service and have not run in this cloud environment.

## Required native acceptance gate before production selection

1. In a separately authorized disposable Mac/VM, compile both targets and mock tests with the selected macOS SDK and Swift 6 strict concurrency. Verify actual packaged Info.plist, LaunchAgent placement, BundleProgram resolution, scheme isolation and signing/hardened-runtime entitlements. Never weaken signing to make a test pass.
2. Use authorized production-team test artifacts to test exact app/helper requirements both ways. Reject unsigned/ad-hoc, wrong team, same-team wrong identifier, malformed/incompatible protocol and impersonated Mach service. Verify only the content-free hello reaches a wrong endpoint.
3. Review/install the independently versioned host at its stable path, then explicitly authorize registration and a fresh Accessibility grant. Inspect which process macOS holds responsible for the grant. Confirm service registration, approval, reconnect, login, disable and removal behavior rather than inferring it from plist contents.
4. Keep the host bytes/path/signature unchanged across a UI/policy-only Bex update and compare observed registration and TCC behavior. Separately test a compatible signed host update and incompatible contract rejection. Record exact artifacts/OS/build/signing identities. A fresh grant or reset for one test cannot prove persistence in another.
5. Test secure/unsupported fields, hung/slow AX destinations, app exit/PID reuse, focus/value changes, revocation and return of permission, cancelled/closed reviews, silent connections, maximum-size traffic, reconnect and stop/drain interleavings. Verify no automatic text replacement or Return occurs.
6. Only after those checks, review a separate production migration of synchronous capture/validation to the asynchronous adapter. Keep unavailable/not-enrolled states explicit; do not silently request permission, reinstall the host or switch back to a differently trusted capture path.

No installer, updater, activation automation or production migration is included here. The source implementation is intentionally dormant until that gate is met.

## Primary references

- [NSXPCConnection code-signing requirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [Apple discussion of first-message authentication](https://developer.apple.com/forums/thread/837286)
- [Service Management packaging and host-relative helper paths](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Apple DTS discussion of app-wrapped helpers](https://developer.apple.com/forums/thread/802443)
- [AX messaging timeout scope](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
- [NSXPCConnection invalidation](https://developer.apple.com/documentation/foundation/nsxpcconnection/invalidate())
- [Code-signing requirements and identity continuity](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
