#!/usr/bin/env node
/** One entrypoint; never installs hooks, writes Bex user data, or touches /Applications. */
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const web = path.join(root, 'web');
const command = process.argv[2] ?? 'dev';
const [major, minor] = process.versions.node.split('.').map(Number);
const allowed = ['dev', 'desktop', 'test', 'check', 'e2e', 'help'];
const children = new Set();
function stop() { for (const child of children) { if (child.exitCode === null) child.kill('SIGTERM'); } }
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { stop(); process.exit(signal === 'SIGINT' ? 130 : 143); });
process.on('exit', stop);
function launch(executable, args, options = {}) {
  const child = spawn(executable, args, { cwd: web, stdio: 'inherit', ...options });
  children.add(child);
  const done = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      children.delete(child);
      if (code === 0) resolve();
      else reject(new Error(`${executable} exited with ${signal ?? code}.`));
    });
  });
  return { child, done };
}
async function run(executable, args, options) { await launch(executable, args, options).done; }
async function requireFreePort() {
  await new Promise((resolve, reject) => {
    const server = createServer();
    server.once('error', () => reject(new Error('Port 5179 is in use. Close the existing web lab before starting another instance.')));
    server.listen(5179, '127.0.0.1', () => server.close(error => error ? reject(error) : resolve()));
  });
}
async function waitUntilReady(child) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (child.exitCode !== null) throw new Error('The Vite server exited before becoming ready.');
    try {
      const response = await fetch('http://127.0.0.1:5179', { signal: AbortSignal.timeout(500) });
      if (response.ok && (await response.text()).includes('Bex · Web Lab')) return;
    } catch { /* wait for our server; port ownership was checked before launch */ }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('The web development server did not become ready.');
}
async function main() {
  if (major < 22 || (major === 22 && minor < 13)) throw new Error('Node 22.13 or newer is required.');
  if (!allowed.includes(command)) throw new Error(`Unknown command: ${command}. Use: ${allowed.join(', ')}`);
  if (command === 'help') {
    console.log('node scripts/bex-web.mjs dev      Browser + live reload (first run installs npm dependencies)\nnode scripts/bex-web.mjs desktop  Isolated macOS WKWebView lab (requires Xcode CLT)\nnode scripts/bex-web.mjs test     Domain tests; no npm install required\nnode scripts/bex-web.mjs check    Typecheck, domain tests, production build\nnode scripts/bex-web.mjs e2e      Install test browsers and run Chromium + WebKit tests');
    return;
  }
  if (command === 'test') {
    await run(process.execPath, ['--experimental-strip-types', '--test', 'tests/core.test.mjs', 'tests/coaching-quality.test.mjs', 'tests/native-smoke.test.mjs', 'tests/native-transport.test.mjs', 'tests/packaged-endpoint.test.mjs', '../scripts/tests/bex-audit-native-resources.test.mjs', '../scripts/tests/bex-helper-contract.test.mjs', '../scripts/tests/bex-native-composition-source.test.mjs', '../scripts/tests/bex-native-resource-admission.test.mjs', '../scripts/tests/bex-package-native-resources.test.mjs', '../scripts/tests/bex-package-native-resources-adversarial.test.mjs', 'tests/study-materials.test.mjs', 'tests/host-flow.test.mjs', 'tests/personalization-quality.test.mjs', 'tests/study-documents.test.mjs', '../scripts/tests/bex-native-build-inputs.test.mjs', '../scripts/tests/prompt-gate-framing.test.mjs', '../scripts/tests/bex-cross-app-safety-source.test.mjs', '../scripts/tests/bex-native-source-binding.test.mjs', '../scripts/tests/bex-accessibility-agent-source.test.mjs', '../scripts/tests/bex-accessibility-composition-source.test.mjs', '../scripts/tests/bex-ui-isolation-source.test.mjs', '../scripts/tests/bex-ui-artifact.test.mjs']);
    return;
  }
  if (command === 'desktop' && process.platform !== 'darwin') throw new Error('desktop requires macOS. Use dev for the browser lab.');
  if (!existsSync(path.join(web, 'node_modules', '.bin', 'vite'))) {
    console.log('Installing web dependencies in web/node_modules; no native Bex files are changed.');
    await run('npm', [existsSync(path.join(web, 'package-lock.json')) ? 'ci' : 'install']);
  }
  if (command === 'check') { await run('npm', ['run', 'check']); return; }
  if (command === 'e2e') {
    await run('npm', ['run', 'test:e2e:install']);
    await run('npm', ['run', 'test:e2e']); return;
  }
  await requireFreePort();
  if (command === 'dev') {
    await run(process.execPath, [path.join(web, 'node_modules', 'vite', 'bin', 'vite.js'), '--host', '127.0.0.1', '--port', '5179', '--strictPort', '--open']);
    return;
  }

  const app = path.join(web, '.native-build', 'Bex Web Lab.app');
  const executable = path.join(app, 'Contents', 'MacOS', 'BexWebLab');
  await mkdir(path.dirname(executable), { recursive: true });
  await writeFile(path.join(app, 'Contents', 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.bex.web-lab</string>
<key>CFBundleName</key><string>Bex Web Lab</string>
<key>CFBundleExecutable</key><string>BexWebLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>\n`);
  await run('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '5', 'native/main.swift', '-o', executable, '-framework', 'AppKit', '-framework', 'WebKit']);
  const server = launch(process.execPath, [path.join(web, 'node_modules', 'vite', 'bin', 'vite.js'), '--host', '127.0.0.1', '--port', '5179', '--strictPort']);
  // Register immediately: an early server exit must not become an unhandled rejection.
  let serverFailure;
  void server.done.catch(error => { serverFailure = error; });
  try {
    await waitUntilReady(server.child);
    if (serverFailure) throw serverFailure;
    console.log('Opening the isolated Web Lab. It has no access to Bex credentials or hooks.');
    const native = launch(executable, []);
    // If Vite unexpectedly stops, close the lab rather than leaving a dead window.
    void server.done.catch(() => native.child.kill('SIGTERM'));
    await native.done;
  } finally { if (server.child.exitCode === null) server.child.kill('SIGTERM'); }
}
main().catch(error => { console.error(`Bex Web Lab: ${error.message}`); stop(); process.exitCode = 1; });
