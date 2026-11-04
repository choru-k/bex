/** Read-only, bounded accidental-staleness checks. Not build provenance or attestation. */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { verifyNativeResourcePackage } from './bex-package-native-resources.mjs';

export const SOURCE_RECEIPT_NAME = 'native-source-binding.json';
export const SOURCE_PROFILE = 'bex-native-source-binding-v1';
export const BUILD_RECIPE = 'bex-native-direct-tsc-vite-native-config-v1';
export const BUILD_COMMANDS = Object.freeze([
  Object.freeze({ entry: 'web/node_modules/typescript/bin/tsc', arguments: Object.freeze(['-p', 'tsconfig.json']) }),
  Object.freeze({ entry: 'web/node_modules/vite/bin/vite.js', arguments: Object.freeze(['build', '--config', 'vite.native.config.ts', '--configLoader', 'native', '--outDir', '$PREPARATION/build-output']) }),
]);
export const BUILD_ENVIRONMENT = Object.freeze({ CI: '1', NODE_ENV: 'production', TZ: 'UTC', LANG: 'C', LC_ALL: 'C' });
export const BINDING_LIMITATIONS = 'Accidental-staleness checks for the declared source tree, installed dependency bytes and Node executable across this direct build only. Not provenance, authenticity, hermeticity or permission to execute. Does not cover external undeclared config inputs, external runtime libraries, hostile mutation or mutate-and-restore changes. Current-source admission does not require preparation dependencies/runtime to match another platform.';
export const SOURCE_FILES = Object.freeze([
  '.node-version',
  'Config/BexNativeResourceScripts.xcfilelist',
  'scripts/bex-audit-native-resources.mjs',
  'scripts/bex-package-native-resources.mjs',
  'scripts/bex-embed-native-resources.mjs',
  'scripts/bex-native-resource-build-phase.sh',
  'scripts/bex-native-source-binding.mjs',
  'scripts/bex-prepare-native-resources.mjs',
]);
export const EXCLUDED_WEB_DIRECTORIES = Object.freeze(['node_modules', 'dist', 'dist-native', '.parallel', '.native-build', 'playwright-report', 'test-results']);
const MAX_SOURCE_FILES = 4096, MAX_SOURCE_BYTES = 64 * 1024 * 1024;
const MAX_DEPENDENCY_FILES = 10000, MAX_DEPENDENCY_BYTES = 512 * 1024 * 1024;
const MAX_FILE_BYTES = 128 * 1024 * 1024, MAX_RECEIPT_BYTES = 2 * 1024 * 1024;
const fail = message => { throw new Error(message); };
export const canonicalBytes = value => Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
export const digestBytes = bytes => createHash('sha256').update(bytes).digest('hex');
const digestPattern = /^[a-f0-9]{64}$/;
const beneath = (child, parent) => child.startsWith(`${parent}${path.sep}`);
const sameIdentity = (a, b) => a.dev === b.dev && a.ino === b.ino;
const stable = (a, b) => sameIdentity(a, b) && a.mode === b.mode && a.nlink === b.nlink && a.size === b.size && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs;

