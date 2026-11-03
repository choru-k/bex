# Inactive native packaged-resource admission

**Native status: UNCOMPILED / UNRUN.** `NativePackagedResourceValidator` is actual
fail-closed Swift candidate source used by `PackagedCorrectionHost.make`, before
content-rule compilation, WKWebView configuration, construction or document load.
This change neither activates that host nor adds a resource-copy phase. Missing
resources still fail closed. The default browser/development app behavior is
unchanged. No native build/test, app launch, device operation, credentials,
provider transmission or socket operation is part of this work.

## Fixed production input and output

The only production entry is `validateMainBundle()`. It reads
`Bundle.main.resourceURL`, never a caller-selected URL, bundle or server. Only
successful validation creates the internal admission holding the exact
`BexWebUI/native.html` document and `BexWebUI` read-access root. The admission's
initializer is file-private. The host still exposes no arbitrary-document
constructor. A DEBUG-only synthetic test entry takes a fixture directory and
returns **no admission or URL**.

The expected layout under the application's resource directory is:

```text
native-resource-manifest.json
BexWebUI/
  native.html
  assets/
    native-<8–64 ASCII letters, digits, underscores or hyphens>.js
    native-<8–64 ASCII letters, digits, underscores or hyphens>.css
```

Unrelated app resources alongside `BexWebUI` are permitted. The native validator
does not enumerate the entire application resource directory, which contains other
legitimate app resources. Inside `BexWebUI`, there must be exactly `native.html`
and `assets`; inside `assets`, exactly one matching JS file and one matching CSS
file. Each enumeration stops on a third entry. Names are bounded to 75 UTF-8 bytes,
including the longest valid CSS filename. Extra/empty directories, extra scripts,
source maps, hidden files and alternative names are not accepted.

## Filesystem and read bounds

The validator rejects nonabsolute paths, empty/dot/dot-dot path components,
backslashes, NULs, trailing separators and components ending in a dot or space.
Paths must fit Darwin `MAXPATHLEN`. It walks from `/` through pinned directory
file descriptors using `openat` with `O_DIRECTORY`, `O_NOFOLLOW` and `O_CLOEXEC`.
Every resource directory and file is opened relative to those descriptors.
`F_GETPATH` checks actual descriptor-path spelling, including fixed siblings,
without a potentially unbounded app-resource enumeration. Case-insensitive
filesystem aliases are not intended to bypass exact names. This Darwin behavior
has **not** been executed or compiled here.

Directories must have no special or group/world-write mode bits. Manifest and
resource files must be regular, singly linked, nonexecutable, without special or
group/world-write mode bits. A no-follow named-file check rejects static special
files before open, followed by `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` open and another
FD check. This rejects symlinks, hard links, FIFOs, directory substitutes and
unsafe mode bits. Native admission accepts safe read-only bundle modes, such as
`0755` directories and `0444`/`0644` files, as well as the offline package's
`0700`/`0600`. This does not loosen the separate offline verifier's exact modes.
No ownership, ACL, sandbox or signature guarantee is inferred from Unix modes.

JS and CSS are each limited to 16 MiB. HTML is limited to the exact expected
template's byte count, so an oversized HTML allocation is unnecessary. The
manifest is limited to 64 KiB. Each read allocates at most its admitted size plus
one byte, loops only within that buffer, and checks for truncation/growth. The
extra byte detects ordinary growth during reading. Device/inode, mode, link count,
size, modification time and change time are compared before/after reads and
against the currently named entry. Resource directory snapshots and named
identities are checked again before success. Files are not read through unbounded
`Data(contentsOf:)` or stream-to-end APIs, and no recursive tree walk occurs.

## Exact profile and manifest comparison

The complete UTF-8 HTML must equal the unchanged auditor's `nativeHTML()` template,
including whitespace, one final newline, tag/attribute order, exact CSP and the
two admitted relative asset filenames. This rejects inline execution, remote or
aliased URLs, duplicate attributes/tags, alternate CSP, encoding and extra HTML.
It is a fixed template comparison, not a general HTML parser.

