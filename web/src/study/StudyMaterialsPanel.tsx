import { useEffect, useRef, useState } from 'react';
import type { PolicyStorage, StudySource } from '../core/model.ts';
import { MAX_EXCERPT, MAX_SOURCE_TITLE } from '../core/model.ts';
import { addStudyMaterial, addStudySection, clearStudyLibrary, emptyStudyLibrary, loadStudyLibrary,
  removeStudyMaterial, removeStudySection, renameStudyMaterial, saveStudyLibrary, selectedStudySource,
  updateStudySection } from '../core/studyMaterials.ts';
import type { StudyLibrary, StudySelection } from '../core/studyMaterials.ts';
import './studyMaterials.css';

type Editor = { kind: 'material'; id: string | null; title: string } |
  { kind: 'section'; materialID: string; id: string | null; label: string; excerpt: string };
type Removal = { kind: 'material'; materialID: string } | { kind: 'section'; materialID: string; sectionID: string } |
  { kind: 'saved' };
export interface StudyMaterialsPanelProps {
  mode?: 'fixture' | 'native';
  providerName?: string;
  /** Must synchronously invalidate pending corrections before accepting this source. Never dispatch here. */
  onSourceChange: (source: StudySource | null) => void;
  /** Increment when the parent resets or replaces the source outside this panel. Does not erase the library. */
  selectionResetKey?: number;
  /** Optional local-only storage adapter. Native mode never accesses it. */
  storage?: PolicyStorage;
}

