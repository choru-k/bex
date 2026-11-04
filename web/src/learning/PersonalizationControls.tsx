import type { CorrectionTransport, ExplanationLanguage, LearningPolicy, Vocabulary } from '../core/model.ts';
import { parsePolicy } from '../core/model.ts';

export function languagesFor(transport: CorrectionTransport): readonly ExplanationLanguage[] {
  return transport.kind === 'fixture' ? ['ko', 'en'] : transport.explanationLanguages ?? [];
}
/** Capability-aware local initialization. Never silently serialize unsupported saved preferences. */
export function policyForTransport(policy: LearningPolicy, transport: CorrectionTransport): LearningPolicy {
  const parsed = parsePolicy(policy); const languages = languagesFor(transport);
  if (!languages.length) { const { explanationLanguage: _unsupported, ...legacy } = parsed; return legacy; }
  return { ...parsed, explanationLanguage: parsed.explanationLanguage && languages.includes(parsed.explanationLanguage)
    ? parsed.explanationLanguage : languages[0] };
}

export function PersonalizationControls({ policy, onChange, transport }: {
  policy: LearningPolicy; onChange: (policy: LearningPolicy) => void; transport: CorrectionTransport;
}) {
  const languages = languagesFor(transport);
  const labels = { familiar: '익숙한 표현 중심', stretch: '조금씩 확장', wide: '폭넓은 표현' };
  const descriptions = {
    familiar: '자주 쓰는 일반 단어로 선택 표현을 제안합니다.',
    stretch: '익숙한 표현에서 한 단계 넓힌 대안을 제안합니다.',
    wide: '더 다양한 표현을 탐색합니다. 어려운 단어를 목표로 삼지 않습니다.',
  };
  return <div className="personalization-controls">
    <label className="field-label" htmlFor="vocabulary">일반 어휘 수준</label>
    <select id="vocabulary" value={policy.vocabulary} onChange={event => onChange({ ...policy, vocabulary: event.target.value as Vocabulary })}>
      {Object.entries(labels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
    </select>
    <p className="hint">{descriptions[policy.vocabulary]} 기술 용어·코드·의미는 유지합니다. 수준 평가는 아닙니다.</p>
    <label className="field-label" htmlFor="restraint">교정 방식</label>
    <select id="restraint" value={policy.alternatives ? 'with-alternatives' : 'necessary-only'} onChange={event => onChange({ ...policy, alternatives: event.target.value === 'with-alternatives' })}>
      <option value="necessary-only">필요한 오류만</option><option value="with-alternatives">오류 교정 + 선택 표현</option>
    </select>
    <p className="hint">두 모드 모두 자연스러운 원문은 고치지 않습니다. 선택 표현은 교정문에 자동 적용하지 않고 따로 표시합니다.</p>
    <label className="field-label" htmlFor="explanation-language">설명 언어</label>
    <select id="explanation-language" disabled={!languages.length} value={languages.length ? policy.explanationLanguage ?? languages[0] : 'provider-default'} onChange={event => onChange({ ...policy, explanationLanguage: event.target.value as ExplanationLanguage })}>
      {!languages.length && <option value="provider-default">제공자 기본 언어 · 호스트 설정 미지원</option>}
      {languages.map(language => <option key={language} value={language}>{language === 'ko' ? '한국어' : 'English'}</option>)}
    </select>
    <p className="hint">{!languages.length ? '이 호스트는 설명 언어 선택을 지원하지 않습니다. 언어 설정을 요청에 넣지 않습니다.' :
      transport.kind === 'fixture' ? '미리 작성한 샘플 설명과 선택 표현에 적용됩니다. 자유 입력의 AI 교정은 아닙니다.' :
        '설명에만 적용하며 영어 원문·교정문·인용문은 번역하지 않습니다. 요청마다 호스트 동의에서 확인할 수 있습니다.'}</p>
  </div>;
}
