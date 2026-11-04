import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { auditNativeResources, nativeHTML, NATIVE_CSP, writeManifest } from '../bex-audit-native-resources.mjs';

const script = 'native-abcdefgh.js';
const style = 'native-12345678.css';
function fixture(t) {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'bex-resource-audit-'));
  const root = path.join(parent, 'dist-native');
  fs.mkdirSync(path.join(root, 'assets'), { recursive: true });
  fs.writeFileSync(path.join(root, 'native.html'), nativeHTML(script, style));
  fs.writeFileSync(path.join(root, 'assets', script), 'export const fixture = true;\n');
  fs.writeFileSync(path.join(root, 'assets', style), 'body { color: black; }\n');
  t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
  return { root, parent, html: path.join(root, 'native.html') };
}

test('deterministic inventory hashes all bytes; default audit leaves staging unchanged', t => {
  const { root, html } = fixture(t);
  const before = fs.statSync(html);
  const first = auditNativeResources(root);
  assert.deepEqual(first, auditNativeResources(root));
  assert.equal(first.inventory.length, 3);
  assert.match(first.inventorySha256, /^[a-f0-9]{64}$/);
  assert.equal(fs.statSync(html).mtimeMs, before.mtimeMs);
  fs.appendFileSync(path.join(root, 'assets', script), '// changed\n');
  assert.notEqual(auditNativeResources(root).inventorySha256, first.inventorySha256);
});

const maliciousHTML = {
  'missing CSP': h => h.replace(`    <meta http-equiv="Content-Security-Policy" content="${NATIVE_CSP}" />\n`, ''),
  'weakened CSP': h => h.replace("script-src 'self'", "script-src 'self' 'unsafe-eval'"),
  'duplicate CSP': h => h.replace('<title>', `<meta http-equiv="Content-Security-Policy" content="default-src *"><title>`),
  'late CSP': h => h.replace(`    <meta http-equiv="Content-Security-Policy" content="${NATIVE_CSP}" />\n`, '').replace('</head>', `<meta http-equiv="Content-Security-Policy" content="${NATIVE_CSP}" /></head>`),
  'remote module': h => h.replace('./assets/' + script, 'https://evil.example/app.js'),
  'protocol-relative stylesheet': h => h.replace('./assets/' + style, '//evil.example/app.css'),
  'traversal': h => h.replace('./assets/' + script, './assets/../assets/' + script),
  'encoded traversal': h => h.replace('./assets/' + script, './%2e%2e/' + script),
  'entity URL': h => h.replace('./assets/' + script, '&#46;/assets/' + script),
  'query URL': h => h.replace('./assets/' + script, './assets/' + script + '?v=1'),
  'fragment URL': h => h.replace('./assets/' + script, './assets/' + script + '#x'),
  'inline script': h => h.replace('</body>', '<script>alert(1)</script></body>'),
  'inline style': h => h.replace('<div id="root">', '<div id="root" style="color:red">'),
  'inline event': h => h.replace('<body>', '<body onload="alert(1)">'),
  'duplicate attribute': h => h.replace('src="', 'src="https://evil.example/app.js" src="'),
  'duplicate module': h => h.replace('</head>', `<script type="module" crossorigin src="./assets/${script}"></script></head>`),
  'duplicate stylesheet': h => h.replace('</head>', `<link rel="stylesheet" crossorigin href="./assets/${style}"></head>`),
  'base': h => h.replace('</head>', '<base href="https://evil.example/"></head>'),
  'frame': h => h.replace('</body>', '<iframe src="about:blank"></iframe></body>'),
  'form': h => h.replace('</body>', '<form action="https://evil.example/"></form></body>'),
  'image': h => h.replace('</body>', '<img src="https://evil.example/"></body>'),
  'preload': h => h.replace('</head>', '<link rel="modulepreload" href="./assets/extra.js"></head>'),
  'HTML comment': h => h.replace('</head>', '<!-- alternate parser content --></head>'),
};
for (const [name, mutate] of Object.entries(maliciousHTML)) test(`rejects ${name}`, t => {
  const { root, html } = fixture(t);
  fs.writeFileSync(html, mutate(fs.readFileSync(html, 'utf8')));
  assert.throws(() => auditNativeResources(root), /template profile/);
});

