# UI validation isolation

UI validation requires a **dedicated compiled artifact**, not a normal Debug app with `--ui-testing` or `BEX_UI_TESTING=1`. A process can be relaunched without its original arguments, environment or process sandbox. Runtime selectors alone cannot preserve isolation.

## Artifact identity and every-entry policy

The `UITesting` configuration compiles `DEBUG BEX_UI_TEST_ARTIFACT` and produces `BexUIValidation.app` with module name `Bex`, bundle ID `com.bex.desktop.ui-validation`, and the `BexUITestArtifact = isolated-ui-v1` Info.plist marker. The dedicated plist does not register `bex://` or use `LSEnvironment`. The compile-time discriminator is the authority; the plist and bundle ID are consistency checks, not cryptographic identity.

- Every entry checks identity before constructing `NSApplication` or the delegate. The lifecycle callback checks again before composition. A test artifact with no arguments and an empty environment still selects the standard isolated fixture graph.
- Missing, malformed or mismatched artifact metadata rejects the launch. The test flag without `DEBUG` is a compile error. The production composition call and production effect/factory implementations are compiled out of the test artifact; the latter fail explicitly if called.
- Ordinary Debug/Release apps reject test selectors, any artifact-marker claim and unexpected bundle IDs. Supported ordinary builds still use `com.bex.desktop` and retain their normal behavior. A manually renamed/reidentified ordinary Debug app is not a supported validation artifact. Existing binaries built before this guard are not repaired by these sources.
- The embedded helper exits without reading input or entering its live runtime in `UITesting`. The independent Accessibility host also returns before AppKit/server/setup work in that configuration. Normal Debug/Release helper behavior is unchanged. These guards do not make arbitrary calls into helper internals safe.
- Both shared schemes select `UITesting` for their TestAction. The ordinary Bex scheme still uses Debug for Run and Release for Archive. App-hosted unit/UI test targets fail compilation without the dedicated flag, so an explicit Debug test override cannot silently rebuild an ordinary test host. The independent Swift package is unaffected. UI tests target the dedicated bundle ID explicitly.
- Validation artifacts ignore external URL callbacks. Normal URL callbacks received before services exist are ignored rather than entering an uninitialized coordinator.

This is an app dependency/entry boundary, **not an OS security sandbox**. It does not promise that AppKit, Xcode, LaunchServices, accessibility automation or other system frameworks make no changes to system metadata or preferences.

## Supported preparation and execution

Do not manually compile an ordinary Debug binary and wrap it in a different `.app`, or rely on `HOME`, runtime flags, an inherited sandbox, a bundle-name change or ad-hoc signing to make it safe. Do not run an unknown candidate to ask whether it is isolated.

After **separate explicit approval of the Mac testing setup**, the supported preparation is:

```sh
node scripts/bex-ui-test-artifact.mjs build
node scripts/bex-ui-test-artifact.mjs inspect /absolute/path/from-build/receipt.json
```

The build script selects the dedicated scheme/configuration with no caller overrides, uses fresh temporary DerivedData, checks effective compiler/product/signing settings, and invokes `build-for-testing`. Only `UITesting` is configured for **teamless ad-hoc signing**: `CODE_SIGN_IDENTITY=-`, `CODE_SIGN_STYLE=Manual`, signing allowed/required, empty development team and provisioning settings, and no additional signing flags. These values are also fixed command-line arguments for every settings query and build. Ordinary Debug/Release signing is unchanged. This is local test signing, not distribution signing or proof of isolation.

Before building, the CLI checks all four project targets in this scheme's graph: `Bex`, `BexTests`, `BexUITests` and embedded dependency `bex-hook`. If a scheme settings response omits a target, a settings-only query uses the same fixed configuration, SDK and signing arguments. Unknown, duplicate or missing targets, non-ad-hoc effective settings and missing fixture compilation flags on any target fail closed. An external `XCODE_XCCONFIG_FILE` override is rejected before invoking Xcode, and `CODE_SIGN_KEYCHAIN` is pinned empty. The independent `BexAccessibility` target's `UITesting` configuration is also pinned in the project, but it is not a dependency of this scheme and is not built. The CLI makes no certificate-lookup call and requests no certificate signing, provisioning update, account sign-in, post-build re-signing or unsigned fallback. This does not guarantee that Xcode itself never consults keychain/tool state. Existing hardened-runtime settings, helper CodeSignOnCopy, entitlements and script-sandbox settings are retained. A failure requires setup review, not weaker signing or a manually assembled app.

