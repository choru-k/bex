import { cancelled, SafeDocumentError, DOCUMENT_LIMITS, indexStudyDocument, validateFileBytes } from './documentModel.ts';
import type { IndexedStudyDocument } from './documentModel.ts';
import { extractEpub } from './extractEpub.ts';
import { loadPdfExtractor } from './pdfLoader.ts';
import type { PdfExtractor } from './pdfLoader.ts';

/** One explicitly selected local file, no server or URL input. Abort/deadline drops all partial output. */
export async function importStudyDocument(file: File, signal: AbortSignal): Promise<IndexedStudyDocument> {
  if (!file.size || file.size > DOCUMENT_LIMITS.fileBytes) throw new SafeDocumentError('비어 있지 않은 8 MiB 이하의 문서를 선택하세요.');
  const extension = file.name.split('.').at(-1)?.toLowerCase();
  if (extension !== 'pdf' && extension !== 'epub') throw new SafeDocumentError('PDF 또는 EPUB 파일을 선택하세요.');
  const controller = new AbortController(); const abort = () => controller.abort(); let timedOut = false;
  const deadline = performance.now() + DOCUMENT_LIMITS.timeoutMs;
  function checkAdmission() {
    // Synchronous module evaluation can delay timer tasks. Never admit late work
    // merely because the timeout callback has not had a chance to execute yet.
    if (performance.now() >= deadline) { timedOut = true; controller.abort(); }
    cancelled(signal); cancelled(controller.signal);
  }
  const timer = setTimeout(() => { timedOut = true; controller.abort(); }, DOCUMENT_LIMITS.timeoutMs);
  signal.addEventListener('abort', abort, { once: true });
  try {
    checkAdmission();
    let pdf: PdfExtractor | null = null;
    if (extension === 'pdf') {
      // Only five local bytes are retained while the uncancellable code chunk loads.
      const marker = new Uint8Array(await file.slice(0, 5).arrayBuffer());
      checkAdmission();
      if (new TextDecoder('ascii').decode(marker) !== '%PDF-') throw new SafeDocumentError('PDF 파일 형식 식별자가 올바르지 않습니다.');
      pdf = await loadPdfExtractor(controller.signal);
      checkAdmission();
    }
    const bytes = new Uint8Array(await file.arrayBuffer());
    checkAdmission(); validateFileBytes(bytes);
    const raw = pdf ? await pdf(bytes, controller.signal) : await extractEpub(bytes, controller.signal);
    checkAdmission();
    const document = indexStudyDocument(raw);
    checkAdmission();
    // Filename is only a visible, editable attribution suggestion, never a hidden persisted path.
    return { ...document, suggestedTitle: document.suggestedTitle || file.name.replace(/\.(pdf|epub)$/i, '').slice(0, 160) };
  } catch (error) {
    if (timedOut) throw new SafeDocumentError('문서 읽기 시간 한도(20초)를 넘었습니다. 더 작은 문서를 사용하세요.');
    if (signal.aborted) throw new DOMException('문서 읽기를 취소했습니다.', 'AbortError');
    // Never expose parser internals, file content, passwords, or paths in error messages.
    if (error instanceof SafeDocumentError) throw error;
    throw new SafeDocumentError('문서를 읽지 못했습니다. 지원되는 암호화되지 않은 텍스트 PDF 또는 EPUB인지 확인하세요.');
  } finally { clearTimeout(timer); signal.removeEventListener('abort', abort); controller.abort(); }
}
