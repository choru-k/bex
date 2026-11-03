import { useEffect, useRef, useState } from 'react';
import type { Focus, LearningPolicy, StudySource, Vocabulary } from './core/model.ts';
import type { CorrectionResult } from './core/model.ts';
import { buildCoachContext, clearPolicy, DEFAULT_POLICY, hasSavedPolicy, loadPolicy, makeRequest, MAX_EXCERPT,
  MAX_INPUT, parseResult, presentNotes, RequestGate, savePolicy } from './core/model.ts';
import { FixtureTransport, SCENARIOS } from './core/fixtures.ts';

const transport = new FixtureTransport();
function initialPreferences() {
  try { return { policy: loadPolicy(window.localStorage), remember: hasSavedPolicy(window.localStorage) }; }
  catch { return { policy: { ...DEFAULT_POLICY }, remember: false }; }
}

export function App() {
  const [text, setText] = useState<string>(SCENARIOS[0].text);
  const [initial] = useState(initialPreferences);
  const [policy, setPolicy] = useState<LearningPolicy>(initial.policy);
  const [remember, setRemember] = useState(initial.remember);
  const [sourceEnabled, setSourceEnabled] = useState(false);
  const [source, setSource] = useState<StudySource>({ title: '', section: '', excerpt: '' });
  const [result, setResult] = useState<CorrectionResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [ready, setReady] = useState(false);
  const gate = useRef(new RequestGate());

  useEffect(() => {
    setReady(true);
    return () => gate.current.cancel();
  }, []);
  function invalidate() {
    gate.current.cancel(); setBusy(false); setResult(null); setError(''); setNotice('');
  }
  function updatePolicy(next: LearningPolicy) {
    invalidate(); setPolicy(next);
    if (remember) {
      try { if (!savePolicy(window.localStorage, next)) setNotice('설정을 저장하지 못했습니다. 이번 세션에서는 적용됩니다.'); }
      catch { setNotice('브라우저 저장소를 사용할 수 없습니다. 이번 세션에서만 적용됩니다.'); }
    }
  }
  function rememberPolicy(enabled: boolean) {
    setRemember(enabled);
    try {
      const ok = enabled ? savePolicy(window.localStorage, policy) : clearPolicy(window.localStorage);
      setNotice(ok ? (enabled ? '학습 설정만 이 기기에 저장합니다. 원문과 자료는 저장하지 않습니다.' : '저장된 학습 설정을 삭제했습니다.')
        : '브라우저 저장소를 사용할 수 없습니다.');
    } catch { setNotice('브라우저 저장소를 사용할 수 없습니다.'); }
  }
  async function check() {
    // StrictMode's initial effect cleanup can cancel a request dispatched as
    // soon as the DOM appears. Accept interactions only after effects are ready.
    if (!ready) return;
    setError(''); setNotice(''); setResult(null);
    let request;
    try { request = makeRequest(text, policy, sourceEnabled ? source : null); }
    catch (cause) { setError(cause instanceof Error ? cause.message : '입력을 확인하세요.'); return; }
    const token = gate.current.start();
    setBusy(true);
    try {
      const raw = await transport.check(request, token.signal);
      if (gate.current.isCurrent(token)) setResult(parseResult(raw, request.text));
    } catch (cause) {
      if (gate.current.isCurrent(token)) setError(cause instanceof Error ? cause.message : '요청을 처리하지 못했습니다.');
    } finally { if (gate.current.isCurrent(token)) setBusy(false); }
  }
  async function copyResult() {
    if (!result) return;
    try { await navigator.clipboard.writeText(result.corrected); setNotice('교정문을 복사했습니다. 자동 전송은 하지 않습니다.'); }
    catch { setNotice('복사 권한이 없습니다. 교정문을 직접 선택해 복사하세요.'); }
  }
  function reset() {
    invalidate(); setText(SCENARIOS[0].text); setPolicy({ ...DEFAULT_POLICY });
    setSourceEnabled(false); setSource({ title: '', section: '', excerpt: '' }); setRemember(false);
    try { if (!clearPolicy(window.localStorage)) setNotice('저장된 설정을 삭제하지 못했습니다.'); } catch { setNotice('메모리 상태는 초기화했지만 저장된 설정 삭제는 확인하지 못했습니다.'); }
  }
  let preview = '';
  try { preview = JSON.stringify(buildCoachContext(makeRequest(text, policy, sourceEnabled ? source : null)), null, 2); }
  catch { preview = '유효한 문장과 자료를 입력하면 요청 구조가 표시됩니다.'; }
  const notes = result ? presentNotes(result, policy) : [];

  return (
    <main className="shell" data-lab-ready={ready}
      data-lab-state={busy ? 'pending' : error ? 'error' : result ? 'result' : 'idle'}>
      <header className="topbar">
        <a className="brand" href="#editor" aria-label="Bex 교정 입력으로 이동"><span className="brand-mark">b.</span><strong>Bex</strong><span className="brand-label">WEB LAB</span></a>
        <span className="mode"><span className="status-dot" />샘플 모드 · AI 미연결</span>
      </header>
      <section className="intro">
        <p className="eyebrow">BETTER EXPRESSION, LESS INTERRUPTION</p>
        <h1>하던 대화에서,<br className="mobile-break" /> 한 문장씩 더 자연스럽게.</h1>
        <p>교정은 정확하게, 설명은 필요한 만큼만. Bex의 새 학습 화면을 실험하는 공간입니다.</p>
      </section>
      <div className="lab-banner" role="note">
        <strong>개발용 실험실입니다.</strong> 샘플에만 미리 정한 결과를 표시합니다. 자유 입력의 실제 AI 교정·Codex 연동·교재 검색은 아직 연결되지 않았습니다.
      </div>
      <div className="workspace">
        <div className="conversation">
          <section className="panel editor-panel" aria-labelledby="editor-title">
            <div className="section-heading"><div><span className="step">01</span><h2 id="editor-title">내가 쓴 문장</h2></div><span className="muted">전송 없이 검토</span></div>
            <label className="field-label" htmlFor="scenario">테스트 시나리오</label>
            <select id="scenario" value={SCENARIOS.find(item => item.text === text)?.id ?? 'custom'} onChange={event => {
              const scenario = SCENARIOS.find(item => item.id === event.target.value);
              if (scenario) { invalidate(); setText(scenario.text); }
            }}>
              {SCENARIOS.map(item => <option key={item.id} value={item.id}>{item.label}</option>)}
              <option value="custom" disabled>직접 입력 — 실제 교정 미연결</option>
            </select>
            <label className="sr-only" htmlFor="editor">검토할 영어 문장</label>
            <textarea id="editor" className="composer" spellCheck={false} value={text} maxLength={MAX_INPUT}
              onChange={event => { invalidate(); setText(event.target.value); }}
              onKeyDown={event => { if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') { event.preventDefault(); if (!busy) void check(); } }} />
            <div className="editor-actions"><span className="muted">{text.length.toLocaleString()} / 12,000 · ⌘/Ctrl + Enter</span>
              {busy && <button type="button" className="button secondary" onClick={() => { invalidate(); setNotice('검토를 취소했습니다.'); }}>취소</button>}
              <button type="button" className="button primary" disabled={!ready || busy || !text.trim()} onClick={() => void check()}>{busy ? '샘플 확인 중…' : '샘플 피드백 보기'}<span aria-hidden="true">↗</span></button>
            </div>
          </section>
          {error && <p className="alert error" role="alert">{error}</p>}
          {notice && <p className="alert" role="status">{notice}</p>}
          <section className="panel feedback-panel" aria-labelledby="feedback-title" aria-busy={busy}>
            <div className="section-heading"><div><span className="step">02</span><h2 id="feedback-title">한눈에 보는 피드백</h2></div>{result && <span className="tag">샘플 결과</span>}</div>
            {result ? <>
              <div className="result-heading"><span className="field-label">{result.corrected === result.original ? '그대로 사용해도 좋아요' : '교정문'}</span><button type="button" className="text-button" onClick={() => void copyResult()}>복사</button></div>
              <p className="corrected" data-testid="corrected">{result.corrected}</p>
              {result.corrected === result.original && <p className="muted">이 샘플에는 수정할 오류가 없습니다. 불필요한 대안을 만들지 않았습니다.</p>}
              {notes.map((note, index) => <article className="feedback-note" key={`${note.kind}-${index}`}>
                <span className={`note-kind ${note.kind}`}>{note.kind === 'correction' ? '오류 교정' : '선택 가능한 표현'}</span>
                <p className="change"><del>{note.before}</del><span aria-label="에서"> → </span><strong>{note.after}</strong></p>
                <p>{note.reason}</p>
              </article>)}
              {policy.maxNotes === 0 && <p className="muted">설명은 숨겼습니다. 교정문은 그대로 유지됩니다.</p>}
            </> : <div className="empty-state"><span className="empty-mark" aria-hidden="true">Aa</span><h3>{busy ? '피드백을 준비하고 있습니다' : '내 문장은 유지하고, 필요한 부분만'}</h3><p>샘플을 선택해 교정과 표현 제안을 비교하세요.<br />오른쪽에서 설명의 양과 집중 학습 항목을 바꿀 수 있습니다.</p></div>}
          </section>
        </div>
        <aside className="panel settings-panel" aria-labelledby="settings-title">
          <div className="section-heading"><div><span className="step">03</span><h2 id="settings-title">나에게 맞추기</h2></div></div>
          <label className="field-label" htmlFor="vocabulary">일반 어휘 수준</label>
          <select id="vocabulary" value={policy.vocabulary} onChange={event => updatePolicy({ ...policy, vocabulary: event.target.value as Vocabulary })}>
            <option value="familiar">익숙한 표현 중심</option><option value="stretch">조금씩 확장</option><option value="wide">폭넓은 표현</option>
          </select>
          <p className="hint">기술 용어는 그대로 보존합니다. 샘플 문장은 고정이며, 이 설정은 연결 예정인 모델 요청에 포함됩니다.</p>
          <label className="field-label" htmlFor="notes">메시지당 설명</label>
          <select id="notes" value={policy.maxNotes} onChange={event => updatePolicy({ ...policy, maxNotes: Number(event.target.value) as 0 | 1 | 2 })}>
            <option value="0">교정문만</option><option value="1">핵심 1개</option><option value="2">최대 2개</option>
          </select>
          <label className="field-label" htmlFor="focus">집중 학습</label>
          <select id="focus" value={policy.focus} onChange={event => updatePolicy({ ...policy, focus: event.target.value as Focus })}>
            <option value="general">전체에서 필요한 부분</option><option value="articles">관사</option><option value="verb-forms">동사 형태</option><option value="expression">표현 확장</option>
          </select>
          <label className="check-row"><input type="checkbox" checked={policy.alternatives} onChange={event => updatePolicy({ ...policy, alternatives: event.target.checked })} /><span>선택 가능한 다른 표현도 보기</span></label>
          <div className="divider" />
          <label className="check-row source-toggle"><input type="checkbox" checked={sourceEnabled} onChange={event => { invalidate(); setSourceEnabled(event.target.checked); }} /><span>지금 공부하는 자료 추가</span></label>
          <p className="hint">발췌문을 요청 데이터로 준비합니다. 샘플 피드백에는 적용되지 않으며, 외부로 전송하지 않습니다.</p>
          {sourceEnabled && <div className="source-fields">
            <label className="field-label" htmlFor="source-title">자료 제목</label><input id="source-title" maxLength={160} value={source.title} placeholder="예: 내가 공부하는 교재" onChange={event => { invalidate(); setSource({ ...source, title: event.target.value }); }} />
            <label className="field-label" htmlFor="source-section">단원·페이지 (선택)</label><input id="source-section" maxLength={160} value={source.section} placeholder="예: Unit 3 · p. 24" onChange={event => { invalidate(); setSource({ ...source, section: event.target.value }); }} />
            <label className="field-label" htmlFor="source-excerpt">직접 발췌한 학습 내용</label><textarea id="source-excerpt" maxLength={MAX_EXCERPT} value={source.excerpt} placeholder="연습하려는 표현이나 설명을 붙여 넣으세요." onChange={event => { invalidate(); setSource({ ...source, excerpt: event.target.value }); }} />
            <span className="hint">{source.excerpt.length} / {MAX_EXCERPT} · 이번 세션에만 유지</span>
          </div>}
          <div className="divider" />
          <label className="check-row"><input type="checkbox" checked={remember} onChange={event => rememberPolicy(event.target.checked)} /><span>학습 설정만 이 기기에 기억</span></label>
          <p className="hint">원문·발췌문·결과는 저장하지 않습니다. 기존 Bex 데이터나 연동 설정도 변경하지 않습니다.</p>
          <button className="text-button reset" type="button" onClick={reset}>이 실험실 초기화</button>
        </aside>
      </div>
      <details className="developer-panel"><summary>개발자 보기 · 모델에 전달할 요청 구조</summary><p className="hint">현재는 전송하지 않습니다. 설정과 자료가 UI 밖의 독립 모듈에서 구성되는지 확인하는 화면입니다.</p><pre>{preview}</pre></details>
      <footer><span>Bex Web Lab · protocol v1</span><span>로컬 전용 / 자동 전송 없음 / 기존 앱 변경 없음</span></footer>
    </main>
  );
}