The validator hashes actual bytes using CryptoKit SHA-256 and reconstructs the
manifest with the existing schema version, profile, CSP, relative paths, integer
byte counts, lowercase full SHA-256 hashes, inventory digest and exact limitations
text. The inventory digest remains SHA-256 of UTF-8 compact JSON without a trailing
newline. The complete manifest must match the two-space JSON representation with
one final newline. No JSON decoder is used, so duplicate/unknown keys, duplicate
inventory entries, coerced types/numbers, key reordering, escaped aliases, BOMs,
CRLF, missing/trailing content and unsupported versions cannot be silently merged
or normalized into accepted data.

There is one deliberate, bounded ordering difference from the offline verifier:
the native consumer accepts **either ordering of the two asset entries**, with
`native.html` always last and the correct digest for the chosen order. Node's
existing auditor uses `localeCompare(..., 'en')`; reproducing its ICU/platform
collation in Swift would introduce an unnecessary compatibility dependency. The
native consumer compares exactly two complete canonical candidates, not arbitrary
JSON permutations. Both describe the same exact resource bytes. The auditor and
offline packager are unchanged and still emit/require their original order.

## Trust and concurrency limits

The manifest is an integrity record, **not a signature or authenticity proof**.
An attacker who replaces both resources and manifest consistently can create
another matching artifact. This validator does not verify a code signature,
trusted build provenance, release approval or JS/CSS semantics. A trusted, signed,
immutable app bundle and trusted ancestors/mounts are prerequisites supplied by
separate release/platform controls, not conclusions of this check.

Pinned descriptors and repeated snapshots narrow static alias and ordinary
mutation hazards. They do not promise protection against hostile concurrent
mutation, ancestor/mount changes, timestamp restoration or content changes after
read. In particular, the host awaits rule compilation after admission and WebKit
later reopens the document/assets **by path**; the checked FDs are not the bytes
WebKit is guaranteed to load. This post-check path race remains an explicit
activation blocker unless immutable trusted packaging supplies the prerequisite.
No race-free snapshot, secure concurrent publisher or runtime enforcement is
claimed. The synchronous admission can read up to 32 MiB of JS/CSS plus HTML and
manifest on the host's main actor. Native responsiveness and loading behavior
remain unvalidated.

CSP declaration and hashes do not establish WebKit `file:` origin semantics,
relative asset loading, frame/navigation/resource/network isolation or native
bridge trust. Those existing native security gates remain unvalidated, and the
host must stay inactive until separately authorized native verification and
review. A matching package must not be treated as permission to execute it.

## Evidence and tests

Cloud checks:

```sh
node --test scripts/tests/bex-native-resource-admission.test.mjs \
  scripts/tests/bex-audit-native-resources.test.mjs \
  scripts/tests/bex-package-native-resources.test.mjs \
  scripts/tests/bex-package-native-resources-adversarial.test.mjs
```

The new Node suite extracts the actual Swift HTML, compact inventory and manifest
literals, checks them against the unchanged Node auditor, and verifies Swift
synthetic golden fixtures against real offline package output. Fixtures exercise
both asset orders and mixed-case/punctuation names, including 64-character suffixes
and a 75-byte CSS filename. Source assertions check Bundle.main-only admission,
pre-WebKit call ordering, bounds, filesystem operations and exact comparison.
These are template/source checks, **not execution of Swift, Darwin or CryptoKit**.

`NativePackagedResourceValidatorTests` authors 16 synthetic XCTest groups against
the exact validator: valid fixtures and both orders, maximum filenames, normal
app-resource siblings/safe modes, missing/extra entries, ancestor/leaf symlinks,
case aliases, hard links, FIFO/nonregular files, unsafe modes, sparse overlimits,
invalid filename bounds/characters, path aliases, HTML/CSP mutations, changed and
appended content, duplicate/unknown/reordered/coerced manifest fields and
noncanonical bytes. The Node suite also checks that authored direct manifest
mutations are not accidental no-ops. These Swift tests are **uncompiled and unrun**
in cloud. They are application-hosted tests and future execution may launch Bex;
this document does not request such execution. Concurrent mutation behavior,
Darwin path semantics, actual signed bundles and native/WebKit behavior remain
outside the cloud evidence.
