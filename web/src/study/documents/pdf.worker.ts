// Bundled local module only. No CDN, sandbox scripting, external fonts, CMaps or wasm.
import 'pdfjs-dist/legacy/build/pdf.worker.mjs';
const rejectNetwork = () => Promise.reject(new Error('External PDF resource loading is disabled.'));
Object.defineProperty(globalThis, 'fetch', { value: rejectNetwork, writable: false, configurable: false });

class BlockedXMLHttpRequest { constructor() { throw new Error('External PDF resource loading is disabled.'); } }
Object.defineProperty(globalThis, 'XMLHttpRequest', { value: BlockedXMLHttpRequest, writable: false, configurable: false });
