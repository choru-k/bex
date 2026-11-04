# Cross-app delivery safety

## Current production behavior

The generic macOS Accessibility adapter captures a supported focused draft for review, then offers **Copy Correction**. It does not activate another application, change its focus or selection, replace its text, post Paste, or press Return. The user selects the intended destination, replaces the draft and submits manually. A generic hook-provided composer also offers Copy, even with Accessibility enabled.

This deliberately removes the former automatic paste and Return options. AX observations and global keyboard events cannot atomically bind a later operation to the observed application, field and draft revision. Extra polling does not close that race. Observed text equality also cannot detect an edit that changed back between reads. These limitations are not treated as guarantees.

The authenticated Oh My Pi host-managed staging/replay path remains available. Its approval/acknowledgement and exact replay receipt are separate from generic GUI input. The UI never labels copying or staging as a completed send.

## Capability lifetime and binding

- The concrete target service issues every target, including standalone Clipboard targets. Reconstructing a target with the same ID is not an authorization path.
- A target binds its complete model identity, including exact UTF-8 spelling of displayed and hook-context strings. Captures also bind process ID, bundle ID, process launch date, AX field identity, role, security subrole checks and observed original UTF-8 bytes. Missing process launch identity requires manual entry.
- Capture checks are repeated before presenting the capture and before copying. These are drift checks, not a transaction with the destination app.
- At most 64 unconsumed targets are retained; each expires after one hour. Rejected sessions, replacements, invalidation and closure discard their live capabilities. No permanent prompt tombstones are retained.
- Concrete delivery validates and removes its issued capability before its one clipboard write, without an intervening suspension. Unknown, expired, discarded, mutated or consumed targets cannot deliver. A new explicit review gets a new capability.
- A clipboard write may clear or change its contents before reporting failure. Such a failure is terminal and does not authorize an automatic retry.
- The view model validates target and hook request/client context before issuing a receipt and again before acknowledgement. Once acknowledgement may have committed, later cancellation, target invalidation or local copy failure cannot be reported as a safely retryable no-effect failure.

## Accessibility isolation status

The production dependency boundary now exposes observation methods only, apart from the existing user-invoked Accessibility trust request. No new permission prompt, monitor, event tap, hook, service, launch agent, XPC endpoint, entitlement, installation or runtime activation is introduced.

This is **not** a separate stable Accessibility helper process and is not a new security boundary. The existing main application still owns the OS grant. A signed process split requires native design and validation of signing identity, caller authorization, lifecycle, permission ownership and installation/update behavior. A placeholder XPC or helper target without those properties would not solve that problem and is intentionally absent.

## Verification boundaries

`node --test scripts/tests/bex-cross-app-safety-source.test.mjs` checks source-level capability restrictions, issuance/consumption order, context validation, uncertainty handling, session cleanup, truthful UI and native-test coverage. Source checks do not compile or execute Swift.

`BexTests/PromptTargetServiceTests.swift` covers exact target/revision binding, Unicode byte changes, process/field/security drift, unknown and downgraded IDs, single-use copy, cancellation, clipboard uncertainty, expiry/capacity and preserved managed staging. `PromptGateViewModelTests` covers pre-ack rejection, post-ack copy failure/cancellation, invalidation, actions and no false send callback. Updated UI tests assert copied bytes and an unchanged destination, including an opt-in real AX capture smoke using an isolated test copy sink.

The native XCTest and UI suites must be compiled and run on an explicitly authorized Mac before native activation is considered validated. The cloud source checks alone do not establish AppKit/AX behavior, OS trust, Swift actor isolation, signing, native test success or readiness to activate.
