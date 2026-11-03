# Browser-local PDF / EPUB study passages

The browser workbench can read a user-selected local PDF or EPUB, extract text,
find passages using deterministic keyword matching, and add an explicitly chosen
passage to the existing study library. Files, extracted full text, and search
queries are not uploaded or persisted. There is no server extraction, model call,
embedding index, OCR, or automatic selection of a passage for correction.

This importer is browser-only. `main.tsx` injects `StudyDocumentImport` through
`App` into `StudyMaterialsPanel`. `NativeApp` never imports that module. The native
build keeps its existing strict three-resource profile and `worker-src 'none'`
policy; it continues to support manual session-only excerpts.

## Workflow and attribution

1. Select one local `.pdf` or `.epub` file. The file picker is disabled while a read
   or code-module load is outstanding. PDF checks its size, extension and five-byte
   format marker before loading the app's bundled PDF parser on demand. The full
   file is read only after that module loads and cancellation/deadline checks pass.
   EPUB never requests the PDF module. Cancelling suppresses results but does not
   release the admission slot until the underlying operation actually settles.
2. Review the suggested title/author. PDF currently uses the visible filename
   without its extension as a suggestion; EPUB uses package title/creator metadata.
   Suggestions are bounded to 160 characters and editable before use.
3. Search for words or expressions. Matches use Unicode-aware **exact tokens**,
   ranked first by how many query terms appear, then bounded occurrence counts,
   with source order as a stable tie breaker. Common English function words are
   ignored. Empty or unmatched queries return no invented result. This is not
   semantic retrieval, learner assessment, or adaptive model behavior.
4. Review the extracted passage and its attribution, then explicitly add it.
   Adding does not activate a source or request correction. Identical repeated
   additions are deduplicated. Select the desired library section separately.
5. Close the imported document to drop its full extracted text from component
   state. Any explicitly added library passages remain. If browser-library saving
   was already opted into, only those added passages use that existing setting.

PDF attribution uses the **physical file page number**, not a guessed printed page
label. EPUB attribution uses spine order and an extracted chapter heading where
available; it invents no page numbers. Passages are at most 1,200 UTF-16 code units,
with deterministic boundaries. Whitespace/control characters are normalized, and
layout is not preserved. Users must check extracted text against the original,
especially for multi-column PDFs, tables, ligatures, and non-embedded/CJK fonts.

## Supported subset and resource limits

- File input: nonempty, at most 8 MiB, valid expected format marker.
- Documents: at most 250 PDF pages or EPUB spine entries, 600,000 extracted text
  code units, and 1,200 passages. Exceeding a limit rejects the whole import rather
  than presenting partial output as complete.
- PDF: text extraction only through pinned Mozilla `pdfjs-dist` **6.5.438**, using
  its official legacy distribution for runtime compatibility. A dedicated bundled
  local worker is mandatory. Worker failures have no fake-worker/main-thread
  fallback. Password-protected PDFs are rejected; no password prompt is shown.
  No PDF viewer, annotation actions, scripts, form rendering, images, or OCR are
  invoked. XFA, wasm, image decoders, font loading, and worker rendering are off.
- EPUB: ZIP store/deflate only, UTF-8 XML/XHTML, one package, explicit manifest and
  spine. Reject encryption/DRM/font obfuscation, symlinks, duplicate paths/IDs,
  absolute/parent/encoded paths, external manifest URLs, ZIP64, unsupported ZIP
  flags/compression, mismatched local headers, overlaps, and bad CRC/size data.
  At most 600 ZIP entries, 2 MiB expanded per entry, 24 MiB declared/read expanded
  data, and a 200:1 declared expansion ratio are admitted. Streamed decompression
  stops on actual output beyond the advertised or configured limits.
- XML: at most 1,000,000 characters, 25,000 markup tokens/nodes and depth 100.
  Quote-aware lexical depth checks run before DOM allocation. DTDs, entity
  declarations, comments, CDATA, non-declaration processing instructions, and
  non-XHTML spine content are outside this narrow supported subset. No XML/HTML
  is attached to the live DOM. Scripts/styles/media/foreign/explicitly hidden
  elements are ignored; CSS layout is not evaluated.
- A 20-second deadline includes file/header reads, parser-module loading and
  extraction. A timer aborts active asynchronous work and terminates an owned PDF
  worker. Absolute monotonic-time checks at each stage also reject late work when
  synchronous module evaluation delays the timer callback. No full-file read or
  worker is admitted after an overdue/cancelled module load.
