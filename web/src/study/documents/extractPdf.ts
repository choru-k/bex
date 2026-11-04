import { SafeDocumentError } from './documentModel.ts';
import { getDocument, PDFWorker } from 'pdfjs-dist/legacy/build/pdf.mjs';
import type { PDFDocumentLoadingTask } from 'pdfjs-dist/types/src/display/api';
import PdfWorker from './pdf.worker.ts?worker';
import { cancelled, validateFileBytes } from './documentModel.ts';
import { readPdfText } from './pdfTextCore.ts';
import type { ExtractedDocument } from './documentModel.ts';
import { privatePdfOptions } from './pdfOptions.ts';
export async function extractPdf(bytes: Uint8Array, signal?: AbortSignal): Promise<ExtractedDocument> {
  validateFileBytes(bytes); cancelled(signal);
  if (new TextDecoder('ascii').decode(bytes.subarray(0, 5)) !== '%PDF-') throw new SafeDocumentError('PDF 파일 형식 식별자가 올바르지 않습니다.');
  // Explicit local worker: do not permit PDF.js's main-thread/fake-worker fallback.
  const port = new PdfWorker(); let worker: PDFWorker | undefined; let task: PDFDocumentLoadingTask | undefined; let disposed = false;
  const stop = () => { if (disposed) return; disposed = true; port.terminate(); worker?.destroy(); if (task) void task.destroy().catch(() => {}); };
  let rejectAbort: (cause: Error) => void = () => {};
  const abort = () => { stop(); rejectAbort(new DOMException('문서 읽기를 취소했습니다.', 'AbortError')); };
  signal?.addEventListener('abort', abort, { once: true });
  const workerError = () => { stop(); rejectAbort(new SafeDocumentError('PDF 처리 작업을 시작하지 못했습니다.')); };
  port.addEventListener('error', workerError); port.addEventListener('messageerror', workerError);
  try {
    worker = PDFWorker.create({ port });
    const aborted = new Promise<never>((_, reject) => { rejectAbort = reject; });
    const read = async () => {
      await worker!.promise; cancelled(signal);
      task = getDocument({ ...privatePdfOptions(bytes), worker });
      task.onPassword = () => { stop(); rejectAbort(new SafeDocumentError('암호로 보호된 PDF는 지원하지 않습니다.')); };
      const document = await task.promise; cancelled(signal);
      return readPdfText(document, signal);
    };
    return await Promise.race([read(), aborted]);
  } finally { signal?.removeEventListener('abort', abort); port.removeEventListener('error', workerError); port.removeEventListener('messageerror', workerError); stop(); }
}
