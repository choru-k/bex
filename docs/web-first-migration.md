# Bex web-first migration: implemented source and acceptance gates

## Goal

Make UI, learning-policy and document work testable in the cloud without repeatedly rebuilding or reinstalling host integration. Keep credentials, provider transmission, signing and system permissions native. This draft is not a production switch or release.

## Current implementation

- **Default browser workbench:** React UI, validated policy/request/result model and honest fixture transport. Unknown free text is rejected. Learning-material management, local PDF/EPUB extraction, attributed passage search, personalization and a simulated nonblocking host flow are implemented.
- **Native renderer candidate:** a separate three-file local bundle with restrictive CSP and explicit capability handshake. The default browser build is not privileged. Native mode excludes the document parser/importer/worker and does not fall back to fixtures.
- **Native host/provider source:** origin/document admission, disclosure/consent, bounded transport, cancellation/drain and account mutation coordination are implemented but activation is gated. Cloud source checks do not establish real provider, security-dialog or WKWebView behavior.
- **Cross-app safety:** generic capture is read-only with explicit Copy/manual replacement, not automatic Paste/Return. Authenticated managed-host staging remains distinct from actual submission.
- **Stable helper work:** existing terminal `bex-hook` has explicit signed compatibility/reviewed lifecycle source. A separate read-only Accessibility host, signed peer contract, asynchronous client and dormant coordinator/view-model integration also exist. These are different helpers. Production supplies no independent Accessibility backend; it is neither embedded in nor a dependency of the main app. Stable TCC attribution/persistence is unverified.
- **Packaging:** exact resource/CSP audit, offline package verification, default-OFF native resource build inputs and explicit source-bound preparation are implemented. Declared-input continuity is not authenticity, hermeticity or trusted build provenance.

The original first-slice statement that this PR changes no Swift/project files is no longer true. Production source has changed, even where new selection branches remain inactive. Historical commit-specific verification does not verify later changes.

## What cloud verification establishes

A committed lockfile supports fresh `npm ci`. Installed TypeScript, browser and native-web builds, Node domain/source checks, actual document parsers and React/JSDOM lifecycle tests have passed in the cloud. Synthetic fixtures cover cancellation, malformed data and policy behavior; they do not measure live-model teaching quality. Static chunk graphs confirm browser PDF code is deferred and excluded from the native entry; they are not browser timing/network traces.

Native source assertions and unexecuted XCTest files are not Swift compilation or runtime evidence. No current native app, signed helper/XPC, launchd/TCC or privileged WebKit activation is claimed. Browser launches remain blocked in the current cloud environment; no alternative route bypassed that restriction.

## Remaining acceptance gates

1. **Permitted browser runtime:** Chromium/WebKit UI, keyboard, clipboard, dynamic PDF chunk/worker loading, error and cancellation behavior, and accessibility checks. Do not interpret Playwright WebKit as Apple's WKWebView.
2. **Separately authorized native build:** compile the exact source and mock tests with the supported SDK/Swift modes; inspect actual Info.plist, LaunchAgent and resource packaging. Build/registration side effects must be reviewed before running native commands.
3. **Native security/runtime:** exact signed peer rejection, spoofed service/handshake handling, session replacement and stop/drain, navigation/main-frame enforcement, offline resource admission and consent dialogs. A source-level signing requirement does not prove its runtime enforcement.
4. **Explicit helper setup/permission validation:** only after approval, inspect independent host registration, actual TCC attribution, revocation, reconnect and update persistence. Do not silently migrate, request the main app's AX permission as fallback, or infer permission persistence from bundle identity alone.
5. **Provider evaluation:** authorize bounded real-provider calls with specific transmitted data and cost limits; measure correction accuracy, minimal edits, protected technical spans, vocabulary level, explanation language and source-grounding on the real corpus. Offline fixtures are not this evaluation.
6. **Production selection:** only after the above, review an explicit activation change. Preserve unavailable/not-enrolled states and existing safe behavior. No UI or policy update should silently install/replace a helper or broaden permissions.
7. **Distribution/update/rollback:** choose a release channel and trusted signing/update mechanism, then validate signed packaging, compatibility, atomic replacement/rollback and required user actions on native systems. This draft has no enabled app updater or release. Do not invent signing keys or a trust root to fill the gap.

## Invariants to retain

- Keep credentials, model endpoints, arbitrary file paths and command execution outside renderer messages.
- Treat imported/reference text as untrusted data, never system instructions. Shape validation cannot prove semantic correctness.
- Disclose selected source title/section/excerpt together with writing and policy before native provider transmission; imported files/full books are never automatically uploaded.
- Edits, cancellation and session changes must reject stale success and failure responses before side effects.
- Feedback budgets limit notes, not necessary edits in the complete corrected text.
- Preserve user history, preferences, accounts and host configuration through explicit, reviewed migrations.
- Separate app source implementation, compile evidence, runtime evidence, permission approval and release readiness in every report.

## Developer entry points

See [web/README.md](../web/README.md) for current setup and commands. Focused designs and boundaries are documented in [native provider bridge](native-provider-bridge.md), [inactive app composition](inactive-app-composition.md), [independent Accessibility agent](independent-accessibility-agent.md), [document import](study-document-import.md), [source freshness](native-source-freshness.md) and [native build inputs](native-build-input-integration.md).
