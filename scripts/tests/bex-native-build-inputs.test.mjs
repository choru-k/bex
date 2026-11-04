// Cloud-only integration evidence. No Xcode, .app write, Swift, signing or launch.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { nativeHTML } from '../bex-audit-native-resources.mjs';
import { packageNativeResources, MANIFEST_NAME, RESOURCE_DIRECTORY } from '../bex-package-native-resources.mjs';
import { stageNativeBuildInputs, writeNativeResourceInputFileList, validateXcodeBuildContext } from '../bex-embed-native-resources.mjs';

const script = 'native-abcdefgh.js', style = 'native-12345678.css';
const repo = fileURLToPath(new URL('../../', import.meta.url)).replace(/\/$/, '');
const cli = path.join(repo, 'scripts/bex-embed-native-resources.mjs');
const shell = path.join(repo, 'scripts/bex-native-resource-build-phase.sh');
function fixture(t) {
  const parent = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'bex-build-inputs-'));
  const source = path.join(parent, 'staging'), pkg = path.join(parent, 'review'), output = path.join(parent, 'resources');
  fs.mkdirSync(source, { mode: 0o700 }); fs.mkdirSync(path.join(source, 'assets'), { mode: 0o700 });
  fs.writeFileSync(path.join(source, 'native.html'), nativeHTML(script, style), { mode: 0o600 });
  fs.writeFileSync(path.join(source, 'assets', script), 'export const value = 42;\n', { mode: 0o600 });
  fs.writeFileSync(path.join(source, 'assets', style), 'body { color: black; }\n', { mode: 0o600 });
  const manifest = packageNativeResources(source, pkg);
  fs.mkdirSync(output, { mode: 0o755 });
  fs.writeFileSync(path.join(output, 'other-resource.txt'), 'untouched');
  t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
  return { parent, source, pkg, output, manifest, digest: manifest.inventorySha256, list: path.join(parent, 'inputs.xcfilelist') };
}
function snapshot(folder) {
  return fs.readdirSync(folder).sort().flatMap(name => {
    const full = path.join(folder, name), stat = fs.lstatSync(full);
    return [{ name, mode: stat.mode & 0o7777, ino: stat.ino, size: stat.size, mtime: stat.mtimeMs, ...(stat.isFile() ? { bytes: fs.readFileSync(full).toString('base64') } : {}) }, ...(stat.isDirectory() ? snapshot(full).map(value => ({ ...value, name: `${name}/${value.name}` })) : [])];
  });
}
function patched(method, replacement, operation) {
  const original = fs[method];
  fs[method] = (...args) => replacement(original, ...args);
  try { return operation(); } finally { fs[method] = original; }
}
function runShell(env) {
  return spawnSync('/bin/sh', [shell], { env: { PATH: '/usr/bin:/bin', SRCROOT: repo, ...env }, encoding: 'utf8', timeout: 5000 });
}

test('copies exact pinned bytes with native-safe modes and preserves unrelated resources and inputs', t => {
  const f = fixture(t), before = snapshot(f.pkg), sibling = fs.statSync(path.join(f.output, 'other-resource.txt'));
  assert.deepEqual(stageNativeBuildInputs(f.pkg, f.output, f.digest), { inventorySha256: f.digest, copied: true });
  assert.deepEqual(snapshot(f.pkg), before);
  for (const entry of f.manifest.inventory) {
    const from = path.join(f.pkg, RESOURCE_DIRECTORY, entry.path), to = path.join(f.output, RESOURCE_DIRECTORY, entry.path);
    assert.deepEqual(fs.readFileSync(to), fs.readFileSync(from));
    assert.equal(fs.statSync(to).mode & 0o7777, 0o644);
    assert.equal(fs.statSync(to).nlink, 1);
    assert.notEqual(fs.statSync(to).ino, fs.statSync(from).ino);
  }
  assert.deepEqual(fs.readFileSync(path.join(f.output, MANIFEST_NAME)), fs.readFileSync(path.join(f.pkg, MANIFEST_NAME)));
  assert.equal(fs.statSync(path.join(f.output, RESOURCE_DIRECTORY)).mode & 0o7777, 0o755);
  assert.equal(fs.statSync(path.join(f.output, RESOURCE_DIRECTORY, 'assets')).mode & 0o7777, 0o755);
  assert.equal(fs.statSync(path.join(f.output, 'other-resource.txt')).ino, sibling.ino);
  const copied = snapshot(f.output);
  assert.equal(stageNativeBuildInputs(f.pkg, f.output, f.digest).copied, false);
  assert.deepEqual(snapshot(f.output), copied, 'exact incremental build must not rewrite or chmod outputs');
});

