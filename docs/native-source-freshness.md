# Explicit native resource source-freshness preparation

This is an **accidental-staleness guard**, not trusted provenance, build
attestation or permission to activate the native host. It performs a web build
and offline packaging only. The native resource phase remains OFF by default;
no Xcode, Swift/Bex native build, app copy, signing, installation, registration,
device operation or host activation is part of this command.

**Coverage limits:** before/after snapshots do not detect an edit that is made
and restored between snapshots. A trusted Vite config, plugin or compiler can
read undeclared files outside the declared trees, import generated/excluded
paths, resolve a missing module from an ancestor `node_modules`, or consult
external runtime libraries/system state. Those inputs are not covered. This is
not a hermetic build, executable authentication or a hostile-concurrency
sandbox. A person able to forge resources and a matching receipt can forge the
integrity observations. Do not treat this receipt as release approval.

## What the new flow actually does

The existing offline packager continues to accept a previously built, valid
`dist-native` tree. Its original four-file package and verifier are unchanged.
The [legacy build-input flow](native-build-input-integration.md) continues to
check artifact integrity against a selected inventory pin without proving
current-source freshness.

The new command does not accept an existing `dist-native` as build evidence. It:

1. Captures bounded, canonical inventories of the declared source inputs and
   actual installed dependency tree, plus the current Node executable hash and
   version/platform/architecture. `.node-version` must equal the running Node
   version exactly, with one final newline. Nothing is installed automatically.
2. Exclusively creates a fresh offline preparation directory and an empty
   `build-output` directory outside the checkout.
3. Directly invokes the existing installed TypeScript and Vite entrypoints with
   the captured Node executable, using the existing native Vite config:
   - `web/node_modules/typescript/bin/tsc -p tsconfig.json`
   - `web/node_modules/vite/bin/vite.js build --config vite.native.config.ts --configLoader native --outDir <fresh build-output>`
4. Recaptures source, dependency and Node inputs after both child tools succeed
   and rejects any persistent change. It packages only that fresh build output
   with the unchanged strict offline packager, then recaptures inputs again.
5. Writes an exact Xcode input list, performs another full continuity check, and
   writes the source receipt **last**, as the completion record. It verifies the
   complete envelope, current source snapshot, canonical receipt and selected
   package before reporting success.

This is the distinct recipe `bex-native-direct-tsc-vite-native-config-v1`, **not**
a claim to have run `npm run build:native`. The receipt contains the exact entry
paths and argument templates. Its one output argument uses the documented
`$PREPARATION/build-output` placeholder, resolved to the fresh output directory
for execution. Native config loading avoids a temporary compiled config in
`node_modules`; it requires the pinned Node runtime to support the repository's
config syntax. Unsupported future config syntax fails instead of silently
changing loaders.

The subprocess environment contains only `CI=1`, `NODE_ENV=production`, `TZ=UTC`,
`LANG=C`, `LC_ALL=C` and `PATH` set to the current Node executable's directory.
Inherited `VITE_*`, `NODE_OPTIONS`, `NODE_PATH` and other environment variables are
not passed. Vite can still read declared `.env*` files in the web tree. Commands
use argument arrays without a shell. Each child has a 120-second timeout and a
1 MiB captured-output budget; failures report the error/status/signal and a
bounded output tail. TypeScript may delegate to its installed platform compiler;
that package is in the dependency fingerprint. There is no npm script, installer,
download or network command in the orchestrator. Trusted build tools/configs
still execute, and this script is not a network or process-tree sandbox.

## Explicit offline commands

Use existing installed dependencies and the repository's pinned Node. Choose an
existing trusted review parent outside the checkout. The final directory must
not already exist, even if it is empty:

```sh
node scripts/bex-prepare-native-resources.mjs \
  --output /absolute/reviews/bex-source-bound-001

# Independent read-only check against the current declared checkout sources:
node scripts/bex-prepare-native-resources.mjs \
  --verify /absolute/reviews/bex-source-bound-001 \
  --inventory-sha256 SELECTED_64_CHARACTER_LOWERCASE_SHA256
```

Use the actual inventory digest returned by preparation; the placeholder is
rejected. The verification command does not rebuild or require installed web
dependencies. It does need Node to run the read-only checks.

Successful preparation contains exactly:

```text
bex-source-bound-001/
  build-output/                  # Retained diagnostic web output, never consumed by the app phase
  package/
    native-resource-manifest.json
    BexWebUI/
      native.html
      assets/<one JS and one CSS file>
  native-inputs.xcfilelist
  native-source-binding.json     # Final completion record, outside the unchanged package
```

The envelope and package roots are `0700`; receipt and original input list are
singly linked `0600` files. The receipt is canonical two-space JSON plus one
newline. Its schema/profile are version 1 / `bex-native-source-binding-v1`. It
contains the exact source inventory/digest, dependency fingerprint counts/bytes,
Node identity observations, exact direct-tool recipe/environment, selected
resource inventory and canonical manifest digest, original input-list digest,
and fixed limitations text. Unknown/reordered/duplicate fields, altered
formatting, unsupported values and mismatches are rejected.

The source/dependency digests exclude absolute checkout paths and timestamps.
The input list necessarily contains absolute local paths, and its digest is in
the receipt; therefore the entire receipt is not claimed to be path-independent
or a reproducible archive. No timestamps, credentials or source-file contents
are deliberately copied into the receipt. Hashed `.env*` contents are still
private input data and the resulting Vite bundle may include variables that the
existing Vite configuration deliberately exposes.

## Exact snapshot coverage and budgets

The declared source profile includes the entire `web` tree except these exact
top-level generated paths and their contents:

