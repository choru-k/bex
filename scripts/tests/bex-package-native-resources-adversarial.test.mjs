import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { auditNativeResources, nativeHTML } from '../bex-audit-native-resources.mjs';
import { packageNativeResources, verifyNativeResourcePackage, RESOURCE_DIRECTORY, MANIFEST_NAME } from '../bex-package-native-resources.mjs';

const script = 'native-abcdefgh.js';
const style = 'native-12345678.css';
const cli = fileURLToPath(new URL('../bex-package-native-resources.mjs', import.meta.url));
function fixture(t) {
  const parent = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'bex-package-adversarial-'));
  const root = path.join(parent, 'staging');
  fs.mkdirSync(root, { mode: 0o700 });
  fs.mkdirSync(path.join(root, 'assets'), { mode: 0o700 });
  fs.writeFileSync(path.join(root, 'native.html'), nativeHTML(script, style), { mode: 0o600 });
  fs.writeFileSync(path.join(root, 'assets', script), 'export const trusted = false;\n', { mode: 0o600 });
  fs.writeFileSync(path.join(root, 'assets', style), 'body { color: black; }\n', { mode: 0o600 });
  // This recursive cleanup is confined to the test-owned fixture; the production
  // cleanup is separately checked to use only unlink and empty-directory rmdir.
  t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
  return { parent, root, output: path.join(parent, 'review'), js: path.join(root, 'assets', script) };
}
function withPatched(method, replacement, operation) {
  const original = fs[method];
  fs[method] = (...args) => replacement(original, ...args);
  try { return operation(); } finally { fs[method] = original; }
}

for (const mutation of ['shrink', 'grow', 'mode', 'hardlink']) test(`bounded copy rejects source ${mutation} during its read`, t => {
  const { parent, root, output, js } = fixture(t);
  const sourceIdentity = fs.statSync(js);
  let injected = false;
  withPatched('readSync', (original, ...args) => {
    const count = original(...args);
    const current = fs.fstatSync(args[0]);
    if (!injected && fs.existsSync(output) && current.dev === sourceIdentity.dev && current.ino === sourceIdentity.ino) {
      injected = true;
      if (mutation === 'shrink') fs.truncateSync(js, 0);
      if (mutation === 'grow') fs.appendFileSync(js, 'growth');
      if (mutation === 'mode') fs.chmodSync(js, 0o644);
      if (mutation === 'hardlink') fs.linkSync(js, path.join(parent, 'linked-source'));
    }
    return count;
  }, () => assert.throws(() => packageNativeResources(root, output), /File changed while reading/));
  assert.ok(injected, 'mutation reached the bounded copy read');
  assert.ok(!fs.existsSync(output));
});

test('cleanup preserves a replaced owned regular file and reports incomplete output', t => {
  const { parent, root, output } = fixture(t);
  const saved = path.join(parent, 'saved-owned-file');
  const replacement = path.join(output, RESOURCE_DIRECTORY, 'assets', style);
  let count = 0;
  withPatched('writeFileSync', (original, ...args) => {
    if (++count === 2) {
      fs.renameSync(replacement, saved);
      original(replacement, 'unrelated replacement', { mode: 0o600 });
      throw new Error('Injected owned-file replacement');
    }
    return original(...args);
  }, () => assert.throws(() => packageNativeResources(root, output), /cleanup incomplete/));
  assert.equal(fs.readFileSync(replacement, 'utf8'), 'unrelated replacement');
  assert.ok(fs.existsSync(saved));
  assert.equal(auditNativeResources(root).inventory.length, 3);
});

test('cleanup preserves an owned nested directory replaced by a symlink', t => {
  const { parent, root, output, js } = fixture(t);
  const originalBytes = fs.readFileSync(js);
  const assets = path.join(output, RESOURCE_DIRECTORY, 'assets');
  const moved = path.join(parent, 'saved-owned-assets');
  let count = 0;
  withPatched('writeFileSync', (original, ...args) => {
    if (++count === 2) {
      fs.renameSync(assets, moved);
      fs.symlinkSync(path.join(root, 'assets'), assets);
      throw new Error('Injected owned-directory replacement');
    }
    return original(...args);
  }, () => assert.throws(() => packageNativeResources(root, output), /cleanup incomplete/));
  assert.ok(fs.lstatSync(assets).isSymbolicLink());
  assert.ok(fs.existsSync(moved));
  assert.deepEqual(fs.readFileSync(js), originalBytes);
  assert.equal(auditNativeResources(root).inventory.length, 3);
});

test('handled failure cleanup never invokes recursive filesystem removal', t => {
  const { root, output } = fixture(t);
  withPatched('rmSync', () => { throw new Error('Recursive removal is forbidden'); }, () => {
    withPatched('writeFileSync', () => { throw new Error('Injected write failure'); }, () => {
      assert.throws(() => packageNativeResources(root, output), /^Error: Injected write failure$/);
    });
  });
  assert.ok(!fs.existsSync(output));
});

for (const kind of ['fifo', 'directory', 'symlink']) test(`verification rejects ${kind} resource without blocking or mutating it`, t => {
  const { root, output } = fixture(t);
  packageNativeResources(root, output);
  const resource = path.join(output, RESOURCE_DIRECTORY, 'assets', script);
  fs.unlinkSync(resource);
  if (kind === 'fifo') assert.equal(spawnSync('mkfifo', [resource]).status, 0);
  if (kind === 'directory') fs.mkdirSync(resource);
  if (kind === 'symlink') fs.symlinkSync(path.join(root, 'assets', script), resource);
  const before = fs.lstatSync(resource);
  const result = spawnSync(process.execPath, [cli, '--verify', output], { encoding: 'utf8', timeout: 5000 });
  assert.equal(result.status, 1, result.stderr);
  assert.equal(result.error, undefined);
  const after = fs.lstatSync(resource);
  assert.equal(after.ino, before.ino);
  assert.equal(after.mode, before.mode);
  assert.equal(after.mtimeMs, before.mtimeMs);
});

test('verification is read-only even when the manifest is a directory', t => {
  const { root, output } = fixture(t);
  packageNativeResources(root, output);
  const manifest = path.join(output, MANIFEST_NAME);
  fs.unlinkSync(manifest);
  fs.mkdirSync(manifest, { mode: 0o700 });
  fs.writeFileSync(path.join(manifest, 'keep'), 'unrelated file');
  assert.throws(() => verifyNativeResourcePackage(output));
  assert.equal(fs.readFileSync(path.join(manifest, 'keep'), 'utf8'), 'unrelated file');
});

test('verification checks integrity, not authenticity of a consistently replaced resource and manifest', t => {
  const { root, output } = fixture(t);
  const original = packageNativeResources(root, output);
  const resources = path.join(output, RESOURCE_DIRECTORY);
  fs.appendFileSync(path.join(resources, 'assets', script), 'fetch("https://example.invalid/");\n');
  const replacement = auditNativeResources(resources);
  fs.writeFileSync(path.join(output, MANIFEST_NAME), `${JSON.stringify(replacement, null, 2)}\n`);
  assert.notEqual(original.inventorySha256, replacement.inventorySha256);
  assert.deepEqual(verifyNativeResourcePackage(output), replacement);
});
