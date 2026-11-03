import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { auditNativeResources, nativeHTML, NATIVE_CSP } from '../bex-audit-native-resources.mjs';
import { packageNativeResources, verifyNativeResourcePackage, RESOURCE_DIRECTORY, MANIFEST_NAME } from '../bex-package-native-resources.mjs';

const script = 'native-abcdefgh.js';
const style = 'native-12345678.css';
const cli = fileURLToPath(new URL('../bex-package-native-resources.mjs', import.meta.url));
function fixture(t) {
  const parent = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'bex-resource-package-'));
  const root = path.join(parent, 'dist-native');
  fs.mkdirSync(root, { mode: 0o700 });
  fs.mkdirSync(path.join(root, 'assets'), { mode: 0o700 });
  fs.writeFileSync(path.join(root, 'native.html'), nativeHTML(script, style), { mode: 0o600 });
  fs.writeFileSync(path.join(root, 'assets', script), 'export const fixture = true;\n', { mode: 0o600 });
  fs.writeFileSync(path.join(root, 'assets', style), 'body { color: black; }\n', { mode: 0o600 });
  t.after(() => {
    if (fs.existsSync(root)) {
      fs.chmodSync(root, 0o700);
      if (fs.existsSync(path.join(root, 'assets')) && !fs.lstatSync(path.join(root, 'assets')).isSymbolicLink()) fs.chmodSync(path.join(root, 'assets'), 0o700);
    }
    fs.rmSync(parent, { recursive: true, force: true });
  });
  return { parent, root, output: path.join(parent, 'review'), html: path.join(root, 'native.html'), js: path.join(root, 'assets', script), css: path.join(root, 'assets', style) };
}
function snapshot(directory) {
  const result = [];
  function walk(folder, prefix = '') {
    for (const name of fs.readdirSync(folder).sort()) {
      const file = path.join(folder, name);
      const stat = fs.lstatSync(file);
      result.push({ path: prefix + name, mode: stat.mode & 0o7777, ...(stat.isDirectory() ? {} : { bytes: fs.readFileSync(file).toString('base64'), mtimeMs: stat.mtimeMs, ino: stat.ino }) });
      if (stat.isDirectory()) walk(file, `${prefix}${name}/`);
    }
  }
  walk(directory);
  return result;
}
function stableSnapshot(directory) {
  return snapshot(directory).map(({ mtimeMs, ino, ...entry }) => entry);
}
function run(...args) { return spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', timeout: 5000 }); }
function withPatched(method, replacement, operation) {
  const original = fs[method];
  fs[method] = (...args) => replacement(original, ...args);
  try { return operation(); } finally { fs[method] = original; }
}

test('copies only the audited inventory with deterministic bytes/modes and unchanged staging', t => {
  const { root, output, parent } = fixture(t);
  const before = snapshot(root);
  const expected = auditNativeResources(root);
  assert.deepEqual(packageNativeResources(root, output), expected);
  assert.deepEqual(verifyNativeResourcePackage(output), expected);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(output, MANIFEST_NAME))), expected);
  assert.deepEqual(snapshot(root), before);
  assert.deepEqual(fs.readdirSync(output).sort(), [RESOURCE_DIRECTORY, MANIFEST_NAME].sort());
  for (const entry of expected.inventory) {
    const source = path.join(root, entry.path);
    const dest = path.join(output, RESOURCE_DIRECTORY, entry.path);
    assert.deepEqual(fs.readFileSync(dest), fs.readFileSync(source));
    assert.notEqual(fs.statSync(dest).ino, fs.statSync(source).ino);
    assert.equal(fs.statSync(dest).nlink, 1);
    assert.equal(fs.statSync(dest).mode & 0o7777, 0o600);
  }
  const second = path.join(parent, 'review-two');
  packageNativeResources(root, second);
  assert.deepEqual(stableSnapshot(output), stableSnapshot(second));
  assert.equal(fs.statSync(output).mode & 0o7777, 0o700);
  assert.ok(!fs.readFileSync(path.join(output, MANIFEST_NAME), 'utf8').includes(parent));
});

