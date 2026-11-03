import type { DocumentInitParameters } from 'pdfjs-dist/types/src/display/api';
/** Main-thread resource factory also fails closed; no library fallback fetch is allowed. */
class NoExternalPDFData { async fetch(): Promise<never> { throw new Error('External PDF resources are disabled.'); } }
export function privatePdfOptions(bytes: Uint8Array): DocumentInitParameters {
  return { data: bytes, verbosity: 0, useWorkerFetch: false, BinaryDataFactory: NoExternalPDFData,
    useWasm: false, enableXfa: false, stopAtErrors: true, disableFontFace: true, useSystemFonts: false,
    maxImageSize: 0, isOffscreenCanvasSupported: false, isImageDecoderSupported: false,
    disableWorkerRendering: true, disableAutoFetch: true, disableStream: true, disableRange: true };
}
