import { test, expect } from '@playwright/test';

test.beforeEach(async ({ page }) => { await page.goto('/'); });
test('vocabulary and explanation language change curated teaching without changing the correction', async ({ page }) => {
  await page.getByLabel('메시지당 설명').selectOption('2');
  await page.getByLabel('일반 어휘 수준').selectOption('wide');
  await page.getByLabel('설명 언어', { exact: true }).selectOption('en');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByTestId('corrected')).toHaveText('Wouldn’t this make it harder to maintain?');
  await expect(page.locator('.feedback-note')).toContainText(['Use the base verb after would.', 'more demanding to maintain']);
  await page.getByLabel('설명 언어', { exact: true }).selectOption('ko');
  await expect(page.getByTestId('corrected')).toHaveCount(0);
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.locator('.feedback-note').first()).toContainText('조동사 would 뒤에는');
});
test('necessary-only leaves natural language alone and hides optional style alternatives', async ({ page }) => {
  await page.getByLabel('교정 방식').selectOption('necessary-only');
  await page.getByLabel('메시지당 설명').selectOption('2');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.locator('.note-kind.alternative')).toHaveCount(0);
  await expect(page.getByTestId('corrected')).toHaveText('Wouldn’t this make it harder to maintain?');
  await page.getByLabel('테스트 시나리오').selectOption('correct');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByTestId('corrected')).toHaveText('Could we keep the implementation simple?');
  await expect(page.locator('.feedback-note')).toHaveCount(0);
});
test('language changes invalidate pending results and do not silently persist settings', async ({ page }) => {
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await page.getByLabel('설명 언어', { exact: true }).selectOption('en');
  await page.waitForTimeout(400);
  await expect(page.getByTestId('corrected')).toHaveCount(0);
  expect(await page.evaluate(() => localStorage.getItem('bex.web-lab.policy.v1'))).toBeNull();
  await page.getByLabel('학습 설정만 이 기기에 기억').check();
  await page.reload();
  await expect(page.getByLabel('설명 언어', { exact: true })).toHaveValue('en');
  await page.getByRole('button', { name: '이 실험실 초기화' }).click();
  await expect(page.getByLabel('설명 언어', { exact: true })).toHaveValue('ko');
});
