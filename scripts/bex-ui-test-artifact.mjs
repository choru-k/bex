#!/usr/bin/env node
// Build/inspect trusted local artifacts only. Never launch an unknown candidate.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readdirSync, readlinkSync, realpathSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const contract = Object.freeze({
  configuration: 'UITesting', scheme: 'BexUITesting', flag: 'BEX_UI_TEST_ARTIFACT',
  bundleID: 'com.bex.desktop.ui-validation', marker: 'isolated-ui-v1',
  executable: 'BexUIValidation', stamp: 'BEX_COMPILED_UI_TEST_ARTIFACT_V1_7A8D4C62',
});
// Only this dedicated build lane may use local ad-hoc signing. No certificate,
// team, provisioning profile, caller-supplied signing flags or unsigned fallback.
export const signingSettings = Object.freeze({
  CODE_SIGN_IDENTITY: '-', CODE_SIGN_STYLE: 'Manual', DEVELOPMENT_TEAM: '',
  CODE_SIGNING_ALLOWED: 'YES', CODE_SIGNING_REQUIRED: 'YES',
  PROVISIONING_PROFILE: '', PROVISIONING_PROFILE_SPECIFIER: '', OTHER_CODE_SIGN_FLAGS: '', CODE_SIGN_KEYCHAIN: '',
});
export const signingArguments = Object.freeze(Object.entries(signingSettings).map(([key, value]) => `${key}=${value}`));
export const buildTargets = Object.freeze(['Bex', 'BexTests', 'BexUITests', 'bex-hook']);
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
export function validateBuildEnvironment(environment) {
  requireCondition(!Object.hasOwn(environment, 'XCODE_XCCONFIG_FILE') || environment.XCODE_XCCONFIG_FILE === '',
    'External XCODE_XCCONFIG_FILE overrides are not admitted.');
}
export function validateSigningSettings(entries, requiredTargets = buildTargets) {
  requireCondition(Array.isArray(entries) && entries.length > 0, 'Missing target build settings.');
  const seen = new Set();
  for (const entry of entries) {
    const name = entry?.target, settings = entry?.buildSettings;
    requireCondition(buildTargets.includes(name) && !seen.has(name) && settings
      && typeof settings === 'object' && !Array.isArray(settings), 'Unexpected, duplicate or malformed build target.');
    seen.add(name);
    requireCondition(settings.CONFIGURATION === contract.configuration, `Wrong configuration for ${name}.`);
    const conditions = typeof settings.SWIFT_ACTIVE_COMPILATION_CONDITIONS === 'string'
      ? settings.SWIFT_ACTIVE_COMPILATION_CONDITIONS.split(/\s+/) : [];
    requireCondition(conditions.includes('DEBUG') && conditions.includes(contract.flag),
      `Missing compiled UI-test discriminator for ${name}.`);
    for (const [key, value] of Object.entries(signingSettings)) {
      // Xcode can omit an empty setting from its JSON. An absent nonempty value
      // is never accepted; unresolved variables and certificate names also fail.
      const actual = Object.hasOwn(settings, key) ? settings[key] : '';
      requireCondition(actual === value, `Non-ad-hoc signing setting ${key} for ${name}.`);
    }
    for (const key of ['EXPANDED_CODE_SIGN_IDENTITY', 'EXPANDED_CODE_SIGN_IDENTITY_NAME']) {
      const allowed = key === 'EXPANDED_CODE_SIGN_IDENTITY' ? ['', '-'] : ['', '-', 'Sign to Run Locally'];
      requireCondition(allowed.includes(Object.hasOwn(settings, key) ? settings[key] : ''), `Certificate identity resolved for ${name}.`);
    }
    if (['Bex', 'bex-hook'].includes(name)) {
      requireCondition(settings.ENABLE_HARDENED_RUNTIME === 'YES', `Hardened runtime is required for ${name}.`);
    }
  }
  for (const target of requiredTargets) requireCondition(seen.has(target), `Missing ${target} build settings.`);
  return entries;
}
export function validateBuildSettings(entries) {
  validateSigningSettings(entries);
  const settings = entries.find(entry => entry.target === 'Bex')?.buildSettings;
  requireCondition(settings, 'Missing Bex build settings.');
  requireCondition(settings.PRODUCT_BUNDLE_IDENTIFIER === contract.bundleID
    && settings.PRODUCT_NAME === contract.executable && settings.PRODUCT_MODULE_NAME === 'Bex'
    && settings.EXECUTABLE_NAME === contract.executable, 'Wrong validation product identity.');
  requireCondition(settings.INFOPLIST_FILE === 'Config/UITesting-Info.plist'
    && settings.GENERATE_INFOPLIST_FILE === 'NO', 'Wrong validation Info.plist input.');
  requireCondition(settings.BEX_EMBED_NATIVE_WEB_RESOURCES === 'NO', 'Packaged-host resources are not admitted.');
  return settings;
}
export function validateAdHocSignature(display, identifier, hardenedRuntime = false) {
  requireCondition(typeof display === 'string', 'Missing code-signature display.');
  const values = key => display.split(/\r?\n/).filter(line => line.startsWith(`${key}=`)).map(line => line.slice(key.length + 1));
  requireCondition(JSON.stringify(values('Signature')) === '["adhoc"]'
    && JSON.stringify(values('TeamIdentifier')) === '["not set"]'
    && JSON.stringify(values('Identifier')) === JSON.stringify([identifier])
    && values('Authority').length === 0, 'Product is not the expected teamless ad-hoc signature.');
  const flags = [...display.matchAll(/^CodeDirectory\s+[^\r\n]*\bflags=0x[0-9a-f]+\(([^)]*)\)/gmi)];
  requireCondition(flags.length === 1 && flags[0][1].split(',').includes('adhoc')
    && (!hardenedRuntime || flags[0][1].split(',').includes('runtime')), 'Unsupported or weakened code-signature flags.');
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
function run(executable, args, capture = false, includeStderr = false) {
  // No manual system-target opt-in or injected BEX test selectors are inherited.
  const environment = Object.fromEntries(Object.entries(process.env).filter(([k]) =>
    !k.startsWith('BEX_UI_TEST') && k !== 'BEX_RUN_MANUAL_SYSTEM_TARGET_TEST'));
  const result = spawnSync(executable, args, { cwd: root, env: environment,
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit', encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.error) throw result.error;
  requireCondition(result.status === 0, `${path.basename(executable)} failed (${result.status}): ${result.stderr ?? ''}`);
  return includeStderr ? `${result.stdout ?? ''}\n${result.stderr ?? ''}` : result.stdout;
}
function plist(file) { return JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file], true)); }
export function inspectSignature(product, executable, identifier, hardenedRuntime = false, command = run) {
  // These are read-only Apple tool operations, not an execution of the product.
  // Inspect every architecture rather than trusting the host-selected slice.
  const architectures = command('/usr/bin/lipo', ['-archs', executable], true).trim().split(/\s+/);
  requireCondition(architectures.length > 0 && new Set(architectures).size === architectures.length
    && architectures.every(arch => ['arm64', 'arm64e', 'x86_64'].includes(arch)), 'Unsupported product architectures.');
  for (const architecture of architectures) {
    const display = command('/usr/bin/codesign', ['--display', '--verbose=4', '--arch', architecture, product], true, true);
    validateAdHocSignature(display, identifier, hardenedRuntime);
  }
  command('/usr/bin/codesign', ['--verify', '--strict', '--all-architectures', product], true);
}
function inspectProductSignatures(products, targets) {
  const directory = path.join(products, contract.configuration);
  const app = path.join(directory, `${contract.executable}.app`);
  const runner = path.join(directory, 'BexUITests-Runner.app');
  inspectSignature(app, path.join(app, 'Contents', 'MacOS', contract.executable), contract.bundleID, true);
  for (const helper of [path.join(directory, 'bex-hook'), path.join(app, 'Contents', 'Helpers', 'bex-hook')]) {
    inspectSignature(helper, helper, 'bex-hook', true);
  }
  inspectSignature(runner, path.join(runner, 'Contents', 'MacOS', 'BexUITests-Runner'), `${contract.bundleID}.uitests.xctrunner`);
  for (const target of targets) {
    const name = target.BlueprintName ?? target.TargetName;
    const host = name === 'BexTests' ? app : runner;
    // validateTestPlan has already constrained these exact paths and variables.
    const selected = path.resolve(target.TestBundlePath.replaceAll('__TESTROOT__', products).replaceAll('__TESTHOST__', host));
    const bundles = new Set([selected, ...[path.join(directory, `${name}.xctest`),
      path.join(host, 'Contents', 'PlugIns', `${name}.xctest`)].filter(existsSync)]);
    for (const bundle of bundles) {
      inspectSignature(bundle, path.join(bundle, 'Contents', 'MacOS', name),
        `${contract.bundleID}.${name === 'BexTests' ? 'tests' : 'uitests'}`);
    }
  }
  // Do not demand ad-hoc signatures from Apple-supplied XCTest frameworks.
}
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
  const targets = validateTestPlan(plist(xctestrun), products);
  inspectProductSignatures(products, targets);
  return { products, app, xctestrun, hashes };
}
function same(a, b, message) { requireCondition(JSON.stringify(a) === JSON.stringify(b), message); }
export function main(args = process.argv.slice(2)) {
  const [command, receiptPath, ...extra] = args;
  if (command === 'help' || !command) {
    console.log('After separate Mac testing approval:\n  node scripts/bex-ui-test-artifact.mjs build\n  node scripts/bex-ui-test-artifact.mjs inspect /absolute/path/receipt.json\n  node scripts/bex-ui-test-artifact.mjs test /absolute/path/receipt.json\nBuild pins teamless ad-hoc signing in fresh temporary products, with no certificate or unsigned fallback. Xcode can still register apps and add execution-policy exceptions; build is not system-neutral. LaunchServices registration approval does not cover execution-policy exceptions. Do not build until those effects are approved; do not disable security tooling to bypass a blocker.\nInspect reads and verifies signatures without executing or re-signing the candidate. This is wrong-artifact detection, not a sandbox or signed attestation.');
    return;
  }
  requireCondition(['build', 'inspect', 'test'].includes(command) && extra.length === 0,
    'Unknown command or unsupported arguments; manual build overrides are not admitted.');
  requireCondition(process.platform === 'darwin', 'Native artifact building/testing requires macOS and separate user approval. Portable guards run on Linux.');
  validateBuildEnvironment(process.env);
  const source = sourceHashes();
  if (command === 'build') {
    requireCondition(!receiptPath, 'Build takes no overrides and always creates a fresh temporary directory.');
    const directory = mkdtempSync(path.join(realpathSync(tmpdir()), 'BexUIValidation-'));
    const derivedData = path.join(directory, 'DerivedData.noindex');
    const commonArgs = ['-project', path.join(root, 'Bex.xcodeproj'), '-configuration', contract.configuration,
      '-sdk', 'macosx', ...signingArguments];
    const buildArgs = [...commonArgs, '-scheme', contract.scheme,
      '-destination', 'platform=macOS', '-derivedDataPath', derivedData];
    const settings = JSON.parse(run('/usr/bin/xcodebuild', [...buildArgs, '-showBuildSettings', '-json'], true));
    validateSigningSettings(settings, ['Bex']);
    // Scheme settings may omit dependencies or test targets. Query only those
    // known missing targets, with the same configuration/SDK/signing pins, before
    // any build. No independent Accessibility target is built by this lane.
    for (const target of buildTargets.filter(name => !settings.some(entry => entry.target === name))) {
      const missing = JSON.parse(run('/usr/bin/xcodebuild', [...commonArgs, '-target', target, '-showBuildSettings', '-json'], true));
      validateSigningSettings(missing, [target]);
      requireCondition(missing.length === 1 && missing[0].target === target, 'Unsupported per-target settings layout.');
      settings.push(missing[0]);
    }
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
