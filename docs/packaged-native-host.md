# Packaged native host candidate: inactive

**Native status: UNCOMPILED / UNRUN.** The wiring below describes candidate source,
not verified native behavior.

This follow-up implements concrete host/consent/renderer wiring and an
[inert app-owned window controller](inactive-app-composition.md), but does not open
a window, install a live handler in the existing app, or package resources into
Bex.app. `AppServices` owns one controller whose constructor performs no work.
Its real native session calls `PackagedCorrectionHost.make` only after an explicit
open operation; the only composition open hook is inside literal `#if false` with
no UI, menu, shortcut, URL, environment or build-flag activation path. The default
browser and WKWebView development lab remain fixture-only.

## Candidate source wiring

- `PackagedCorrectionHost.make(window:factory:)` accepts no caller-supplied destination
  or effort. It reserves an epoch in the process-wide account mutation coordinator
  before reading one native preferences snapshot. It revalidates after the snapshot
  read and asynchronous content-rule compilation. Registration validates the same
  epoch atomically, with no suspension before document loading. A stale construction
  cannot load a document or join a replacement account's lifetime.
  It rebuilds the factory with its own [isolated provider transport](native-provider-transport.md),
  ignoring any caller-supplied transport. This remains inactive and uncompiled;
  the existing app's transport/factory wiring does not change.
  It uses [strict native resource admission](native-resource-admission.md) against
  `Bundle.main` before any WebKit construction or loading. The fixed sibling manifest,
  exact three-file `BexWebUI` inventory, HTML/CSP template, byte counts and full hashes
  must agree; missing, nonregular, linked, oversized or noncanonical resources fail
  closed. There is no development-server or arbitrary-document/bundle initializer.
  This integrity check requires a trusted, signed, immutable app bundle and does
  not establish authenticity or prevent WebKit's later path-reopen race.
- The candidate creates a nonpersistent WKWebView, installs resource-blocking rules
  before loading, and admits one exact document navigation. Messages require the
  owning webview, main frame, exact committed document and bounded string JSON.
  Response values are passed as WebKit arguments, never interpolated into code.
- The real structured provider, coordinator and consent presenter are connected in
  this candidate. Navigation/failure/process termination/window close revoke work
  and message delivery. `closeAndWait()` is required before replacing the lifetime.
  It awaits both coordinator work and provider-session task completion/invalidation.
  A shared drain task survives close-waiter cancellation. The process-wide barrier
  retains the lifetime after close, including when the view owner is dropped, until
  both drains finish. Closing cannot unregister still-running work. Construction
  also observes window closure before either asynchronous step and rejects a window
  closed during that work.
- `NativeCorrectionConsentPresenter` shows full native destination/model and all
  text/source/options as read-only plain text, with a bounded scrolling viewport.
  Cancel is the default. Its FIFO has at most four admitted requests; queued work
  cancels immediately, active work returns only after AppKit dismissal completes.
- The separate `native.html` renderer requires an explicit connection handshake.
  Handshake contains no writing. Correction sends request data to the native host;
  the native dialog must grant each provider transmission. Disconnect/handshake failure is
  terminal for the document, with no fixture fallback. Native preferences are
  session-only. The default `index.html` page retains fixture behavior.

## Required before activation

1. Compile/review the new AppKit/WebKit code and test native sheet layout, default
   keys, cancellation and dismissal. Source assertions are not UI validation.
2. Validate actual WebKit origin/frame/navigation/resource isolation. In particular,
   content-rule behavior for fetch, sockets and resource schemes has not been run.
   A method name, endpoint global, provider label or capability flag is not proof
   of trust or consent.
3. Review immutable packaged resources and CSP, relative asset loading and build
   provenance. A separate native web build is not an audited app packaging path.
   The [offline resource audit](native-resource-audit.md) checks the exact native
   HTML/CSP and hashed three-file staging inventory. It does not establish JavaScript
   semantics, signing, provenance, race-free filesystems or WebKit enforcement.
   No resource-copy build phase is added here; absent assets fail closed.
4. Compile and validate the integrated cooperative account/settings barrier and
   all store/OAuth mutation paths. The implementation uses one process-wide gate
   across backing domains, not one gate per factory or suite/service pair. Mutation
   closes admission and synchronously revokes admitted hosts, then awaits complete
   termination before committing. A non-cooperative drain keeps mutation blocked;
   cancellation or a timeout must never substitute for termination. This protects
   cooperative Bex-owned store writes only. External processes, direct UserDefaults
   edits and external Keychain writers are outside this guarantee. It cannot retract
   bytes already sent or revoke an upstream API key. Only registered packaged-native
   lifetimes participate in revocation and drain. Existing `GrammarService` jobs are
   not registered; this change does not promise to stop their in-flight requests or
   revoke keys already copied into legacy clients. OpenAI Codex stays rejected;
   its dynamic refresh needs a separate lifetime/deadlock design.
5. Obtain appropriate authorization before any app execution, platform side effect,
   permission change or live-provider transmission. This slice performs none.

## Evidence boundaries

Cloud Node tests execute the exact injected endpoint JavaScript and fake endpoint
renderer flows. Two source-regression checks inspect reservation/snapshot/register/
load ordering and the lifetime's drain-before-removal wiring. They do not execute
Swift and are not concurrency or lifecycle proofs.

`PackagedCorrectionHostLifetimeTests` contains seven synthetic XCTest cases for
manual close racing mutation, sequential coordinator/transport termination,
synchronous mutation revocation, cancelled close waiters, stale and already-closed
construction, duplicate registration, and lifetime retention after its owner drops.
They exercise the exact lifetime helper used by the host with fake drains, without
creating AppKit/WebKit objects or accessing Keychain, preferences or the network.
These Swift tests are authored but have **not been compiled or run** in cloud.
Actual construction failure/window-close races and WebKit cleanup still require
native runtime validation.

Cloud TypeScript and web builds check web source only. These do not
compile AppKit/WebKit or establish native security enforcement. AppKit test sources
are authored but unrun and are application-hosted; running them may launch Bex.
No native build or test is requested by this document. Earlier exact-commit package
and synthetic-adapter passes do not verify this new host or presenter. Native testing
is paused; do not rerun a stopped build/postprocessing operation through this code.
