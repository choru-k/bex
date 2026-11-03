// Synthetic offline fixtures and installed-Node child tools only. No native build/app writes.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { nativeHTML } from '../bex-audit-native-resources.mjs';
import { packageNativeResources } from '../bex-package-native-resources.mjs';
import { stageNativeBuildInputs, writeNativeResourceInputFileList } from '../bex-embed-native-resources.mjs';
import { prepareNativeResources } from '../bex-prepare-native-resources.mjs';
import { SOURCE_FILES, SOURCE_RECEIPT_NAME, BUILD_COMMANDS, BUILD_ENVIRONMENT, canonicalBytes, captureSourceSnapshot, captureBuildInputs, verifyNativeSourceBinding } from '../bex-native-source-binding.mjs';

const jsName = 'native-abcdefgh.js', cssName = 'native-12345678.css';
const repo = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
function write(file, bytes, mode = 0o644) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes, { mode }); }
function fixture(t, { tscMutation = '', viteFailure = '', tscFailure = '' } = {}) {
  const parent = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'bex-source-binding-'));
  const root = path.join(parent, 'checkout'), output = path.join(parent, 'prepared');
  fs.mkdirSync(root, { mode: 0o700 });
  for (const file of SOURCE_FILES) write(path.join(root, file), `${file}\n`);
  write(path.join(root, '.node-version'), `${process.versions.node}\n`);
  for (const name of ['package.json', 'package-lock.json', 'tsconfig.json', 'vite.native.config.ts', 'native.html']) write(path.join(root, 'web', name), `${name}\n`);
  write(path.join(root, 'web/src/main.ts'), 'export const fixture = true;\n');
  write(path.join(root, 'web/node_modules/typescript/package.json'), '{"name":"typescript","version":"0.0.0-fixture","type":"commonjs"}\n');
  write(path.join(root, 'web/node_modules/vite/package.json'), '{"name":"vite","version":"0.0.0-fixture","type":"commonjs"}\n');
  write(path.join(root, 'web/node_modules/payload.js'), 'exports.fixture = true;\n');
  const trace = path.join(parent, 'commands.jsonl');
  write(path.join(root, 'web/node_modules/typescript/bin/tsc'), `const fs = require('node:fs');\nfs.appendFileSync(${JSON.stringify(trace)}, JSON.stringify({tool:'tsc', args:process.argv.slice(2), env:process.env})+'\\n');\n${tscMutation}\n${tscFailure}\n`);
  write(path.join(root, 'web/node_modules/vite/bin/vite.js'), `const fs = require('node:fs'); const path = require('node:path');\nfs.appendFileSync(${JSON.stringify(trace)}, JSON.stringify({tool:'vite',args:process.argv.slice(2),env:process.env})+'\\n');\nconst out = process.argv[process.argv.indexOf('--outDir')+1];\nfs.mkdirSync(path.join(out,'assets'), {mode:0o755});\nfs.writeFileSync(path.join(out,'native.html'),${JSON.stringify(nativeHTML(jsName, cssName))}, {mode:0o644});\nfs.writeFileSync(path.join(out,'assets',${JSON.stringify(jsName)}),'export const fixture = true;\\n', {mode:0o644});\nfs.writeFileSync(path.join(out,'assets',${JSON.stringify(cssName)}),'body { color: black; }\\n', {mode:0o644});\n${viteFailure}\n`);
  fs.mkdirSync(path.join(root, 'web/node_modules/.bin'));
  fs.symlinkSync('../typescript/bin/tsc', path.join(root, 'web/node_modules/.bin/tsc'));
  fs.symlinkSync('../vite/bin/vite.js', path.join(root, 'web/node_modules/.bin/vite'));
  t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
  return { parent, root, output, trace, receipt: path.join(output, SOURCE_RECEIPT_NAME) };
}
function prepare(f) { return prepareNativeResources(f.root, f.output); }
function binding(f) { return { sourceReceipt: f.receipt, sourceRoot: f.root }; }
function verify(f, result) { return verifyNativeSourceBinding(f.receipt, f.root, result.packageDirectory, result.inventorySha256); }
function patched(method, replacement, operation) {
  const original = fs[method]; fs[method] = (...args) => replacement(original, ...args);
  try { return operation(); } finally { fs[method] = original; }
}
function snapshotDirectory(folder) {
  return fs.readdirSync(folder).sort().map(name => {
    const full = path.join(folder, name), stat = fs.lstatSync(full);
    return { name, ino: stat.ino, mode: stat.mode, ...(stat.isFile() ? { bytes: fs.readFileSync(full).toString('base64') } : {}) };
  });
}