test('read-only staging remains read-only; restrictive caller umask cannot change package modes', t => {
  const { root, html, js, css, output } = fixture(t);
  for (const file of [html, js, css]) fs.chmodSync(file, 0o444);
  fs.chmodSync(path.join(root, 'assets'), 0o555);
  fs.chmodSync(root, 0o555);
  const before = snapshot(root);
  const umask = process.umask(0o777);
  try { packageNativeResources(root, output); } finally { process.umask(umask); }
  verifyNativeResourcePackage(output);
  assert.deepEqual(snapshot(root), before);
  assert.equal(fs.statSync(root).mode & 0o7777, 0o555);
});

for (const description of ['existing directory', 'existing nonempty directory', 'existing file', 'existing symlink', 'missing parent']) test(`rejects ${description} without changing it`, t => {
  const { root, parent, output } = fixture(t);
  let target = output;
  if (description === 'existing directory') fs.mkdirSync(output);
  if (description === 'existing nonempty directory') { fs.mkdirSync(output); fs.writeFileSync(path.join(output, 'keep'), 'keep'); }
  if (description === 'existing file') fs.writeFileSync(output, 'keep');
  if (description === 'existing symlink') fs.symlinkSync(root, output);
  if (description === 'missing parent') target = path.join(output, 'child');
  const before = fs.lstatSync(parent).mtimeMs;
  assert.throws(() => packageNativeResources(root, target));
  assert.equal(fs.lstatSync(parent).mtimeMs, before);
  assert.equal(auditNativeResources(root).inventory.length, 3);
  if (description === 'existing nonempty directory') assert.equal(fs.readFileSync(path.join(output, 'keep'), 'utf8'), 'keep');
  if (description === 'existing file') assert.equal(fs.readFileSync(output, 'utf8'), 'keep');
  if (description === 'existing symlink') assert.ok(fs.lstatSync(output).isSymbolicLink());
});

test('rejects output within staging and never creates a partial subtree there', t => {
  const { root } = fixture(t);
  const before = snapshot(root);
  for (const target of [root, path.join(root, 'review'), path.join(root, 'assets', 'review')]) assert.throws(() => packageNativeResources(root, target), /outside staging/);
  assert.deepEqual(snapshot(root), before);
});

for (const suffix of ['Bex.app', 'Bex.APP', 'Bex.xcodeproj', 'Bex.xcworkspace', 'Bex.framework', 'Bex.bundle', 'Bex.appex', 'Applications', 'System', 'Library']) test(`rejects offline output under ${suffix}`, t => {
  const { root, parent } = fixture(t);
  const folder = path.join(parent, suffix);
  fs.mkdirSync(folder);
  assert.throws(() => packageNativeResources(root, path.join(folder, 'review')), /offline review|system or installation/);
  assert.deepEqual(fs.readdirSync(folder), []);
  assert.throws(() => packageNativeResources(root, path.join(parent, `new-${suffix}.app`)), /offline review/);
});

test('rejects system-root output before creation', t => {
  const { root } = fixture(t);
  assert.throws(() => packageNativeResources(root, '/usr/bex-review-must-not-exist'), /system or installation/);
});

const aliases = [p => `${p}/`, p => `${path.dirname(p)}//${path.basename(p)}`, p => `${path.dirname(p)}/./${path.basename(p)}`, p => `${path.dirname(p)}/../${path.basename(path.dirname(p))}/${path.basename(p)}`, p => `${p}\\alias`, p => `${p}\0alias`, p => `${p}.`, p => `${p} `, () => 'relative'];
for (const [index, alias] of aliases.entries()) test(`rejects path spelling alias ${index}`, t => {
  const { root, output, parent } = fixture(t);
  assert.throws(() => packageNativeResources(alias(root), output));
  assert.throws(() => packageNativeResources(root, alias(output)));
  assert.deepEqual(fs.readdirSync(parent), ['dist-native']);
});

for (const item of ['root', 'ancestor', 'assets', 'native.html', `assets/${script}`]) test(`rejects input symlink at ${item}`, t => {
  const { root, output, parent } = fixture(t);
  let input = root;
  if (item === 'root') { input = path.join(parent, 'alias'); fs.symlinkSync(root, input); }
  else if (item === 'ancestor') { fs.symlinkSync(parent, path.join(parent, 'alias')); input = path.join(parent, 'alias', 'dist-native'); }
  else { const source = path.join(root, item); const moved = path.join(parent, 'moved'); fs.renameSync(source, moved); fs.symlinkSync(moved, source); }
  assert.throws(() => packageNativeResources(input, output), /Symlink/);
  assert.ok(!fs.existsSync(output));
});