for (const name of ['extra.js', 'assets/native-aaaaaaaa.js', 'assets/native-aaaaaaaa.css', '.DS_Store', 'assets/image.svg', 'assets/native-abcdefgh.js.map']) test(`rejects extra file ${name}`, t => {
  const { root } = fixture(t);
  fs.writeFileSync(path.join(root, name), 'extra');
  assert.throws(() => auditNativeResources(root));
});
for (const item of ['native.html', 'assets', `assets/${script}`]) test(`rejects symlink ${item}`, t => {
  const { root, parent } = fixture(t);
  const source = path.join(root, item);
  const outside = path.join(parent, 'outside');
  fs.renameSync(source, outside);
  fs.symlinkSync(outside, source);
  assert.throws(() => auditNativeResources(root), /Symlink/);
});
test('rejects symlink root and ancestor, traversal input and unexpected directory', t => {
  const { root, parent } = fixture(t);
  fs.symlinkSync(root, path.join(parent, 'alias'));
  assert.throws(() => auditNativeResources(path.join(parent, 'alias')), /Symlink/);
  fs.symlinkSync(parent, path.join(parent, 'ancestor'));
  assert.throws(() => auditNativeResources(path.join(parent, 'ancestor', 'dist-native')), /Symlink/);
  assert.throws(() => auditNativeResources(`${root}/../dist-native`), /dot segments/);
  fs.mkdirSync(path.join(root, 'unexpected'));
  assert.throws(() => auditNativeResources(root), /Unexpected directory/);
});
test('rejects executable mode and hard links', t => {
  const { root, parent } = fixture(t);
  const resource = path.join(root, 'assets', script);
  fs.chmodSync(resource, 0o755);
  assert.throws(() => auditNativeResources(root), /unsafe-mode/);
  fs.chmodSync(resource, 0o644);
  fs.linkSync(resource, path.join(parent, 'hard-link'));
  assert.throws(() => auditNativeResources(root), /hard-linked/);
});
test('rejects nonregular FIFO without blocking', t => {
  const { root } = fixture(t);
  const resource = path.join(root, 'assets', script);
  fs.unlinkSync(resource);
  const mkfifo = spawnSync('mkfifo', [resource]);
  assert.equal(mkfifo.status, 0);
  assert.throws(() => auditNativeResources(root), /Nonregular/);
});
test('manifest output is explicit, separate and exclusive, rejects aliases', t => {
  const { root, parent } = fixture(t);
  const manifest = auditNativeResources(root);
  const output = path.join(parent, 'manifest.json');
  assert.throws(() => writeManifest(manifest, path.join(root, 'manifest.json'), root), /outside staging/);
  writeManifest(manifest, output, root);
  assert.deepEqual(JSON.parse(fs.readFileSync(output, 'utf8')), manifest);
  assert.throws(() => writeManifest(manifest, output, root), /EEXIST/);
  fs.symlinkSync(output, path.join(parent, 'alias.json'));
  assert.throws(() => writeManifest(manifest, path.join(parent, 'alias.json'), root), /Symlink/);
  fs.symlinkSync(root, path.join(parent, 'alias-dir'));
  assert.throws(() => writeManifest(manifest, path.join(parent, 'alias-dir', 'manifest.json'), root), /Symlink/);
  assert.deepEqual(auditNativeResources(root), manifest);
});
test('CLI requires explicit input, fails closed and defaults to stdout', t => {
  const { root, parent } = fixture(t);
  const cli = fileURLToPath(new URL('../bex-audit-native-resources.mjs', import.meta.url));
  const run = (...args) => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8' });
  assert.equal(run().status, 1);
  assert.equal(run('--dist-native', root, '--unknown', 'x').status, 1);
  const result = run('--dist-native', root);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), auditNativeResources(root));
  assert.deepEqual(fs.readdirSync(parent), ['dist-native']);
});
test('native source CSP matches profile and default fixture remains without this policy', () => {
  const source = fs.readFileSync(new URL('../../web/native.html', import.meta.url), 'utf8');
  assert.ok(source.includes(`<meta charset="UTF-8" />\n    <meta http-equiv="Content-Security-Policy" content="${NATIVE_CSP}" />`));
  const fixtureHTML = fs.readFileSync(new URL('../../web/index.html', import.meta.url), 'utf8');
  assert.ok(!fixtureHTML.includes(NATIVE_CSP));
});

for (const mode of [0o664, 0o646, 0o4644, 0o2644, 0o1644]) test(`rejects unsafe mode ${mode.toString(8)}`, t => {
  const { root } = fixture(t);
  fs.chmodSync(path.join(root, 'assets', script), mode);
  assert.throws(() => auditNativeResources(root), /unsafe-mode/);
});