test('explicit orchestration invokes the exact direct tools, snapshots continuity and writes completion receipt last', t => {
  const f = fixture(t), before = captureSourceSnapshot(f.root), order = [];
  let result;
  patched('openSync', (original, ...args) => {
    if (typeof args[1] === 'number' && args[1] & fs.constants.O_CREAT) order.push(args[0]);
    return original(...args);
  }, () => { result = prepare(f); });
  const checked = verify(f, result), receipt = JSON.parse(fs.readFileSync(f.receipt, 'utf8'));
  assert.equal(checked.sourceSha256, before.sha256);
  assert.deepEqual(captureSourceSnapshot(f.root), before);
  assert.equal(order.at(-1), f.receipt);
  assert.deepEqual(receipt.buildInputs.commands, BUILD_COMMANDS);
  assert.deepEqual(receipt.buildInputs.environment, BUILD_ENVIRONMENT);
  assert.equal(receipt.buildInputs.runtime.nodeVersion, process.versions.node);
  assert.match(receipt.buildInputs.runtime.executableSha256, /^[a-f0-9]{64}$/);
  assert.ok(receipt.buildInputs.dependencies.bytes > 0);
  assert.deepEqual(fs.readdirSync(f.output).sort(), ['build-output', 'native-inputs.xcfilelist', SOURCE_RECEIPT_NAME, 'package'].sort());
  assert.deepEqual(fs.readdirSync(result.packageDirectory).sort(), ['BexWebUI', 'native-resource-manifest.json']);
  const commands = fs.readFileSync(f.trace, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  assert.deepEqual(commands.map(command => command.tool), ['tsc', 'vite']);
  assert.deepEqual(commands[0].args, BUILD_COMMANDS[0].arguments);
  assert.deepEqual(commands[1].args, BUILD_COMMANDS[1].arguments.map(arg => arg === '$PREPARATION/build-output' ? path.join(f.output, 'build-output') : arg));
  for (const command of commands) {
    assert.deepEqual(Object.keys(command.env).sort(), [...Object.keys(BUILD_ENVIRONMENT), 'PATH'].sort());
    assert.equal(command.env.NODE_OPTIONS, undefined);
  }
  assert.ok(checked.inputPaths.includes(f.output), 'envelope enumeration is declared for sandbox input');
  assert.ok(checked.inputPaths.includes(path.join(f.root, 'web')));
});

test('bound staging and exact repeats accept current sources while legacy package behavior remains explicit', t => {
  const f = fixture(t), result = prepare(f), resources = path.join(f.parent, 'resources');
  fs.mkdirSync(resources);
  assert.equal(stageNativeBuildInputs(result.packageDirectory, resources, result.inventorySha256, binding(f)).copied, true);
  const before = snapshotDirectory(resources);
  assert.equal(stageNativeBuildInputs(result.packageDirectory, resources, result.inventorySha256, binding(f)).copied, false);
  assert.deepEqual(snapshotDirectory(resources), before);
  fs.appendFileSync(path.join(f.root, 'web/src/main.ts'), '// new source\n');
  assert.throws(() => stageNativeBuildInputs(result.packageDirectory, resources, result.inventorySha256, binding(f)), /Current declared sources differ/);
  assert.deepEqual(snapshotDirectory(resources), before);
  assert.equal(stageNativeBuildInputs(result.packageDirectory, resources, result.inventorySha256).copied, false, 'legacy integrity-only flow does not imply source freshness');
});

for (const target of ['web/src/main.ts', 'web/package-lock.json', 'web/vite.native.config.ts', 'web/node_modules/payload.js']) test(`persistent ${target} change during actual child build rejects completion`, t => {
  const f = fixture(t, { tscMutation: `fs.appendFileSync(require('node:path').join(process.cwd(), ${JSON.stringify(target.slice(4))}), 'changed');` });
  assert.throws(() => prepare(f), /changed during preparation/);
  assert.ok(!fs.existsSync(f.receipt));
  assert.ok(fs.existsSync(path.join(f.output, 'build-output', 'native.html')), 'tool-created output remains for inspection');
});

test('typecheck failure stops before Vite and removes only newly created empty directories', t => {
  const f = fixture(t, { tscFailure: 'process.stderr.write("synthetic typecheck failure"); process.exit(7);' });
  assert.throws(() => prepare(f), /exit=7, signal=none.*synthetic typecheck failure/);
  assert.ok(!fs.existsSync(f.output));
  assert.equal(fs.readFileSync(f.trace, 'utf8').trim().split('\n').length, 1);
});

test('Vite failure preserves partial tool output but never writes a source completion receipt', t => {
  const f = fixture(t, { viteFailure: 'process.stderr.write("synthetic vite failure"); process.exit(9);' });
  assert.throws(() => prepare(f), /exit=9.*preparation incomplete/);
  assert.ok(!fs.existsSync(f.receipt));
  assert.ok(!fs.existsSync(path.join(f.output, 'package')));
  assert.ok(fs.existsSync(path.join(f.output, 'build-output', 'native.html')));
});

test('a preexisting dist cannot substitute for a child build that emitted no assets', t => {
  const f = fixture(t);
  fs.mkdirSync(path.join(f.root, 'web/dist-native'), { recursive: true });
  fs.writeFileSync(path.join(f.root, 'web/dist-native/native.html'), 'stale');
  fs.writeFileSync(path.join(f.root, 'web/node_modules/vite/bin/vite.js'), 'process.exit(0);\n');
  assert.throws(() => prepare(f), /ENOENT|Expected exactly/);
  assert.ok(!fs.existsSync(f.receipt));
  assert.equal(fs.readFileSync(path.join(f.root, 'web/dist-native/native.html'), 'utf8'), 'stale');
});

test('canonical schema rejects tampering, wrong recipe, duplicate keys and noncanonical receipt bytes', t => {
  const f = fixture(t), result = prepare(f), original = fs.readFileSync(f.receipt);
  const mutations = [
    bytes => Buffer.concat([bytes, Buffer.from(' ')]),
    bytes => Buffer.from(bytes.toString().replace('"schemaVersion": 1,', '"schemaVersion": 1,\n  "schemaVersion": 1,')),
    bytes => { const value = JSON.parse(bytes); value.extra = true; return canonicalBytes(value); },
    bytes => { const value = JSON.parse(bytes); value.buildInputs.recipe = 'npm-run-build'; return canonicalBytes(value); },
    bytes => { const value = JSON.parse(bytes); value.buildInputs.commands[1].arguments[4] = 'bundle'; return canonicalBytes(value); },
    bytes => { const value = JSON.parse(bytes); value.resources.inventorySha256 = '0'.repeat(64); return canonicalBytes(value); },
    bytes => { const value = JSON.parse(bytes); value.source.sha256 = '0'.repeat(64); return canonicalBytes(value); },
    bytes => { const value = JSON.parse(bytes); value.buildInputs.dependencies.entries = 10001; return canonicalBytes(value); },
    bytes => { const value = JSON.parse(bytes); value.preparationInputListSha256 = '0'.repeat(64); return canonicalBytes(value); },
  ];
  for (const mutate of mutations) {
    fs.writeFileSync(f.receipt, mutate(original));
    assert.throws(() => verify(f, result));
    fs.writeFileSync(f.receipt, original);
    verify(f, result);
  }
});

test('old artifact cannot be relabeled with a different valid selected inventory', t => {
  const f = fixture(t), result = prepare(f);
  const staging = path.join(f.output, 'build-output');
  fs.appendFileSync(path.join(staging, 'assets', jsName), '// newer bytes\n');
  const other = path.join(f.parent, 'different-package'), changed = packageNativeResources(staging, other);
  assert.throws(() => verifyNativeSourceBinding(f.receipt, f.root, other, changed.inventorySha256), /exact versioned envelope paths/);
  assert.throws(() => verifyNativeSourceBinding(f.receipt, f.root, result.packageDirectory, changed.inventorySha256), /selected resource inventory/);
});

test('missing receipt/list, extra envelope entries and changed original list reject incomplete preparation', t => {
  const f = fixture(t), result = prepare(f), receipt = fs.readFileSync(f.receipt), list = fs.readFileSync(result.inputFileList);
  fs.unlinkSync(f.receipt); assert.throws(() => verify(f, result)); fs.writeFileSync(f.receipt, receipt, { mode: 0o600 });
  fs.unlinkSync(result.inputFileList); assert.throws(() => verify(f, result), /incomplete/); fs.writeFileSync(result.inputFileList, list, { mode: 0o600 });
  fs.appendFileSync(result.inputFileList, 'unexpected\n'); assert.throws(() => verify(f, result), /differs from the completion receipt/); fs.writeFileSync(result.inputFileList, list);
  fs.writeFileSync(path.join(f.output, 'foreign'), 'keep'); assert.throws(() => verify(f, result), /extra entries/);
});

test('receipt links, unsafe modes, oversize data and missing explicit binding options fail closed', t => {
  const f = fixture(t), result = prepare(f), original = fs.readFileSync(f.receipt), resources = path.join(f.parent, 'resources');
  fs.mkdirSync(resources);
  for (const options of [{}, { sourceReceipt: f.receipt }, { sourceReceipt: '', sourceRoot: f.root }, { sourceReceipt: f.receipt, sourceRoot: f.root, fallback: true }]) assert.throws(() => stageNativeBuildInputs(result.packageDirectory, resources, result.inventorySha256, options));
  fs.linkSync(f.receipt, path.join(f.parent, 'linked')); assert.throws(() => verify(f, result), /singly linked/); fs.unlinkSync(path.join(f.parent, 'linked'));
  fs.chmodSync(f.receipt, 0o644); assert.throws(() => verify(f, result), /0600/); fs.chmodSync(f.receipt, 0o600);
  fs.truncateSync(f.receipt, 2 * 1024 * 1024 + 1); assert.throws(() => verify(f, result), /size rejected/); fs.writeFileSync(f.receipt, original);
  fs.renameSync(f.receipt, path.join(f.parent, 'moved-receipt')); fs.symlinkSync(path.join(f.parent, 'moved-receipt'), f.receipt); assert.throws(() => verify(f, result), /symlink/);
  assert.deepEqual(fs.readdirSync(resources), []);
});

test('source edits during fresh copy trigger existing bounded cleanup, not successful stale admission', t => {
  const f = fixture(t), result = prepare(f), resources = path.join(f.parent, 'resources');
  fs.mkdirSync(resources); fs.writeFileSync(path.join(resources, 'keep'), 'keep');
  let changed = false;
  patched('writeFileSync', (original, ...args) => {
    const value = original(...args);
    if (!changed) { changed = true; fs.appendFileSync(path.join(f.root, 'web/src/main.ts'), '// changed during copy\n'); }
    return value;
  }, () => assert.throws(() => stageNativeBuildInputs(result.packageDirectory, resources, result.inventorySha256, binding(f)), /Current declared sources differ/));
  assert.deepEqual(fs.readdirSync(resources), ['keep']);
});

test('bound input lists can be rebased to a relocated envelope and current checkout without changing receipt', t => {
  const f = fixture(t), result = prepare(f), moved = path.join(f.parent, 'relocated');
  const originalReceipt = fs.readFileSync(f.receipt);
  fs.renameSync(f.output, moved);
  const movedReceipt = path.join(moved, SOURCE_RECEIPT_NAME), movedPackage = path.join(moved, 'package');
  const list = path.join(f.parent, 'rebased.xcfilelist');
  writeNativeResourceInputFileList(movedPackage, list, result.inventorySha256, { sourceReceipt: movedReceipt, sourceRoot: f.root });
  assert.deepEqual(fs.readFileSync(movedReceipt), originalReceipt);
  const lines = fs.readFileSync(list, 'utf8').trimEnd().split('\n');
  assert.equal(lines[0], movedPackage);
  assert.ok(lines.includes(moved));
  assert.ok(lines.includes(movedReceipt));
  assert.ok(lines.includes(path.join(f.root, 'web')));
  assert.ok(!lines.includes(f.receipt));
  assert.throws(() => writeNativeResourceInputFileList(movedPackage, path.join(moved, 'extra.xcfilelist'), result.inventorySha256, { sourceReceipt: movedReceipt, sourceRoot: f.root }), /disjoint from the preparation/);
  assert.ok(!fs.existsSync(path.join(moved, 'extra.xcfilelist')));
  assert.throws(() => stageNativeBuildInputs(movedPackage, path.join(f.root, 'web'), result.inventorySha256, { sourceReceipt: movedReceipt, sourceRoot: f.root }), /disjoint from the preparation/);
  const resources = path.join(f.parent, 'resources'); fs.mkdirSync(resources);
  assert.equal(stageNativeBuildInputs(movedPackage, resources, result.inventorySha256, { sourceReceipt: movedReceipt, sourceRoot: f.root }).copied, true);
});

test('rebased bound input list rejects an otherwise valid over-budget long-path selection before writing', { skip: process.platform !== 'linux' }, t => {
  const f = fixture(t), result = prepare(f);
  function longDestination(label) {
    let current = path.join(f.parent, label); fs.mkdirSync(current);
    while (3940 - current.length - 1 > 200) { current = path.join(current, 'd'.repeat(200)); fs.mkdirSync(current); }
    return path.join(current, 'z'.repeat(3940 - current.length - 1));
  }
  const source = longDestination('source-long'), envelope = longDestination('envelope-long');
  fs.renameSync(f.root, source); fs.renameSync(f.output, envelope);
  const destination = path.join(f.parent, 'oversized.xcfilelist');
  assert.throws(() => writeNativeResourceInputFileList(path.join(envelope, 'package'), destination, result.inventorySha256, { sourceReceipt: path.join(envelope, SOURCE_RECEIPT_NAME), sourceRoot: source }), /input list exceeds its size budget/);
  assert.ok(!fs.existsSync(destination));
});

test('bounded snapshot permits only normal internal .bin links and rejects escaped or directory links', t => {
  const f = fixture(t);
  assert.ok(captureBuildInputs(f.root).buildInputs.dependencies.bytes > 0);
  const link = path.join(f.root, 'web/node_modules/.bin/vite');
  fs.unlinkSync(link); fs.symlinkSync('/etc/passwd', link);
  assert.throws(() => captureBuildInputs(f.root), /Unsupported dependency link target/);
  fs.unlinkSync(link); fs.symlinkSync('../../../../outside', link);
  assert.throws(() => captureBuildInputs(f.root), /escapes node_modules/);
  fs.unlinkSync(link); fs.symlinkSync('../vite', link);
  assert.throws(() => captureBuildInputs(f.root), /internal regular file/);
  fs.unlinkSync(link); fs.symlinkSync('../vite/bin/vite.js', link);
  fs.symlinkSync('vite', path.join(f.root, 'web/node_modules/workspace'));
  assert.throws(() => captureBuildInputs(f.root), /Unsupported input symlink/);
});

test('bounded source inventory rejects links, FIFO, oversized files and excessive entry counts', t => {
  const f = fixture(t), source = path.join(f.root, 'web/src/main.ts');
  fs.unlinkSync(source); fs.symlinkSync('/etc/passwd', source); assert.throws(() => captureSourceSnapshot(f.root), /Unsupported input symlink/); fs.unlinkSync(source);
  assert.equal(spawnSync('mkfifo', [source]).status, 0); assert.throws(() => captureSourceSnapshot(f.root), /type, mode or size/); fs.unlinkSync(source);
  fs.writeFileSync(source, ''); fs.truncateSync(source, 64 * 1024 * 1024 + 1); assert.throws(() => captureSourceSnapshot(f.root), /size rejected/); fs.unlinkSync(source);
  for (let i = 0; i < 4097; i++) fs.writeFileSync(path.join(f.root, 'web/src', `file-${i}`), '');
  assert.throws(() => captureSourceSnapshot(f.root), /entry budget/);
});

test('dependency byte budget rejects a sparse oversized file before hashing its contents', t => {
  const f = fixture(t), large = path.join(f.root, 'web/node_modules/too-large');
  fs.writeFileSync(large, ''); fs.truncateSync(large, 128 * 1024 * 1024 + 1);
  assert.throws(() => captureBuildInputs(f.root), /size rejected/);
});

test('generated exclusions and mutate-and-restore are explicit coverage limits, not authenticity claims', t => {
  const f = fixture(t), before = captureSourceSnapshot(f.root), file = path.join(f.root, 'web/src/main.ts'), original = fs.readFileSync(file);
  write(path.join(f.root, 'web/dist-native/ignored'), 'not a declared source');
  write(path.join(f.root, 'web/.parallel/ignored'), 'not a declared source');
  assert.equal(captureSourceSnapshot(f.root).sha256, before.sha256);
  fs.writeFileSync(file, 'temporary edit'); fs.writeFileSync(file, original);
  assert.equal(captureSourceSnapshot(f.root).sha256, before.sha256, 'snapshots cannot detect an already-restored transient edit');
});

test('wrong runtime, existing output, aliases and app paths fail without replacing anything', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.root, '.node-version'), '0.0.0\n');
  assert.throws(() => prepare(f), /exact .node-version/); assert.ok(!fs.existsSync(f.output));
  fs.writeFileSync(path.join(f.root, '.node-version'), `${process.versions.node}\n`);
  fs.mkdirSync(f.output); fs.writeFileSync(path.join(f.output, 'keep'), 'keep');
  assert.throws(() => prepare(f), /EEXIST/); assert.equal(fs.readFileSync(path.join(f.output, 'keep'), 'utf8'), 'keep');
  for (const output of [f.root, path.join(f.root, 'new-output'), `${f.output}/`, path.join(f.parent, 'Bex.app')]) assert.throws(() => prepareNativeResources(f.root, output));
  fs.symlinkSync(f.parent, path.join(f.parent, 'alias'));
  assert.throws(() => prepareNativeResources(f.root, path.join(f.parent, 'alias', 'new-output')), /symlink/);
  assert.ok(!fs.existsSync(path.join(f.parent, 'Bex.app')));
});

