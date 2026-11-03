/** Real browser/build/HMR verification. Uses only synthetic fixture text. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const evidence = path.join(root, 'verification');
const sourcePath = path.join(root, 'src', 'App.tsx');
const originalSource = await readFile(sourcePath, 'utf8');
const outcomes = {};
const children = new Set();
let browser;
let changedSource = false;

function launch(args, options = {}) {
  const child = spawn(process.execPath, args, { cwd: root, stdio: 'inherit', ...options });
  children.add(child);
  child.once('error', error => { child.startError = error; });
  child.once('exit', () => children.delete(child));
  return child;
}
async function stop(child) {
  if (!child || child.exitCode !== null || child.startError) return;
  const stopped = new Promise(resolve => child.once('exit', resolve));
  child.kill('SIGTERM');
  let timer;
  try {
    await Promise.race([stopped, new Promise(resolve => {
      timer = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 3000);
    })]);
  } finally { clearTimeout(timer); }
}
async function ready(child, origin) {
  for (let i = 0; i < 100; i++) {
    if (child.startError) throw child.startError;
    if (child.exitCode !== null) throw new Error('Vite exited before it was ready.');
    try {
      const response = await fetch(origin, { signal: AbortSignal.timeout(500) });
      if (response.ok && (await response.text()).includes('Bex · Web Lab')) return;
    } catch { /* wait for startup */ }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`Vite was not ready at ${origin}`);
}
async function nativeSmoke() {
  const binary = process.env.BEX_WEB_LAB_NATIVE;
  if (!binary) { outcomes.nativeWKWebView = 'not requested on this platform'; return; }
  await new Promise((resolve, reject) => {
    const child = spawn(path.resolve(root, binary), [], {
      cwd: root, env: { ...process.env, BEX_WEB_LAB_SMOKE: '1' }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    children.add(child);
    let output = '';
    let errors = '';
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Native smoke timed out.')); }, 40_000);
    child.stdout.on('data', chunk => { output += chunk; process.stdout.write(chunk); });
    child.stderr.on('data', chunk => { errors += chunk; process.stderr.write(chunk); });
    child.once('error', error => { clearTimeout(timer); children.delete(child); reject(error); });
    child.once('exit', async code => {
      clearTimeout(timer); children.delete(child);
      await writeFile(path.join(evidence, 'native-smoke.log'), output + errors);
      if (code === 0 && output.includes('BEX_WEB_LAB_SMOKE PASS')) resolve();
      else reject(new Error(`Native smoke failed (${code}).`));
    });
  });
  outcomes.nativeWKWebView = 'passed: React loaded, submitted sample, rendered actual correction';
}

await mkdir(evidence, { recursive: true });
try {
  const dev = launch(['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '5179', '--strictPort']);
  await ready(dev, 'http://127.0.0.1:5179');
  browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 1000 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('http://127.0.0.1:5179');
  await page.getByLabel('메시지당 설명').selectOption('2');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await page.getByTestId('corrected').waitFor();
  assert.equal(await page.getByTestId('corrected').textContent(), 'Wouldn’t this make it harder to maintain?');
  await page.screenshot({ path: path.join(evidence, 'desktop-feedback.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({ path: path.join(evidence, 'mobile-feedback.png'), fullPage: true });
  outcomes.visualCapture = 'desktop and mobile screenshots captured; no horizontal mobile overflow';

  // A real edit, not a mocked HMR event. Always restore the original source afterwards.
  await page.getByLabel('검토할 영어 문장').fill('HMR keeps this unsent draft.');
  const changed = originalSource.replace('이 실험실 초기화', 'HMR 검증 표시');
  assert.notEqual(changed, originalSource);
  changedSource = true;
  await writeFile(sourcePath, changed);
  await page.getByRole('button', { name: 'HMR 검증 표시' }).waitFor({ timeout: 15_000 });
  assert.equal(await page.getByLabel('검토할 영어 문장').inputValue(), 'HMR keeps this unsent draft.');
  await writeFile(sourcePath, originalSource);
  changedSource = false;
  await page.getByRole('button', { name: '이 실험실 초기화' }).waitFor({ timeout: 15_000 });
  outcomes.hmr = 'passed: real React source edit appeared and unsent draft survived';
  await nativeSmoke();
  await stop(dev);

  const preview = launch(['node_modules/vite/bin/vite.js', 'preview', '--host', '127.0.0.1', '--port', '5180', '--strictPort']);
  await ready(preview, 'http://127.0.0.1:5180');
  await page.setViewportSize({ width: 1280, height: 1000 });
  await page.goto('http://127.0.0.1:5180');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await page.getByTestId('corrected').waitFor();
  assert.equal(await page.getByTestId('corrected').textContent(), 'Wouldn’t this make it harder to maintain?');
  await page.screenshot({ path: path.join(evidence, 'production-feedback.png'), fullPage: true });
  assert.deepEqual(errors, []);
  outcomes.productionBundle = 'passed: built assets rendered and submitted a sample without page errors';
  await stop(preview);
  outcomes.status = 'passed';
} catch (error) {
  outcomes.status = 'failed';
  outcomes.error = error.stack ?? String(error);
  console.error(error);
  process.exitCode = 1;
} finally {
  if (changedSource) await writeFile(sourcePath, originalSource);
  await browser?.close();
  for (const child of children) await stop(child);
  await writeFile(path.join(evidence, 'smoke.json'), JSON.stringify(outcomes, null, 2) + '\n');
  console.log(JSON.stringify(outcomes, null, 2));
}
