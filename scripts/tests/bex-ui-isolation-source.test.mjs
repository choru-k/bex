// Source guards only. These do not compile Swift, run AppKit, or prove macOS isolation.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const read = path => fs.readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const services = read('Bex/Application/AppServices.swift');
const delegate = read('Bex/Application/AppDelegate.swift');
const fixtures = read('Bex/Application/UITestingServices.swift');
const window = read('Bex/Application/WindowCoordinator.swift');
const settings = read('Bex/Settings/SettingsViewModel.swift');
const oauth = read('Bex/Grammar/CodexOAuthService.swift');
function between(source, start, end) {
  const first = source.indexOf(start); assert.ok(first >= 0, start);
  const last = source.indexOf(end, first + start.length); assert.ok(last > first, end);
  return source.slice(first, last);
}
const effects = between(fixtures, '  extension AppRuntimeEffects {', '  extension AppServices {');
const factory = fixtures.slice(fixtures.indexOf('    static func uiTesting(\n      seedCredential:'));

test('both launch selectors share fail-closed mode resolution before production composition', () => {
  assert.match(services, /arguments\.contains\("--ui-testing"\)/);
  assert.match(services, /environment\["BEX_UI_TESTING"\] == "1"/);
  assert.match(services, /guard debugBuild,[\s\S]*else \{ return \.rejectedUITesting \}/);
  assert.match(services, /guard realTarget == manualTarget else \{ return \.rejectedUITesting \}/);
  assert.ok(delegate.indexOf('guard launchMode != .rejectedUITesting') < delegate.indexOf('#if DEBUG'));
  assert.ok(delegate.indexOf('guard launchMode != .rejectedUITesting') < delegate.indexOf('AppServices.production()'));
  assert.match(delegate, /catch \{[\s\S]*?NSApp\.terminate\(nil\)\s+return/);
  assert.doesNotMatch(delegate, /if ProcessInfo\.processInfo\.environment\["BEX_UI_TESTING"\]/);
});

test('app lifecycle accesses notification, status and hotkey only through injected effects', () => {
  assert.match(delegate, /services\.runtimeEffects\.configureStudyNotifications\(self\)/);
  assert.match(delegate, /services\.runtimeEffects\.makeHotKey\(\)/);
  assert.match(delegate, /services\.runtimeEffects\.publishStudyStatus\(/);
  assert.doesNotMatch(delegate, /UNUserNotificationCenter\.current\(|StudyNotificationScheduler\(\)|StudyStatusFile\.write\(|GlobalHotKey\(\)/);
  assert.match(effects, /configureStudyNotifications: \{ _ in nil \}/);
  assert.match(effects, /publishStudyStatus: \{ _, _, _, _, _ in \}/);
  assert.match(effects, /makeHotKey: \{ GlobalHotKey\(backend: UITestingHotKeyRegistrationBackend/);
  for (const edge of ['configureStudyNotifications', 'publishStudyStatus', 'makeHotKey', 'openAuthorizationURL', 'activateExternalApplication']) {
    assert.match(services, new RegExp(`let ${edge}: @MainActor`));
  }
});

test('production effect closures preserve notification, status, browser, activation and hotkey behavior', () => {
  const production = between(services, '  static func production() -> Self {', '@MainActor\nfinal class AppServices');
  for (const expected of ['UNUserNotificationCenter.current().delegate = delegate', 'return StudyNotificationScheduler()',
    'StudyStatusFile.write(', 'makeHotKey: { GlobalHotKey() }', 'NSWorkspace.shared.open($0)',
    'activateExternalApplication: { NSRunningApplication(processIdentifier: $0)?.activate() },', 'persistsWindowFrames: true']) assert.ok(production.includes(expected), expected);
  assert.match(services, /runtimeEffects: AppRuntimeEffects = \.production\(\)/);
});

test('OAuth denies admission before credentials/listener work and fixture graph has no HTTP fallback', () => {
  const begin = between(oauth, '  func begin() async throws', '  func waitForLoopbackCompletion');
  assert.ok(begin.indexOf('guard authorizationEnabled else') < begin.indexOf('keychain.beginCodexLogin()'));
  assert.ok(begin.indexOf('guard authorizationEnabled else') < begin.indexOf('makeListener('));
  assert.match(oauth, /authorizationEnabled: Bool = true/);
  assert.match(factory, /let transport = UITestingHTTPTransport\(\)/);
  assert.match(factory, /authorizationEnabled: false/);
  assert.match(factory, /makeListener: \{ _ in UITestingOAuthListener\(\) \}/);
  assert.doesNotMatch(factory, /URLSessionTransport\(|NativeProviderTransport\(/);
  const deny = between(fixtures, '  struct UITestingHTTPTransport:', '  enum UITestingIsolationError:');
  assert.doesNotMatch(deny, /URLSession\(|CodexLoopbackListener\(|NWListener\(/);
  assert.match(effects, /openAuthorizationURL: \{ _ in false \}/);
  assert.match(window, /openAuthorizationURL: services\.runtimeEffects\.openAuthorizationURL/);
});

test('fixture factory validates target mode and paths before stores and keeps all stores synthetic', () => {
  assert.ok(factory.indexOf('throw UITestingIsolationError.invalidMode') < factory.indexOf('UITestingArtifacts.prepare'));
  assert.ok(factory.indexOf('UITestingArtifacts.prepare') < factory.indexOf('UserDefaults(suiteName:'));
  assert.match(factory, /configuration\.target\.usesRealTarget == \(mode == \.manualSystemTargetTesting\)/);
  assert.match(factory, /inMemory: true/);
  assert.ok(factory.includes('com.bex.desktop.ui-testing.\\(directory.lastPathComponent)'));
  assert.match(factory, /credentials\.ui-testing\.\\\(UUID\(\)\.uuidString\)/);
  assert.doesNotMatch(factory, /BexDataStore\(\)|LearningLogStore\(\)|PromptApprovalStore\(\)|HookInstallationManager\(\)|PromptGateIPCServer\(\)/);
  assert.match(factory, /runtimeEffects: \.uiTesting\(/);
  assert.doesNotMatch(factory, /removeItem\(at: directory\)/);
});

test('launch artifact validation rejects existing outputs, escapes, aliases and symlinks', () => {
  const paths = between(fixtures, '  enum UITestingArtifacts {', '  @MainActor\n  extension AppRuntimeEffects');
  assert.match(paths, /resolved\.path\.hasPrefix\(base\.path \+ "\/"\)/);
  assert.match(paths, /\.typeSymbolicLink/);
  assert.match(paths, /mustBeNew, FileManager\.default\.fileExists/);
  assert.match(paths, /let path = url\.resolvingSymlinksInPath\(\)\.standardizedFileURL\.path/);
  assert.match(paths, /guard path != directoryPath/);
  assert.match(paths, /!paths\.contains\(where:/);
  assert.match(paths, /for case let file as URL in enumerator/);
  assert.match(paths, /configuration\.preservesStoredState/);
  assert.match(paths, /BexUITesting-\\\(UUID\(\)\.uuidString\)/);
});

test('all fixture window frames and external focus restoration are gated', () => {
  assert.match(effects, /persistsWindowFrames: false/);
  assert.match(effects, /permitsExternalFocus: permitsSystemTarget/);
  assert.equal((window.match(/persistsWindowFrames: services\.runtimeEffects\.persistsWindowFrames/g) ?? []).length, 2);
  assert.match(window, /if persistsWindowFrames \{\s+restoredSavedFrame = window\.setFrameUsingName/);
  assert.match(window, /frameAutosaveName: services\.runtimeEffects\.persistsWindowFrames\s+\? PromptGatePanelController\.frameAutosaveName : nil/);
  assert.match(read('Bex/PromptGate/PromptGatePanel.swift'), /if let frameAutosaveName \{\s+let restoredSavedFrame/);
  assert.match(window, /services\.runtimeEffects\.activateExternalApplication\(processID\)/);
  assert.doesNotMatch(window, /NSRunningApplication\(/);
  assert.match(effects, /if permitsSystemTarget \{ NSRunningApplication/);
  assert.match(window, /permitsExternalFocus: services\.runtimeEffects\.permitsExternalFocus/);
  const drill = read('Bex/Study/StudyMicroDrill.swift');
  assert.match(drill, /permitsExternalFocus \? NSWorkspace\.shared\.frontmostApplication : nil/);
  assert.match(drill, /if permitsExternalFocus \{ previousApp\?\.activate\(\) \}/);
});

test('integration copy uses injected fixture clipboard, not a view-level system bypass', () => {
  const view = read('Bex/Settings/SettingsView.swift');
  assert.doesNotMatch(view, /NSPasteboard/);
  assert.match(view, /viewModel\.copyIntegrationArtifact\(value\)/);
  assert.match(settings, /func copyIntegrationArtifact[\s\S]*?try pasteboard\.write\(value\)/);
  assert.match(window, /pasteboard: services\.pasteboard/);
});

test('manual AX smoke is opted out before any file, process, or app action', () => {
  const ui = read('BexUITests/BexUITests.swift');
  const smoke = between(ui, '  func testStandardAXPromptGateSmoke() throws {', '\n  private func');
  const gate = smoke.indexOf('BEX_RUN_MANUAL_SYSTEM_TARGET_TEST');
  const skip = smoke.indexOf('throw XCTSkip(');
  assert.ok(gate >= 0 && skip > gate);
  for (const action of ['source.write(', 'XCUIApplication()', 'opener.run()', 'target.terminate()']) {
    assert.ok(smoke.indexOf(action) > skip, action);
  }
  assert.match(smoke, /launchArguments\.append\("--ui-testing-system-target"\)/);
  assert.equal((ui.match(/--ui-testing-system-target/g) ?? []).length, 1);
});

test('packaged host remains unreachable and native tests cover every important isolation edge', () => {
  assert.match(window, /#if false\s+func showPackagedCorrection\(\)/);
  const tests = read('BexTests/UITestScenarioContractTests.swift');
  for (const name of ['testLaunchSelectorsResolveOneFailClosedDebugMode', 'testRealTargetRequiresSeparateManualMode',
    'testDisabledOAuthNeverConstructsListenerOrCallsTransport', 'testFallbackTransportAndListenerDenyAllIO',
    'testIsolatedWindowsHaveNoAutosaveDomainAndSettingsCopiesToInjectedPasteboard',
    'testArtifactValidationRejectsExistingOutsideAndSymlinkPathsWithoutChangingThem',
    'testFreshArtifactsHaveDistinctRootsAndResumeRemainsInsideFixtureNamespace']) assert.ok(tests.includes(name), name);
});
