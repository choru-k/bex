import { readFileSync } from 'node:fs';
import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';

// Execute the exact scripts embedded in WKWebView, not a parallel reimplementation.
const nativeSource = readFileSync(new URL('../native/main.swift', import.meta.url), 'utf8');
function nativeScript(name: string): string {
  const source = nativeSource.match(new RegExp(`private let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`))?.[1];
  if (!source) throw new Error(`Missing native smoke script: ${name}`);
  return source;
}
const smokeProbe = nativeScript('smokeProbeScript');
const captureErrors = nativeScript('smokeErrorCaptureScript');
interface SmokeSnapshot {
  phase: string; clicked: boolean; ready: boolean; state: string;
  corrected: string; alert: string; errors: string[];
  documentState: string; buttonPresent: boolean; buttonDisabled: boolean | null;
}
async function probe(page: Page, shouldClick = true): Promise<SmokeSnapshot> {
  const json = await page.evaluate<string>(`JSON.stringify((${smokeProbe})(${shouldClick}))`);
  return JSON.parse(json) as SmokeSnapshot;
}
async function fixture(page: Page, ready = 'true', state = 'idle') {
  await page.setContent(`<main class="shell" data-lab-ready="${ready}" data-lab-state="${state}">
    <textarea id="editor">Private draft: do not log</textarea><button class="primary">Check</button>
  </main>`);
  await page.evaluate(() => {
    document.querySelector('button')!.addEventListener('click', () => {
      document.body.dataset.clicks = String(Number(document.body.dataset.clicks || '0') + 1);
    });
  });
}

test('native programmatic click waits for React readiness and produces the exact sample', async ({ page }) => {
  await page.addInitScript({ content: captureErrors });
  await page.goto('/');
  await expect.poll(async () => (await probe(page, false)).ready).toBe(true);
  const dispatched = await probe(page);
  expect(dispatched.phase).toBe('click-dispatched');
  expect(dispatched.clicked).toBe(true);
  await expect.poll(async () => (await probe(page, false)).phase).toBe('result');
  const result = await probe(page, false);
  expect(result.corrected).toBe('Wouldn’t this make it harder to maintain?');
  expect(result.errors).toEqual([]);
  expect(result.alert).toBe('');
});

test('a visible button before readiness is not clicked or called a submission', async ({ page }) => {
  await fixture(page, 'false');
  expect(await probe(page)).toMatchObject({ phase: 'waiting-ready', clicked: false, ready: false });
  await expect(page.locator('body')).not.toHaveAttribute('data-clicks');
  await page.locator('.shell').evaluate(element => element.setAttribute('data-lab-ready', 'true'));
  expect(await probe(page)).toMatchObject({ phase: 'click-dispatched', clicked: true, state: 'idle' });
  // The caller remembers dispatch, but an ignored click still reports idle, not submitted.
  expect(await probe(page, false)).toMatchObject({ phase: 'idle', clicked: false, state: 'idle' });
  await expect(page.locator('body')).toHaveAttribute('data-clicks', '1');
});

test('missing and disabled buttons are distinct from an accepted request', async ({ page }) => {
  await fixture(page);
  await page.locator('button').evaluate((button: HTMLButtonElement) => { button.disabled = true; });
  expect(await probe(page)).toMatchObject({ phase: 'waiting-button', clicked: false, buttonDisabled: true });
  await page.locator('button').evaluate(button => button.remove());
  expect(await probe(page)).toMatchObject({ phase: 'waiting-button', clicked: false, buttonPresent: false });
  await expect(page.locator('body')).not.toHaveAttribute('data-clicks');
});

test('pending state is observed without dispatching another request', async ({ page }) => {
  await fixture(page, 'true', 'pending');
  expect(await probe(page)).toMatchObject({ phase: 'pending', clicked: false, state: 'pending' });
  await expect(page.locator('body')).not.toHaveAttribute('data-clicks');
});

test('rendered application errors stop the smoke and do not expose the draft', async ({ page }) => {
  await fixture(page, 'true', 'error');
  await page.locator('.shell').evaluate(element => {
    const alert = document.createElement('p');
    alert.setAttribute('role', 'alert');
    alert.textContent = 'Controlled fixture failure';
    element.append(alert);
  });
  const snapshot = await probe(page);
  expect(snapshot).toMatchObject({ phase: 'error', clicked: false, alert: 'Controlled fixture failure' });
  expect(JSON.stringify(snapshot)).not.toContain('Private draft');
});

test('page errors and promise rejections are captured with bounded output', async ({ page }) => {
  await fixture(page);
  await page.evaluate(captureErrors);
  await page.evaluate(() => {
    window.dispatchEvent(new ErrorEvent('error', { message: 'Script failed' }));
    window.dispatchEvent(new PromiseRejectionEvent('unhandledrejection', {
      promise: Promise.resolve(), reason: new Error('Promise failed'),
    }));
    for (let index = 0; index < 10; index++) {
      window.dispatchEvent(new ErrorEvent('error', { message: 'x'.repeat(2_000) }));
    }
  });
  const snapshot = await probe(page);
  expect(snapshot.phase).toBe('error');
  expect(snapshot.clicked).toBe(false);
  expect(snapshot.errors.slice(0, 2)).toEqual(['Script failed', 'Promise failed']);
  expect(snapshot.errors).toHaveLength(5);
  expect(snapshot.errors.every(error => error.length <= 500)).toBe(true);
  expect(JSON.stringify(snapshot)).not.toContain('Private draft');
});

test('a real failed sample is surfaced instead of waiting for a result forever', async ({ page }) => {
  await page.addInitScript({ content: captureErrors });
  await page.goto('/');
  await expect.poll(async () => (await probe(page, false)).ready).toBe(true);
  await page.getByLabel('테스트 시나리오').selectOption('failure');
  expect(await probe(page)).toMatchObject({ phase: 'click-dispatched', clicked: true });
  await expect.poll(async () => (await probe(page, false)).phase).toBe('error');
  expect((await probe(page, false)).alert).toContain('테스트용 실패');
});

test('non-bubbling resource errors are captured before the app becomes ready', async ({ page }) => {
  await fixture(page, 'false');
  await page.evaluate(captureErrors);
  await page.evaluate(() => {
    const script = document.createElement('script');
    script.type = 'application/json';
    document.head.append(script);
    script.dispatchEvent(new Event('error', { bubbles: false }));
  });
  expect(await probe(page)).toMatchObject({ phase: 'error', clicked: false,
    errors: ['Page script/resource error'] });
});

test('a result is observable without pretending another click occurred', async ({ page }) => {
  await fixture(page, 'true', 'result');
  await page.locator('.shell').evaluate(element => {
    const result = document.createElement('p');
    result.setAttribute('data-testid', 'corrected');
    result.textContent = 'Unexpected result';
    element.append(result);
  });
  expect(await probe(page)).toMatchObject({ phase: 'result', clicked: false, corrected: 'Unexpected result' });
  await expect(page.locator('body')).not.toHaveAttribute('data-clicks');
});