/** Local manual excerpts. No automatic loads, external requests, file access, or provider invocation. */
export function StudyMaterialsPanel({ mode = 'fixture', providerName = '제공자', onSourceChange,
  selectionResetKey = 0, storage }: StudyMaterialsPanelProps) {
  const [library, setLibrary] = useState<StudyLibrary>(emptyStudyLibrary);
  const [materialID, setMaterialID] = useState('');
  const [active, setActive] = useState<StudySelection | null>(null);
  const [editor, setEditor] = useState<Editor | null>(null);
  const [removal, setRemoval] = useState<Removal | null>(null);
  const [remember, setRemember] = useState(false);
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  const lastReset = useRef(selectionResetKey);
  // Parent owns its source on a reset; avoid callback loops from unstable function props.
  useEffect(() => {
    if (lastReset.current !== selectionResetKey) { lastReset.current = selectionResetKey; setActive(null); }
  }, [selectionResetKey]);
  const native = mode === 'native';
  const material = library.materials.find(item => item.id === materialID);
  const activeSource = selectedStudySource(library, active);
  const locked = editor !== null || removal !== null;
  const getStorage = () => storage ?? window.localStorage;
  function clearMessages() { setError(''); setNotice(''); }
  function selectSource(next: StudySelection | null) {
    clearMessages(); setActive(next); onSourceChange(selectedStudySource(library, next));
  }
  function commit(next: StudyLibrary) {
    // Compute and notify from the same snapshot; removal must not retain an old active excerpt.
    const nextSource = selectedStudySource(next, active);
    const sourceChanged = JSON.stringify(activeSource) !== JSON.stringify(nextSource);
    if (sourceChanged) onSourceChange(nextSource);
    if (!nextSource) setActive(null);
    setLibrary(next);
    if (!native && remember) {
      let saved = false;
      try { saved = saveStudyLibrary(getStorage(), next); } catch { /* private failure copy below */ }
      if (!saved) setError('변경 내용은 이번 화면에만 적용했습니다. 기기 저장에 실패하여 이전 저장본이 남아 있을 수 있습니다.');
    }
  }
  function saveEditor() {
    if (!editor) return;
    clearMessages();
    try {
      if (editor.kind === 'material') {
        const id = editor.id ?? crypto.randomUUID();
        commit(editor.id ? renameStudyMaterial(library, id, editor.title) : addStudyMaterial(library, id, editor.title));
        setMaterialID(id);
      } else {
        const section = { id: editor.id ?? crypto.randomUUID(), label: editor.label, excerpt: editor.excerpt };
        commit(editor.id ? updateStudySection(library, editor.materialID, section) : addStudySection(library, editor.materialID, section));
      }
      setEditor(null);
    } catch (cause) { setError(cause instanceof Error ? cause.message : '자료를 저장하지 못했습니다. 입력을 확인하세요.'); }
  }
  function toggleRemember(enabled: boolean) {
    if (native) return;
    clearMessages();
    try {
      const ok = enabled ? saveStudyLibrary(getStorage(), library) : clearStudyLibrary(getStorage());
      if (!ok) { setError(enabled ? '기기에 저장하지 못했습니다. 이번 화면에서만 사용할 수 있습니다.' : '저장된 자료를 삭제하지 못했습니다. 저장 설정을 유지했습니다.'); return; }
      setRemember(enabled);
      setNotice(enabled ? '자료 제목·단원·발췌문을 이 브라우저에 저장합니다. 활성 단원과 교정 원문·결과는 저장하지 않습니다.' : '기기에 저장된 자료를 삭제했습니다. 이번 화면의 자료는 유지합니다.');
    } catch { setError('브라우저 저장소를 사용할 수 없습니다. 저장 설정을 변경하지 않았습니다.'); }
  }
  function restore() {
    if (native || locked || library.materials.length) return;
    clearMessages();
    try {
      const loaded = loadStudyLibrary(getStorage());
      if (loaded.status === 'loaded') {
        setLibrary(loaded.library); setMaterialID(loaded.library.materials[0]?.id ?? ''); setActive(null);
        setNotice('저장된 자료를 불러왔습니다. 참고할 단원을 직접 선택하세요. 변경 자동 저장은 별도로 켜야 합니다.');
      } else if (loaded.status === 'empty') setNotice('이 브라우저에 저장된 자료가 없습니다.');
      else setError(loaded.status === 'invalid' ? '저장된 자료의 형식을 확인하지 못했습니다. 저장본은 덮어쓰지 않았습니다.' : '브라우저 저장소를 사용할 수 없습니다.');
    } catch { setError('브라우저 저장소를 사용할 수 없습니다.'); }
  }
  function removeConfirmed() {
    if (!removal) return;
    clearMessages();
    try {
      if (removal.kind === 'saved') {
        if (native) return;
        if (!clearStudyLibrary(getStorage())) { setError('저장된 자료를 삭제하지 못했습니다. 다시 시도할 수 있습니다.'); return; }
        setRemember(false); setNotice('기기에 저장된 자료를 삭제했습니다. 이번 화면의 자료는 유지합니다.');
      } else if (removal.kind === 'material') {
        const next = removeStudyMaterial(library, removal.materialID); commit(next);
        if (materialID === removal.materialID) setMaterialID(next.materials[0]?.id ?? '');
      } else commit(removeStudySection(library, removal.materialID, removal.sectionID));
      setRemoval(null);
    } catch (cause) { setError(cause instanceof Error ? cause.message : '삭제하지 못했습니다.'); }
  }
  return <section className="study-materials" aria-labelledby="study-materials-title">
    <h3 id="study-materials-title">내 학습 자료</h3>
    <p className="hint">책이나 학습 자료에서 직접 고른 짧은 발췌문을 단원별로 관리하세요. PDF·EPUB 가져오기, 전체 책 검색, 자동 검색은 지원하지 않습니다.</p>
    <p className="hint">{native ? `선택한 한 단원의 제목·단원·발췌문만 다음 교정 요청에 포함합니다. ${providerName} 전송에는 요청별 네이티브 동의가 필요합니다. 자료를 추가하거나 선택하는 동작만으로 전송하지 않습니다.` : '선택한 한 단원만 요청 미리보기에 포함합니다. 샘플 피드백에는 적용되지 않으며, 자료 관리 동작으로 외부 전송하지 않습니다.'}</p>
    <div className="study-actions">
      <button className="button secondary" type="button" disabled={locked} onClick={() => { clearMessages(); setEditor({ kind: 'material', id: null, title: '' }); }}>자료 추가</button>
      {!native && <button className="text-button" type="button" disabled={locked || library.materials.length > 0} onClick={restore}>기기 자료 불러오기</button>}
    </div>
    {!native && library.materials.length > 0 && <p className="hint">불러오기는 빈 자료 목록에서만 가능합니다. 현재 자료를 덮어쓰지 않습니다.</p>}
    {library.materials.length > 0 ? <>
      <label className="field-label" htmlFor="study-material-picker">관리할 자료</label>
      <select id="study-material-picker" disabled={locked} value={materialID} onChange={event => { clearMessages(); setMaterialID(event.target.value); }}>
        {library.materials.map(item => <option key={item.id} value={item.id}>{item.title}</option>)}
      </select>
      {material && <>
        <div className="study-actions">
          <button className="text-button" type="button" disabled={locked} onClick={() => { clearMessages(); setEditor({ kind: 'material', id: material.id, title: material.title }); }}>자료 제목 수정</button>
          <button className="text-button" type="button" disabled={locked} onClick={() => { clearMessages(); setRemoval({ kind: 'material', materialID: material.id }); }}>자료 삭제</button>
          <button className="button secondary" type="button" disabled={locked} onClick={() => { clearMessages(); setEditor({ kind: 'section', materialID: material.id, id: null, label: '', excerpt: '' }); }}>단원 추가</button>
        </div>
        {!material.sections.length && <p className="hint">단원명과 발췌문을 추가한 뒤 참고할 단원을 선택하세요.</p>}
        <ul className="study-section-list">
          {material.sections.map(section => <li key={section.id}>
            <label className="check-row"><input type="radio" name="active-study-section" checked={active?.materialID === material.id && active.sectionID === section.id}
              onChange={() => selectSource({ materialID: material.id, sectionID: section.id })} /><span>{section.label} 참고</span></label>
            <p className="study-excerpt">{section.excerpt}</p>
            <div className="study-actions"><span className="hint">{section.excerpt.length.toLocaleString()}자</span>
              <button className="text-button" type="button" aria-label={`${section.label} 수정`} disabled={locked} onClick={() => { clearMessages(); setEditor({ kind: 'section', materialID: material.id, id: section.id, label: section.label, excerpt: section.excerpt }); }}>수정</button>
              <button className="text-button" type="button" aria-label={`${section.label} 삭제`} disabled={locked} onClick={() => { clearMessages(); setRemoval({ kind: 'section', materialID: material.id, sectionID: section.id }); }}>삭제</button>
            </div>
          </li>)}
        </ul>
      </>}
    </> : <p className="hint">아직 추가한 자료가 없습니다. 자료는 자동으로 불러오지 않습니다.</p>}
    {editor && <div className="study-editor" role="group" aria-label={editor.kind === 'material' ? '자료 편집' : '단원 편집'}>
      {editor.kind === 'material' ? <><label className="field-label" htmlFor="study-title">자료 제목·저자</label>
        <input id="study-title" maxLength={MAX_SOURCE_TITLE} value={editor.title} onChange={event => setEditor({ ...editor, title: event.target.value })} placeholder="예: 내가 읽는 책 · 저자" /></> : <>
        <p className="hint">{library.materials.find(item => item.id === editor.materialID)?.title}</p>
        <label className="field-label" htmlFor="study-section-label">단원·페이지</label>
        <input id="study-section-label" maxLength={MAX_SOURCE_TITLE} value={editor.label} onChange={event => setEditor({ ...editor, label: event.target.value })} placeholder="예: Unit 3 · p. 24" />
        <label className="field-label" htmlFor="study-section-excerpt">학습 발췌문</label>
        <textarea id="study-section-excerpt" maxLength={MAX_EXCERPT} value={editor.excerpt} onChange={event => setEditor({ ...editor, excerpt: event.target.value })} placeholder="사용할 권한이 있는 짧은 학습 내용만 붙여 넣으세요." />
        <span className="hint">{editor.excerpt.length.toLocaleString()} / {MAX_EXCERPT.toLocaleString()} · 수정 적용 전에는 요청에 반영되지 않습니다.</span>
      </>}
      <div className="study-actions"><button className="button secondary" type="button" onClick={saveEditor}>수정 적용</button>
        <button className="text-button" type="button" onClick={() => { clearMessages(); setEditor(null); }}>편집 취소</button></div>
    </div>}
    {removal && <div className="study-confirm" role="group" aria-label="자료 삭제 확인">
      <p>{removal.kind === 'saved' ? '이 브라우저에 저장한 모든 학습 자료를 삭제할까요? 이번 화면의 자료는 유지합니다.' : removal.kind === 'material' ? '이 화면에서 이 자료와 모든 단원을 삭제할까요? 활성 단원도 해제됩니다.' : '이 화면에서 이 단원을 삭제할까요? 활성 단원이면 해제됩니다.'} 삭제는 되돌릴 수 없습니다.</p>
      {removal.kind !== 'saved' && !native && !remember && <p>기기 저장이 꺼져 있어 기존 저장본은 그대로 남습니다. 저장본도 지우려면 ‘기기에 저장된 자료 삭제’를 사용하세요.</p>}
      <div className="study-actions"><button className="button secondary" type="button" onClick={removeConfirmed}>삭제 확인</button>
        <button className="text-button" type="button" onClick={() => { clearMessages(); setRemoval(null); }}>삭제 취소</button></div>
    </div>}
    <div className="study-active" role="status" aria-label="활성 학습 단원">
      {activeSource ? <><strong>활성 단원: {activeSource.title} · {activeSource.section}</strong><button className="text-button" type="button" onClick={() => selectSource(null)}>참고 해제</button></> : '활성 단원 없음 · 저장된 자료는 자동으로 선택하지 않습니다.'}
    </div>
    {!native && <>
      <label className="check-row"><input type="checkbox" checked={remember} disabled={locked} onChange={event => toggleRemember(event.target.checked)} /><span>자료를 이 브라우저에 저장</span></label>
      <p className="hint">기본은 이번 화면에서만 유지합니다. 저장을 켜면 제목·단원·발췌문이 암호화되지 않은 브라우저 저장소에 남습니다. 같은 브라우저를 사용하는 사람이 볼 수 있으므로 민감한 내용은 넣지 마세요. 활성 단원, 교정 원문·결과는 저장하지 않습니다.</p>
      <button className="text-button" type="button" disabled={locked} onClick={() => { clearMessages(); setRemoval({ kind: 'saved' }); }}>기기에 저장된 자료 삭제</button>
    </>}
    {native && <p className="hint">이 네이티브 화면의 자료는 이번 화면에서만 유지합니다. 영구 저장 기능은 제공하지 않습니다. 화면을 닫으면 자료가 사라집니다.</p>}
    {notice && <p className="alert" role="status">{notice}</p>}
    {error && <p className="alert error" role="alert">{error}</p>}
  </section>;
}