**Build-for-testing is not system-neutral.** Xcode may sign products, register applications with LaunchServices or invoke `RegisterExecutionPolicyException` even though this script does not launch the app's main entrypoint. That task attempts to add an execution-policy exception and is distinct from LaunchServices registration. Approval of temporary LaunchServices registration alone does **not** authorize that security-policy change. The native build remains held until any required execution-policy change is explicitly approved; ad-hoc signing does not remove that requirement. Do not disable registration/security tasks or alter protections to bypass the hold. Settings queries may also resolve packages or touch Xcode/tool state, so they are not a zero-side-effect claim. See the [Swift build task implementation](https://github.com/swiftlang/swift-build/blob/fb7a92288cf31340b77d31c364e8eef383f08085/Sources/SWBTaskExecution/TaskActions/RegisterExecutionPolicyExceptionTaskAction.swift).

Inspection reads bundle metadata, a compiled-test-branch stamp, the generated test plan and hashes of the build products. It also uses read-only `lipo -archs`, per-architecture `codesign --display`, and `codesign --verify --strict --all-architectures` checks for the app, original and embedded helper, both test bundles and generated test runner. Each expected project-produced product must have a valid ad-hoc signature, the expected identifier, no authority/team, and the app/helper must retain hardened runtime. Apple-supplied XCTest frameworks are not required to be ad-hoc. Unsupported architectures, product layouts or diagnostic formats fail closed and require review of the installed Xcode/tools. See Apple's [universal binary guidance](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary), [per-architecture code-signing guidance](https://developer.apple.com/documentation/technotes/tn3126-inside-code-signing-hashes) and [strict signature verification guidance](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

The checks reject normal/unstamped binaries, stale Debug hosts, certificate-signed or unsigned project products, plans pointing outside the checked products, a production UI target, and restored manual-target selectors. Inspection never executes or re-signs a candidate. The receipt binds checked contract-source hashes and product bytes; it is **accidental wrong-artifact detection, not a signed attestation or proof of machine-code behavior**. Use trusted, quiescent build products. Concurrent malicious replacement is outside this boundary. No receipt exists until a real authorized native build succeeds.

After review and explicit approval of native execution:

```sh
node scripts/bex-ui-test-artifact.mjs test /absolute/path/from-build/receipt.json
```

This rechecks the same products and invokes only seven named entry-policy/relaunch tests using `test-without-building`, not the complete native suite. The tests launch the dedicated app, create fixture data/preferences, open fixture UI and terminate only processes they own. One native regression directly launches the admitted executable twice with `arguments = []` and `environment = [:]`, waiting until the fixture graph reports ready. The UI regression repeats termination/relaunch with cleared selectors and requires fixture-only commands to work. These model stripped relaunches; they do not establish what caused any earlier OS/tool relaunch.

The CLI strips manual-target opt-ins and never includes the manual AX smoke. Broader unit/UI suites need separate review: arbitrary app-hosted tests can directly construct live stores or system services, and the entry guard does not authorize or isolate those calls. The scheme's broader TestAction is not a blanket safety claim. Existing CI files are unchanged, but native tests using the Bex scheme now use the dedicated host configuration.

## Default fixture boundary

- Runtime selectors customize fixtures only after compiled artifact admission. Both legacy selectors and an argument/environment-free launch choose the same mock hotkey, fixture commands and fixture services. Invalid combinations reject before production composition.
- No system notification delegate is installed, scheduler constructed, authorization requested, or pending `bex.study.daily` notification removed. Study status publication is suppressed, including the real `study-status.json` file.
- Provider work uses deterministic grammar fixtures. OAuth login is rejected before credential mutation or callback listener construction. The separately injected HTTP transport and callback listener also deny I/O. Settings cannot open an authorization URL in a browser.
- Credentials remain in memory, with a different identity per factory invocation. Data, learning, study and receipt stores use a temporary fixture directory. Non-resume launches use a fresh UUID directory and preferences suite; named resume fixtures retain their existing dedicated preferences/data namespace.
- Hook management and IPC use fixtures. No real hook configuration is installed or updated and no real IPC listener starts.
- Bex’s explicit copy/export actions, including Settings integration-artifact Copy, use the fixture pasteboard. Standard Edit-menu/responder copy, cut and paste, NSTextView behavior and XCTest input can still use system clipboard/framework facilities independently. Normal fixture capture cannot instantiate the real target service, activate an external process, or restore another app's focus.
- Main, Welcome and Fix & Send windows neither restore nor autosave the production frame defaults. In-memory frame behavior remains available for the test session.
- App-local menus, windows, local keyboard handling and fixture command notifications still operate. Distributed test commands can trigger only the capabilities of the already selected fixture graph; they cannot select a different mode.

