// Portable contract/source guards, NOT a Swift compile or native runtime test.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { contract, validateBuildSettings, validateBundleInfo, validateCompiledStamp,
  artifactHashes, relaunchTests, validateTestPlan } from '../bex-ui-test-artifact.mjs';
const read = p => fs.readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8');
const launch = read('Bex/Application/AppLaunchMode.swift');
const delegate = read('Bex/Application/AppDelegate.swift');

// A small OpenStep parser validates actual config object structure, not a regex
// that could overlook a missing buildSettings/object brace. No Xcode semantics.
function parseProject(source) {
  const tokens = [...source.matchAll(/\s+|\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+/g)]
    .map(m => m[0]).filter(t => !/^\s|^\/\*|^\/\//.test(t));
  let i = 0;
  const take = expected => { assert.equal(tokens[i++], expected); };
  const scalar = () => { const t = tokens[i++]; assert.ok(t); return t.startsWith('"') ? JSON.parse(t) : t; };
  function value() {
    if (tokens[i] === '{') {
      take('{'); const result = {};
      while (tokens[i] !== '}') {
        const key = scalar(); take('='); result[key] = value(); take(';');
      }
      take('}'); return result;
    }
    if (tokens[i] === '(') {
      take('('); const result = [];
      while (tokens[i] !== ')') { result.push(value()); if (tokens[i] !== ')') take(','); }
      take(')'); return result;
    }
    return scalar();
  }
  const result = value(); assert.equal(i, tokens.length); return result;
}
function compiledSlice(source, symbols) {
  const stack = []; let active = true; const output = [];
  const condition = expression => expression.split('||').some(part => part.split('&&').every(piece => {
    const term = piece.trim(), negate = term.startsWith('!'), name = negate ? term.slice(1) : term;
    const truth = name === 'true' || symbols.has(name); return negate ? !truth : truth;
  }));
  for (const line of source.split('\n')) {
    const match = line.trim().match(/^#(if|else|endif)\b(.*)/);
    if (!match) { if (active) output.push(line); continue; }
    if (match[1] === 'if') { stack.push({ parent: active, value: condition(match[2]) }); active = active && stack.at(-1).value; }
    if (match[1] === 'else') { active = stack.at(-1).parent && !stack.at(-1).value; }
    if (match[1] === 'endif') { active = stack.pop().parent; }
  }
  assert.equal(stack.length, 0); return output.join('\n');
}
const symbols = new Set(['DEBUG', contract.flag]);
const validSettings = () => [{ target: 'Bex', buildSettings: {
  CONFIGURATION: 'UITesting', SWIFT_ACTIVE_COMPILATION_CONDITIONS: 'DEBUG BEX_UI_TEST_ARTIFACT',
  PRODUCT_BUNDLE_IDENTIFIER: contract.bundleID, PRODUCT_NAME: contract.executable,
  PRODUCT_MODULE_NAME: 'Bex', EXECUTABLE_NAME: contract.executable,
  INFOPLIST_FILE: 'Config/UITesting-Info.plist', GENERATE_INFOPLIST_FILE: 'NO', BEX_EMBED_NATIVE_WEB_RESOURCES: 'NO',
} }];
const validInfo = () => ({ CFBundleIdentifier: contract.bundleID,
  CFBundleExecutable: contract.executable, BexUITestArtifact: contract.marker });

test('all project configurations parse, dedicated identity inherits fixture compile discriminator', () => {
  const project = parseProject(read('Bex.xcodeproj/project.pbxproj'));
  const objects = project.objects;
  const configs = Object.values(objects).filter(o => o.isa === 'XCBuildConfiguration');
  assert.equal(configs.length, 18);
  for (const c of configs) { assert.ok(['Debug', 'Release', 'UITesting'].includes(c.name)); assert.equal(typeof c.buildSettings, 'object'); }
  assert.equal(objects.D80000000000000000000011.buildSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS,
    'DEBUG BEX_UI_TEST_ARTIFACT $(inherited)');
  const app = objects.D80000000000000000000021.buildSettings;
  assert.equal(app.INFOPLIST_FILE, 'Config/UITesting-Info.plist');
  assert.equal(app.PRODUCT_BUNDLE_IDENTIFIER, contract.bundleID);
  assert.equal(app.PRODUCT_NAME, contract.executable);
  assert.equal(app.PRODUCT_MODULE_NAME, 'Bex');
  for (const id of ['A00000000000000000000121', 'A00000000000000000000122']) {
    assert.equal(objects[id].buildSettings.PRODUCT_BUNDLE_IDENTIFIER, 'com.bex.desktop');
    assert.equal(objects[id].buildSettings.INFOPLIST_FILE, 'Config/Info.plist');
  }
  for (const list of Object.values(objects).filter(o => o.isa === 'XCConfigurationList')) {
    assert.deepEqual(list.buildConfigurations.map(id => objects[id].name).sort(), ['Debug', 'Release', 'UITesting']);
  }
});

test('both scheme TestActions select UITesting, ordinary Run/Archive remain normal', () => {
  const normal = read('Bex.xcodeproj/xcshareddata/xcschemes/Bex.xcscheme');
  const dedicated = read('Bex.xcodeproj/xcshareddata/xcschemes/BexUITesting.xcscheme');
  for (const scheme of [normal, dedicated]) assert.match(scheme, /<TestAction\s+buildConfiguration = "UITesting"/);
  assert.match(normal, /<LaunchAction\s+buildConfiguration = "Debug"/);
  assert.match(normal, /<ArchiveAction\s+buildConfiguration = "Release"/);
  assert.doesNotMatch(dedicated, /buildConfiguration = "(?:Debug|Release)"/);
  for (const file of ['BexTests/UITestScenarioContractTests.swift', 'BexUITests/BexUITests.swift']) {
    assert.match(read(file), /^#if !BEX_UI_TEST_ARTIFACT\s+#error/);
  }
  const runner = read('BexUITests/BexUITests.swift');
  assert.doesNotMatch(runner, /XCUIApplication\(\)/);
  assert.match(runner, /XCUIApplication\(bundleIdentifier: "com.bex.desktop.ui-validation"\)/);
});

test('dedicated compile branch removes live entry/factories; ordinary production retains them', () => {
  const fixtureDelegate = compiledSlice(delegate, symbols);
  assert.doesNotMatch(fixtureDelegate, /AppServices\.production\(|PreferencesStore\.standardAppearance\(/);
  assert.match(fixtureDelegate, /AppServices\.uiTesting\(/);
  const factory = compiledSlice(read('Bex/Application/AppServices.swift'), symbols);
  assert.match(factory, /fatalError\("A UI validation artifact cannot construct production services/);
  assert.doesNotMatch(factory, /let preferences = PreferencesStore\(\)|UNUserNotificationCenter\.current\(|StudyStatusFile\.write\(/);
  for (const normal of [new Set(), new Set(['DEBUG'])]) {
    assert.match(compiledSlice(delegate, normal), /AppServices\.production\(\)/);
    assert.match(compiledSlice(read('Bex/Application/AppServices.swift'), normal), /UNUserNotificationCenter\.current\(/);
    assert.doesNotMatch(compiledSlice(launch, normal), new RegExp(contract.stamp));
  }
});

test('compile identity dominates absent/forged metadata and runtime selectors', () => {
  assert.match(launch, /#if BEX_UI_TEST_ARTIFACT && !DEBUG\s+#error/);
  assert.match(launch, /guard artifactBuild else/);
  assert.ok(launch.indexOf('guard artifactBuild else') < launch.indexOf('guard debugBuild,'));
  assert.match(launch, /artifactMarker != nil/);
  assert.match(launch, /bundleIdentifier != "com.bex.desktop"/);
  assert.match(launch, /artifactMarker as\? String == artifactMarkerValue/);
  assert.doesNotMatch(launch, /guard requested else \{ return \.production \}/);
  assert.match(launch, /return manualTarget \? \.manualSystemTargetTesting : \.isolatedUITesting/);
  assert.ok(delegate.indexOf('guard mode != .rejectedUITesting') < delegate.indexOf('let app = NSApplication.shared'));
});

test('secondary executables are inert under test flag and artifact does not register URLs', () => {
  const hook = compiledSlice(read('BexHook/BexHookMain.swift'), symbols);
  const hookEntry = hook.slice(hook.indexOf('static func main() async {'), hook.indexOf('private static func runLegacy'));
  assert.match(hookEntry, /exit\(69\)/);
  assert.doesNotMatch(hookEntry, /runOMP|runLegacy|writeSelfCheck|CommandLine/);
  const accessibility = compiledSlice(read('BexAccessibilityHost/BexAccessibilityMain.swift'), symbols);
  const entry = accessibility.slice(accessibility.indexOf('static func main()'), accessibility.indexOf('@MainActor\nprivate final class'));
  assert.match(entry, /return/); assert.doesNotMatch(entry, /NSApplication|server\.start|setup\.show/);
  const info = read('Config/UITesting-Info.plist');
  assert.match(info, /<key>BexUITestArtifact<\/key>\s+<string>isolated-ui-v1<\/string>/);
  assert.doesNotMatch(info, /CFBundleURLTypes|CFBundleURLSchemes|LSEnvironment/);
});

test('build settings reject normal Debug, missing compile flag, wrong identity, plist or packaged host', () => {
  assert.doesNotThrow(() => validateBuildSettings(validSettings()));
  assert.throws(() => validateBuildSettings([]));
  for (const [key, value] of Object.entries({ CONFIGURATION: 'Debug', SWIFT_ACTIVE_COMPILATION_CONDITIONS: 'DEBUG',
    PRODUCT_BUNDLE_IDENTIFIER: 'com.bex.desktop', PRODUCT_NAME: 'Bex', PRODUCT_MODULE_NAME: 'BexUIValidation',
    EXECUTABLE_NAME: 'Bex', INFOPLIST_FILE: 'Config/Info.plist', GENERATE_INFOPLIST_FILE: 'YES', BEX_EMBED_NATIVE_WEB_RESOURCES: 'YES' })) {
    const values = validSettings(); values[0].buildSettings[key] = value;
    assert.throws(() => validateBuildSettings(values), key);
  }
  const values = validSettings(); values[0].buildSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS = 'BEX_UI_TEST_ARTIFACT';
  assert.throws(() => validateBuildSettings(values));
});

test('read-only artifact checks reject malformed/absent metadata and ordinary unstamped binary', () => {
  assert.doesNotThrow(() => validateBundleInfo(validInfo()));
  for (const marker of [undefined, null, false, 1, '', 'isolated-ui-v2', { marker: contract.marker }]) {
    assert.throws(() => validateBundleInfo({ ...validInfo(), BexUITestArtifact: marker }));
  }
  for (const key of ['CFBundleURLTypes', 'LSEnvironment']) assert.throws(() => validateBundleInfo({ ...validInfo(), [key]: {} }));
  assert.throws(() => validateBundleInfo({ ...validInfo(), CFBundleIdentifier: 'com.bex.desktop.manual-copy' }));
  assert.throws(() => validateCompiledStamp(Buffer.from(JSON.stringify(validInfo()))));
  assert.doesNotThrow(() => validateCompiledStamp(Buffer.from(contract.stamp)));
  // This stamp check is deliberately NOT a cryptographic or machine-code proof.
});

test('product hashes detect byte changes and reject escaping symlinks without mutation', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'bex-artifact-contract-'));
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'bex-artifact-outside-'));
  try {
    fs.writeFileSync(path.join(directory, 'binary'), 'fixture bytes');
    fs.writeFileSync(path.join(outside, 'sentinel'), 'keep');
    const before = artifactHashes(directory);
    fs.writeFileSync(path.join(directory, 'binary'), 'changed bytes');
    assert.notDeepEqual(artifactHashes(directory), before);
    fs.symlinkSync(path.join(outside, 'sentinel'), path.join(directory, 'escape'));
    assert.throws(() => artifactHashes(directory), /escapes/);
    assert.equal(fs.readFileSync(path.join(outside, 'sentinel'), 'utf8'), 'keep');
    fs.unlinkSync(path.join(directory, 'escape'));
    fs.symlinkSync('binary', path.join(directory, 'internal'));
    assert.equal(artifactHashes(directory).internal, 'symlink:binary');
  } finally { fs.rmSync(directory, { recursive: true }); fs.rmSync(outside, { recursive: true }); }
});

test('artifact recipe never executes inspected app, accepts overrides, or invents signing identity', () => {
  const script = read('scripts/bex-ui-test-artifact.mjs');
  assert.match(script, /build-for-testing/); assert.match(script, /test-without-building/);
  assert.match(script, /validateBuildSettings\(settings\)/);
  assert.match(script, /validateCompiledStamp\(readFileSync\(executable\)\)/);
  assert.doesNotMatch(script, /\n\s+run\(executable,|codesign|CODE_SIGN_IDENTITY|DEVELOPMENT_TEAM|\/usr\/bin\/open/);
  assert.match(script, /BEX_RUN_MANUAL_SYSTEM_TARGET_TEST/);
  assert.equal(relaunchTests.length, 7);
  assert.ok(relaunchTests.every(name => !name.includes('StandardAX')));
  assert.match(script, /relaunchTests\.map\(name => `-only-testing:/);
  assert.match(script, /build is not system-neutral/);
  if (process.platform !== 'darwin') {
    const result = spawnSync(process.execPath, [new URL('../bex-ui-test-artifact.mjs', import.meta.url).pathname, 'build'], { encoding: 'utf8' });
    assert.equal(result.status, 1); assert.match(result.stderr, /requires macOS and separate user approval/);
  }
});

test('native authored tests cover true zero-arg empty-env subprocess and repeated fixture UI relaunch', () => {
  const native = read('BexTests/UITestScenarioContractTests.swift');
  for (const expected of ['testArtifactMetadataMismatchNeverFallsThroughToProduction',
    'testNormalDebugAndReleaseRejectEveryTestSelectorAndMalformedVariant',
    'testExecutableRelaunchWithNoArgumentsAndEmptyEnvironmentReachesFixtures',
    'process.arguments = []', 'process.environment = [:]', 'BEX_UI_FIXTURE_READY_V1']) assert.ok(native.includes(expected));
  assert.match(delegate, /services\?\.runtimeEffects\.usesUITestingCommands == true[\s\S]*BEX_UI_FIXTURE_READY_V1/);
  const ui = read('BexUITests/BexUITests.swift');
  assert.match(ui, /testRelaunchWithoutArgumentsOrEnvironmentStaysInFixtureGraph/);
  assert.match(ui, /app\.launchArguments = \[\]\s+app\.launchEnvironment = \[:\]/);
});


test('test plans reject production/external hosts, stale Debug, escapes and restored manual flags', () => {
  const products = '/temporary-build/Build/Products';
  const target = name => ({ BlueprintName: name,
    TestHostPath: name === 'BexTests'
      ? '__TESTROOT__/UITesting/BexUIValidation.app/Contents/MacOS/BexUIValidation'
      : '__TESTROOT__/UITesting/BexUITests-Runner.app',
    TestBundlePath: `__TESTROOT__/UITesting/${name}.xctest`,
    ...(name === 'BexUITests' ? { UITargetAppPath: '__TESTROOT__/UITesting/BexUIValidation.app' } : {}),
    DependentProductPaths: ['__TESTROOT__/UITesting/BexUIValidation.app'],
  });
  const valid = () => ({ TestConfigurations: [{ TestTargets: [target('BexTests'), target('BexUITests')] }] });
  assert.doesNotThrow(() => validateTestPlan(valid(), products));
  assert.doesNotThrow(() => validateTestPlan({ BexTests: target('BexTests'), BexUITests: target('BexUITests') }, products));
  for (const wrong of ['/Applications/Bex.app/Contents/MacOS/Bex', '__TESTROOT__/Debug/Bex.app',
    '__TESTROOT__/../../Bex.app', '__PLATFORMS__/Bex.app']) {
    const plan = valid(); plan.TestConfigurations[0].TestTargets[0].TestHostPath = wrong;
    assert.throws(() => validateTestPlan(plan, products), wrong);
  }
  for (const key of ['TestBundlePath', 'UITargetAppPath']) {
    const plan = valid(); plan.TestConfigurations[0].TestTargets[1][key] = '/Applications/Bex.app';
    assert.throws(() => validateTestPlan(plan, products));
  }
  for (const environment of [{ BEX_RUN_MANUAL_SYSTEM_TARGET_TEST: '1' }, { BEX_UI_TEST_REAL_TARGET: '1' }]) {
    const plan = valid(); plan.TestConfigurations[0].TestTargets[1].EnvironmentVariables = environment;
    assert.throws(() => validateTestPlan(plan, products));
  }
  for (const [key, value] of Object.entries({ UseDestinationArtifacts: true,
    TestHostDestinationRelativePath: 'Bex.app', TestHostBundleIdentifier: 'com.bex.desktop',
    UITargetAppBundleIdentifier: 'com.bex.desktop', TestBundlePath: '__TESTROOT__/UITesting/Other.xctest',
    IsUITestBundle: false, IsAppHostedTestBundle: true, IsXCTRunnerHostedTestBundle: false })) {
    const plan = valid(); plan.TestConfigurations[0].TestTargets[1][key] = value;
    assert.throws(() => validateTestPlan(plan, products), key);
  }
  for (const value of [true, 1, 'YES', 'true', null]) {
    const plan = valid(); plan.TestConfigurations[0].TestTargets[0].UseDestinationArtifacts = value;
    assert.throws(() => validateTestPlan(plan, products));
  }
  const plan = valid(); plan.TestConfigurations[0].TestTargets[0].DependentProductPaths = ['/outside/Product'];
  assert.throws(() => validateTestPlan(plan, products));
});
