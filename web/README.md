# Bex Web Lab — first web-first slice

An **isolated development workbench**, not a replacement Bex release. It uses React +
TypeScript + Vite for the feedback UI and a framework-independent TypeScript domain.
The existing Swift app, release workflow, credentials, user data and host hooks are unchanged.

## Start on your Mac

From the repository root, with Node **22.12 or newer** installed:

```sh
node scripts/bex-web.mjs dev
```

The first run installs dependencies in `web/node_modules`, then opens the browser at
`http://127.0.0.1:5179`. Edits to React/CSS use Vite's development reload path.
A port conflict is an error: the launcher does not kill an unknown process or silently
switch ports. Press Ctrl+C to stop. Initial installation requires internet access.

```sh
node scripts/bex-web.mjs desktop  # macOS: isolated WKWebView + same Vite server
node scripts/bex-web.mjs test     # 39 domain tests; no dependency installation needed
node scripts/bex-web.mjs check    # full TS check + domain tests + production web build
node scripts/bex-web.mjs e2e      # installs Chromium/WebKit; runs both test projects
```

`desktop` needs Xcode Command Line Tools. It compiles a separate app at
`web/.native-build/Bex Web Lab.app`, with bundle identifier `com.bex.web-lab`.
It does not modify `Bex.xcodeproj`, install in `/Applications`, request Accessibility
permissions, read Keychain, register hooks or access production Bex stores.
Closing the lab stops its Vite child process. The desktop shell uses a **nonpersistent**
WebKit data store: even saved lab preferences are discarded when that shell exits.
The browser version can retain the learning settings only after explicit opt-in.

## What works in this slice

- Feedback UI: draft, complete corrected sentence, error vs optional-expression notes.
- Five deterministic scenarios: verb form, already-correct text, articles, protected
  technical text and failure. Unknown free text is explicitly rejected in fixture mode.
- Note budget (0/1/2), optional alternatives and focus-based note ordering.
- Vocabulary preference and a titled/attributed study excerpt in the versioned request.
  These are **request preparation**, not model adaptation or retrieval yet.
- Input/response validation, cancellation, stale-response protection, browser-safe text
  rendering, guarded storage and opt-in persistence of settings only.
- Clipboard copy on an explicit click; never auto-send or auto-replace host text.
- Developer view showing the future model request without sending it.

## Deliberately not connected yet

**No live AI correction. No automatic Codex/Claude/ChatGPT capture. No PDF/EPUB
import or book search. No automatic app update. No change to existing helper installs.**
The sample results are fixtures, not LLM evaluations. The interface labels this in the
header, banner and each result. Arbitrary text cannot accidentally receive a fake success.
Changing vocabulary or adding a reference does not regenerate the fixed sample wording.

The next slice should implement `CorrectionTransport` using the existing native
provider service, behind explicit outbound consent and protected-token validation.
Do not expose provider credentials or general file/command execution to the renderer.
Do not load a remote page into a privileged WebView. This dev shell has **no script bridge**.
See `docs/web-first-migration.md` for boundaries and acceptance criteria.

## Layout

```text
src/core/model.ts      policy, validation, request context, presentation, lifecycle
src/core/fixtures.ts   honest demo transport, separated from product policy
src/App.tsx           React feedback/settings UI
native/main.swift     disposable, unprivileged macOS development shell
../scripts/bex-web.mjs one entrypoint for dev/test/build/native lab
```

The core tests use Node's type-stripping support and have no npm dependencies.
They intentionally avoid TypeScript syntax that needs runtime transformation.
Playwright checks Chromium and WebKit, but **Playwright WebKit is not a replacement
for running Apple's WKWebView and real macOS permissions/integrations**.

## Dependency/review status

Direct React/Vite/TypeScript versions follow the official Vite React TS template
retrieved on 2026-11-03; Playwright is pinned to its released 1.64.1, not `main`'s
`-next`. Dependencies could not be installed in the authoring sandbox because npm
DNS/network access failed. **No lockfile or passing full build/browser-test claim
is provided.** Generate and review `web/package-lock.json` on the first networked
verification, then commit it and switch fresh CI installs to `npm ci` before merging.

Verified in the authoring Linux environment: 39 core tests, core-only strict checking
with available TypeScript 5.8.3, launcher JavaScript syntax and Swift syntax parsing.
Not verified there: installed TS 7 project build, React rendering/HMR, Playwright
suite, macOS typechecking, WKWebView execution or live Bex integration. Keep the PR draft.

### Explicit native renderer candidate (not the default lab)

`npm run build` and `src/main.tsx` still build the fixture-only `index.html`.
`npm run build:native` separately emits `dist-native/native.html` with relative
assets. It does not copy resources into the Bex application, launch it, register
it with macOS, or select a native runtime provider.

The alternate entry expects the packaged host's
`window.__bexNativeCorrectionEndpoint` (`postMessage(string)` and
`subscribe(listener) -> unsubscribe`). The global declaration is not an origin
or authentication mechanism: the host remains responsible for exact-document,
main-frame, navigation, capability, and per-request consent enforcement.

The page does nothing until **Connect native** is clicked. The handshake sends
only bridge/session/request identifiers, never writing, policy, or source.
After verified capabilities, the editor starts empty and displays the returned
provider name. Each correction sends the writing, learning policy, and any
selected source title/section/excerpt to the host. Provider transmission requires
native consent for that particular request. The native view does not claim
sample/offline operation and never substitutes fixture success on failure.
Learning preferences are session-only in this alternate view.

A host binds one session per document. Cancelling, disconnecting, or failing the
handshake closes this page's connection permanently; reopen the document through
the native host to try again. The page does not auto-reconnect or reload. Editor
cancellation, editing, disconnect, and unmount invalidate pending results.

Cloud-only lifecycle coverage (not browser/WebKit/AppKit verification):

```
# Use an existing isolated harness with jsdom and TypeScript 5.x. No app deps added.
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/native-renderer.node.cjs
```

The harness uses real React with a fake endpoint and synthetic strings. It checks
explicit text-free connection, repeated connect clicks, capability rejection,
stale replies, timeout, terminal cancellation/disconnect, provider labels,
source transfer, consent-denied errors, and unmount cleanup. It does not exercise
native dialogs, credentials, devices, or live providers.

After building the alternate native page, run the offline resource audit from the
repository root: `node scripts/bex-audit-native-resources.mjs --dist-native web/dist-native`.
It verifies the strict native CSP/HTML and records hashes without copying files into
the app. See `docs/native-resource-audit.md` for the exact profile and trust limits.