- `node_modules`, `dist`, `dist-native`, `.parallel`, `.native-build`
- `playwright-report`, `test-results`

It also includes `.node-version`, `Config/BexNativeResourceScripts.xcfilelist`,
and the six resource audit/packaging/embedding/build-wrapper/source-binding/
preparation scripts listed by `SOURCE_FILES`. This deliberately includes the web
package/lockfile, all Vite and TypeScript configs, `.env*` files, native HTML,
source/assets/public files and web tests. Some conservative inputs, such as web
documentation or test changes, can invalidate a receipt even when the generated
JS would be unchanged. Changes to unrelated native/helper sources do not.

Source snapshots allow at most 4,096 entries and 64 MiB of file bytes. Dependency
snapshots allow at most 10,000 entries, 512 MiB total and 128 MiB per file. Node's
executable is bounded to 256 MiB. Paths have bounded length/depth; enumeration
stops at its budget. Reads stream through at most 64 KiB buffers, hash bytes and
check named/opened identity and metadata before/after. Source files, directories
and regular dependency files must have safe mode bits. Symlinks in source or
ordinary dependency paths, special files and unsafe directory aliases fail.

Normal npm `.bin/<name>` links are the only accepted dependency links. Their
relative targets are normalized, required to stay inside `node_modules`, and
checked as canonical regular files; the literal link target is also recorded.
No escaped, absolute, directory, workspace/store or other package symlink is
followed. pnpm/workspace layouts with additional links are unsupported and fail
rather than being read outside the declared tree. Package dependency bytes are
observed, not authenticated or certified to correspond to the lockfile. External
linked libraries and ancestor module fallback remain outside coverage.

The receipt is at most 2 MiB and each Xcode list at most 64 KiB. Current-source
admission rehashes only the declared source profile, not 234 MiB of dependencies
or the preparation Node executable. This permits a Linux-prepared package to be
checked against identical declared sources on a Mac with a different toolchain,
or with no installed web dependencies. It does not promise current dependency or
runtime equivalence across those environments.

## Bound build admission and relocation

For a future **separately authorized** native resource-only build, select all the
existing explicit settings and additionally set:

- `BEX_NATIVE_SOURCE_RECEIPT` to the canonical source receipt path.

When that setting is present, even if empty, there is no fallback to unbound
verification. The exact versioned envelope, original list digest, receipt schema,
current source inventory and selected resource inventory must all match. The
selected Xcode input list must also include the exact additional receipt/source
read paths. Binding is checked before and after output verification/copy; a
persistent source edit during a fresh copy triggers the existing owned-only
cleanup. An edit after the final check is outside the quiescent-tree contract.

The original input list is preserved with the envelope. If the envelope or
checkout moves, generate a fresh selected list outside both the preparation
envelope and declared source checkout:

```sh
node scripts/bex-embed-native-resources.mjs \
  --package /new/reviews/bex-source-bound-001/package \
  --inventory-sha256 SELECTED_64_CHARACTER_LOWERCASE_SHA256 \
  --write-input-file-list /new/reviews/rebased-native-inputs.xcfilelist \
  --source-receipt /new/reviews/bex-source-bound-001/native-source-binding.json
```

Run that command from the scripts belonging to the current checkout. It verifies
current source equality before writing a new list. The original receipt/list
stay unchanged. The selected list declares the entire offline envelope for its
bounded top-level enumeration and diagnostic directory metadata checks, as well
as the exact declared source roots, scripts and package files. This is a
recursive read allowance for those input directories, not a write grant. The
static script input list includes the eagerly imported binding module even for
the legacy flow. Actual Xcode sandbox behavior remains unvalidated; do not
disable the sandbox or silently broaden permissions to make it run.

If the receipt setting/option is omitted entirely, the explicitly documented
legacy inventory-only behavior remains available. Selecting a nested package
and old inventory pin without selecting its receipt does **not** claim freshness.
Nothing here enables the host, changes project settings, or changes native
resource admission/runtime security requirements.

## Failures and evidence limits

Existing output paths are never reused. Output within the checkout, app/project
bundles, installation paths and aliased/symlink paths is rejected. A failed
preparation does not supply a usable completion receipt. Cleanup uses only
individual unlink/empty-directory removal for newly created entries whose
identity and ancestors remain known. It never recursively removes tool output,
a completed nested package, foreign entries or preexisting directories. Partial
outputs can remain for inspection and the error names them. Abrupt termination
can leave a partial envelope; bound admission rejects a missing completion
receipt, missing list, missing package or unexpected envelope entry.

The retained `build-output` tree is diagnostic, not an app input and not reread
as trusted resources during admission. Only the independently verified nested
package's four files are copied. A normal signed/immutable release pipeline and
the existing native security review remain separate requirements. No cloud
result proves actual Xcode phase execution, signing, WebKit isolation, native
responsiveness or any permission owner behavior.

Run synthetic cloud checks with:

```sh
node --test --test-concurrency=1 scripts/tests/bex-native-source-binding.test.mjs \
  scripts/tests/bex-native-build-inputs.test.mjs
```

The new suite uses tiny synthetic installed-tool scripts executed by the real
Node runtime. It covers actual orchestration ordering, environment/arguments,
source/config/lock/dependency mutation, child failure, stale old dist, wrong
artifact selection, schema/format/list tampering, missing/extra envelope entries,
links/FIFO/oversize/budget rejection, aliases/overlap, bound copy cleanup, retained
foreign files, relocated input lists and intentional legacy behavior. A separate
actual installed TypeScript/Vite build is needed as cloud toolchain evidence;
synthetic fixtures alone are not that evidence. Neither path performs a native
Bex build or creates an `.app` directory.
