#!/usr/bin/env node
/** Explicit cloud-capable web build + bounded source continuity receipt. Never native. */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { packageNativeResources } from './bex-package-native-resources.mjs';
import { nativeResourceInputListBytes } from './bex-embed-native-resources.mjs';
import { SOURCE_RECEIPT_NAME, BUILD_COMMANDS, BUILD_ENVIRONMENT, sourceBindingInputPaths, digestBytes, canonicalBytes, canonicalPath, requireOfflineLocation, captureBuildInputs, createSourceReceipt, verifyNativeSourceBinding } from './bex-native-source-binding.mjs';

const fail = message => { throw new Error(message); };
const sameIdentity = (a, b) => a.dev === b.dev && a.ino === b.ino;
const beneath = (child, parent) => child.startsWith(`${parent}${path.sep}`);
const defaultRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function runTool(root, relative, args) {
  const executable = canonicalPath(path.join(root, relative));
  const stat = fs.lstatSync(executable);
  if (!stat.isFile() || (stat.mode & 0o7022)) fail('Installed build tool is missing or unsafe; no installation is performed');
  const result = spawnSync(process.execPath, [executable, ...args], {
    cwd: path.join(root, 'web'), shell: false, encoding: 'utf8', timeout: 120000,
    maxBuffer: 1024 * 1024,
    env: { ...BUILD_ENVIRONMENT, PATH: path.dirname(process.execPath) },
  });
  if (result.error || result.status !== 0 || result.signal) {
    const detail = result.error ? `${result.error.code ?? 'error'}: ${result.error.message}` : `exit=${result.status}, signal=${result.signal ?? 'none'}`;
    const output = [result.stdout, result.stderr].filter(Boolean).join('\n').slice(-4096);
    fail(`Build tool ${relative} failed (${detail}); ${output}`);
  }
}

/** Explicitly builds current declared inputs; never accepts an existing dist tree. */
export function prepareNativeResources(sourceRoot, outputDirectory) {
  const root = canonicalPath(sourceRoot), output = canonicalPath(outputDirectory, true);
  requireOfflineLocation(output);
  if (root === output || beneath(output, root) || beneath(root, output)) fail('Preparation output must be outside and disjoint from the checkout');
  const parent = path.dirname(output), parentStat = fs.lstatSync(parent);
  if (!parentStat.isDirectory() || (parentStat.mode & 0o7022)) fail('Preparation parent must be a safe existing directory');
  const before = captureBuildInputs(root);
  const owned = [];
  function checkRoot() {
    canonicalPath(parent);
    if (!sameIdentity(parentStat, fs.lstatSync(parent))) fail('Preparation parent was replaced');
    for (const entry of owned.filter(entry => entry.directory)) {
      if (!entry.stat || !sameIdentity(entry.stat, fs.lstatSync(entry.path)) || !fs.lstatSync(entry.path).isDirectory()) fail('Preparation directory was replaced or cannot be identified');
    }
  }
  function mkdir(value) {
    checkRoot();
    fs.mkdirSync(value, { mode: 0o700 });
    const entry = { path: value, directory: true, stat: null };
    owned.push(entry); entry.stat = fs.lstatSync(value); fs.chmodSync(value, 0o700);
  }
  function write(value, bytes) {
    checkRoot();
    const fd = fs.openSync(value, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    const entry = { path: value, directory: false, stat: null };
    owned.push(entry);
    try { entry.stat = fs.fstatSync(fd); fs.fchmodSync(fd, 0o600); fs.writeFileSync(fd, bytes); }
    finally { fs.closeSync(fd); }
  }
  function unchanged() {
    if (!canonicalBytes(captureBuildInputs(root)).equals(canonicalBytes(before))) fail('Declared source, installed dependencies or runtime changed during preparation');
  }
  try {
    mkdir(output);
    const staging = path.join(output, 'build-output'); mkdir(staging);
    for (const command of BUILD_COMMANDS) runTool(root, command.entry, command.arguments.map(argument => argument === '$PREPARATION/build-output' ? staging : argument));
    checkRoot(); unchanged();
    const packageDirectory = path.join(output, 'package');
    const manifest = packageNativeResources(staging, packageDirectory);
    // The packager owns its own bounded failure cleanup. A completed package and
    // tool-created outputs are never recursively deleted by this orchestrator.
    unchanged(); checkRoot();
    const receiptPath = path.join(output, SOURCE_RECEIPT_NAME);
    const inputFileList = path.join(output, 'native-inputs.xcfilelist');
    const listBytes = nativeResourceInputListBytes(packageDirectory, manifest, { inputPaths: sourceBindingInputPaths(receiptPath, root) });
    if (listBytes.length > 64 * 1024) fail('Generated input list exceeds its size budget');
    write(inputFileList, listBytes);
    unchanged(); checkRoot();
    const receiptBytes = canonicalBytes(createSourceReceipt(before, manifest, digestBytes(listBytes)));
    if (receiptBytes.length > 2 * 1024 * 1024) fail('Generated receipt exceeds its size budget');
    write(receiptPath, receiptBytes); // Last write: completion record, never an early marker.
    verifyNativeSourceBinding(receiptPath, root, packageDirectory, manifest.inventorySha256);
    checkRoot();
    return { schemaVersion: 1, packageDirectory, receiptPath, inputFileList, sourceSha256: before.source.sha256, inventorySha256: manifest.inventorySha256 };
  } catch (error) {
    const left = [];
    for (const entry of [...owned].reverse()) {
      try {
        canonicalPath(parent);
        if (!sameIdentity(parentStat, fs.lstatSync(parent))) fail('Preparation parent was replaced');
        for (const ancestor of owned.filter(item => item.directory && (item.path === entry.path || beneath(entry.path, item.path)))) {
          const current = fs.lstatSync(ancestor.path);
          if (!ancestor.stat || !sameIdentity(ancestor.stat, current) || !current.isDirectory() || current.isSymbolicLink()) fail('Created directory was replaced');
        }
        const current = fs.lstatSync(entry.path);
        if (!entry.stat || !sameIdentity(entry.stat, current) || current.isSymbolicLink() || current.isDirectory() !== entry.directory) fail('Cannot identify created entry');
        if (entry.directory) fs.rmdirSync(entry.path); else fs.unlinkSync(entry.path);
      } catch (cleanupError) { if (cleanupError.code !== 'ENOENT') left.push(entry.path); }
    }
    if (left.length) throw new Error(`${error.message}; preparation incomplete, do not use output; retained tool-created or unidentified entries: ${left.join(', ')}`, { cause: error });
    throw error;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    let result;
    if (args.length === 2 && args[0] === '--output') result = prepareNativeResources(defaultRoot, args[1]);
    else if (args.length === 4 && args[0] === '--verify' && args[2] === '--inventory-sha256') {
      const envelope = canonicalPath(args[1]);
      const binding = verifyNativeSourceBinding(path.join(envelope, SOURCE_RECEIPT_NAME), defaultRoot, path.join(envelope, 'package'), args[3]);
      result = { sourceSha256: binding.sourceSha256, inventorySha256: args[3] };
    } else fail('Usage: node scripts/bex-prepare-native-resources.mjs --output NEW_ABSOLUTE_OFFLINE_DIRECTORY | --verify ABSOLUTE_ENVELOPE --inventory-sha256 HASH');
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (error) { console.error(`Native resource preparation: ${error.message}`); process.exitCode = 1; }
}