test('copy modes remain deterministic with a restrictive umask', t => {
  const f = fixture(t), mask = process.umask(0o777);
  try { stageNativeBuildInputs(f.pkg, f.output, f.digest); } finally { process.umask(mask); }
  assert.equal(fs.statSync(path.join(f.output, MANIFEST_NAME)).mode & 0o7777, 0o644);
  assert.equal(fs.statSync(path.join(f.output, RESOURCE_DIRECTORY)).mode & 0o7777, 0o755);
});

for (const digest of [undefined, '', '0'.repeat(64), 'A'.repeat(64), '../bad', 'a'.repeat(65)]) test(`rejects missing, malformed or different input pin: ${String(digest)}`, t => {
  const f = fixture(t), before = snapshot(f.output);
  assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, digest));
  assert.deepEqual(snapshot(f.output), before);
});

const mutations = {
  'manifest altered': f => fs.appendFileSync(path.join(f.pkg, MANIFEST_NAME), ' '),
  'resource altered': f => fs.appendFileSync(path.join(f.pkg, RESOURCE_DIRECTORY, 'assets', script), 'changed'),
  'missing manifest': f => fs.unlinkSync(path.join(f.pkg, MANIFEST_NAME)),
  'extra root entry': f => fs.writeFileSync(path.join(f.pkg, 'extra'), ''),
  'extra asset': f => fs.writeFileSync(path.join(f.pkg, RESOURCE_DIRECTORY, 'assets', 'extra'), ''),
  'unsafe package directory': f => fs.chmodSync(f.pkg, 0o777),
  'unsafe resource mode': f => fs.chmodSync(path.join(f.pkg, RESOURCE_DIRECTORY, 'native.html'), 0o664),
  'symlink resource': f => { const html = path.join(f.pkg, RESOURCE_DIRECTORY, 'native.html'); fs.unlinkSync(html); fs.symlinkSync(path.join(f.source, 'native.html'), html); },
  'hardlink resource': f => fs.linkSync(path.join(f.pkg, RESOURCE_DIRECTORY, 'native.html'), path.join(f.parent, 'linked')),
  'oversized resource': f => fs.truncateSync(path.join(f.pkg, RESOURCE_DIRECTORY, 'assets', script), 16 * 1024 * 1024 + 1),
  'oversized manifest': f => fs.truncateSync(path.join(f.pkg, MANIFEST_NAME), 64 * 1024 + 1),
  'oversized HTML': f => fs.truncateSync(path.join(f.pkg, RESOURCE_DIRECTORY, 'native.html'), 4097),
};
for (const [name, mutate] of Object.entries(mutations)) test(`rejects ${name} before writing any build output`, t => {
  const f = fixture(t), before = snapshot(f.output);
  mutate(f);
  assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest));
  assert.deepEqual(snapshot(f.output), before);
});

test('rejects FIFO inputs without waiting on a stream', t => {
  const f = fixture(t), html = path.join(f.pkg, RESOURCE_DIRECTORY, 'native.html');
  fs.unlinkSync(html);
  assert.equal(spawnSync('mkfifo', [html]).status, 0);
  assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest), /nonregular/);
});

for (const item of [RESOURCE_DIRECTORY, MANIFEST_NAME]) test(`rejects partial existing output ${item} without modifying it`, t => {
  const f = fixture(t);
  if (item === RESOURCE_DIRECTORY) fs.mkdirSync(path.join(f.output, item));
  else fs.writeFileSync(path.join(f.output, item), 'partial');
  const before = snapshot(f.output);
  assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest));
  assert.deepEqual(snapshot(f.output), before);
});

