import { test, expect } from '@playwright/test';

const original = 'Wouldn’t this makes it harder to maintain?';
const corrected = 'Wouldn’t this make it harder to maintain?';
test.beforeEach(async ({ page }) => {
  await page.goto('/');
  await expect(page.getByTestId('host-flow-lab')).toHaveAttribute('data-ready', 'true');
});

test('nonblocking original sends preserve the conversation while feedback arrives separately', async ({ page }) => {
  await expect(page.getByText('SIMULATED · 시뮬레이션')).toBeVisible();
  await page.getByRole('button', { name: '원문 모의 전송', exact: true }).click();
  await expect(page.getByTestId('host-transcript')).toContainText(original);
  await expect(page.getByLabel('모의 대화에 보낼 문장')).toHaveValue('');
  await page.getByLabel('모의 대화에 보낼 문장').fill('My next message stays here.');
  await expect(page.getByTestId('host-feedback-card')).toContainText(corrected);
  await expect(page.getByTestId('host-transcript')).not.toContainText(corrected);
  await expect(page.getByLabel('모의 대화에 보낼 문장')).toHaveValue('My next message stays here.');
});
test('feedback refusal never prevents unknown free text from being sent', async ({ page }) => {
  await page.getByLabel('모의 대화에 보낼 문장').fill('A new sentence without a fixture.');
  await page.getByRole('button', { name: '원문 모의 전송', exact: true }).click();
  await expect(page.getByTestId('host-transcript')).toContainText('A new sentence without a fixture.');
  await expect(page.getByTestId('host-feedback-card')).toContainText('원문 전송에는 영향이 없습니다.');
});
test('review cannot send until Fix & Send confirmation and repeated clicks cannot duplicate', async ({ page }) => {
  await page.getByRole('button', { name: '보내기 전 검토', exact: true }).click();
  await expect(page.getByTestId('host-review-corrected')).toHaveText(corrected);
  await expect(page.getByTestId('host-transcript')).not.toContainText(original);
  await expect(page.getByLabel('모의 대화에 보낼 문장')).toHaveValue(original);
  await page.getByRole('button', { name: 'Fix & Send · 모의 전송 확인', exact: true }).click();
  await expect(page.getByTestId('host-transcript').locator('li')).toHaveCount(1);
  await expect(page.getByTestId('host-transcript')).toContainText(corrected);
  await expect(page.getByRole('button', { name: 'Fix & Send · 모의 전송 확인', exact: true })).toHaveCount(0);
  await expect(page.getByTestId('host-feedback-card')).toHaveCount(0);
});
test('editing after review clears approval and keeps the changed draft', async ({ page }) => {
  await page.getByRole('button', { name: '보내기 전 검토', exact: true }).click();
  await expect(page.getByTestId('host-review-corrected')).toBeVisible();
  await page.getByLabel('모의 대화에 보낼 문장').fill('Changed draft.');
  await expect(page.getByTestId('host-review-corrected')).toHaveCount(0);
  await expect(page.getByTestId('host-transcript')).toContainText('아직 전송한 문장이 없습니다.');
  await expect(page.getByLabel('모의 대화에 보낼 문장')).toHaveValue('Changed draft.');
});
test('switching simulated apps dismisses approval and labels feedback with the source app', async ({ page }) => {
  await page.getByRole('button', { name: '보내기 전 검토', exact: true }).click();
  await expect(page.getByTestId('host-review-corrected')).toBeVisible();
  await page.getByLabel('모의 대화 앱').selectOption('claude');
  await expect(page.getByTestId('host-review-corrected')).toHaveCount(0);
  await page.getByRole('button', { name: '원문 모의 전송', exact: true }).click();
  await page.getByLabel('모의 대화 앱').selectOption('other');
  await expect(page.getByTestId('host-feedback-card')).toContainText('Claude');
  await expect(page.getByTestId('host-feedback-card')).toContainText(corrected);
  await expect(page.getByTestId('host-transcript')).toContainText('Claude');
});
test('close and pending cancellation never send and cannot leak a late result', async ({ page }) => {
  await page.getByRole('button', { name: '보내기 전 검토', exact: true }).click();
  await page.getByRole('button', { name: '검토 취소', exact: true }).click();
  await page.getByRole('button', { name: '보내기 전 검토', exact: true }).click();
  await expect(page.getByTestId('host-review-corrected')).toBeVisible();
  await page.getByRole('button', { name: '검토 닫기', exact: true }).click();
  await expect(page.getByTestId('host-review-corrected')).toHaveCount(0);
  await expect(page.getByLabel('모의 대화에 보낼 문장')).toHaveValue(original);
  await expect(page.getByTestId('host-transcript')).toContainText('아직 전송한 문장이 없습니다.');
});
test('reset and reload forget the session transcript and feedback', async ({ page }) => {
  await page.getByRole('button', { name: '원문 모의 전송', exact: true }).click();
  await expect(page.getByTestId('host-transcript')).toContainText(original);
  await page.getByRole('button', { name: '이 실험실 초기화', exact: true }).click();
  await expect(page.getByTestId('host-feedback-card')).toHaveCount(0);
  await expect(page.getByTestId('host-transcript')).toContainText('아직 전송한 문장이 없습니다.');
  await page.getByRole('button', { name: '원문 모의 전송', exact: true }).click();
  await page.reload();
  await expect(page.getByTestId('host-feedback-card')).toHaveCount(0);
  await expect(page.getByTestId('host-transcript')).toContainText('아직 전송한 문장이 없습니다.');
});
test('simulated flows make no external requests and persist no transcript', async ({ page, baseURL }) => {
  const external: string[] = []; const origin = new URL(baseURL!).origin;
  page.on('request', request => { if (new URL(request.url()).origin !== origin) external.push(request.url()); });
  await page.getByRole('button', { name: '원문 모의 전송', exact: true }).click();
  await expect(page.getByTestId('host-feedback-card')).toContainText(corrected);
  const persisted = await page.evaluate(() => JSON.stringify({ local: localStorage, session: sessionStorage }));
  expect(persisted).not.toContain(original); expect(persisted).not.toContain(corrected);
  expect(external).toEqual([]);
});
test('mobile flow fits without horizontal overflow', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByTestId('host-flow-lab').scrollIntoViewIfNeeded();
  await page.getByRole('button', { name: '보내기 전 검토', exact: true }).click();
  await expect(page.getByTestId('host-review-corrected')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
