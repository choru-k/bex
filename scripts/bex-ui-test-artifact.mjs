#!/usr/bin/env node
// Build/inspect trusted local artifacts only. Never launch an unknown candidate.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readdirSync, readlinkSync, realpathSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const contract = Object.freeze({
  configuration: 'UITesting', scheme: 'BexUITesting', flag: 'BEX_UI_TEST_ARTIFACT',
  bundleID: 'com.bex.desktop.ui-validation', marker: 'isolated-ui-v1',
  executable: 'BexUIValidation', stamp: 'BEX_COMPILED_UI_TEST_ARTIFACT_V1_7A8D4C62',
});
export const relaunchTests = Object.freeze([
  'BexTests/UITestScenarioContractTests/testLaunchSelectorsResolveOneFailClosedDebugMode',
  'BexTests/UITestScenarioContractTests/testRealTargetRequiresSeparateManualModeAndNeverUpgradesIsolatedLaunch',
  'BexTests/UITestScenarioContractTests/testArtifactMetadataMismatchNeverFallsThroughToProduction',
  'BexTests/UITestScenarioContractTests/testNormalDebugAndReleaseRejectEveryTestSelectorAndMalformedVariant',
  'BexTests/UITestScenarioContractTests/testCompiledHostHasDedicatedArtifactIdentityWithoutRuntimeSelectors',
  'BexTests/UITestScenarioContractTests/testExecutableRelaunchWithNoArgumentsAndEmptyEnvironmentReachesFixtures',
  'BexUITests/BexUITests/testRelaunchWithoutArgumentsOrEnvironmentStaysInFixtureGraph',
]);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const sourcePaths = ['Bex.xcodeproj/project.pbxproj',
  'Bex.xcodeproj/xcshareddata/xcschemes/Bex.xcscheme',
  'Bex.xcodeproj/xcshareddata/xcschemes/BexUITesting.xcscheme',
  'Config/UITesting-Info.plist', 'Bex/Application/AppLaunchMode.swift',
  'Bex/Application/AppDelegate.swift', 'Bex/Application/AppServices.swift',
  'Bex/Application/UITestingServices.swift', 'BexHook/BexHookMain.swift',
  'BexAccessibilityHost/BexAccessibilityMain.swift', 'BexUITests/BexUITests.swift',
  'BexTests/UITestScenarioContractTests.swift', 'scripts/bex-ui-test-artifact.mjs'];
