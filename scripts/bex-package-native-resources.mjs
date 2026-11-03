#!/usr/bin/env node
/** Offline review artifact only. Never builds, installs, signs or activates Bex. */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { auditNativeResources } from './bex-audit-native-resources.mjs';

export const RESOURCE_DIRECTORY = 'BexWebUI';
export const MANIFEST_NAME = 'native-resource-manifest.json';
const MAX_RESOURCE_BYTES = 16 * 1024 * 1024;
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw new Error(message); };
const sameIdentity = (a, b) => a.dev === b.dev && a.ino === b.ino;
const manifestBytes = manifest => Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);

// Check the supplied spelling before normalization. This is deliberately stricter
// than the auditor: package paths are absolute, canonical and have no aliases.
function checkedPath(input, missingLeaf = false) {
  if (typeof input !== 'string' || !path.isAbsolute(input) || input === path.parse(input).root || input.includes('\0') || input.includes('\\')) fail('Use an explicit absolute path without aliases');
  const parts = input.slice(path.parse(input).root.length).split(path.sep);
  if (parts.some(part => !part || part === '.' || part === '..' || /[. ]$/.test(part))) fail('Path aliases, dot segments and trailing separators are rejected');
  let current = path.parse(input).root;
  for (const [index, part] of parts.entries()) {
    current = path.join(current, part);
    let stat;
    try { stat = fs.lstatSync(current); } catch (error) {
      if (missingLeaf && index === parts.length - 1 && error.code === 'ENOENT') return input;
      throw error;
    }
    if (stat.isSymbolicLink()) fail(`Symlink rejected: ${current}`);
    if (index < parts.length - 1 && !stat.isDirectory()) fail(`Not a directory: ${current}`);
    if (fs.realpathSync(current) !== current) fail(`Noncanonical path rejected: ${current}`);
  }
  return input;
}

function checkedReviewLocation(target) {
  const parts = target.split(path.sep).filter(Boolean);
  if (parts.some(part => /\.(app|appex|bundle|framework|xcodeproj|xcworkspace)$/i.test(part))) fail('Output must be an offline review directory, never an app bundle or Xcode path');
  // Include user Library, conventional Unix installation roots and their normal
  // macOS spellings. This is an accidental-install guard, not an OS sandbox.
  if (parts.some(part => /^(Applications|System|Library)$/i.test(part)) || /^(bin|boot|dev|etc|lib|lib32|lib64|libexec|opt|proc|root|run|sbin|srv|sys|usr|var)$/i.test(parts[0]) || (parts[0] === 'private' && parts[1] !== 'tmp')) fail('Output must not be in a system or installation location');
}

function checkedDirectory(directory, exactMode) {
  checkedPath(directory);
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || (stat.mode & 0o7022)) fail(`Unsafe directory: ${directory}`);
  if (exactMode !== undefined && (stat.mode & 0o7777) !== exactMode) fail(`Unexpected package directory mode: ${directory}`);
  return stat;
}

function readRegular(file, limit, exactMode) {
  checkedPath(file);
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.nlink !== 1 || (before.mode & 0o7133)) fail(`Nonregular, hard-linked or unsafe-mode file: ${file}`);
    if (exactMode !== undefined && (before.mode & 0o7777) !== exactMode) fail(`Unexpected package file mode: ${file}`);
    if (before.size > limit) fail(`File exceeds package size limit: ${file}`);
    // Read a bounded allocation, including one extra byte to detect ordinary
    // growth during the read. Concurrent hostile mutation is outside the contract.
    const buffer = Buffer.alloc(before.size + 1);
    let length = 0;
    while (length < buffer.length) {
      const count = fs.readSync(fd, buffer, length, buffer.length - length, null);
      if (!count) break;
      length += count;
    }
    const after = fs.fstatSync(fd);
    if (length !== before.size || !sameIdentity(before, after) || before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs || before.mode !== after.mode || after.nlink !== 1) fail(`File changed while reading: ${file}`);
    return buffer.subarray(0, length);
  } finally { fs.closeSync(fd); }
}

function requireMatchingBytes(bytes, entry) {
  if (bytes.length !== entry.bytes || sha256(bytes) !== entry.sha256) fail(`Resource bytes differ from the audit: ${entry.path}`);
}

/** Verify only. Does not repair, execute or trust a manifest as provenance. */
export function verifyNativeResourcePackage(directory) {
  const root = checkedPath(directory);
  checkedDirectory(root, 0o700);
  const names = fs.readdirSync(root).sort();
  if (JSON.stringify(names) !== JSON.stringify([RESOURCE_DIRECTORY, MANIFEST_NAME].sort())) fail('Package must contain exactly BexWebUI and native-resource-manifest.json');
  const resources = path.join(root, RESOURCE_DIRECTORY);
  checkedDirectory(resources, 0o700);
  checkedDirectory(path.join(resources, 'assets'), 0o700);
  const audit = auditNativeResources(resources);
  for (const entry of audit.inventory) requireMatchingBytes(readRegular(path.join(resources, entry.path), MAX_RESOURCE_BYTES, 0o600), entry);
  const manifest = readRegular(path.join(root, MANIFEST_NAME), 64 * 1024, 0o600);
  if (!manifest.equals(manifestBytes(audit))) fail('Package manifest does not match the audited resource bytes and canonical format');
  return audit;
}

