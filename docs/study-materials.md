# Manual study-material library

This candidate adds a small, local library of **user-entered attributed excerpts**.
The browser entry also offers explicit local PDF/EPUB text extraction and keyword
passage search; see [document import and limits](study-document-import.md). Native
mode remains manual and session-only. Neither path builds embeddings or claims
that fixed sample feedback adapts to a book.

## User workflow

1. Add a material using its title and, where useful, author in the attribution field.
2. Add a named section/page reference and a short excerpt the user has permission to use.
3. Explicitly select one section to reference. The active section's title, section,
   and exact excerpt populate the existing protocol-v1 `source` field.
4. Edit or delete materials and sections. Draft edits are separate from the active
   request until **Apply edits**. Editing an active source or deleting it invalidates
   pending feedback; deleting it clears selection rather than choosing another source.
5. Clear the active selection without deleting the material. Resetting the lab clears
   active selection but intentionally preserves the library, including unfinished
   material edits. Use the explicit material/delete controls to remove those.

The library accepts up to 20 materials, 20 sections per material, 4,000 UTF-16 code
units per excerpt, and 120,000 excerpt code units overall. Attribution and section
labels are limited to the existing protocol's 160-code-unit boundary. It does not
truncate attribution or concatenate sections to fit a request. Invalid data is
rejected without changing the last valid state.

## Privacy and persistence

- Adding, viewing, editing, or selecting a material makes no external request.
- Mounting the panel never reads or writes browser storage, even when saved data exists.
- Browser fixture mode starts session-only. **Save materials in this browser** is a
  separate, explicit opt-in from saving learning preferences. It persists only the
  whitelisted material/section/excerpt fields, never draft writing, correction
  results, active selection, provider configuration, or credentials.
- Stored excerpts are plaintext localStorage, not encrypted storage. The UI warns
  against sensitive content and shared-browser access. This is not cross-device sync.
- Restore is an explicit action and is disabled while the current library is nonempty
  or editing/deletion confirmation is open, avoiding silent replacement. Restored
  material is not automatically active, and ongoing persistence must be opted into
  separately. Corrupt or oversized stored data is not silently repaired or erased.
- Disabling storage deletes this feature's one namespaced key. An explicit saved-data
  deletion control is also available, including for corrupted data. Failures are
  visible; a failed deletion does not claim success or turn off a previously enabled
  saving setting. Deleting session items with saving disabled leaves old saved data
  alone, as disclosed in the confirmation.
- **Native mode is always session-only.** It neither exposes save/restore controls
  nor accesses storage. The packaged WKWebView uses a nonpersistent data store, so
  the UI does not promise durable native persistence.
- Native mode only prepares the currently selected source for the next explicit
  correction. Existing native per-request outbound consent still governs provider
  transmission. Other stored sections are never bundled into the request.
- Book text is rendered as escaped React text, never HTML, instructions, external
  URLs, or code. The existing coach context labels the reference as untrusted data.

## Parent integration contract

`StudyMaterialsPanel` is independent of the transport and app state. Its
`onSourceChange(StudySource | null)` callback must invalidate/cancel any in-flight
correction **before** updating the app's source. It must not dispatch a request.
The panel calls this on explicit selection/clear and on committed changes to an
active source. Unrelated material edits and restore do not call it.

The parent increments `selectionResetKey` when it resets or replaces the source
outside the panel, for example through the existing one-off source fields. This
clears the panel's active choice without overwriting the parent source or deleting
library material. Do not increment the key in response to the panel's own callback.
Keep the panel outside the one-off source toggle's conditional subtree so turning
that toggle off cannot discard library edits.

Use `mode="native"` in the alternate native renderer. The component's optional
`storage` adapter exists for testing; it is never accessed in native mode.

## Validation

From `web/`:

```sh
node --experimental-strip-types --test tests/study-materials.test.mjs
BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/study-materials.node.cjs
npm run typecheck
BEX_WEB_PORT=5197 npm exec -- playwright test tests/study-materials.spec.ts
```

The dependency-free domain suite covers strict schemas, size/count limits,
immutable edits, exact attribution, source selection/deletion, persistence
allowlists, unavailable/corrupt storage, and instruction-shaped excerpt data.
The separate React/JSDOM harness uses synthetic content and covers manual editing,
cancel/repeated apply, active source updates, explicit restoration, persistence
failures, deletion confirmation, native storage isolation, reset, and escaped
rendering. It is not browser, WebKit, native consent, or live-provider verification.
The Playwright suite requires the integrated `App` panel and covers request preview,
stale results, manual source replacement/reset, browser persistence, malicious text,
external request absence, and narrow layout.

## Remaining boundaries

- Learner history/mastery, automatic semantic relevance selection and verified
  full-document quotations are not added. Browser PDF/EPUB extraction is a bounded
  separate workflow; its source attribution and limits are documented above.
- Existing general vocabulary preference remains a request preference, not a
  demonstrated adaptive learning result.
- Fixture feedback remains deterministic and does not incorporate the excerpt.
- Durable native storage requires a separate host-managed design and privacy review.
- Cloud tests do not establish macOS Accessibility, global shortcut capture,
  input replacement, native consent UI, or live correction quality.
