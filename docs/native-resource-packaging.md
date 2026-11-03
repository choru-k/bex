# Offline native resource packaging

This command prepares an **inactive review artifact**, not Bex.app. It does not
build, install dependencies, invoke Xcode, sign, install, activate or execute any
resource. No Xcode resource-copy phase, application-resource destination or
runtime entry point is added. Native runtime verification remains Mac-last and
separately authorized.

## Explicit workflow

Build the alternate web entry separately, only when existing dependencies and
that build are available. The packager never runs a build for you:

```sh
(cd web && npm run build:native)
node --test scripts/tests/bex-audit-native-resources.test.mjs \
  scripts/tests/bex-package-native-resources.test.mjs \
  scripts/tests/bex-package-native-resources-adversarial.test.mjs
```

Choose an existing, trusted review parent outside staging. Supply canonical,
absolute paths. The final output directory must **not exist**, even if empty:

```sh
node scripts/bex-package-native-resources.mjs \
  --dist-native /absolute/checkout/web/dist-native \
  --output /absolute/reviews/bex-native-review-001

# Independent, read-only verification of the completed artifact:
node scripts/bex-package-native-resources.mjs \
  --verify /absolute/reviews/bex-native-review-001
```

Both successful commands print the audit manifest as JSON. Failure exits nonzero
and prints an error to stderr. There are no defaults, force/overwrite options,
recursive parent creation, automatic subprocesses or installation steps. Paths
with symlink components, dot segments, duplicate/trailing separators, backslashes,
NULs, or components ending in a dot or space are rejected. Relative paths are
rejected, rather than interpreted against a possibly unexpected working directory.
On systems where a familiar temporary path is itself a symlink, use its canonical
existing parent instead.

Output under `.app`, `.appex`, `.bundle`, `.framework`, `.xcodeproj` or
`.xcworkspace` components is rejected, case-insensitively. Components named
`Applications`, `System` or `Library` and conventional Unix system/installation
roots are rejected too. These guards reduce accidental installation; they are not
a filesystem sandbox or an exhaustive classification of every mounted location.
Do not use an application, system, installed-resource or project-bundle destination.

## Exact artifact layout

```text
bex-native-review-001/
  native-resource-manifest.json
  BexWebUI/
    native.html
    assets/
      native-<audited-suffix>.js
      native-<audited-suffix>.css
```

The top level contains exactly the manifest and `BexWebUI`. The manifest is the
unchanged [native audit](native-resource-audit.md) result, written as two-space
JSON with one final newline. Inventory paths are relative to `BexWebUI`, not the
artifact root. The existing profile still requires exactly one native HTML file,
one native JS module and one stylesheet with the exact HTML/CSP template. No
extra resource, directory, executable, map or arbitrary tree is copied.

The three file byte counts and SHA-256 hashes are recorded in the manifest.
`inventorySha256` hashes UTF-8 `JSON.stringify(inventory)` without a trailing
newline, exactly as in the auditor. Identical audited inputs produce identical
manifest/resource bytes and layout; no timestamp, absolute source path, machine
identifier or new provenance claim is embedded. Filesystem inode numbers,
creation/access/modification times and other filesystem metadata are **not** a
reproducible archive format. No archive or signed release is produced.

New directories are `0700`; manifest and resource files are `0600`, independent
of the caller's umask. Copies are fresh regular, singly linked files. Permission
checks inspect Unix mode bits, not ACLs or owner/group identities; these mode bits
do not prove access isolation on a filesystem with additional permission rules.
Verification requires those exact mode bits. An external copy/export that changes modes
needs explicit review and cannot silently pass this verifier. Input files retain
their bytes, permission bits and modification times; ordinary reads may update
access time. The packager does not chmod or otherwise write to staging.

## Byte verification and failure handling

Packaging performs these steps:

1. Validate source/output paths and reject output within staging. Check input root
   and `assets` directory modes, and run the unchanged strict resource auditor.
2. Exclusively create the requested new directory and fixed two-directory resource
   layout. Copy only the auditor's three inventory paths. Each bounded regular-file
   read is compared to the initially audited byte count and SHA-256 before writing.
3. Re-audit the copied tree and compare the entire audit result to the initial
   source result. Re-audit staging to detect ordinary intervening changes.
4. Exclusively write the manifest. Independently verify the finished artifact's
   exact top-level layout, modes, resource audit and canonical manifest bytes.

`--verify` performs no repair or writes. It rejects extra/missing entries, altered
resource or manifest bytes, noncanonical manifest formatting, symlinks, hard
links, nonregular files, unsafe modes and oversized files. Resource limits remain
16 MiB per file; the manifest limit is 64 KiB. It does not accept an older manifest
as a substitute for reading the resources again.

On a handled failure, cleanup removes only paths this invocation created and
still identifies by device/inode and type. It uses individual `unlink` and
empty-directory `rmdir`, **never recursive removal**. Existing output paths are
never reused or removed. Replaced paths/ancestors, entries whose identity could not be recorded after
creation, and unexpected foreign entries are left alone; the error explicitly reports incomplete cleanup. A partial output
must not be accepted or used. An abrupt process termination, machine failure or
unrecoverable I/O error may leave partial output; no crash-atomic publication or
durability guarantee is made. Only a successful command followed by successful
verification establishes this limited offline artifact result.

## Trust limits and activation boundary

Use trusted, quiescent staging and output ancestors throughout packaging and
verification. Path checks, no-follow/nonblocking leaf reads, exclusive writes,
identity-aware cleanup and repeated audits detect the tested static hazards and
ordinary injected mutations. They do **not** make JavaScript filesystem operations
race-free against hostile concurrent ancestor replacement, file modification,
bind mounts, changing mount points or mutation after verification. No filesystem
sandbox, immutable snapshot or secure concurrent publisher is claimed.

The manifest records integrity observations, not origin, authenticity or approval.
An attacker able to replace resources and their manifest consistently may produce
another internally consistent artifact. There is no signature, signed provenance,
trusted build attestation or authorization to execute the contained JS/CSS.

The auditor does not parse or prove JavaScript/CSS semantics. A package can contain
network operations or dynamic imports in those bytes. CSP declaration and successful
offline packaging do not prove WebKit enforcement, native endpoint trust, origin,
frame/navigation/resource isolation, relative asset loading or live-network
isolation. Those remain separate required checks before any activation. The
[packaged host candidate](packaged-native-host.md) remains inactive, uncompiled and
unrun by this workflow. No Mac/device, provider, credential, socket or native-app
operation is performed.

## Inactive native consumer

The [native resource admission candidate](native-resource-admission.md) now checks
this layout and exact manifest/content profile before the inactive host constructs
WebKit. It is source-only and unrun, not a packaging, signing, installation or
activation step. Its two narrowly accepted inventory orders and native read-only
permission policy are documented separately; this offline verifier remains
unchanged and still requires its exact output modes and auditor ordering.
