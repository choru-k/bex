import { cancelled, SafeDocumentError } from './documentModel.ts';
import type { ExtractedDocument } from './documentModel.ts';
export type PdfExtractor = (bytes: Uint8Array, signal?: AbortSignal) => Promise<ExtractedDocument>;

/** Local build chunk only. No eager PDF dependency, CDN, prefetch, or rejected-promise cache. */
export async function loadPdfExtractor(signal: AbortSignal): Promise<PdfExtractor> {
  cancelled(signal);
  try {
    // import() cannot be aborted. Keep the caller's admission slot until it settles;
    // never race it with cancellation and admit more file buffers/continuations.
    const module = await import('./extractPdf.ts');
    cancelled(signal);
    return module.extractPdf;
  } catch {
    cancelled(signal);
    // Chunk errors can contain URLs or runtime details. Only fixed owned copy reaches UI.
    throw new SafeDocumentError('PDF 읽기 모듈을 불러오지 못했습니다. 다시 시도하거나 화면을 새로 여세요.');
  }
}
