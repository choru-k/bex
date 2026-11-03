#!/usr/bin/env node
/** Opt-in resource build integration. No host activation, subprocesses or networking. */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { verifyNativeResourcePackage, RESOURCE_DIRECTORY, MANIFEST_NAME } from './bex-package-native-resources.mjs';
import { verifyNativeSourceBinding } from './bex-native-source-binding.mjs';

const scriptRoot = path.dirname(fileURLToPath(import.meta.url));
const fail = message => { throw new Error(message); };
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const sameIdentity = (a, b) => a.dev === b.dev && a.ino === b.ino;
const beneath = (child, parent) => child.startsWith(`${parent}${path.sep}`);
const jsonBytes = value => Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
const MAX_RESOURCE = 16 * 1024 * 1024;

function checkedPath(value, missingLeaf = false) {
  // Also reject xcfilelist substitutions, comments and newlines instead of
  // trying to escape user-selected paths in the Xcode input list language.
  if (typeof value !== 'string' || !path.isAbsolute(value) || value === '/' || value.length > 4096 || /[\\\x00-\x1f\x7f$#]/.test(value)) fail('Use a canonical absolute path without control characters or Xcode substitutions');
  const parts = value.slice(1).split('/');
  if (parts.some(part => !part || part === '.' || part === '..' || /[. ]$/.test(part))) fail('Path aliases are rejected');
  let current = '/';
  for (const [index, part] of parts.entries()) {
    current = path.join(current, part);
    let stat;
    try { stat = fs.lstatSync(current); } catch (error) {
      if (missingLeaf && index === parts.length - 1 && error.code === 'ENOENT') return value;
      throw error;
    }
    if (stat.isSymbolicLink() || fs.realpathSync(current) !== current) fail(`Noncanonical or symlink path: ${current}`);
    if (index < parts.length - 1 && !stat.isDirectory()) fail(`Non-directory ancestor: ${current}`);
  }
  return value;
}

function offlineLocation(value) {
  const parts = value.split('/').filter(Boolean);
  if (parts.some(part => /\.(app|appex|bundle|framework|xcodeproj|xcworkspace)$/i.test(part) || /^(Applications|System|Library)$/i.test(part)) || /^(bin|boot|dev|etc|lib|lib32|lib64|libexec|opt|proc|root|run|sbin|srv|sys|usr|var)$/i.test(parts[0]) || (parts[0] === 'private' && parts[1] !== 'tmp')) fail('Offline inputs and staging must not be in an app, project bundle, system or installation location');
}

function directory(value, exactMode) {
  checkedPath(value);
  const stat = fs.lstatSync(value);
  if (!stat.isDirectory() || (stat.mode & 0o7022) || (exactMode !== undefined && (stat.mode & 0o7777) !== exactMode)) fail(`Unsafe directory or unexpected mode: ${value}`);
  return stat;
}

function exactEntries(value, expected) {
  const names = [];
  const dir = fs.opendirSync(value);
  try {
    for (let i = 0; i <= expected.length; i++) {
      const entry = dir.readSync();
      if (!entry) break;
      names.push(entry.name);
    }
  } finally { dir.closeSync(); }
  if (JSON.stringify(names.sort()) !== JSON.stringify([...expected].sort())) fail(`Unexpected or missing entries: ${value}`);
}

function readRegular(value, limit, exactMode) {
  checkedPath(value);
  const named = fs.lstatSync(value);
  if (!named.isFile() || named.nlink !== 1 || (named.mode & 0o7133)) fail(`Unsafe, linked or nonregular file: ${value}`);
  const fd = fs.openSync(value, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  try {
    const before = fs.fstatSync(fd);
    if (!sameIdentity(named, before) || !before.isFile() || before.nlink !== 1 || (before.mode & 0o7133) || before.size > limit || (exactMode !== undefined && (before.mode & 0o7777) !== exactMode)) fail(`File mode, type or size rejected: ${value}`);
    const bytes = Buffer.alloc(before.size + 1);
    let length = 0;
    while (length < bytes.length) {
      const count = fs.readSync(fd, bytes, length, bytes.length - length, null);
      if (!count) break;
      length += count;
    }
    const after = fs.fstatSync(fd), current = fs.lstatSync(value);
    if (length !== before.size || !sameIdentity(before, after) || !sameIdentity(after, current) || before.size !== after.size || before.mode !== after.mode || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs || after.nlink !== 1 || current.isSymbolicLink()) fail(`File changed while reading: ${value}`);
    return bytes.subarray(0, length);
  } finally { fs.closeSync(fd); }
}

function readPackage(packageDirectory, expectedDigest) {
  if (typeof expectedDigest !== 'string' || !/^[a-f0-9]{64}$/.test(expectedDigest)) fail('An explicit lowercase SHA-256 inventory pin is required');
  const root = checkedPath(packageDirectory);
  offlineLocation(root);
  directory(root, 0o700);
  exactEntries(root, [RESOURCE_DIRECTORY, MANIFEST_NAME]);
  const resources = path.join(root, RESOURCE_DIRECTORY), assets = path.join(resources, 'assets');
  directory(resources, 0o700);
  exactEntries(resources, ['assets', 'native.html']);
  directory(assets, 0o700);
  // Bound enumeration and reads before invoking the unchanged offline verifier.
  const names = [];
  const dir = fs.opendirSync(assets);
  try { for (let i = 0; i < 3; i++) { const entry = dir.readSync(); if (!entry) break; names.push(entry.name); } }
  finally { dir.closeSync(); }
  if (names.length !== 2 || names.filter(name => /^native-[A-Za-z0-9_-]{8,64}\.js$/.test(name)).length !== 1 || names.filter(name => /^native-[A-Za-z0-9_-]{8,64}\.css$/.test(name)).length !== 1) fail('Package needs exactly one native script and stylesheet');
  readRegular(path.join(root, MANIFEST_NAME), 64 * 1024, 0o600);
  readRegular(path.join(resources, 'native.html'), 4096, 0o600);
  for (const name of names) readRegular(path.join(assets, name), MAX_RESOURCE, 0o600);
  const manifest = verifyNativeResourcePackage(root);
  if (manifest.inventorySha256 !== expectedDigest) fail('Package inventory differs from the explicitly selected build input');
  const files = manifest.inventory.map(entry => {
    const bytes = readRegular(path.join(resources, entry.path), MAX_RESOURCE, 0o600);
    if (bytes.length !== entry.bytes || sha256(bytes) !== entry.sha256) fail('Package changed after verification');
    return { relative: `${RESOURCE_DIRECTORY}/${entry.path}`, bytes };
  });
  const manifestBytes = readRegular(path.join(root, MANIFEST_NAME), 64 * 1024, 0o600);
  if (!manifestBytes.equals(jsonBytes(manifest)) || !jsonBytes(verifyNativeResourcePackage(root)).equals(manifestBytes)) fail('Package changed after verification');
  files.push({ relative: MANIFEST_NAME, bytes: manifestBytes });
  return { root, manifest, files };
}

/** Pure list rendering, shared by preparation before its completion receipt exists. */
export function nativeResourceInputListBytes(packageDirectory, manifest, binding) {
  return Buffer.from([packageDirectory,
    ...manifest.inventory.map(entry => `${packageDirectory}/${RESOURCE_DIRECTORY}/${entry.path}`),
    `${packageDirectory}/${MANIFEST_NAME}`, ...(binding?.inputPaths ?? []),
  ].join('\n') + '\n');
}

function sourceBinding(input, options) {
  if (options === undefined) return undefined; // Explicitly retained legacy/unbound flow.
  if (!options || typeof options !== 'object' || Object.keys(options).sort().join(',') !== 'sourceReceipt,sourceRoot') fail('Source binding requires an explicit receipt and source root');
  return verifyNativeSourceBinding(options.sourceReceipt, options.sourceRoot, input.root, input.manifest.inventorySha256);
}

function checkBoundDestination(binding, target) {
  if (!binding) return;
  for (const protectedRoot of [path.dirname(binding.receiptPath), binding.sourceRoot]) {
    if (target === protectedRoot || beneath(target, protectedRoot) || beneath(protectedRoot, target)) fail('Bound output must be disjoint from the preparation envelope and declared source checkout');
  }
}

/** Read-only selection plus one exclusive offline .xcfilelist; no .app destination. */
export function writeNativeResourceInputFileList(packageDirectory, output, expectedDigest, options) {
  const target = checkedPath(output, true);
  offlineLocation(target);
  if (!target.endsWith('.xcfilelist')) fail('Input file list output must end in .xcfilelist');
  const parent = path.dirname(target), parentStat = directory(parent);
  const input = readPackage(packageDirectory, expectedDigest);
  const binding = sourceBinding(input, options);
  checkBoundDestination(binding, target);
  if (target === input.root || beneath(target, input.root)) fail('Input list must be outside the package');
  const listBytes = nativeResourceInputListBytes(input.root, input.manifest, binding);
  if (listBytes.length > 64 * 1024) fail('Generated input list exceeds its size budget');
  const fd = fs.openSync(target, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  let identity;
  try {
    identity = fs.fstatSync(fd);
    fs.fchmodSync(fd, 0o600);
    fs.writeFileSync(fd, listBytes);
  } catch (error) {
    try {
      checkedPath(target);
      if (!identity || !sameIdentity(parentStat, fs.lstatSync(parent)) || !sameIdentity(identity, fs.lstatSync(target))) fail('Cannot identify created input list');
      fs.unlinkSync(target);
    } catch {
      throw new Error(`${error.message}; cleanup incomplete, do not use this input list: ${target}`, { cause: error });
    }
    throw error;
  } finally { fs.closeSync(fd); }
  return input.manifest;
}

function existing(value) {
  try { return fs.lstatSync(value); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

function verifyCopied(input, target) {
  const resources = path.join(target, RESOURCE_DIRECTORY);
  directory(resources, 0o755);
  exactEntries(resources, ['assets', 'native.html']);
  directory(path.join(resources, 'assets'), 0o755);
  exactEntries(path.join(resources, 'assets'), input.manifest.inventory.filter(entry => entry.path.startsWith('assets/')).map(entry => path.basename(entry.path)));
  for (const file of input.files) {
    if (!readRegular(path.join(target, file.relative), file.relative === MANIFEST_NAME ? 64 * 1024 : MAX_RESOURCE, 0o644).equals(file.bytes)) fail('Existing native build outputs are stale or incomplete; use a separately authorized clean build');
  }
}

function copyIntoResources(input, target, verifyBinding = () => {}) {
  verifyBinding();
  const targetStat = directory(target);
  if (target === input.root || beneath(target, input.root) || beneath(input.root, target)) fail('Build destination and input package must be disjoint');
  if (existing(path.join(target, RESOURCE_DIRECTORY)) || existing(path.join(target, MANIFEST_NAME))) {
    verifyCopied(input, target); // Exact repeat is a read-only no-op. Never overwrite.
    verifyBinding();
    return { inventorySha256: input.manifest.inventorySha256, copied: false };
  }
  const owned = [];
  function checkParents(name) {
    checkedPath(target);
    if (!sameIdentity(fs.lstatSync(target), targetStat)) fail('Build resource root was replaced');
    for (const entry of owned.filter(entry => entry.directory && (name === entry.name || beneath(name, entry.name)))) {
      if (!entry.stat) fail(`Cannot identify created directory: ${entry.name}`);
      const current = fs.lstatSync(entry.name);
      if (!current.isDirectory() || current.isSymbolicLink() || !sameIdentity(current, entry.stat)) fail('Created directory was replaced');
    }
  }
  function mkdir(name) {
    checkParents(name);
    fs.mkdirSync(name, { mode: 0o755 });
    const entry = { name, directory: true, stat: null };
    owned.push(entry);
    entry.stat = fs.lstatSync(name);
    fs.chmodSync(name, 0o755);
  }
  function write(file) {
    const name = path.join(target, file.relative);
    checkParents(name);
    const fd = fs.openSync(name, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o644);
    const entry = { name, directory: false, stat: null };
    owned.push(entry);
    try { entry.stat = fs.fstatSync(fd); fs.fchmodSync(fd, 0o644); fs.writeFileSync(fd, file.bytes); }
    finally { fs.closeSync(fd); }
  }
  try {
    mkdir(path.join(target, RESOURCE_DIRECTORY));
    mkdir(path.join(target, RESOURCE_DIRECTORY, 'assets'));
    for (const file of input.files) write(file); // Manifest last, never an early success marker.
    checkParents(path.join(target, RESOURCE_DIRECTORY, 'assets'));
    verifyCopied(input, target);
    if (!jsonBytes(readPackage(input.root, input.manifest.inventorySha256).manifest).equals(jsonBytes(input.manifest))) fail('Package changed while copying');
    verifyBinding();
    return { inventorySha256: input.manifest.inventorySha256, copied: true };
  } catch (error) {
    const failures = [];
    for (const entry of [...owned].reverse()) {
      try {
        checkParents(entry.name);
        if (!entry.stat) fail('Cannot identify created entry');
        const stat = fs.lstatSync(entry.name);
        if (!sameIdentity(stat, entry.stat) || stat.isSymbolicLink() || stat.isDirectory() !== entry.directory) fail('Created entry was replaced');
        if (entry.directory) fs.rmdirSync(entry.name);
        else fs.unlinkSync(entry.name);
      } catch (cleanupError) { if (cleanupError.code !== 'ENOENT') failures.push(entry.name); }
    }
    if (failures.length) throw new Error(`${error.message}; cleanup incomplete, do not use these outputs: ${failures.join(', ')}`, { cause: error });
    throw error;
  }
}

/** Offline integration tests/staging only: existing ordinary directory, never an app. */
export function stageNativeBuildInputs(packageDirectory, resourceDirectory, expectedDigest, options) {
  const target = checkedPath(resourceDirectory);
  offlineLocation(target);
  const input = readPackage(packageDirectory, expectedDigest);
  return copyIntoResources(input, target, () => checkBoundDestination(sourceBinding(input, options), target));
}

/** Pure context validation. Does not execute Xcode, copy, sign, install or activate. */
export function validateXcodeBuildContext(env) {
  for (const [key, value] of Object.entries({ BEX_EMBED_NATIVE_WEB_RESOURCES: 'YES', ACTION: 'build', PROJECT_NAME: 'Bex', TARGET_NAME: 'Bex', PRODUCT_NAME: 'Bex', FULL_PRODUCT_NAME: 'Bex.app', WRAPPER_NAME: 'Bex.app', UNLOCALIZED_RESOURCES_FOLDER_PATH: 'Bex.app/Contents/Resources', DEPLOYMENT_LOCATION: 'NO' })) {
    if (env[key] !== value) fail(`Unexpected Xcode build context: ${key}`);
  }
  if (!['Debug', 'Release'].includes(env.CONFIGURATION)) fail('Only explicit Debug or Release builds are supported');
  const source = checkedPath(env.SRCROOT);
  if (source !== path.dirname(scriptRoot) || env.PROJECT_DIR !== source) fail('Xcode project does not match this checked-out integration');
  const build = checkedPath(env.BUILD_DIR), products = checkedPath(env.TARGET_BUILD_DIR);
  directory(build); directory(products);
  if (!beneath(products, build) || env.BUILT_PRODUCTS_DIR !== products || build === source || beneath(source, build) || beneath(build, source)) fail('Expected an isolated build-products directory outside the checkout');
  if (build.split('/').some(part => /^(Applications|System)$/i.test(part) || /\.(app|appex|bundle|framework|xcodeproj|xcworkspace)$/i.test(part))) fail('Build products must not be installed or nested in another bundle');
  const target = checkedPath(`${products}/Bex.app/Contents/Resources`);
  directory(target);
  return target;
}

function runXcodeBuildPhase(env) {
  if (process.platform !== 'darwin') fail('Actual Xcode resource embedding is macOS-only and requires separate native authorization');
  const target = validateXcodeBuildContext(env);
  if (checkedPath(env.BEX_NATIVE_NODE_PATH) !== process.execPath) fail('Use the explicit canonical Node executable selected for this build');
  const input = readPackage(env.BEX_NATIVE_RESOURCE_PACKAGE, env.BEX_NATIVE_RESOURCE_INVENTORY_SHA256);
  const options = Object.hasOwn(env, 'BEX_NATIVE_SOURCE_RECEIPT')
    ? { sourceReceipt: env.BEX_NATIVE_SOURCE_RECEIPT, sourceRoot: path.dirname(scriptRoot) } : undefined;
  const binding = sourceBinding(input, options);
  const list = checkedPath(env.BEX_NATIVE_RESOURCE_INPUT_FILE_LIST);
  offlineLocation(list);
  if (!readRegular(list, 64 * 1024, 0o600).equals(nativeResourceInputListBytes(input.root, input.manifest, binding))) fail('The selected Xcode input file list does not match the package');
  return copyIntoResources(input, target, () => checkBoundDestination(sourceBinding(input, options), target));
}

function main(args) {
  if (args.length === 1 && args[0] === '--xcode-build-phase') return runXcodeBuildPhase(process.env);
  if ((args.length === 6 || (args.length === 8 && args[6] === '--source-receipt')) && args[0] === '--package' && args[2] === '--inventory-sha256' && args[4] === '--write-input-file-list') return writeNativeResourceInputFileList(args[1], args[5], args[3], args.length === 8 ? { sourceReceipt: args[7], sourceRoot: path.dirname(scriptRoot) } : undefined);
  fail('Usage: node scripts/bex-embed-native-resources.mjs --package ABSOLUTE_PACKAGE --inventory-sha256 HASH --write-input-file-list NEW_ABSOLUTE.xcfilelist [--source-receipt ABSOLUTE_RECEIPT] | --xcode-build-phase');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(main(process.argv.slice(2)), null, 2)}\n`); }
  catch (error) { console.error(`Native resource integration: ${error.message}`); process.exitCode = 1; }
}