- JavaScript module loading itself cannot be aborted. A stalled code chunk can
  leave the picker busy or cancellation-pending until it settles. The component
  retains its one admission slot instead of accepting repeated files or racing
  away from an outstanding load. Unmounting invalidates all late output. This is
  not a guarantee that all network activity or a file read drains within 20 seconds.
- Chunk-load failures use fixed generic UI text, never raw URLs/stacks. A later
  explicit attempt calls the loader again without an app-cached rejected promise.
  The browser's own module cache may still require a page reload after a failure.

These are **input, archive, output and admission limits**, not a hard process-memory
or CPU sandbox. PDF.js can allocate internally before page/text limits are checked.
Synchronous bounded XML DOM parsing cannot be preempted by a JavaScript timer.
An unusually hostile or complex document can still exhaust browser resources or
freeze/crash its tab. No stronger isolation guarantee is claimed.

## Privacy and dependency boundaries

The API takes a local `File`, not a URL. PDF.js receives byte data only. External
PDF binary resources are refused by a custom main-thread factory, worker fetching
is disabled, and the owned worker denies both `fetch` and `XMLHttpRequest`.
No font/CMap/wasm/CDN URL is configured. EPUB entries are read into bounded memory,
never extracted to paths or passed to an HTML renderer. Query/extracted content
is rendered as escaped React text and is not executed as commands or instructions.

Only owned `SafeDocumentError` messages reach the UI. Arbitrary third-party parser
messages are replaced with a fixed generic failure, even if their text begins
with a familiar format name. No document content, parser stack, password, or path
is intentionally logged by this feature. Parser verbosity is set to errors only.

PDF.js 6 does not expose the older `isEvalSupported` option. This implementation
therefore does **not** claim to set such an option. Its protection is the text-only
API, no scripting/viewer layer, resource-denial configuration, and owned worker
lifecycle. Mozilla distribution: [PDF.js setup](https://mozilla.github.io/pdf.js/getting_started/),
[releases](https://github.com/mozilla/pdf.js/releases/tag/v6.5.438).
The package is Apache-2.0; its license remains in the installed dependency. The npm
lock pins integrity. No install scripts or optional canvas binaries were needed
for cloud verification. Optional canvas platform packages may appear in npm's
lock graph but are not used by browser text extraction.

## On-demand production bundle

The PDF loader uses one static local dynamic-import target, not a CDN or a URL
constructed from file content. PDF.js and its worker are absent from the initial
browser script's static import graph and from HTML preloads. The PDF worker asset
belongs only to the deferred extraction chunk. Loading code sends no document,
query, filename, or file path in the module request.

For the isolated change against local baseline `99a7313` (published source
`50b1d3d`), actual Vite builds reduced initial JavaScript from **790,299 to 290,360
bytes (63.26%)**. The PDF module is a separate 501,577-byte chunk, and the existing
worker is 1,251,621 bytes. These are emitted uncompressed bytes and static graph
evidence, not measured browser startup latency or a runtime network trace. The
native three-resource output remains byte-for-byte identical to that baseline.
The deferred parser still triggers Vite's 500 kB chunk-size warning.

## Cloud validation

From `web/`:

```sh
node --experimental-strip-types --test tests/study-documents.test.mjs
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node --experimental-strip-types --test tests/study-documents-parsers.test.mjs
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/study-document-ui.node.cjs
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/pdf-worker-lifecycle.node.cjs
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/document-admission.node.cjs
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/pdf-lazy-loading.node.cjs
npm run typecheck
npm exec -- vite build --manifest
node tests/pdf-build-graph.mjs dist # optional second argument: exact baseline dist
```

The parser suite uses a real generated synthetic PDF through the actual pinned
Mozilla parser and actual detached XML parsing through JSDOM. No private books or
account data are test fixtures. The UI/coordinator suites deliberately simulate
workers, failed/ignored cancellation, delayed reads/code-module loading, delayed
timer delivery, retries, and parser errors to inspect ownership and stale-result
behavior. The lazy-loading suite includes the real React importer and coordinator
with only the PDF module boundary replaced by a controlled double. They do not prove browser worker startup.

A standalone Vite production build of the importer was verified in cloud. Browser
launch remains blocked by the environment, so no Chromium/WebKit, visual, file
picker, browser-worker, or device pass is claimed. There were no Mac/device runs,
provider calls, document uploads, or direct pushes.