test('rejects output ancestor symlink without touching its destination', t => {
  const { root, output, parent } = fixture(t);
  fs.symlinkSync(parent, output);
  assert.throws(() => packageNativeResources(root, path.join(output, 'review')), /Symlink/);
  assert.deepEqual(fs.readdirSync(parent).sort(), ['dist-native', 'review']);
});

const rejectedInputs = {
  'missing script': ({ js }) => fs.unlinkSync(js),
  'extra file': ({ root }) => fs.writeFileSync(path.join(root, 'extra.txt'), 'extra'),
  'extra directory': ({ root }) => fs.mkdirSync(path.join(root, 'extra')),
  'second script': ({ root }) => fs.writeFileSync(path.join(root, 'assets', 'native-aaaaaaaa.js'), 'extra'),
  'CSP mismatch': ({ html }) => fs.writeFileSync(html, fs.readFileSync(html, 'utf8').replace(NATIVE_CSP, "default-src *")),
  'HTML mismatch': ({ html }) => fs.appendFileSync(html, '<script>bad()</script>'),
  'oversized resource': ({ js }) => fs.truncateSync(js, 16 * 1024 * 1024 + 1),
  'hard-linked resource': ({ js, parent }) => fs.linkSync(js, path.join(parent, 'hardlink')),
  'writable staging directory': ({ root }) => fs.chmodSync(root, 0o777),
  'writable assets directory': ({ root }) => fs.chmodSync(path.join(root, 'assets'), 0o770),
  'special staging directory': ({ root }) => fs.chmodSync(root, 0o1700),
};
for (const [name, mutate] of Object.entries(rejectedInputs)) test(`audit rejects ${name} before output is created`, t => {
  const f = fixture(t);
  mutate(f);
  assert.throws(() => packageNativeResources(f.root, f.output));
  assert.ok(!fs.existsSync(f.output));
});
for (const mode of [0o755, 0o664, 0o646, 0o4644, 0o2644, 0o1644]) test(`rejects source unsafe mode ${mode.toString(8)}`, t => {
  const { js, root, output } = fixture(t);
  fs.chmodSync(js, mode);
  assert.throws(() => packageNativeResources(root, output));
  assert.ok(!fs.existsSync(output));
});
test('rejects FIFO input promptly without opening a blocking stream', t => {
  const { js, root, output } = fixture(t);
  fs.unlinkSync(js);
  assert.equal(spawnSync('mkfifo', [js]).status, 0);
  const result = run('--dist-native', root, '--output', output);
  assert.equal(result.status, 1, result.stderr);
  assert.equal(result.error, undefined);
  assert.ok(!fs.existsSync(output));
});

for (const phase of ['resource', 'manifest']) test(`cleans up its fresh files after ${phase} write failure`, t => {
  const { root, output, parent } = fixture(t);
  fs.writeFileSync(path.join(parent, 'keep'), 'untouched');
  const before = snapshot(root);
  let count = 0;
  withPatched('writeFileSync', (original, ...args) => {
    count++;
    if ((phase === 'resource' && count === 2) || (phase === 'manifest' && count === 4)) {
      original(args[0], 'partial');
      throw new Error('Injected write failure');
    }
    return original(...args);
  }, () => assert.throws(() => packageNativeResources(root, output), /Injected write failure/));
  assert.ok(!fs.existsSync(output));
  assert.deepEqual(snapshot(root), before);
  assert.equal(fs.readFileSync(path.join(parent, 'keep'), 'utf8'), 'untouched');
});

test('failure cleanup leaves unexpected new files alone and explicitly reports incomplete cleanup', t => {
  const { root, output } = fixture(t);
  let count = 0;
  withPatched('writeFileSync', (original, ...args) => {
    if (++count === 2) { original(path.join(output, 'foreign.txt'), 'do not delete'); throw new Error('Injected write failure'); }
    return original(...args);
  }, () => assert.throws(() => packageNativeResources(root, output), /cleanup incomplete/));
  assert.deepEqual(fs.readdirSync(output), ['foreign.txt']);
  assert.equal(fs.readFileSync(path.join(output, 'foreign.txt'), 'utf8'), 'do not delete');
});

