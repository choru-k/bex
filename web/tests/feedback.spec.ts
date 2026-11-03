import { test, expect } from '@playwright/test';

test.beforeEach(async ({ page }) => { await page.goto('/'); });
test('honest fixture mode, error vs alternative, and note budget', async ({ page }) => {
  await expect(page.getByText('샘플 모드 · AI 미연결')).toBeVisible();
  await page.getByLabel('메시지당 설명').selectOption('2');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByTestId('corrected')).toHaveText('Wouldn’t this make it harder to maintain?');
  await expect(page.getByText('오류 교정', { exact: true })).toBeVisible();
  await expect(page.getByText('선택 가능한 표현', { exact: true })).toBeVisible();
  await page.getByLabel('메시지당 설명').selectOption('0');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByTestId('corrected')).toHaveText('Wouldn’t this make it harder to maintain?');
  await expect(page.getByText('설명은 숨겼습니다.', { exact: false })).toBeVisible();
});
test('natural text stays unchanged', async ({ page }) => {
  await page.getByLabel('테스트 시나리오').selectOption('correct');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByTestId('corrected')).toHaveText('Could we keep the implementation simple?');
  await expect(page.getByText('그대로 사용해도 좋아요')).toBeVisible();
});
test('free text is not silently passed off as AI corrected', async ({ page }) => {
  await page.getByLabel('검토할 영어 문장').fill('A completely new sentence.');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByRole('alert')).toContainText('실제 AI 교정은 아직 연결되지 않았습니다.');
  await expect(page.getByTestId('corrected')).toHaveCount(0);
});
test('failure preserves the draft and permits another sample', async ({ page }) => {
  await page.getByLabel('테스트 시나리오').selectOption('failure');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByRole('alert')).toContainText('테스트용 실패');
  await expect(page.getByLabel('검토할 영어 문장')).toHaveValue('Show me how a failed request is handled.');
  await page.getByLabel('테스트 시나리오').selectOption('verb');
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByTestId('corrected')).toBeVisible();
});
test('source input is validated, escaped, and not persisted', async ({ page }) => {
  await page.getByLabel('지금 공부하는 자료 추가').check();
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByRole('alert')).toContainText('제목과 발췌문');
  await page.getByLabel('자료 제목', { exact: true }).fill('My private book');
  await page.getByLabel('직접 발췌한 학습 내용').fill('<script>window.bookExecuted = true</script>');
  await page.locator('summary').click();
  await expect(page.locator('pre')).toContainText('My private book');
  await page.getByLabel('학습 설정만 이 기기에 기억').check();
  const persisted = await page.evaluate(() => JSON.stringify(localStorage));
  expect(persisted).not.toContain('My private book');
  expect(persisted).not.toContain('bookExecuted');
  expect(await page.evaluate(() => (window as unknown as Record<string, unknown>).bookExecuted)).toBeUndefined();
  await page.reload();
  await expect(page.getByLabel('지금 공부하는 자료 추가')).not.toBeChecked();
});
test('editing while pending does not apply stale feedback', async ({ page }) => {
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await page.getByLabel('검토할 영어 문장').fill('New draft that must stay untouched.');
  // Wait longer than fixture latency; test targets a race, not page readiness.
  await page.waitForTimeout(500);
  await expect(page.getByTestId('corrected')).toHaveCount(0);
  await expect(page.getByLabel('검토할 영어 문장')).toHaveValue('New draft that must stay untouched.');
});
test('mobile layout fits without horizontal scrolling', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole('heading', { name: '내가 쓴 문장' })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
test('correction sends no request to an external origin', async ({ page, baseURL }) => {
  const external: string[] = [];
  const origin = new URL(baseURL!).origin;
  page.on('request', request => { if (new URL(request.url()).origin !== origin) external.push(request.url()); });
  await page.getByRole('button', { name: '샘플 피드백 보기' }).click();
  await expect(page.getByTestId('corrected')).toBeVisible();
  expect(external).toEqual([]);
});
