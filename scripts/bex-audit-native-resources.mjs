#!/usr/bin/env node
/** Read-only, fail-closed audit of the constrained native Vite output, not JS semantics. */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const NATIVE_CSP = "default-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'";
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw new Error(message); };

// No normalization of hostile aliases before checking them; reject every symlink
// component, including the staging root and its ancestors.
function checkedPath(input, allowMissingLeaf = false) {
  if (typeof input !== 'string' || !input || input.includes('\0') || input.includes('\\') || input.split('/').some(p => p === '..' || p === '.')) fail('Use an explicit path without dot segments or backslashes');
  const absolute = path.resolve(input);
  const parts = absolute.slice(path.parse(absolute).root.length).split(path.sep);
  let current = path.parse(absolute).root;
  for (const [i, part] of parts.entries()) {
    current = path.join(current, part);
    let stat;
    try { stat = fs.lstatSync(current); } catch (error) {
      if (allowMissingLeaf && i === parts.length - 1 && error.code === 'ENOENT') return absolute;
      throw error;
    }
    if (stat.isSymbolicLink()) fail(`Symlink rejected: ${current}`);
    if (i < parts.length - 1 && !stat.isDirectory()) fail(`Not a directory: ${current}`);
  }
  return absolute;
}

export function nativeHTML(script, style) {
  return `<!doctype html>
<html lang="ko">
  <head>
    <meta charset="UTF-8" />
    <meta http-equiv="Content-Security-Policy" content="${NATIVE_CSP}" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="color-scheme" content="light dark" />
    <title>Bex · Native Preview</title>
    <script type="module" crossorigin src="./assets/${script}"></script>
    <link rel="stylesheet" crossorigin href="./assets/${style}">
  </head>
  <body>
    <div id="root"></div>
  </body>
</html>
`;
}

function readRegular(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || (stat.mode & 0o7133)) fail(`Nonregular, hard-linked or unsafe-mode resource: ${file}`);
    if (stat.size > 16 * 1024 * 1024) fail(`Resource exceeds 16 MiB profile limit: ${file}`);
    return fs.readFileSync(fd);
  } finally { fs.closeSync(fd); }
}

export function auditNativeResources(directory) {
  const root = checkedPath(directory);
  if (!fs.lstatSync(root).isDirectory()) fail('Staging input must be a directory');
  const files = new Map();
  function walk(dir, prefix = '') {
    for (const name of fs.readdirSync(dir).sort()) {
      const relative = prefix + name;
      const absolute = path.join(dir, name);
      const stat = fs.lstatSync(absolute);
      if (stat.isSymbolicLink()) fail(`Symlink rejected: ${relative}`);
      if (stat.isDirectory()) {
        if (relative !== 'assets') fail(`Unexpected directory: ${relative}`);
        walk(absolute, 'assets/');
      } else {
        if (!stat.isFile()) fail(`Nonregular resource: ${relative}`);
        if (!(relative === 'native.html' || /^assets\/native-[A-Za-z0-9_-]{8,64}\.(js|css)$/.test(relative))) fail(`Unexpected file: ${relative}`);
        files.set(relative, readRegular(absolute));
      }
    }
  }
  walk(root);
  const scripts = [...files.keys()].filter(name => name.endsWith('.js'));
  const styles = [...files.keys()].filter(name => name.endsWith('.css'));
  if (files.size !== 3 || !files.has('native.html') || scripts.length !== 1 || styles.length !== 1) fail('Expected exactly native.html, one native module and one stylesheet');
  const expected = nativeHTML(path.basename(scripts[0]), path.basename(styles[0]));
  if (!files.get('native.html').equals(Buffer.from(expected))) fail('Native HTML does not match the exact CSP/resource template profile');
  const inventory = [...files].sort(([a], [b]) => a.localeCompare(b, 'en')).map(([name, bytes]) => ({ path: name, bytes: bytes.length, sha256: sha256(bytes) }));
  return {
    schemaVersion: 1,
    profile: 'bex-native-vite-single-entry-v1',
    csp: NATIVE_CSP,
    inventory,
    inventorySha256: sha256(Buffer.from(JSON.stringify(inventory))),
    limitations: 'Static resource inventory and HTML/CSP configuration only. Does not prove JavaScript/CSS semantics, provenance, WebKit enforcement, or network isolation. No runtime, signing, installation or activation performed.',
  };
}

export function writeManifest(manifest, output, directory) {
  const root = checkedPath(directory);
  const target = checkedPath(output, true);
  const relative = path.relative(root, target);
  if (relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) fail('Manifest output must be outside staging');
  fs.writeFileSync(target, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
}

function main(args) {
  if (!(args.length === 2 || args.length === 4) || args[0] !== '--dist-native' || (args.length === 4 && args[2] !== '--manifest')) fail('Usage: node scripts/bex-audit-native-resources.mjs --dist-native PATH [--manifest NEW_PATH_OUTSIDE_STAGING]');
  const manifest = auditNativeResources(args[1]);
  if (args.length === 4) writeManifest(manifest, args[3], args[1]);
  else process.stdout.write(`${JSON.stringify(manifest, null, 2)}\n`);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); } catch (error) { console.error(`Native resource audit: ${error.message}`); process.exitCode = 1; }
}
