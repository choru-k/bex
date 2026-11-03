# Packaged native host candidate: inactive

This follow-up implements concrete host/consent/renderer wiring, but does not open a
window, install a handler in the existing app, or package resources into Bex.app.
No composition root calls `PackagedCorrectionHost.make`. The default browser and
WKWebView development lab remain fixture-only.

## Implemented wiring

- `PackagedCorrectionHost` accepts native-owned factory/destination/effort values.
  It looks only for `Bundle.main/BexWebUI/native.html`, rejecting missing or symlinked
  entry assets. There is no development-server or arbitrary-document initializer.
- The candidate creates a nonpersistent WKWebView, installs resource-blocking rules
  before loading, and admits one exact document navigation. Messages require the
  owning webview, main frame, exact committed document and bounded string JSON.
  Response values are passed as WebKit arguments, never interpolated into code.
- The real structured provider, coordinator and consent presenter are connected in
  this candidate. Navigation/failure/process termination/window close revoke work
  and message delivery. `closeAndWait()` is required before replacing the lifetime.
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
   No resource-copy build phase is added here; absent assets fail closed.
4. Implement the account/settings mutation barrier across every mutation path:
   revoke admission and await `closeAndWait()` BEFORE changing credentials, account,
   model or endpoint. Capturing a factory/destination does not implement this lock.
   OpenAI Codex remains rejected because dynamic account refresh is not pinned.
5. Obtain appropriate authorization before any app execution, platform side effect,
   permission change or live-provider transmission. This slice performs none.

## Evidence boundaries

Cloud Node tests execute the exact injected endpoint JavaScript and fake endpoint
renderer flows. Cloud TypeScript and web builds check web source only. These do not
compile AppKit/WebKit or establish native security enforcement. AppKit test sources
are authored but unrun and are application-hosted; running them may launch Bex.
No native build or test is requested by this document. Earlier exact-commit package
and synthetic-adapter passes do not verify this new host or presenter. Native testing
is paused; do not rerun a stopped build/postprocessing operation through this code.