for (const mutation of ['bytes', 'extra', 'symlink', 'hardlink', 'mode']) test(`rejects stale existing output (${mutation}), with no repair`, t => {
  const f = fixture(t); stageNativeBuildInputs(f.pkg, f.output, f.digest);
  const file = path.join(f.output, RESOURCE_DIRECTORY, 'native.html');
  if (mutation === 'bytes') fs.appendFileSync(file, 'changed');
  if (mutation === 'extra') fs.writeFileSync(path.join(f.output, RESOURCE_DIRECTORY, 'unexpected'), 'keep');
  if (mutation === 'symlink') { fs.unlinkSync(file); fs.symlinkSync(path.join(f.source, 'native.html'), file); }
  if (mutation === 'hardlink') fs.linkSync(file, path.join(f.parent, 'linked'));
  if (mutation === 'mode') fs.chmodSync(file, 0o444);
  const before = snapshot(f.output);
  assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest));
  assert.deepEqual(snapshot(f.output), before);
});

test('rejects aliases, source overlap, missing output parents and output links', t => {
  const f = fixture(t), before = snapshot(f.pkg);
  fs.symlinkSync(f.output, path.join(f.parent, 'alias'));
  for (const target of [f.pkg, path.join(f.pkg, RESOURCE_DIRECTORY), f.parent, path.join(f.parent, 'alias'), `${f.output}/`, `${f.output}/../resources`, 'relative', path.join(f.parent, 'missing')]) assert.throws(() => stageNativeBuildInputs(f.pkg, target, f.digest));
  assert.deepEqual(snapshot(f.pkg), before);
});

test('offline staging refuses app, project and installation destinations before touching them', t => {
  const f = fixture(t);
  // No .app is created or copied into, even as a test fixture.
  for (const target of [path.join(f.parent, 'Bex.app'), path.join(f.parent, 'Bex.APP/Contents/Resources'), '/Applications/Bex.app', '/usr/resources']) assert.throws(() => stageNativeBuildInputs(f.pkg, target, f.digest));
  assert.deepEqual(fs.readdirSync(f.output), ['other-resource.txt']);
});

for (const write of [1, 2, 3, 4]) test(`bounded cleanup after write failure ${write} preserves unrelated resources`, t => {
  const f = fixture(t); let count = 0;
  patched('writeFileSync', (original, ...args) => {
    if (++count === write) { original(args[0], 'partial'); throw new Error('injected write failure'); }
    return original(...args);
  }, () => assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest), /injected write failure/));
  assert.deepEqual(fs.readdirSync(f.output), ['other-resource.txt']);
  assert.equal(fs.readFileSync(path.join(f.output, 'other-resource.txt'), 'utf8'), 'untouched');
});

test('cleanup leaves foreign entries untouched and reports incomplete output', t => {
  const f = fixture(t); let injected = false;
  patched('writeFileSync', (original, ...args) => {
    if (!injected) { injected = true; original(path.join(f.output, RESOURCE_DIRECTORY, 'foreign'), 'keep'); throw new Error('injected foreign entry'); }
    return original(...args);
  }, () => assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest), /cleanup incomplete/));
  assert.equal(fs.readFileSync(path.join(f.output, RESOURCE_DIRECTORY, 'foreign'), 'utf8'), 'keep');
});

test('copy verification catches write corruption and cleans only owned files', t => {
  const f = fixture(t); let injected = false;
  patched('writeFileSync', (original, ...args) => {
    if (!injected) { injected = true; return original(args[0], 'wrong'); }
    return original(...args);
  }, () => assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest), /stale or incomplete/));
  assert.deepEqual(fs.readdirSync(f.output), ['other-resource.txt']);
});

test('source changes during the copy invalidate output and trigger bounded cleanup', t => {
  const f = fixture(t); let injected = false;
  patched('writeFileSync', (original, ...args) => {
    const result = original(...args);
    if (!injected) { injected = true; original(path.join(f.pkg, RESOURCE_DIRECTORY, 'assets', script), 'changed'); }
    return result;
  }, () => assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest)));
  assert.deepEqual(fs.readdirSync(f.output), ['other-resource.txt']);
});

