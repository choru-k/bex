# Opt-in native resource build integration

**Status: source-only Xcode integration, NOT NATIVE-BUILT OR RUN.** The Bex target
now has an actual post-resources build phase for the offline package's four
files. It is disabled in both Debug and Release. The packaged host's only open
hook remains inside `#if false`; this resource switch cannot make that hook
reachable. No app copy, Xcode/native build, signing, registration, installation,
launch, CI execution or device operation was performed for this change.

This closes the source-level packaging connection between the
[offline review artifact](native-resource-packaging.md) and the fixed layout
expected by [native resource admission](native-resource-admission.md). It does
**not** establish that Xcode executes the phase successfully, that WebKit can
safely load these bytes, or that native activation is approved.

## Default builds and filesystem-synchronized groups

`Bex.xcodeproj` uses filesystem-synchronized `Bex` and `BexHookShared` groups.
Putting generated web files below those groups could silently add resources to
ordinary builds. This change adds no generated files or resource references to
those groups. The scripts and input lists live outside them.

The explicit phase runs after Bex's Resources phase and before Embed Helpers.
`BEX_EMBED_NATIVE_WEB_RESOURCES = NO` is set in both app configurations. In that
mode the shell wrapper does not invoke Node, audit inputs, build web assets or
write anything. It checks only whether `BexWebUI` or the manifest already exists
at the configured resource destination. Leftovers, including dangling symlinks,
fail the build rather than silently retaining a prior opt-in payload. It never
cleans them automatically. Other targets do not have this phase.

The phase always checks its selected inputs, including on incremental builds.
Its output declarations identify the two owned resource entries; its default
package input file list is empty, so missing optional inputs do not become
requirements for disabled builds. No runtime preference, environment override
inside Swift, menu item or host registration was added.

## Offline preparation, safe to test without an application

Use the existing packager to create and verify a fresh offline review directory.
That packager is unchanged and continues to reject app and installation outputs.
It never runs `npm`, installs dependencies or builds resources implicitly.

After reviewing the artifact, take its `inventorySha256` from the successful
verification result. Then create a new input file list outside the package:

```sh
node scripts/bex-embed-native-resources.mjs \
  --package /absolute/reviews/bex-native-review-001 \
  --inventory-sha256 SELECTED_64_CHARACTER_LOWERCASE_SHA256 \
  --write-input-file-list /absolute/reviews/bex-native-review-001.xcfilelist
```

The literal placeholder above is rejected. Supply the selected real digest.
The output file must not already exist; its parent must exist. The generated
list contains the canonical package root and exactly its four resource files.
It declares data inputs for Xcode's script sandbox, not shell commands. Paths
containing newlines, control characters, `$`, `#`, backslashes or aliases are
rejected rather than embedded into Xcode's substitution language. The file is
written as `0600`; an unexpected write failure removes only a newly created file
whose identity and parent still match, or explicitly reports incomplete cleanup.

In this legacy flow, a digest pin is a selection of **artifact bytes**, not a
proof of source freshness. A self-consistent old package with its matching old pin is accepted.
Neither the package nor this phase binds the web source, lockfile, build config,
compiler or dependency versions to the resource bytes. There is no signed
provenance or trusted build attestation. Rebuilding and selecting the intended
artifact from reviewed sources is a separate responsibility. No claim that these
resources reflect the current checkout is made by the legacy flow. The separate
[explicit source-freshness preparation](native-source-freshness.md) now builds
fresh output, records bounded before/after input continuity and can require a
matching current-source receipt. It remains an accidental-staleness guard, not
trusted provenance.

## Future separately authorized native build

Do not run a native build merely because this source exists. After the separate
native build permission and security review, an explicit resource-only opt-in
requires all of the following build settings:

- `BEX_EMBED_NATIVE_WEB_RESOURCES = YES`
- `BEX_NATIVE_NODE_PATH`: an existing canonical absolute Node executable
- `BEX_NATIVE_RESOURCE_PACKAGE`: the canonical absolute offline package directory
- `BEX_NATIVE_RESOURCE_INVENTORY_SHA256`: the reviewed exact inventory digest
- `BEX_NATIVE_RESOURCE_INPUT_FILE_LIST`: the canonical absolute generated list
- Optional `BEX_NATIVE_SOURCE_RECEIPT`: select the new source-bound flow explicitly;
  a present but empty/missing/invalid receipt fails without legacy fallback

No settings file enabling these is committed. The project defaults remain OFF.
The Node runtime should match the repository's `.node-version`; the phase does
not discover, download or install Node. `NODE_OPTIONS` and `NODE_PATH` are cleared
for the child process, and the selected executable is quoted directly. There is
no `eval`, command-string interpretation, PATH lookup, network request or package
manager. The package's JS and CSS are read as bytes, never imported or executed.