/** Create one fresh review artifact, using only the unchanged auditor's inventory. */
export function packageNativeResources(directory, output) {
  const source = checkedPath(directory);
  const sourceStat = checkedDirectory(source);
  checkedDirectory(path.join(source, 'assets'));
  const target = checkedPath(output, true);
  checkedReviewLocation(target);
  // Check directory identities as well as lexical containment, so another
  // spelling of an existing input ancestor does not authorize writes into input.
  for (let ancestor = path.dirname(target); ; ancestor = path.dirname(ancestor)) {
    if (sameIdentity(fs.lstatSync(ancestor), sourceStat)) fail('Package output must be outside staging');
    if (ancestor === path.parse(ancestor).root) break;
  }
  if (target === source || target.startsWith(`${source}${path.sep}`)) fail('Package output must be outside staging');
  const audit = auditNativeResources(source);
  const owned = [];
  function mkdir(name) {
    fs.mkdirSync(name, { mode: 0o700 }); // Exclusive, nonrecursive; no parent creation.
    const entry = { name, stat: null, directory: true };
    owned.push(entry);
    entry.stat = fs.lstatSync(name);
    fs.chmodSync(name, 0o700);
  }
  function write(name, bytes) {
    const fd = fs.openSync(name, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try {
      const entry = { name, stat: null, directory: false };
      owned.push(entry);
      entry.stat = fs.fstatSync(fd);
      fs.fchmodSync(fd, 0o600);
      fs.writeFileSync(fd, bytes);
    } finally { fs.closeSync(fd); }
  }
  function cleanup() {
    const failures = [];
    for (const entry of [...owned].reverse()) {
      try {
        // Never recurse. Reject replaced paths/ancestors, and leave unexpected
        // entries alone. Directory removal succeeds only when it is empty.
        for (const parent of owned.filter(item => item.directory && (entry.name === item.name || entry.name.startsWith(`${item.name}${path.sep}`)))) {
          if (!parent.stat) fail(`Cannot identify owned directory: ${parent.name}`);
          const current = fs.lstatSync(parent.name);
          if (!current.isDirectory() || !sameIdentity(current, parent.stat)) fail(`Replaced owned directory: ${parent.name}`);
        }
        if (!entry.stat) fail(`Cannot identify owned path: ${entry.name}`);
        const current = fs.lstatSync(entry.name);
        if (current.isSymbolicLink() || !sameIdentity(current, entry.stat) || current.isDirectory() !== entry.directory) fail(`Replaced owned path: ${entry.name}`);
        if (entry.directory) fs.rmdirSync(entry.name);
        else fs.unlinkSync(entry.name);
      } catch (error) {
        if (error.code !== 'ENOENT') failures.push(`${entry.name}: ${error.message}`);
      }
    }
    return failures;
  }
  try {
    mkdir(target);
    const resources = path.join(target, RESOURCE_DIRECTORY);
    mkdir(resources);
    mkdir(path.join(resources, 'assets'));
    for (const entry of audit.inventory) {
      const bytes = readRegular(path.join(source, entry.path), MAX_RESOURCE_BYTES);
      requireMatchingBytes(bytes, entry);
      write(path.join(resources, entry.path), bytes);
    }
    const copied = auditNativeResources(resources);
    if (!manifestBytes(copied).equals(manifestBytes(audit))) fail('Copied resource inventory differs from the source audit');
    // Detect ordinary additions/removals/changes since the initial audit, too.
    if (!manifestBytes(auditNativeResources(source)).equals(manifestBytes(audit))) fail('Staging changed during packaging');
    write(path.join(target, MANIFEST_NAME), manifestBytes(audit));
    verifyNativeResourcePackage(target);
    return audit;
  } catch (error) {
    const failures = cleanup();
    if (failures.length) throw new Error(`${error.message}; cleanup incomplete, do not use this output: ${failures.join('; ')}`, { cause: error });
    throw error;
  }
}

function main(args) {
  let audit;
  if (args.length === 4 && args[0] === '--dist-native' && args[2] === '--output') audit = packageNativeResources(args[1], args[3]);
  else if (args.length === 2 && args[0] === '--verify') audit = verifyNativeResourcePackage(args[1]);
  else fail('Usage: node scripts/bex-package-native-resources.mjs --dist-native ABSOLUTE_STAGING --output NEW_ABSOLUTE_REVIEW_DIRECTORY | --verify ABSOLUTE_PACKAGE_DIRECTORY');
  process.stdout.write(`${JSON.stringify(audit, null, 2)}\n`);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); } catch (error) { console.error(`Native resource package: ${error.message}`); process.exitCode = 1; }
}