test('replacement of output ancestors is detected; cleanup does not follow it', t => {
  const f = fixture(t); let injected = false;
  const moved = path.join(f.parent, 'moved');
  patched('writeFileSync', (original, ...args) => {
    if (!injected) { injected = true; fs.renameSync(f.output, moved); fs.symlinkSync(f.source, f.output); throw new Error('injected replacement'); }
    return original(...args);
  }, () => assert.throws(() => stageNativeBuildInputs(f.pkg, f.output, f.digest), /cleanup incomplete/));
  assert.ok(fs.lstatSync(f.output).isSymbolicLink());
  assert.ok(fs.existsSync(path.join(f.source, 'native.html')));
  assert.ok(fs.existsSync(moved));
});

test('exclusive deterministic Xcode input list declares package and exact files only', t => {
  const f = fixture(t), before = snapshot(f.pkg);
  assert.deepEqual(writeNativeResourceInputFileList(f.pkg, f.list, f.digest), f.manifest);
  const lines = fs.readFileSync(f.list, 'utf8').trimEnd().split('\n');
  assert.deepEqual(lines, [f.pkg, ...f.manifest.inventory.map(entry => `${f.pkg}/${RESOURCE_DIRECTORY}/${entry.path}`), `${f.pkg}/${MANIFEST_NAME}`]);
  assert.equal(fs.statSync(f.list).mode & 0o7777, 0o600);
  assert.deepEqual(snapshot(f.pkg), before);
  assert.throws(() => writeNativeResourceInputFileList(f.pkg, f.list, f.digest), /EEXIST/);
  assert.throws(() => writeNativeResourceInputFileList(f.pkg, path.join(f.pkg, 'inside.xcfilelist'), f.digest), /outside the package/);
});

for (const name of ['x\n.xcfilelist', 'x#.xcfilelist', 'x$.xcfilelist', 'x\\.xcfilelist', 'x.xcfilelist ', 'x.txt']) test(`input list rejects Xcode syntax or invalid filename ${JSON.stringify(name)}`, t => {
  const f = fixture(t);
  assert.throws(() => writeNativeResourceInputFileList(f.pkg, path.join(f.parent, name), f.digest));
});

test('input list write failure removes only its own newly created output', t => {
  const f = fixture(t);
  patched('writeFileSync', (original, ...args) => { original(args[0], 'partial'); throw new Error('injected list failure'); },
    () => assert.throws(() => writeNativeResourceInputFileList(f.pkg, f.list, f.digest), /injected list failure/));
  assert.ok(!fs.existsSync(f.list));
});

test('disabled phase requires no Node and performs no writes; stale resources fail closed', t => {
  const f = fixture(t), before = snapshot(f.parent);
  const env = { BEX_EMBED_NATIVE_WEB_RESOURCES: 'NO', TARGET_BUILD_DIR: f.parent, UNLOCALIZED_RESOURCES_FOLDER_PATH: 'resources', BEX_NATIVE_NODE_PATH: '/does/not/exist' };
  let result = runShell(env);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(snapshot(f.parent), before);
  fs.symlinkSync('/does/not/exist', path.join(f.output, RESOURCE_DIRECTORY));
  result = runShell(env);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /remain in a disabled build/);
  assert.ok(fs.lstatSync(path.join(f.output, RESOURCE_DIRECTORY)).isSymbolicLink());
});

test('shell gate rejects unrecognized values, missing Node and injection-shaped executable names', t => {
  const f = fixture(t);
  for (const value of ['yes', 'true', '1', 'YES; touch unexpected']) {
    const result = runShell({ BEX_EMBED_NATIVE_WEB_RESOURCES: value });
    assert.equal(result.status, 1); assert.match(result.stderr, /exactly YES or NO/);
  }
  for (const node of ['', 'node', `${process.execPath}; touch ${f.parent}/unexpected`, '/does/not/exist']) {
    const result = runShell({ BEX_EMBED_NATIVE_WEB_RESOURCES: 'YES', BEX_NATIVE_NODE_PATH: node });
    assert.equal(result.status, 1);
    assert.ok(!fs.existsSync(path.join(f.parent, 'unexpected')));
  }
});

test('actual embedding is never run by these cloud tests; CLI is fail-closed on this platform', { skip: process.platform === 'darwin' }, t => {
  const f = fixture(t);
  const result = spawnSync(process.execPath, [cli, '--xcode-build-phase'], { env: { ...process.env, BEX_EMBED_NATIVE_WEB_RESOURCES: 'YES', BEX_NATIVE_RESOURCE_PACKAGE: f.pkg }, encoding: 'utf8', timeout: 5000 });
  assert.equal(result.status, 1); assert.match(result.stderr, /macOS-only/);
  assert.deepEqual(fs.readdirSync(f.output), ['other-resource.txt']);
});