test('failure cleanup never follows a replaced package directory into an unrelated target', t => {
  const { root, output, parent } = fixture(t);
  const moved = path.join(parent, 'moved-owned-tree');
  let count = 0;
  withPatched('writeFileSync', (original, ...args) => {
    if (++count === 2) { fs.renameSync(output, moved); fs.symlinkSync(root, output); throw new Error('Injected replacement'); }
    return original(...args);
  }, () => assert.throws(() => packageNativeResources(root, output), /cleanup incomplete/));
  assert.equal(auditNativeResources(root).inventory.length, 3);
  assert.ok(fs.lstatSync(output).isSymbolicLink());
  assert.ok(fs.existsSync(moved));
});

test('detects source byte changes between audit and copy and removes only its output', t => {
  const { root, output, js } = fixture(t);
  let changed = false;
  withPatched('mkdirSync', (original, ...args) => {
    const value = original(...args);
    if (args[0] === output && !changed) { changed = true; fs.appendFileSync(js, '// mutation\n'); }
    return value;
  }, () => assert.throws(() => packageNativeResources(root, output), /bytes differ from the audit/));
  assert.ok(!fs.existsSync(output));
  assert.match(fs.readFileSync(js, 'utf8'), /mutation/);
});

test('detects copied byte corruption instead of trusting successful write calls', t => {
  const { root, output } = fixture(t);
  let count = 0;
  withPatched('writeFileSync', (original, ...args) => {
    if (++count === 1) return original(args[0], Buffer.concat([args[1], Buffer.from('/* corrupt */')]));
    return original(...args);
  }, () => assert.throws(() => packageNativeResources(root, output), /Copied resource inventory differs/));
  assert.ok(!fs.existsSync(output));
});

test('detects a source extra entry introduced after its bytes were copied', t => {
  const { root, output } = fixture(t);
  let count = 0;
  withPatched('writeFileSync', (original, ...args) => {
    const result = original(...args);
    if (++count === 3) original(path.join(root, 'extra.txt'), 'mutation');
    return result;
  }, () => assert.throws(() => packageNativeResources(root, output), /Unexpected file/));
  assert.ok(!fs.existsSync(output));
  assert.equal(fs.readFileSync(path.join(root, 'extra.txt'), 'utf8'), 'mutation');
});

const corruptPackages = {
  'changed resource': out => fs.appendFileSync(path.join(out, RESOURCE_DIRECTORY, 'assets', script), '// changed'),
  'changed manifest': out => fs.appendFileSync(path.join(out, MANIFEST_NAME), ' '),
  'extra top-level entry': out => fs.writeFileSync(path.join(out, 'extra.txt'), 'extra'),
  'extra resource entry': out => fs.writeFileSync(path.join(out, RESOURCE_DIRECTORY, 'extra.txt'), 'extra'),
  'missing manifest': out => fs.unlinkSync(path.join(out, MANIFEST_NAME)),
  'manifest hard link': out => fs.linkSync(path.join(out, MANIFEST_NAME), path.join(path.dirname(out), 'linked-manifest')),
  'manifest symlink': out => { const manifest = path.join(out, MANIFEST_NAME); const moved = path.join(path.dirname(out), 'moved-manifest'); fs.renameSync(manifest, moved); fs.symlinkSync(moved, manifest); },
  'resource hard link': out => fs.linkSync(path.join(out, RESOURCE_DIRECTORY, 'native.html'), path.join(path.dirname(out), 'linked-html')),
  'root mode': out => fs.chmodSync(out, 0o755),
  'resource directory mode': out => fs.chmodSync(path.join(out, RESOURCE_DIRECTORY), 0o755),
  'assets directory mode': out => fs.chmodSync(path.join(out, RESOURCE_DIRECTORY, 'assets'), 0o755),
  'resource mode': out => fs.chmodSync(path.join(out, RESOURCE_DIRECTORY, 'native.html'), 0o644),
  'manifest mode': out => fs.chmodSync(path.join(out, MANIFEST_NAME), 0o644),
  'oversized manifest': out => fs.truncateSync(path.join(out, MANIFEST_NAME), 64 * 1024 + 1),
};
for (const [name, mutate] of Object.entries(corruptPackages)) test(`read-only verification rejects ${name}`, t => {
  const { root, output } = fixture(t);
  packageNativeResources(root, output);
  mutate(output);
  const before = fs.lstatSync(output).mtimeMs;
  assert.throws(() => verifyNativeResourcePackage(output));
  assert.equal(fs.lstatSync(output).mtimeMs, before);
});

