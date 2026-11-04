import { useEffect, useRef, useState } from 'react';
import type { StudySource } from '../core/model.ts';
import { DOCUMENT_LIMITS, passageSource, retrieveStudyPassages } from './documents/documentModel.ts';
import type { IndexedStudyDocument, PassageMatch } from './documents/documentModel.ts';
import { importStudyDocument } from './documents/importDocument.ts';

export interface StudyDocumentImportProps { onAdd: (source: StudySource) => void }
/** Browser-only module, injected by main.tsx so native bundles never import PDF.js or worker assets. */
export function StudyDocumentImport({ onAdd }: StudyDocumentImportProps) {
  const [document, setDocument] = useState<IndexedStudyDocument | null>(null);
  const [title, setTitle] = useState(''); const [query, setQuery] = useState('');
  const [matches, setMatches] = useState<PassageMatch[] | null>(null);
  const [busy, setBusy] = useState(false); const [cancelling, setCancelling] = useState(false); const [error, setError] = useState(''); const [notice, setNotice] = useState('');
  const pending = useRef<AbortController | null>(null); const generation = useRef(0);
  useEffect(() => () => { generation.current++; pending.current?.abort(); }, []);
  function stop() { generation.current++; pending.current?.abort(); if (pending.current) setCancelling(true); }
  async function choose(file: File | undefined) {
    if (!file || pending.current) return; // Cancellation never frees the admission slot before actual settlement.
    const current = ++generation.current; const controller = new AbortController(); pending.current = controller;
    setBusy(true); setCancelling(false); setError(''); setNotice(''); setMatches(null); setDocument(null); setQuery('');
    try {
      const next = await importStudyDocument(file, controller.signal);
      if (generation.current !== current || controller.signal.aborted) return;
      setDocument(next); setTitle(next.suggestedTitle); setNotice('파일은 이 화면의 메모리에만 있습니다. 검색 후 필요한 발췌문만 직접 추가하세요.');
    } catch (cause) {
      if (generation.current === current && !controller.signal.aborted) setError(cause instanceof Error ? cause.message : '문서를 읽지 못했습니다.');
    } finally { if (pending.current === controller) { pending.current = null; setBusy(false); setCancelling(false); } }
  }
  function search() {
    if (!document) return;
    setError(''); setNotice('');
    try { setMatches(retrieveStudyPassages(document, query)); } catch (cause) { setError(cause instanceof Error ? cause.message : '검색어를 확인하세요.'); }
  }
  return <details className="study-import"><summary>PDF·EPUB에서 발췌문 찾기 · 브라우저 전용</summary>
    <p className="hint">직접 선택한 파일을 이 브라우저에서 읽습니다. 파일·전체 텍스트·검색어를 외부로 보내거나 저장하지 않습니다. 8 MiB, 250페이지·단원, 추출 텍스트 600,000자까지 지원합니다. 암호·DRM·스캔 OCR은 지원하지 않습니다.</p>
    <label className="field-label" htmlFor="study-document-file">로컬 PDF·EPUB 선택</label>
    <input id="study-document-file" type="file" disabled={busy} accept=".pdf,.epub,application/pdf,application/epub+zip" onChange={event => { const file = event.target.files?.[0]; event.target.value = ''; void choose(file); }} />
    {busy && <div className="study-actions"><span role="status">{cancelling ? '취소 중입니다. 이전 읽기가 끝나면 새 파일을 선택할 수 있습니다.' : '문서 텍스트를 읽고 있습니다…'}</span><button className="text-button" type="button" disabled={cancelling} onClick={() => { stop(); setNotice('문서 읽기 취소를 요청했습니다. 결과는 사용하지 않습니다.'); }}>문서 읽기 취소</button></div>}
    {document && <>
      <p className="hint">{document.passages.length.toLocaleString()}개의 발췌 범위를 준비했습니다. 원본의 레이아웃과 문구를 확인한 뒤 사용하세요.</p>
      {document.warnings.map(warning => <p className="hint" key={warning}>{warning}</p>)}
      <label className="field-label" htmlFor="import-document-title">가져올 자료 제목·저자 확인</label>
      <input id="import-document-title" maxLength={160} value={title} onChange={event => setTitle(event.target.value)} />
      <label className="field-label" htmlFor="study-document-query">찾을 단어·표현</label>
      <input id="study-document-query" maxLength={DOCUMENT_LIMITS.queryCharacters} value={query} onChange={event => { setQuery(event.target.value); setMatches(null); }} />
      <p className="hint">입력한 단어가 텍스트에 나타나는 횟수와 포함된 단어 수로 정렬합니다. 의미 검색이나 자동 추천이 아니며, 일치하지 않으면 결과를 만들지 않습니다.</p>
      <div className="study-actions"><button className="button secondary" type="button" disabled={!query.trim()} onClick={search}>문서 안에서 찾기</button>
        <button className="text-button" type="button" onClick={() => { stop(); setDocument(null); setMatches(null); setTitle(''); setQuery(''); setError(''); setNotice('불러온 문서를 메모리에서 해제했습니다. 이미 추가한 발췌문은 학습 자료에 남습니다.'); }}>불러온 문서 닫기</button></div>
      {matches?.length === 0 && <p role="status">일치하는 발췌문이 없습니다. 다른 검색어를 사용하세요.</p>}
      <ul className="study-section-list">{matches?.map(match => <li key={match.passage.id}>
        <strong>{match.passage.label}</strong><p className="study-excerpt">{match.passage.text}</p>
        <p className="hint">일치 단어: {match.matchedTerms.join(', ')}</p>
        <button className="button secondary" type="button" disabled={!title.trim()} onClick={() => {
          try { onAdd(passageSource(title, match.passage)); setError(''); setNotice('선택한 발췌문을 학습 자료에 추가했습니다. 교정에 쓸 단원은 별도로 선택하세요.'); }
          catch (cause) { setError(cause instanceof Error ? cause.message : '학습 자료에 추가하지 못했습니다.'); }
        }}>이 발췌문을 자료에 추가</button>
      </li>)}</ul>
    </>}
    {notice && <p className="alert" role="status">{notice}</p>}{error && <p className="alert error" role="alert">{error}</p>}
  </details>;
}