test('context validator rejects unrelated targets, installation actions and caller-controlled destinations before copy', t => {
  const f = fixture(t);
  const base = { BEX_EMBED_NATIVE_WEB_RESOURCES: 'YES', ACTION: 'build', PROJECT_NAME: 'Bex', TARGET_NAME: 'Bex', PRODUCT_NAME: 'Bex', FULL_PRODUCT_NAME: 'Bex.app', WRAPPER_NAME: 'Bex.app', UNLOCALIZED_RESOURCES_FOLDER_PATH: 'Bex.app/Contents/Resources', DEPLOYMENT_LOCATION: 'NO', CONFIGURATION: 'Debug', SRCROOT: repo, PROJECT_DIR: repo, BUILD_DIR: f.parent, TARGET_BUILD_DIR: f.output, BUILT_PRODUCTS_DIR: f.output };
  for (const [key, value] of Object.entries({ BEX_EMBED_NATIVE_WEB_RESOURCES: 'NO', ACTION: 'install', TARGET_NAME: 'BexTests', PRODUCT_NAME: 'Other', WRAPPER_NAME: 'Other.app', UNLOCALIZED_RESOURCES_FOLDER_PATH: '../elsewhere', DEPLOYMENT_LOCATION: 'YES', CONFIGURATION: 'Unrecognized', PROJECT_DIR: f.parent, SRCROOT: f.parent, BUILT_PRODUCTS_DIR: f.parent, TARGET_BUILD_DIR: f.parent, BUILD_DIR: repo })) assert.throws(() => validateXcodeBuildContext({ ...base, [key]: value }));
  // The fast runner intentionally places TMPDIR inside the checkout. That fixture
  // must be rejected by containment before looking for a nonexistent app.
  const insideCheckout = f.parent === repo || f.parent.startsWith(`${repo}${path.sep}`);
  assert.throws(() => validateXcodeBuildContext(base), insideCheckout
    ? /Expected an isolated build-products directory outside the checkout/ : /ENOENT/);
  assert.equal(fs.existsSync(path.join(f.output, 'Bex.app')), false, 'no .app is created even for context tests');
});

test('project phase is opt-in, ordered after resources, always validates, and leaves host source untouched', () => {
  const project = fs.readFileSync(path.join(repo, 'Bex.xcodeproj/project.pbxproj'), 'utf8');
  const target = project.slice(project.indexOf('A00000000000000000000011 /* Bex */ = {'), project.indexOf('A00000000000000000000012 /* BexTests */ = {'));
  assert.ok(target.indexOf('/* Resources */') < target.indexOf('/* Embed Native Resources (Explicit Opt-In) */'));
  // Debug, Release and the dedicated UITesting app configuration all default OFF.
  assert.equal((project.match(/BEX_EMBED_NATIVE_WEB_RESOURCES = NO;/g) ?? []).length, 3);
  assert.doesNotMatch(project, /BEX_EMBED_NATIVE_WEB_RESOURCES = YES|ENABLE_USER_SCRIPT_SANDBOXING = NO/);
  const phase = project.slice(project.indexOf('/* Begin PBXShellScriptBuildPhase section */'), project.indexOf('/* End PBXShellScriptBuildPhase section */'));
  assert.match(phase, /alwaysOutOfDate = 1/);
  assert.match(phase, /BexNativeResourceScripts\.xcfilelist/);
  assert.match(phase, /\$\(BEX_NATIVE_RESOURCE_INPUT_FILE_LIST\)/);
  assert.match(phase, /\/BexWebUI/); assert.match(phase, /\/native-resource-manifest\.json/);
  assert.doesNotMatch(phase, /npm |npx |xcodebuild|codesign|curl |wget |eval /);
  assert.match(fs.readFileSync(path.join(repo, 'Bex/Application/WindowCoordinator.swift'), 'utf8'), /#if false\s+func showPackagedCorrection/);
  assert.doesNotMatch(fs.readFileSync(cli, 'utf8'), /child_process|execSync|spawnSync|rmSync|fetch\(/);
});