test('verify rejects a FIFO manifest promptly without opening a blocking stream', t => {
  const { root, output } = fixture(t);
  packageNativeResources(root, output);
  const manifest = path.join(output, MANIFEST_NAME);
  fs.unlinkSync(manifest);
  assert.equal(spawnSync('mkfifo', [manifest]).status, 0);
  const result = run('--verify', output);
  assert.equal(result.status, 1, result.stderr);
  assert.equal(result.error, undefined);
});

test('CLI requires explicit input/output, reports nonzero failures, creates and verifies offline', t => {
  const { root, output, parent } = fixture(t);
  for (const args of [[], ['--dist-native', root], ['--output', output], ['--dist-native', root, '--manifest', output], ['--dist-native', root, '--output', output, '--force'], ['--verify'], ['--verify', root, '--output', output]]) {
    const result = run(...args);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /Usage/);
  }
  assert.deepEqual(fs.readdirSync(parent), ['dist-native']);
  const packaged = run('--dist-native', root, '--output', output);
  assert.equal(packaged.status, 0, packaged.stderr);
  assert.deepEqual(JSON.parse(packaged.stdout), auditNativeResources(root));
  const verified = run('--verify', output);
  assert.equal(verified.status, 0, verified.stderr);
  assert.equal(verified.stdout, packaged.stdout);
  const before = stableSnapshot(output);
  const duplicate = run('--dist-native', root, '--output', output);
  assert.equal(duplicate.status, 1);
  assert.equal(duplicate.stdout, '');
  assert.deepEqual(stableSnapshot(output), before);
});

test('packager retains the auditors explicit semantic and runtime limits', t => {
  const { root, js, output } = fixture(t);
  fs.writeFileSync(js, 'fetch("https://example.invalid/");\n');
  const manifest = packageNativeResources(root, output);
  assert.match(manifest.limitations, /Does not prove JavaScript\/CSS semantics/);
  assert.match(manifest.limitations, /No runtime, signing, installation or activation performed/);
  assert.deepEqual(verifyNativeResourcePackage(output), manifest);
});

test('failed identity capture after directory creation preserves it and reports incomplete cleanup', t => {
  const { root, output } = fixture(t);
  let injected = false;
  withPatched('lstatSync', (original, ...args) => {
    if (args[0] === output && fs.existsSync(output) && !injected) {
      injected = true;
      throw new Error('Injected directory identity failure');
    }
    return original(...args);
  }, () => assert.throws(() => packageNativeResources(root, output), /Injected directory identity failure; cleanup incomplete.*Cannot identify owned directory/));
  assert.ok(injected);
  assert.deepEqual(fs.readdirSync(output), []);
});

test('failed identity capture after file creation preserves it and reports incomplete cleanup', t => {
  const { root, output } = fixture(t);
  let writtenFD;
  let writtenPath;
  let injected = false;
  withPatched('openSync', (original, ...args) => {
    const fd = original(...args);
    if (typeof args[1] === 'number' && (args[1] & fs.constants.O_CREAT)) { writtenFD = fd; writtenPath = args[0]; }
    return fd;
  }, () => withPatched('fstatSync', (original, ...args) => {
    if (args[0] === writtenFD && !injected) { injected = true; throw new Error('Injected file identity failure'); }
    return original(...args);
  }, () => assert.throws(() => packageNativeResources(root, output), /Injected file identity failure; cleanup incomplete.*Cannot identify owned path/)));
  assert.ok(injected);
  assert.ok(fs.existsSync(writtenPath));
  assert.equal(fs.readFileSync(writtenPath).length, 0);
  assert.equal(auditNativeResources(root).inventory.length, 3);
});
