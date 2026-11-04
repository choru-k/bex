import { test, expect } from '@playwright/test';

// Integration acceptance: App mounts StudyMaterialsPanel and clears stale requests on source change.
test.beforeEach(async ({ page }) => { await page.goto('/'); });
async function addBook(page: import('@playwright/test').Page, excerpt = 'Synthetic excerpt for Unit 1.') {
  await page.getByRole('button', { name: '자료 추가', exact: true }).click();
  await page.getByLabel('자료 제목·저자').fill('Synthetic book · Author');
  await page.getByRole('button', { name: '수정 적용', exact: true }).click();
  await page.getByRole('button', { name: '단원 추가', exact: true }).click();
  await page.getByLabel('단원·페이지', { exact: true }).fill('Unit 1 · p. 7');
  await page.getByLabel('학습 발췌문', { exact: true }).fill(excerpt);
  await page.getByRole('button', { name: '수정 적용', exact: true }).click();
}
test('explicitly selected excerpt enters preview; removal clears it and never persists by default', async ({ page }) => {
  await addBook(page);
  await page.getByLabel('Unit 1 · p. 7 참고', { exact: true }).check();
  await page.getByText('개발자 보기 · 모델에 전달할 요청 구조', { exact: true }).click();
  await expect(page.locator('.developer-panel pre')).toContainText('Synthetic excerpt for Unit 1.');
  expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain('Synthetic excerpt');
  await page.getByRole('button', { name: 'Unit 1 · p. 7 삭제', exact: true }).click();
  await page.getByRole('button', { name: '삭제 확인', exact: true }).click();
  await expect(page.locator('.developer-panel pre')).not.toContainText('Synthetic excerpt');
  await expect(page.getByLabel('활성 학습 단원')).toContainText('활성 단원 없음');
});
test('opt-in saves only excerpts; reload and restore require explicit source selection', async ({ page }) => {
  await addBook(page);
  await page.getByLabel('Unit 1 · p. 7 참고', { exact: true }).check();
  await page.getByLabel('자료를 이 브라우저에 저장', { exact: true }).check();
  const saved = await page.evaluate(() => JSON.parse(localStorage.getItem('bex.study-excerpts.v1')!));
  expect(Object.keys(saved)).toEqual(['version', 'materials']);
  await page.reload();
  await expect(page.getByLabel('활성 학습 단원')).toContainText('활성 단원 없음');
  await expect(page.getByLabel('Unit 1 · p. 7 참고', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: '기기 자료 불러오기', exact: true }).click();
  await expect(page.getByLabel('Unit 1 · p. 7 참고', { exact: true })).not.toBeChecked();
  await expect(page.getByLabel('자료를 이 브라우저에 저장', { exact: true })).not.toBeChecked();
  await page.getByRole('button', { name: '기기에 저장된 자료 삭제', exact: true }).click();
  await page.getByRole('button', { name: '삭제 취소', exact: true }).click();
  expect(await page.evaluate(() => localStorage.getItem('bex.study-excerpts.v1'))).not.toBeNull();
  await page.getByRole('button', { name: '기기에 저장된 자료 삭제', exact: true }).click();
  await page.getByRole('button', { name: '삭제 확인', exact: true }).click();
  expect(await page.evaluate(() => localStorage.getItem('bex.study-excerpts.v1'))).toBeNull();
});
test('source replacement and reset clear panel selection, pending feedback cannot reappear', async ({ page }) => {
  await addBook(page);
  await page.getByLabel('Unit 1 · p. 7 참고', { exact: true }).check();
  await page.getByRole('button', { name: '샘플 피드백 보기', exact: true }).click();
  await page.getByRole('button', { name: '참고 해제', exact: true }).click();
  await page.waitForTimeout(500);
  await expect(page.getByTestId('corrected')).toHaveCount(0);
  await page.getByLabel('Unit 1 · p. 7 참고', { exact: true }).check();
  await page.getByLabel('자료 제목', { exact: true }).fill('Manual replacement');
  await expect(page.getByLabel('Unit 1 · p. 7 참고', { exact: true })).not.toBeChecked();
  await page.getByLabel('Unit 1 · p. 7 참고', { exact: true }).check();
  await page.getByRole('button', { name: '이 실험실 초기화', exact: true }).click();
  await expect(page.getByLabel('Unit 1 · p. 7 참고', { exact: true })).not.toBeChecked();
});
test('malicious excerpt stays text, no external requests, narrow layout fits', async ({ page, baseURL }) => {
  const external: string[] = []; const origin = new URL(baseURL!).origin;
  page.on('request', request => { if (new URL(request.url()).origin !== origin) external.push(request.url()); });
  await page.setViewportSize({ width: 390, height: 844 });
  await addBook(page, '<script>window.studyExecuted = true</script><img src="https://invalid.example/private">');
  await page.getByLabel('Unit 1 · p. 7 참고', { exact: true }).check();
  await expect(page.locator('.study-excerpt')).toContainText('<script>');
  expect(await page.evaluate(() => (window as unknown as Record<string, unknown>).studyExecuted)).toBeUndefined();
  expect(external).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});
