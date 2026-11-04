import { useEffect, useRef, useState } from 'react';
import { FixtureTransport, SCENARIOS } from '../core/fixtures.ts';
import { presentNotes } from '../core/model.ts';
import type { LearningPolicy } from '../core/model.ts';
import { HostFlow, SimulatedHost } from './hostFlow.ts';
import type { HostFlowState } from './hostFlow.ts';
import './hostFlow.css';

const APP_LABELS: Record<string, string> = { chatgpt: 'ChatGPT', claude: 'Claude', other: '다른 앱' };
const sampleTransport = new FixtureTransport(700);

/** Browser-only fixture. Never mounted by App when a native transport is present. */
export function HostFlowLab({ policy }: { policy: LearningPolicy }) {
  const host = useRef(new SimulatedHost('chatgpt', SCENARIOS[0].text));
  const flow = useRef<HostFlow | null>(null);
  const [state, setState] = useState<HostFlowState>({ feedback: [], review: { status: 'idle' } });
  const [draft, setDraft] = useState(host.current.snapshot());
  const [transcript, setTranscript] = useState(host.current.transcript());
  const [ready, setReady] = useState(false);
  const [notice, setNotice] = useState('');
  useEffect(() => {
    const current = new HostFlow(sampleTransport, () => setState(current.snapshot()));
    flow.current = current; setReady(true);
    return () => { current.dispose(); flow.current = null; };
  }, []);
  useEffect(() => { flow.current?.configure(policy); }, [policy]);
  function refreshHost() { setDraft(host.current.snapshot()); setTranscript(host.current.transcript()); }
  function edit(text: string) {
    flow.current?.cancelReview(); host.current.edit(text); refreshHost(); setNotice('');
  }
  function sendOriginal() {
    if (!flow.current) return;
    flow.current.cancelReview();
    try {
      // The host commits first. Coaching cannot suppress, replace, or replay this send.
      const event = host.current.sendOriginal();
      refreshHost(); setNotice('원문을 모의 대화에 추가했습니다. 피드백은 별도로 도착합니다.');
      flow.current.observeSent(event);
    } catch { setNotice('모의 전송할 문장을 입력하세요.'); }
  }
  function confirmReview() {
    if (state.review.status !== 'ready' || !flow.current) return;
    const outcome = flow.current.confirmFixAndSend(host.current, state.review.id);
    refreshHost();
    setNotice(outcome.status === 'sent' ? '확인한 교정문만 모의 대화에 추가했습니다.' :
      outcome.status === 'unknown' ? '전송 여부를 확인할 수 없습니다. 다시 보내기 전에 원래 앱을 확인하세요.' : '대상이나 문장이 바뀌어 전송하지 않았습니다. 다시 검토하세요.');
  }
  return <section className="panel host-flow" aria-labelledby="host-flow-title" data-testid="host-flow-lab" data-ready={ready}>
    <div className="section-heading"><div><span className="step">04</span><h2 id="host-flow-title">대화는 계속, 학습은 옆에서</h2></div><span className="tag">SIMULATED · 시뮬레이션</span></div>
    <p className="hint">아래는 브라우저 안의 모의 대화입니다. 실제 ChatGPT·Claude·다른 앱을 읽거나 전송하지 않습니다. 원문을 먼저 보내고, 샘플 피드백을 따로 받아보세요. 오른쪽 학습 설정이 피드백 양에 적용됩니다.</p>
    <div className="host-flow-grid">
      <div>
        <label className="field-label" htmlFor="host-app">모의 대화 앱</label>
        <select id="host-app" value={draft.appId} onChange={event => {
          flow.current?.cancelReview(); host.current.switchTarget(event.target.value); refreshHost(); setNotice('');
        }}>{Object.entries(APP_LABELS).map(([id, label]) => <option key={id} value={id}>{label} · 시뮬레이션</option>)}</select>
        <label className="field-label" htmlFor="host-sample">모의 대화 샘플</label>
        <select id="host-sample" value={SCENARIOS.find(item => item.text === draft.text)?.id ?? 'custom'} onChange={event => {
          const sample = SCENARIOS.find(item => item.id === event.target.value); if (sample) edit(sample.text);
        }}>{SCENARIOS.map(item => <option key={item.id} value={item.id}>{item.label}</option>)}<option value="custom" disabled>직접 입력 · 실제 AI 미연결</option></select>
        <label className="field-label" htmlFor="host-draft">모의 대화에 보낼 문장</label>
        <textarea id="host-draft" maxLength={12_000} value={draft.text} onChange={event => edit(event.target.value)} spellCheck={false} />
        <div className="editor-actions">
          <button type="button" className="button secondary" disabled={!ready || !draft.text.trim() || state.review.status === 'pending' || state.review.status === 'unknown'} onClick={() => { setNotice(''); flow.current?.beginReview(host.current); }}>보내기 전 검토</button>
          <button type="button" className="button primary" disabled={!ready || !draft.text.trim() || state.review.status === 'unknown'} onClick={sendOriginal}>원문 모의 전송</button>
        </div>
        <p className="hint">원문 전송은 피드백을 기다리지 않습니다. 검토만으로는 전송하지 않으며, 교정 전송에는 아래의 별도 확인이 필요합니다.</p>
        {state.review.status === 'pending' && <div className="host-review" role="status">교정안을 준비하는 중입니다. 아직 보내지 않았습니다.<button type="button" className="text-button" onClick={() => flow.current?.cancelReview()}>검토 취소</button></div>}
        {state.review.status === 'ready' && <div className="host-review" aria-label="모의 전송 전 검토">
          <strong>{APP_LABELS[state.review.draft.appId]} · 확인 후에만 모의 전송</strong>
          <p className="hint">원문</p><p className="host-message">{state.review.draft.text}</p>
          <p className="hint">교정문</p><p className="corrected" data-testid="host-review-corrected">{state.review.result.corrected}</p>
          <div className="editor-actions"><button type="button" className="button secondary" onClick={() => flow.current?.cancelReview()}>검토 닫기</button><button type="button" className="button primary" onClick={confirmReview}>Fix &amp; Send · 모의 전송 확인</button></div>
        </div>}
        {state.review.status === 'unavailable' && <p className="alert" role="status">검토 결과를 준비하지 못했습니다. 아무것도 전송하지 않았습니다.</p>}
        {state.review.status === 'blocked' && <p className="alert" role="status">문장 또는 대상이 바뀌어 교정문을 전송하지 않았습니다.</p>}
        {notice && <p className="hint" role="status">{notice}</p>}
        <h3>모의 대화 기록</h3>
        <ol className="host-transcript" aria-label="모의 대화 기록" data-testid="host-transcript">
          {transcript.length === 0 && <li className="hint">아직 전송한 문장이 없습니다.</li>}
          {transcript.map(message => <li key={message.messageId}><span className="hint">{APP_LABELS[message.appId]} · {message.origin === 'original' ? '원문 그대로' : '확인한 교정문'}</span><p className="host-message">{message.text}</p></li>)}
        </ol>
      </div>
      <aside className="host-feedback" aria-label="대화와 독립된 학습 피드백">
        <h3>따로 도착하는 피드백</h3><p className="hint">샘플 결과입니다. 기록과 피드백은 최근 20개만 이 화면에 유지하며, 새로고침하면 사라집니다. 공부 자료는 이 시뮬레이션에 포함되지 않습니다.</p>
        {state.feedback.length === 0 && <p className="muted">원문을 모의 전송하면 여기에 피드백이 나타납니다.</p>}
        {state.feedback.slice().reverse().map(item => <article className="host-feedback-card" key={`${item.observation.appId}:${item.observation.messageId}`} data-testid="host-feedback-card">
          <strong>{APP_LABELS[item.observation.appId]} · {item.observation.messageId}</strong>
          <p className="host-message">{item.observation.text}</p>
          {item.state === 'pending' && <p className="hint" role="status">원문은 전송됨 · 샘플 피드백 준비 중</p>}
          {item.state === 'skipped' && <p className="hint">대기 요청이 많아 피드백을 건너뛰었습니다. 원문 전송에는 영향이 없습니다.</p>}
          {item.state === 'unavailable' && <p className="hint">샘플 피드백을 준비하지 못했습니다. 원문 전송에는 영향이 없습니다.</p>}
          {item.result && <><p className="corrected">{item.result.corrected}</p>{presentNotes(item.result, item.policy).map((note, index) => <p className="hint" key={index}><strong>{note.kind === 'correction' ? '오류 교정' : '선택 표현'}</strong> · {note.before} → {note.after}<br />{note.reason}</p>)}</>}
        </article>)}
      </aside>
    </div>
  </section>;
}
