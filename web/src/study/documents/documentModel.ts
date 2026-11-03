import type { StudySource } from '../../core/model.ts';
/** Only owned fixed validation messages may cross the parser-to-UI boundary. */
export class SafeDocumentError extends Error {}
export const DOCUMENT_LIMITS = Object.freeze({ fileBytes: 8 * 1024 * 1024, entries: 600, entryBytes: 2 * 1024 * 1024,
  archiveBytes: 24 * 1024 * 1024, textCharacters: 600_000, units: 250, passages: 1_200,
  passageCharacters: 1_200, queryCharacters: 300, timeoutMs: 20_000 });
export interface ExtractedUnit { label: string; text: string }
export interface ExtractedDocument { format: 'pdf' | 'epub'; suggestedTitle: string; units: ExtractedUnit[]; warnings: string[] }
export interface StudyPassage { id: string; label: string; text: string; order: number }
export interface IndexedStudyDocument { format: 'pdf' | 'epub'; suggestedTitle: string; passages: StudyPassage[]; warnings: string[] }
export interface PassageMatch { passage: StudyPassage; score: number; matchedTerms: string[] }
export function cancelled(signal?: AbortSignal): void { if (signal?.aborted) throw new DOMException('문서 읽기를 취소했습니다.', 'AbortError'); }
export function validateFileBytes(bytes: Uint8Array): void {
  if (!bytes.length || bytes.length > DOCUMENT_LIMITS.fileBytes) throw new SafeDocumentError('비어 있지 않은 8 MiB 이하의 문서를 선택하세요.');
}
export function normalizeDocumentText(text: string): string {
  return text.normalize('NFC').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').replace(/\s+/gu, ' ').trim();
}
/** Deterministic bounded passages. Text is extracted/normalized, not a verified verbatim quotation. */
export function indexStudyDocument(document: ExtractedDocument): IndexedStudyDocument {
  if (!['pdf', 'epub'].includes(document.format) || document.units.length > DOCUMENT_LIMITS.units) throw new SafeDocumentError('문서의 페이지·단원 한도를 넘었습니다.');
  const passages: StudyPassage[] = []; let total = 0;
  for (const [unitIndex, unit] of document.units.entries()) {
    const text = normalizeDocumentText(unit.text); total += text.length;
    if (total > DOCUMENT_LIMITS.textCharacters) throw new SafeDocumentError('문서의 추출 텍스트 한도(600,000자)를 넘었습니다.');
    let start = 0, part = 1;
    while (start < text.length) {
      let end = Math.min(start + DOCUMENT_LIMITS.passageCharacters, text.length);
      if (end < text.length) {
        const space = text.lastIndexOf(' ', end);
        if (space > start + DOCUMENT_LIMITS.passageCharacters / 2) end = space;
        // Do not split a UTF-16 surrogate pair when a language has no spaces.
        if (/[\uD800-\uDBFF]/.test(text[end - 1] ?? '')) end--;
      }
      const excerpt = text.slice(start, end).trim();
      if (excerpt) passages.push({ id: `${document.format}-${unitIndex + 1}-${part}`, label: `${unit.label.slice(0, 125)} · 발췌 ${part}`, text: excerpt, order: passages.length });
      if (passages.length > DOCUMENT_LIMITS.passages) throw new SafeDocumentError('문서의 발췌문 개수 한도를 넘었습니다.');
      start = end; while (text[start] === ' ') start++; part++;
    }
  }
  if (!passages.length) throw new SafeDocumentError('읽을 수 있는 텍스트가 없습니다. 스캔 PDF의 OCR은 지원하지 않습니다.');
  return { format: document.format, suggestedTitle: normalizeDocumentText(document.suggestedTitle).slice(0, 160), passages, warnings: [...document.warnings] };
}
const STOP_WORDS = new Set(['a', 'an', 'the', 'and', 'or', 'to', 'of', 'in', 'is', 'it', 'for', 'on', 'at', 'be', 'as', 'by', 'with']);
function terms(text: string): string[] {
  return [...new Set((text.normalize('NFC').toLowerCase().match(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu) ?? [])
    .filter(term => !STOP_WORDS.has(term)))].slice(0, 24);
}
/** No embeddings, model, network or fuzzy relevance claim. Stable exact-token coverage + counts. */
export function retrieveStudyPassages(document: IndexedStudyDocument, query: string, limit = 6): PassageMatch[] {
  if (query.length > DOCUMENT_LIMITS.queryCharacters) throw new SafeDocumentError('검색어는 300자까지 입력하세요.');
  if (!Number.isInteger(limit) || limit < 1 || limit > 20) throw new SafeDocumentError('검색 결과 개수 한도를 확인하세요.');
  const queryTerms = terms(query); if (!queryTerms.length) return [];
  return document.passages.map(passage => {
    const counts = new Map<string, number>();
    for (const term of passage.text.normalize('NFC').toLowerCase().match(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu) ?? []) counts.set(term, (counts.get(term) ?? 0) + 1);
    const matchedTerms = queryTerms.filter(term => counts.has(term));
    const score = matchedTerms.length * 100 + matchedTerms.reduce((sum, term) => sum + Math.min(counts.get(term)!, 5), 0);
    return { passage, matchedTerms, score };
  }).filter(match => match.score > 0).sort((a, b) => b.score - a.score || a.passage.order - b.passage.order).slice(0, limit);
}
export function passageSource(title: string, passage: StudyPassage): StudySource {
  if (!title.trim() || title.length > 160 || !passage.text.trim() || passage.text.length > DOCUMENT_LIMITS.passageCharacters || passage.label.length > 160) throw new SafeDocumentError('자료 제목과 발췌문 범위를 확인하세요.');
  return { title: title.trim(), section: passage.label, excerpt: passage.text };
}