function sourceHashes() {
  return Object.fromEntries(sourcePaths.map(p => [p, sha(readFileSync(path.join(root, p)))]));
}
function requireCondition(condition, reason) { if (!condition) throw new Error(reason); }
export function validateBuildSettings(entries) {
  const settings = entries.find(entry => entry.target === 'Bex')?.buildSettings;
  requireCondition(settings, 'Missing Bex build settings.');
  const flags = String(settings.SWIFT_ACTIVE_COMPILATION_CONDITIONS ?? '').split(/\s+/);
  requireCondition(settings.CONFIGURATION === contract.configuration && flags.includes('DEBUG')
    && flags.includes(contract.flag), 'This is not a compiled UI-test configuration.');
  requireCondition(settings.PRODUCT_BUNDLE_IDENTIFIER === contract.bundleID
    && settings.PRODUCT_NAME === contract.executable && settings.PRODUCT_MODULE_NAME === 'Bex'
    && settings.EXECUTABLE_NAME === contract.executable, 'Wrong validation product identity.');
  requireCondition(settings.INFOPLIST_FILE === 'Config/UITesting-Info.plist'
    && settings.GENERATE_INFOPLIST_FILE === 'NO', 'Wrong validation Info.plist input.');
  requireCondition(settings.BEX_EMBED_NATIVE_WEB_RESOURCES === 'NO', 'Packaged-host resources are not admitted.');
  return settings;
}
export function validateBundleInfo(info) {
  requireCondition(info.CFBundleIdentifier === contract.bundleID
    && info.CFBundleExecutable === contract.executable
    && info.BexUITestArtifact === contract.marker, 'Bundle is not the dedicated UI-test artifact.');
  requireCondition(!Object.hasOwn(info, 'CFBundleURLTypes')
    && !Object.hasOwn(info, 'LSEnvironment'), 'Validation bundle must not register URLs or restore runtime selectors.');
}
export function validateCompiledStamp(bytes) {
  requireCondition(bytes.includes(Buffer.from(contract.stamp)), 'Missing compiled-only artifact stamp; normal Debug is not a UI-test artifact.');
}
export function validateTestPlan(plan, products) {
  const targets = Array.isArray(plan.TestConfigurations)
    ? plan.TestConfigurations.flatMap(configuration => configuration.TestTargets ?? [])
    : Object.entries(plan).filter(([key, value]) => !key.startsWith('__') && value?.TestHostPath)
      .map(([name, value]) => ({ ...value, BlueprintName: value.BlueprintName ?? name }));
  requireCondition(targets.length === 2, 'Expected only the BexTests and BexUITests targets.');
  const seen = new Set();
  const base = path.resolve(products);
  function admitted(raw, host) {
    requireCondition(typeof raw === 'string', 'Missing product path in test plan.');
    let expanded = raw.replaceAll('__TESTROOT__', base);
    if (host) expanded = expanded.replaceAll('__TESTHOST__', host);
    requireCondition(!expanded.includes('__'), 'Unsupported test-plan path variable.');
    const resolved = path.resolve(expanded);
    requireCondition(resolved.startsWith(base + path.sep), 'Test plan points outside checked build products.');
    return resolved;
  }
  for (const target of targets) {
    const name = target.BlueprintName ?? target.TargetName;
    requireCondition(['BexTests', 'BexUITests'].includes(name) && !seen.has(name), 'Unexpected/duplicate test target.');
    seen.add(name);
    requireCondition((!Object.hasOwn(target, 'UseDestinationArtifacts') || target.UseDestinationArtifacts === false)
      && !Object.keys(target).some(key => key.includes('DestinationRelativePath')),
      'Destination-installed artifacts are not admitted.');
    if (Object.hasOwn(target, 'IsUITestBundle')) requireCondition(target.IsUITestBundle === (name === 'BexUITests'), 'Wrong UI test bundle kind.');
    if (Object.hasOwn(target, 'IsXCTRunnerHostedTestBundle')) requireCondition(target.IsXCTRunnerHostedTestBundle === (name === 'BexUITests'), 'Wrong runner-hosted test bundle kind.');
    if (Object.hasOwn(target, 'IsAppHostedTestBundle')) requireCondition(target.IsAppHostedTestBundle === (name === 'BexTests'), 'Wrong app-hosted test bundle kind.');
    const expectedHostID = name === 'BexTests' ? contract.bundleID : `${contract.bundleID}.uitests.xctrunner`;
    if (Object.hasOwn(target, 'TestHostBundleIdentifier')) requireCondition(target.TestHostBundleIdentifier === expectedHostID, 'Wrong test-host bundle identifier.');
    if (Object.hasOwn(target, 'UITargetAppBundleIdentifier')) requireCondition(name === 'BexUITests'
      && target.UITargetAppBundleIdentifier === contract.bundleID, 'Wrong UI target bundle identifier.');
    const host = admitted(target.TestHostPath);
    const expectedApp = name === 'BexTests' ? `${contract.executable}.app` : 'BexUITests-Runner.app';
    const expectedPrefix = path.join(base, contract.configuration, expectedApp);
    requireCondition(host === expectedPrefix || host === path.join(expectedPrefix, 'Contents', 'MacOS',
      name === 'BexTests' ? contract.executable : 'BexUITests-Runner'), 'Unexpected test-host executable.');
    const testBundle = admitted(target.TestBundlePath, expectedPrefix);
    requireCondition([path.join(base, contract.configuration, `${name}.xctest`),
      path.join(expectedPrefix, 'Contents', 'PlugIns', `${name}.xctest`)].includes(testBundle),
      'Unexpected test bundle path.');
    if (name === 'BexUITests') {
      requireCondition(admitted(target.UITargetAppPath) === path.join(base, contract.configuration,
        `${contract.executable}.app`), 'UI tests do not target the dedicated artifact.');
    }
    for (const product of target.DependentProductPaths ?? []) admitted(product, expectedPrefix);
    // No runner may restore a real-target lane or silently replace launch policy.
    const serialized = JSON.stringify(target);
    requireCondition(!/BEX_UI_TEST|BEX_RUN_MANUAL_SYSTEM_TARGET_TEST|--ui-testing-system-target/.test(serialized),
      'Runtime test selectors or manual system-target permission appeared in the generated plan.');
  }
  return targets;
}
export function artifactHashes(directory) {
  const base = realpathSync(directory), result = {};
  function visit(relative) {
    const full = path.join(base, relative), stat = lstatSync(full);
    if (stat.isSymbolicLink()) {
      const resolved = realpathSync(full);
      requireCondition(resolved.startsWith(base + path.sep), `Artifact symlink escapes product tree: ${relative}`);
      result[relative] = `symlink:${readlinkSync(full)}`;
    } else if (stat.isDirectory()) {
      for (const entry of readdirSync(full).sort()) visit(path.join(relative, entry));
    } else {
      requireCondition(stat.isFile(), `Non-file artifact: ${relative}`);
      result[relative] = sha(readFileSync(full));
    }
  }
  visit(''); return result;
}
function run(executable, args, capture = false) {
  // No manual system-target opt-in or injected BEX test selectors are inherited.
  const environment = Object.fromEntries(Object.entries(process.env).filter(([k]) =>
    !k.startsWith('BEX_UI_TEST') && k !== 'BEX_RUN_MANUAL_SYSTEM_TARGET_TEST'));
  const result = spawnSync(executable, args, { cwd: root, env: environment,
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit', encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.error) throw result.error;
  requireCondition(result.status === 0, `${path.basename(executable)} failed (${result.status}): ${result.stderr ?? ''}`);
  return result.stdout;
}
function plist(file) { return JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file], true)); }
function inspectProducts(derivedData) {
  const products = path.join(derivedData, 'Build', 'Products');
  // Validate the complete tree before reading any path through a bundle symlink.
  const hashes = artifactHashes(products);
  const app = path.join(products, contract.configuration, `${contract.executable}.app`);
  const infoFile = path.join(app, 'Contents', 'Info.plist');
  validateBundleInfo(plist(infoFile));
  const executable = path.join(app, 'Contents', 'MacOS', contract.executable);
  validateCompiledStamp(readFileSync(executable));
  const xctestruns = readdirSync(products).filter(name => name.endsWith('.xctestrun'));
  requireCondition(xctestruns.length === 1, 'Expected exactly one fresh build-for-testing xctestrun.');
  const xctestrun = path.join(products, xctestruns[0]);
  validateTestPlan(plist(xctestrun), products);
  return { products, app, xctestrun, hashes };
}
function same(a, b, message) { requireCondition(JSON.stringify(a) === JSON.stringify(b), message); }
export function main(args = process.argv.slice(2)) {
  const [command, receiptPath, ...extra] = args;
  if (command === 'help' || !command) {
    console.log('After separate Mac testing approval:\n  node scripts/bex-ui-test-artifact.mjs build\n  node scripts/bex-ui-test-artifact.mjs inspect /absolute/path/receipt.json\n  node scripts/bex-ui-test-artifact.mjs test /absolute/path/receipt.json\nBuild uses fresh temporary products and existing project signing settings. Xcode can still register apps, sign products, and change execution-policy state; build is not system-neutral.\nInspect never executes the candidate. This is wrong-artifact detection, not a sandbox or signed attestation.');
    return;
  }
  requireCondition(['build', 'inspect', 'test'].includes(command) && extra.length === 0,
    'Unknown command or unsupported arguments; manual build overrides are not admitted.');
  requireCondition(process.platform === 'darwin', 'Native artifact building/testing requires macOS and separate user approval. Portable guards run on Linux.');
  const source = sourceHashes();
  if (command === 'build') {
    requireCondition(!receiptPath, 'Build takes no overrides and always creates a fresh temporary directory.');
    const directory = mkdtempSync(path.join(realpathSync(tmpdir()), 'BexUIValidation-'));
    const derivedData = path.join(directory, 'DerivedData.noindex');
    const buildArgs = ['-project', path.join(root, 'Bex.xcodeproj'), '-scheme', contract.scheme,
      '-configuration', contract.configuration, '-destination', 'platform=macOS', '-derivedDataPath', derivedData];
    const settings = JSON.parse(run('/usr/bin/xcodebuild', [...buildArgs, '-showBuildSettings', '-json'], true));
    validateBuildSettings(settings);
    run('/usr/bin/xcodebuild', [...buildArgs, 'build-for-testing']);
    same(source, sourceHashes(), 'Contract sources changed during build; do not run this artifact.');
    const artifacts = inspectProducts(derivedData);
    const receipt = { version: 1, purpose: 'accidental-wrong-artifact-detection-only',
      contract, derivedData, source, xctestrun: artifacts.xctestrun, hashes: artifacts.hashes };
    const output = path.join(directory, 'receipt.json');
    writeFileSync(output, JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    console.log(`Built without launching: ${artifacts.app}\nReceipt: ${output}\nNative runtime behavior remains unverified until separately authorized tests run.`);
    return;
  }
  requireCondition(receiptPath && path.isAbsolute(receiptPath), 'Use an absolute receipt path from this build script.');
  const receipt = JSON.parse(readFileSync(receiptPath, 'utf8'));
  requireCondition(receipt.version === 1 && receipt.purpose === 'accidental-wrong-artifact-detection-only', 'Unsupported receipt.');
  same(receipt.contract, contract, 'Artifact contract mismatch.');
  same(receipt.source, source, 'Contract sources changed since this artifact was built. Rebuild it.');
  const artifacts = inspectProducts(receipt.derivedData);
  requireCondition(receipt.xctestrun === artifacts.xctestrun, 'Test plan changed.');
  same(receipt.hashes, artifacts.hashes, 'Build product bytes changed. Refusing test execution.');
  if (command === 'inspect') {
    console.log('Artifact identity and receipt hashes match. Candidate was not executed. This does not prove native isolation or authorize a Mac test.');
    return;
  }
  // Only exact products from the checked build-for-testing receipt. No rebuild,
  // command-line configuration override, arbitrary app path, or real-target lane.
  run('/usr/bin/xcodebuild', ['-xctestrun', artifacts.xctestrun, '-destination', 'platform=macOS',
    '-parallel-testing-enabled', 'NO', ...relaunchTests.map(name => `-only-testing:${name}`), 'test-without-building']);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
