# Bex web workbench and inactive native renderer

The default React/TypeScript/Vite app is an **offline fixture workbench**, not a replacement Bex release or a live AI service. The separate native renderer and host integration are implemented but remain inactive pending native acceptance. This draft also changes native source; it is no longer only the original web-only slice.

## Run the browser workbench

Use Node 22.13 or newer; `.node-version` pins 24.22.1 for the reviewed preparation flow. From the repository root:

```sh
npm --prefix web ci
node scripts/bex-web.mjs dev
```

The dev launcher serves `http://127.0.0.1:5179` with Vite live reload and opens the browser. If dependencies are absent, it installs them first. Installation requires network access. A port conflict fails without killing another process or switching ports. Stop with Ctrl+C.

```sh
node scripts/bex-web.mjs test   # dependency-free Node domain/source checks
node scripts/bex-web.mjs check # installed TypeScript, Node checks, browser build
node scripts/bex-parallel.mjs fast integration # isolated lane + source-stability evidence
npm --prefix web run build:native # separate native web assets, no app installation
```

`web/package-lock.json` is committed. Use `npm ci` for a fresh locked install. Neither dependency versions nor passing cloud tests authorize a native rollout.

## Available browser features

- Explicitly labeled deterministic correction samples. Unknown free text is rejected instead of receiving fabricated AI success.
- Full corrected output, bounded feedback notes, focus ordering, optional alternatives, vocabulary preference and Korean/English explanation controls. These affect supported fixture cases; they are not measurements of model quality.
- Session-only study books/sections with explicit active-source selection. Browser persistence is separately opt-in; restored excerpts never become active automatically.
- Local PDF/EPUB text extraction and deterministic passage search. Only an explicitly selected, attributed excerpt can enter the study library/request. Files, full extracted text and queries are not uploaded or automatically persisted. PDF code loads only after PDF selection; EPUB does not load it. No OCR, DRM bypass, semantic retrieval or layout reconstruction.
- Fixture-only nonblocking host-flow simulator. It demonstrates draft/send/review behavior without capturing or controlling another application.
- Cancellation, stale-result protection, guarded opt-in storage and explicit clipboard Copy. Browser workbench actions do not auto-send into another app.

See [study materials](../docs/study-materials.md), [document extraction](../docs/study-document-import.md), [personalization](../docs/personalization-policy.md), and [host-flow simulator](../docs/nonblocking-host-flow.md) for exact behavior and limits.

## Native boundary

The default `index.html` uses fixtures. `npm run build:native` inside `web/` emits a separate `dist-native/native.html` with three local resource files and restrictive CSP. It contains no PDF parser/importer/worker. Building those web assets does not build, sign, register, install or launch a native app.

The native page requires the packaged host's `window.__bexNativeCorrectionEndpoint`. A global property is not authentication: the native host must enforce exact-document/main-frame identity, navigation restrictions, capabilities and per-request disclosure/consent. **Connect native** sends only connection identifiers; writing, policy and the explicitly selected excerpt are sent only for a requested correction. No credentials, arbitrary paths, command execution or model endpoint controls belong in renderer messages.

The alternate renderer never silently substitutes fixture success. Its preferences are session-only. Cancelling the initial connection attempt, disconnecting, or a failed handshake is terminal for that document connection; reopen through the host for a new session. Editor edits, cancellation and unmount invalidate late results.

Production native provider/window activation is still gated. The resource build phase defaults OFF. The independent read-only Accessibility host and async adapter are dormant: production supplies no helper backend. No stable TCC persistence or native runtime equivalence is claimed. Existing terminal `bex-hook` lifecycle is a separate concern.

- [Native provider contract](../docs/native-provider-bridge.md)
- [Inactive app composition](../docs/inactive-app-composition.md)
- [Independent Accessibility helper and acceptance gates](../docs/independent-accessibility-agent.md)
- [Cross-app manual delivery safety](../docs/cross-app-delivery-safety.md)
- [Native resource audit](../docs/native-resource-audit.md)
- [Offline package](../docs/native-resource-packaging.md), [build inputs](../docs/native-build-input-integration.md), and [source freshness](../docs/native-source-freshness.md)

The optional `node scripts/bex-web.mjs desktop` command builds and runs a separate macOS WKWebView development shell with Xcode Command Line Tools. It has no production provider bridge, credentials, Accessibility grant, hook registration or production stores. It uses a nonpersistent WebKit data store. **Do not run it or other native commands without the applicable device/build permission.**

## Verification and remaining gates

Cloud verification has passed installed TypeScript and browser/native-web builds, Node domain/source checks, actual PDF/EPUB parser regressions, and React/JSDOM lifecycle suites. The PDF build graph can be inspected without launching a browser:

```sh
cd web
node node_modules/vite/bin/vite.js build --manifest
node tests/pdf-build-graph.mjs dist
```

Supplemental `tests/*.node.cjs` lifecycle suites use an existing isolated JSDOM/TypeScript harness selected by `BEX_NODE_HARNESS`; they are not silently included in the dependency-free aggregate. Native source assertions do not execute Swift. The source-freshness preparation tool records declared-input continuity and resource bytes, not trusted compiler provenance or a hermetic build.

Browser assertions have not run in the restricted cloud environment. `node scripts/bex-web.mjs e2e` installs Chromium/WebKit and launches them; use it only in an environment where that execution is permitted. Playwright WebKit is not Apple's WKWebView or a substitute for real macOS permissions testing.

Current changed Swift, native mock tests, signed XPC/launchd behavior, WKWebView consent/provider operation, and Accessibility attribution/persistence need separately authorized native validation. No live-provider quality, installer/updater/rollback, production activation or release readiness is established. Keep the PR draft until the [migration acceptance gates](../docs/web-first-migration.md) are satisfied.