Production composition retains its ordinary notification, status, hotkey, browser, clipboard, frame and target behavior in ordinary builds. Tests that manually create `AppServices` or a coordinator must explicitly inject fixture effects; the dedicated artifact rejects the default production-effects factory rather than assuming mock stores imply isolation.

## Artifact paths

Existing `BEX_UI_TEST_PASTEBOARD_PATH`, `BEX_UI_TEST_PROMPT_TARGET_PATH`, `BEX_UI_TEST_PROMPT_DELIVERY_EVENTS_PATH` and `BEX_UI_TEST_INTEGRATION_TRANSCRIPT_PATH` inputs remain supported for fresh files beneath the OS temporary directory. Validation happens before any fixture store is composed or reset. Existing paths, symlinks, paths outside that directory, duplicate/overlapping paths and aliases of fixture stores are rejected without deleting the target. Use a new filename for each launch. Without explicit paths, clipboard/target files stay in the fixture directory.

Persisted resume fixture descendants are checked for symlinks before stores use them. These checks prevent accidental use of ordinary user files; they are not a defense against another process maliciously swapping filesystem entries between validation and use. They do not authorize a real-system test or make `HOME` overrides a sandbox.

Direct unit fixtures can still inject their own test-owned paths. Such unit tests are responsible for using unique temporary files and scoped defaults rather than production names.

## Manual system-target lane

`BEX_UI_TEST_REAL_TARGET=1` alone is rejected, including in a dedicated artifact. Manual target validation additionally requires the separate `--ui-testing-system-target` argument. A stripped relaunch does not retain this capability and returns to fixtures when both selectors are gone; a partially stripped manual request rejects. This lane is **not isolated from external apps**: it permits real accessibility capture and external focus changes. Providers, OAuth, notifications, status publication, hook installation, Bex’s explicit clipboard actions and window persistence remain fixture-backed or suppressed.

`testStandardAXPromptGateSmoke` skips before creating a file or launching an app unless its runner explicitly sets `BEX_RUN_MANUAL_SYSTEM_TARGET_TEST=1`. That test then supplies both app flags. It opens and terminates TextEdit, so run it only in a coordinated test session with no user documents at risk. It is not part of ordinary automated UI evidence. Do not enable this lane as a workaround for a blocked isolated test.

The packaged correction open hook remains literal `#if false`. Its native transport does not inherit the UI fixture HTTP transport. Packaged-host acceptance requires its own separately authorized, injected app-hosted test harness and is outside this change.

## Evidence and limitations

`node --test scripts/tests/bex-ui-artifact.test.mjs scripts/tests/bex-ui-isolation-source.test.mjs` runs portable contract/source guards, artifact-validator adversarial cases, mocked signing-tool checks and project-structure checks. It does not compile Swift, resolve real Xcode settings, validate actual signatures, run AppKit or prove native isolation. The OpenStep parser checks structure, not Xcode semantics. All-target effective signing and native signature-output compatibility still need an approved Mac build; portable tests are not that evidence.

`BexTests/UITestScenarioContractTests.swift` and `BexUITests/BexUITests.swift` contain the native selection, metadata-mismatch, stripped-process and UI-relaunch regressions. They are authored but require an approved macOS/Xcode build and execution before being called runtime evidence. The generated `.xctestrun` contract and new configuration also require that native validation; unsupported layouts fail closed instead of broadening path admission.

The motivating validation incident observed writes to real `study-status.json` and `PromptGate/rendezvous.json` after a no-argument ordinary-debug process appeared. A global-preferences hash also changed, without an established writer. Network and notification effects were not established. The original process's flags/environment/process-sandbox state are not proof of the later process's state. This source change neither restores user data nor resolves those unknowns, and cannot guarantee global preferences remain unchanged merely because explicit application writers are fixture-backed.

No Mac/device access, data restoration, permission change, browser launch, native compile or native runtime pass is implied by the cloud checks. Packaged-host activation remains disabled and requires its own authorization and harness.