The JavaScript CLI's production copy entry requires macOS and an exact Bex
Debug/Release `ACTION=build` context. Installation/archive-style deployment
contexts, another target/product, a different checkout, aliased paths and a
caller-chosen resource suffix are rejected. `TARGET_BUILD_DIR` must equal
`BUILT_PRODUCTS_DIR`, be strictly beneath the existing `BUILD_DIR`, and be
outside and disjoint from this checkout. Only the existing canonical
`TARGET_BUILD_DIR/Bex.app/Contents/Resources` directory is accepted. The phase
creates neither the product nor its parents. Ordinary installed application
roots and build roots nested inside other bundles are rejected.

This context validation reduces accidental writes. Environment variables are
not a security capability, and this script does not authenticate that Xcode
invoked it. The build environment, Node executable, checked-out scripts, input
artifacts and destination ancestors must be trusted. Permission to copy
resources is still separate from permission to build, sign or launch an app.

The project declares script inputs, generated package inputs and bounded output
paths. It does **not** disable Xcode's user-script sandbox. Sandbox allowances
for a chosen external Node executable and its runtime libraries, actual Xcode
phase ordering/dependency handling, canonical Darwin paths and native bundle
behavior remain untested. If a future authorized build is blocked by the
sandbox, stop and review the exact missing access; do not disable the sandbox
or expand permissions as an implicit workaround.

## Copy and incremental behavior

Before touching outputs the implementation:

1. Checks canonical paths, package layout, safe modes, symlinks and hard links.
   Directory enumeration is bounded to the exact profile plus one extra entry.
2. Performs bounded reads before the unchanged offline verifier, requires its
   complete canonical manifest, and compares the explicit inventory pin.
3. Takes bounded copies of the verified four files in memory, checks byte counts
   and hashes, and verifies the package again. The HTML precheck is at most 4 KiB;
   each asset is at most 16 MiB; the manifest is at most 64 KiB.
4. Requires the generated Xcode input list to equal the exact selected input list.
   If a source receipt is selected, the complete envelope, canonical receipt and
   current declared source snapshot must also match before and after copying.

It writes only `BexWebUI/native.html`, its two hashed assets, and the sibling
manifest. Directories are fresh `0755`, files are fresh singly linked `0644`.
These are accepted by the existing native validator. Other application
resources are neither enumerated nor changed.

If either owned top-level output already exists, both must form the **exact**
expected layout, modes and bytes. A successful repeat is a read-only no-op. A
stale, partial, linked, unexpected or changed output fails without overwrite,
repair or deletion. When selecting new resource bytes, use a separately
authorized clean build destination instead of expecting an in-place replacement.

Fresh copies use exclusive creation. The manifest is written last; copied bytes
are independently reread and compared, and the input is verified again before
success. Handled failures remove only the files/directories this invocation
created and still identifies, in reverse order with individual `unlink` and
empty-directory `rmdir`. There is no recursive deletion. Unexpected entries,
changed ancestors or unidentified/replaced paths are preserved and reported as
incomplete cleanup. Abrupt termination can leave partial output; it must not be
used, and the next invocation fails closed on it.

Identical selected inputs yield identical bytes, layout and mode bits. This is
not a reproducible signed binary/archive: inode numbers, timestamps, ACLs,
platform metadata, signing and all other build outputs are outside that claim.
The unchanged manifest describes the original offline audit; it is not a receipt
that a subsequent build or native validation has run.

## Trust limits and remaining native gates

Use trusted, quiescent input/output trees and ancestors. Checked paths,
no-follow/nonblocking bounded reads and identity-aware cleanup detect the tested
static hazards and ordinary mutations; Node filesystem operations are not a
race-free publisher against hostile concurrent ancestor/mount changes or file
mutation. The original auditor also retains its documented concurrency limits.
A matching package and pin prove integrity observations, not authenticity,
source freshness, safety of JS/CSS or approval to execute it.

The native validator's post-check path race still requires immutable trusted
packaging. WebKit origin, navigation/frame/resource/network isolation, signed
bundle behavior, provider trust and responsiveness still require separately
authorized native verification. This phase is not a substitute for any of those
gates. The host stays unreachable even if resources are present.

## Cloud evidence

```sh
node --check scripts/bex-embed-native-resources.mjs
sh -n scripts/bex-native-resource-build-phase.sh
node --test scripts/tests/bex-native-build-inputs.test.mjs \
  scripts/tests/bex-native-composition-source.test.mjs \
  scripts/tests/bex-native-resource-admission.test.mjs \
  scripts/tests/bex-package-native-resources.test.mjs \
  scripts/tests/bex-package-native-resources-adversarial.test.mjs \
  scripts/tests/bex-audit-native-resources.test.mjs
```

The synthetic suite invokes the same copy implementation only through an
exported offline-staging entry that rejects app/project/installation locations.
Every successful copy goes into an ordinary temporary resource directory, never
an `.app`, and only tiny synthetic fixture JS/CSS is used. It covers deterministic
bytes/modes, repeat no-op, selected digest failure, malformed/stale/missing inputs,
symlink/hardlink/FIFO/oversize cases, containment, partial/corrupted outputs,
cleanup failures, explicit input-list generation, shell injection-shaped values,
disabled behavior without Node and leftover dangling links. Context validation is
read-only; the Linux production CLI is checked to reject embedding before any
copy. Project/Swift source assertions are not Xcode or native execution evidence.
