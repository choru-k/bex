# UI validation isolation

The normal Debug UI launch (`--ui-testing` or `BEX_UI_TESTING=1`) selects one explicit fixture dependency graph. It is not an OS sandbox and must not be used to claim arbitrary app-hosted or packaged-host code is safe to execute.

## Default fixture boundary

- Both selectors choose the same mock hotkey, fixture commands and fixture services. Invalid combinations are rejected before production composition. Release builds reject UI-test requests instead of silently launching production.
- No system notification delegate is installed, scheduler constructed, authorization requested, or pending `bex.study.daily` notification removed. Study status publication is suppressed, including the real `study-status.json` file.
- Provider work uses deterministic grammar fixtures. OAuth login is rejected before credential mutation or callback listener construction. The separately injected HTTP transport and callback listener also deny I/O. Settings cannot open an authorization URL in a browser.
- Credentials remain in memory, with a different identity per factory invocation. Data, learning, study and receipt stores use a temporary fixture directory. Non-resume launches use a fresh UUID directory and preferences suite; named resume fixtures retain their existing dedicated preferences/data namespace.
- Hook management and IPC use fixtures. No real hook configuration is installed or updated and no real IPC listener starts.
- Clipboard writes, including Settings integration-artifact Copy, use the fixture pasteboard. Normal fixture capture cannot instantiate the real target service, activate an external process, or restore another app's focus.
- Main, Welcome and Fix & Send windows neither restore nor autosave the production frame defaults. In-memory frame behavior remains available for the test session.
- App-local menus, windows, local keyboard handling and fixture command notifications still operate. Distributed test commands can trigger only the capabilities of the already selected fixture graph; they cannot select a different mode.

Production composition retains its ordinary notification, status, hotkey, browser, clipboard, frame and target behavior. A manually constructed `AppServices` defaults to production effects; tests that create a coordinator must explicitly inject fixture effects rather than assuming mock stores imply isolation.

## Artifact paths

Existing `BEX_UI_TEST_PASTEBOARD_PATH`, `BEX_UI_TEST_PROMPT_TARGET_PATH`, `BEX_UI_TEST_PROMPT_DELIVERY_EVENTS_PATH` and `BEX_UI_TEST_INTEGRATION_TRANSCRIPT_PATH` inputs remain supported for fresh files beneath the OS temporary directory. Validation happens before any fixture store is composed or reset. Existing paths, symlinks, paths outside that directory, duplicate/overlapping paths and aliases of fixture stores are rejected without deleting the target. Use a new filename for each launch. Without explicit paths, clipboard/target files stay in the fixture directory.

Persisted resume fixture descendants are checked for symlinks before stores use them. These checks prevent accidental use of ordinary user files; they are not a defense against another process maliciously swapping filesystem entries between validation and use. They do not authorize a real-system test or make `HOME` overrides a sandbox.

Direct unit fixtures can still inject their own test-owned paths. Such unit tests are responsible for using unique temporary files and scoped defaults rather than production names.

## Manual system-target lane

`BEX_UI_TEST_REAL_TARGET=1` alone is rejected. Manual target validation additionally requires the separate `--ui-testing-system-target` argument. This lane is **not isolated from external apps**: it permits real accessibility capture and external focus changes. Providers, OAuth, notifications, status publication, hook installation, system clipboard and window persistence remain fixture-backed or suppressed.

`testStandardAXPromptGateSmoke` skips before creating a file or launching an app unless its runner explicitly sets `BEX_RUN_MANUAL_SYSTEM_TARGET_TEST=1`. That test then supplies both app flags. It opens and terminates TextEdit, so run it only in a coordinated test session with no user documents at risk. It is not part of ordinary automated UI evidence. Do not enable this lane as a workaround for a blocked isolated test.

The packaged correction open hook remains literal `#if false`. Its native transport does not inherit the UI fixture HTTP transport. Packaged-host acceptance requires its own separately authorized, injected app-hosted test harness and is outside this change.

## Evidence levels

`node --test scripts/tests/bex-ui-isolation-source.test.mjs` checks source wiring and guards only. It does not compile Swift or exercise native lifecycle behavior.

`BexTests/UITestScenarioContractTests.swift` adds native regressions for Debug/Release selection, real-target rejection, inert runtime effects, credential separation, OAuth/listener/transport denial, no frame autosave, injected Copy, safe artifact admission, canonical aliases and resume preservation. Run these with the macOS/Xcode unit suite before claiming native runtime verification. Existing OAuth, hotkey, frame, Settings and coordinator tests remain relevant.

No macOS execution, permission change, browser launch or native compile result is implied by passing the portable source guards.
