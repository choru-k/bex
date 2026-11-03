import type { CorrectionRequest, CorrectionResult, CorrectionTransport } from './model.ts';

export const SCENARIOS = [
  { id: 'verb', label: '동사 형태', text: 'Wouldn’t this makes it harder to maintain?' },
  { id: 'correct', label: '이미 자연스러운 문장', text: 'Could we keep the implementation simple?' },
  { id: 'article', label: '관사 집중 학습', text: 'We need rollback plan before we deploy.' },
  { id: 'technical', label: '기술 용어와 코드', text: 'Does this changes `kubectl get pods` or /tmp/bex.json?' },
  { id: 'failure', label: '요청 실패', text: 'Show me how a failed request is handled.' },
] as const;
export type ScenarioID = typeof SCENARIOS[number]['id'];

const FIXTURES: Record<Exclude<ScenarioID, 'failure'>, Omit<CorrectionResult, 'original'>> = {
  verb: { protocolVersion: 1, provenance: 'fixture',
    corrected: 'Wouldn’t this make it harder to maintain?',
    notes: [
      { kind: 'correction', category: 'verb-forms', before: 'makes', after: 'make',
        reason: '조동사 would 뒤에는 동사원형을 씁니다.' },
      { kind: 'alternative', category: 'expression', before: 'harder to maintain', after: 'more difficult to maintain',
        reason: '의미는 비슷합니다. 원문의 짧은 표현도 자연스럽습니다.' },
    ] },
  correct: { protocolVersion: 1, provenance: 'fixture',
    corrected: 'Could we keep the implementation simple?', notes: [] },
  article: { protocolVersion: 1, provenance: 'fixture',
    corrected: 'We need a rollback plan before we deploy.',
    notes: [{ kind: 'correction', category: 'articles', before: 'need rollback plan', after: 'need a rollback plan',
      reason: '하나의 구체적이지 않은 계획을 말하므로 단수 명사 plan 앞에 a를 씁니다.' }] },
  technical: { protocolVersion: 1, provenance: 'fixture',
    corrected: 'Does this change `kubectl get pods` or /tmp/bex.json?',
    notes: [{ kind: 'correction', category: 'verb-forms', before: 'changes', after: 'change',
      reason: 'does 뒤에는 동사원형을 씁니다. 코드와 경로는 그대로 둡니다.' }] },
};

/** Deliberately refuses unknown input. A fixture is not a working grammar model. */
export class FixtureTransport implements CorrectionTransport {
  readonly kind = 'fixture' as const;
  private readonly delayMs: number;
  constructor(delayMs = 220) { this.delayMs = delayMs; }
  async check(request: CorrectionRequest, signal: AbortSignal): Promise<CorrectionResult> {
    if (signal.aborted) throw new DOMException('Cancelled', 'AbortError');
    await new Promise<void>((resolve, reject) => {
      const abort = () => { clearTimeout(timer); reject(new DOMException('Cancelled', 'AbortError')); };
      const timer = setTimeout(() => { signal.removeEventListener('abort', abort); resolve(); }, this.delayMs);
      signal.addEventListener('abort', abort, { once: true });
    });
    if (signal.aborted) throw new DOMException('Cancelled', 'AbortError');
    const scenario = SCENARIOS.find(item => item.text === request.text);
    if (!scenario) throw new Error('현재는 샘플 검증 모드입니다. 위의 샘플을 선택하세요. 실제 AI 교정은 아직 연결되지 않았습니다.');
    if (scenario.id === 'failure') throw new Error('테스트용 실패입니다. 입력은 유지되며 다른 앱으로 전송되지 않습니다.');
    return structuredClone({ ...FIXTURES[scenario.id], original: request.text });
  }
}