export function canonicalPath(value, missingLeaf = false) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value === '/' || Buffer.byteLength(value) > 4096 || /[\\\x00-\x1f\x7f$#]/.test(value)) fail('Use a canonical absolute path without control characters or Xcode substitutions');
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

export function requireOfflineLocation(value) {
  const parts = value.split('/').filter(Boolean);
  if (parts.some(part => /\.(app|appex|bundle|framework|xcodeproj|xcworkspace)$/i.test(part) || /^(Applications|System|Library)$/i.test(part)) || /^(bin|boot|dev|etc|lib|lib32|lib64|libexec|opt|proc|root|run|sbin|srv|sys|usr|var)$/i.test(parts[0]) || (parts[0] === 'private' && parts[1] !== 'tmp')) fail('Preparation and receipt must stay outside app, project, system and installation locations');
}

function checkedDirectory(value) {
  canonicalPath(value);
  const stat = fs.lstatSync(value);
  if (!stat.isDirectory() || (stat.mode & 0o7022)) fail(`Unsafe input directory: ${value}`);
  return stat;
}

function safeName(name) {
  if (!name || Buffer.byteLength(name) > 255 || /[\\\x00-\x1f\x7f$#]/.test(name) || name === '.' || name === '..' || /[. ]$/.test(name)) fail('Unsupported input filename');
}

function readFile(value, limit, retain = false) {
  canonicalPath(value);
  const named = fs.lstatSync(value);
  if (!named.isFile() || (named.mode & 0o7022) || named.size > limit) fail(`Input file type, mode or size rejected: ${value}`);
  const fd = fs.openSync(value, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  try {
    const before = fs.fstatSync(fd);
    if (!stable(named, before)) fail('Input identity changed before reading');
    const hash = createHash('sha256'), chunks = [];
    const buffer = Buffer.alloc(Math.min(64 * 1024, before.size + 1));
    let length = 0;
    while (length <= before.size) {
      const count = fs.readSync(fd, buffer, 0, Math.min(buffer.length, before.size + 1 - length), null);
      if (!count) break;
      length += count;
      hash.update(buffer.subarray(0, count));
      if (retain) chunks.push(Buffer.from(buffer.subarray(0, count)));
    }
    if (length !== before.size || !stable(before, fs.fstatSync(fd)) || !stable(before, fs.lstatSync(value))) fail(`Input changed while reading: ${value}`);
    return { mode: before.mode & 0o7777, bytes: length, sha256: hash.digest('hex'), ...(retain ? { data: Buffer.concat(chunks, length) } : {}) };
  } finally { fs.closeSync(fd); }
}

function inventory(root, roots, { maxEntries, maxBytes, dependencies = false }) {
  const entries = [];
  let bytes = 0;
  const sourceStat = checkedDirectory(root);
  function add(entry) {
    if (entries.length >= maxEntries) fail('Input inventory entry budget exceeded');
    bytes += entry.bytes ?? 0;
    if (bytes > maxBytes) fail('Input inventory byte budget exceeded');
    entries.push(entry);
  }
  function walk(relative, depth = 0) {
    if (depth > 32 || Buffer.byteLength(relative) > 1024) fail('Input path depth or length budget exceeded');
    const absolute = path.join(root, relative), before = fs.lstatSync(absolute);
    if (before.isSymbolicLink()) {
      // npm's executable links are supported; workspace/store/escaped links are not.
      if (!dependencies || !relative.startsWith('.bin/') || relative.split('/').length !== 2) fail(`Unsupported input symlink: ${relative}`);
      const target = fs.readlinkSync(absolute);
      if (path.isAbsolute(target) || /[\\\x00-\x1f\x7f$#]/.test(target) || Buffer.byteLength(target) > 1024) fail('Unsupported dependency link target');
      const resolved = path.resolve(path.dirname(absolute), target);
      if (!beneath(resolved, root)) fail('Dependency symlink escapes node_modules');
      canonicalPath(resolved);
      if (!fs.lstatSync(resolved).isFile() || !stable(before, fs.lstatSync(absolute)) || fs.readlinkSync(absolute) !== target) fail('Dependency link target must be a stable internal regular file');
      add({ path: relative, type: 'symlink', target });
    } else if (before.isDirectory()) {
      checkedDirectory(absolute);
      add({ path: relative, type: 'directory', mode: before.mode & 0o7777 });
      const dir = fs.opendirSync(absolute), names = [];
      try {
        for (;;) {
          const entry = dir.readSync();
          if (!entry) break;
          if (names.length >= maxEntries) fail('Directory entry budget exceeded');
          safeName(entry.name);
          if (!dependencies && relative === 'web' && EXCLUDED_WEB_DIRECTORIES.includes(entry.name)) continue;
          names.push(entry.name);
        }
      } finally { dir.closeSync(); }
      for (const name of names.sort()) walk(`${relative}/${name}`, depth + 1);
      if (!stable(before, fs.lstatSync(absolute))) fail(`Input directory changed while reading: ${relative}`);
    } else {
      const item = readFile(absolute, Math.min(MAX_FILE_BYTES, maxBytes - bytes));
      add({ path: relative, type: 'file', ...item });
    }
  }
  for (const relative of roots) walk(relative);
  if (!stable(sourceStat, fs.lstatSync(root))) fail('Input root changed while reading');
  entries.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  return { inventory: entries, sha256: digestBytes(Buffer.from(JSON.stringify(entries))), entries: entries.length, bytes };
}

export function captureSourceSnapshot(sourceRoot) {
  const root = canonicalPath(sourceRoot);
  return inventory(root, [...SOURCE_FILES, 'web'], { maxEntries: MAX_SOURCE_FILES, maxBytes: MAX_SOURCE_BYTES });
}

export function captureBuildInputs(sourceRoot) {
  const source = captureSourceSnapshot(sourceRoot);
  const dependencyRoot = path.join(sourceRoot, 'web/node_modules');
  const dependencyStat = checkedDirectory(dependencyRoot);
  const dir = fs.opendirSync(dependencyRoot), names = [];
  try {
    for (;;) {
      const entry = dir.readSync(); if (!entry) break;
      if (names.length >= MAX_DEPENDENCY_FILES) fail('Dependency root entry budget exceeded');
      safeName(entry.name); names.push(entry.name);
    }
  } finally { dir.closeSync(); }
  const dependencies = inventory(dependencyRoot, names.sort(), { maxEntries: MAX_DEPENDENCY_FILES, maxBytes: MAX_DEPENDENCY_BYTES, dependencies: true });
  if (!stable(dependencyStat, fs.lstatSync(dependencyRoot))) fail('Dependency root changed during snapshot');
  const pinnedNode = readFile(path.join(sourceRoot, '.node-version'), 128, true).data.toString('utf8');
  if (pinnedNode !== `${process.versions.node}\n`) fail('Preparation requires the exact .node-version runtime; no installation is performed');
  const executable = readFile(fs.realpathSync(process.execPath), 256 * 1024 * 1024);
  return {
    source,
    buildInputs: {
      recipe: BUILD_RECIPE,
      commands: BUILD_COMMANDS,
      dependencies: { sha256: dependencies.sha256, entries: dependencies.entries, bytes: dependencies.bytes },
      runtime: { nodeVersion: process.versions.node, platform: process.platform, arch: process.arch, executableSha256: executable.sha256 },
      environment: { ...BUILD_ENVIRONMENT },
    },
  };
}

export function createSourceReceipt(snapshot, manifest, preparationInputListSha256) {
  if (!digestPattern.test(preparationInputListSha256)) fail('Input-list digest is required');
  return {
    schemaVersion: 1,
    profile: SOURCE_PROFILE,
    source: { inventory: snapshot.source.inventory, sha256: snapshot.source.sha256 },
    buildInputs: snapshot.buildInputs,
    resources: { inventorySha256: manifest.inventorySha256, manifestSha256: digestBytes(canonicalBytes(manifest)) },
    preparationInputListSha256,
    limitations: BINDING_LIMITATIONS,
  };
}

function keys(value, expected) {
  if (!value || Array.isArray(value) || typeof value !== 'object' || JSON.stringify(Object.keys(value)) !== JSON.stringify(expected)) fail('Noncanonical source-binding schema');
}

function validateBuildInputs(value) {
  keys(value, ['recipe', 'commands', 'dependencies', 'runtime', 'environment']);
  if (!canonicalBytes(value.commands).equals(canonicalBytes(BUILD_COMMANDS))) fail('Unexpected direct build command recipe');
  keys(value.dependencies, ['sha256', 'entries', 'bytes']);
  keys(value.runtime, ['nodeVersion', 'platform', 'arch', 'executableSha256']);
  if (value.recipe !== BUILD_RECIPE || !digestPattern.test(value.dependencies.sha256) || !Number.isSafeInteger(value.dependencies.entries) || value.dependencies.entries < 1 || value.dependencies.entries > MAX_DEPENDENCY_FILES || !Number.isSafeInteger(value.dependencies.bytes) || value.dependencies.bytes < 1 || value.dependencies.bytes > MAX_DEPENDENCY_BYTES) fail('Invalid dependency fingerprint');
  if (typeof value.runtime.nodeVersion !== 'string' || !/^\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(value.runtime.nodeVersion) || !['linux', 'darwin', 'win32'].includes(value.runtime.platform) || !['x64', 'arm64'].includes(value.runtime.arch) || !digestPattern.test(value.runtime.executableSha256)) fail('Invalid runtime fingerprint');
  if (!canonicalBytes(value.environment).equals(canonicalBytes(BUILD_ENVIRONMENT))) fail('Unexpected build environment profile');
  return value;
}

export function sourceBindingInputPaths(receiptPath, sourceRoot) {
  const receipt = canonicalPath(receiptPath, true), root = canonicalPath(sourceRoot);
  return [path.dirname(receipt), receipt, path.join(path.dirname(receipt), 'native-inputs.xcfilelist'), ...SOURCE_FILES.map(file => path.join(root, file)), path.join(root, 'web')];
}

function checkEnvelope(receipt, packageDirectory) {
  const root = path.dirname(receipt);
  if (path.basename(receipt) !== SOURCE_RECEIPT_NAME || packageDirectory !== path.join(root, 'package')) fail('Bound preparation requires its exact versioned envelope paths');
  if ((checkedDirectory(root).mode & 0o7777) !== 0o700) fail('Preparation envelope must have mode 0700');
  const dir = fs.opendirSync(root), names = [];
  try { for (let i = 0; i < 5; i++) { const entry = dir.readSync(); if (!entry) break; names.push(entry.name); } }
  finally { dir.closeSync(); }
  if (JSON.stringify(names.sort()) !== JSON.stringify(['build-output', 'native-inputs.xcfilelist', SOURCE_RECEIPT_NAME, 'package'].sort())) fail('Preparation envelope is incomplete or contains extra entries');
  checkedDirectory(path.join(root, 'build-output'));
  const listPath = path.join(root, 'native-inputs.xcfilelist'), list = readFile(listPath, 64 * 1024, true);
  if (list.mode !== 0o600 || fs.lstatSync(listPath).nlink !== 1) fail('Preparation input list must be a singly linked 0600 file');
  return list.sha256;
}

/** Read-only comparison to the current declared sources and exact selected package. */
export function verifyNativeSourceBinding(receiptPath, sourceRoot, packageDirectory, expectedInventorySha256) {
  const receipt = canonicalPath(receiptPath), root = canonicalPath(sourceRoot);
  requireOfflineLocation(receipt);
  const preparationInputListSha256 = checkEnvelope(receipt, packageDirectory);
  const raw = readFile(receipt, MAX_RECEIPT_BYTES, true);
  if (raw.mode !== 0o600 || fs.lstatSync(receipt).nlink !== 1) fail('Source receipt must be singly linked with mode 0600');
  let value;
  try { value = JSON.parse(raw.data.toString('utf8')); } catch { fail('Malformed source-binding JSON'); }
  keys(value, ['schemaVersion', 'profile', 'source', 'buildInputs', 'resources', 'preparationInputListSha256', 'limitations']);
  keys(value.source, ['inventory', 'sha256']);
  keys(value.resources, ['inventorySha256', 'manifestSha256']);
  if (value.schemaVersion !== 1 || value.profile !== SOURCE_PROFILE || value.limitations !== BINDING_LIMITATIONS || !digestPattern.test(value.source.sha256) || !digestPattern.test(expectedInventorySha256) || !digestPattern.test(value.resources.inventorySha256) || !digestPattern.test(value.resources.manifestSha256)) fail('Unsupported or malformed source-binding receipt');
  if (value.preparationInputListSha256 !== preparationInputListSha256) fail('Preparation input list differs from the completion receipt');
  validateBuildInputs(value.buildInputs);
  const source = captureSourceSnapshot(root);
  if (value.source.sha256 !== source.sha256 || JSON.stringify(value.source.inventory) !== JSON.stringify(source.inventory)) fail('Current declared sources differ from the prepared source snapshot');
  const manifest = verifyNativeResourcePackage(packageDirectory);
  if (manifest.inventorySha256 !== expectedInventorySha256 || value.resources.inventorySha256 !== expectedInventorySha256 || value.resources.manifestSha256 !== digestBytes(canonicalBytes(manifest))) fail('Source receipt does not bind the selected resource inventory');
  const expected = createSourceReceipt({ source, buildInputs: value.buildInputs }, manifest, preparationInputListSha256);
  if (!canonicalBytes(expected).equals(raw.data)) fail('Source receipt is not the exact canonical format');
  return {
    receiptPath: receipt, sourceRoot: root, sourceSha256: source.sha256,
    inputPaths: sourceBindingInputPaths(receipt, root),
  };
}