test('foreign preparation output is retained and invalidates completion without recursive cleanup', t => {
  const f = fixture(t, { tscMutation: "fs.writeFileSync(require('node:path').join(process.cwd(),'../../prepared/foreign'),'keep');" });
  assert.throws(() => prepare(f), /extra entries.*preparation incomplete/);
  assert.equal(fs.readFileSync(path.join(f.output, 'foreign'), 'utf8'), 'keep');
  assert.ok(!fs.existsSync(f.receipt));
});

test('source integration retains default-OFF gate, native platform barrier and explicit no-fallback optional receipt', () => {
  const embed = fs.readFileSync(path.join(repo, 'scripts/bex-embed-native-resources.mjs'), 'utf8');
  const prepareSource = fs.readFileSync(path.join(repo, 'scripts/bex-prepare-native-resources.mjs'), 'utf8');
  assert.match(embed, /Object\.hasOwn\(env, 'BEX_NATIVE_SOURCE_RECEIPT'\)/);
  assert.match(embed, /process\.platform !== 'darwin'/);
  assert.match(fs.readFileSync(path.join(repo, 'Config/BexNativeResourceScripts.xcfilelist'), 'utf8'), /bex-native-source-binding\.mjs/);
  assert.doesNotMatch(prepareSource, /rmSync|execSync|shell: true|npm run|npm install|npm ci|fetch\(/);
  const project = fs.readFileSync(path.join(repo, 'Bex.xcodeproj/project.pbxproj'), 'utf8');
  assert.equal((project.match(/BEX_EMBED_NATIVE_WEB_RESOURCES = NO;/g) ?? []).length, 2);
});
