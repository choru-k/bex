# Inactive native resource audit

This is an offline, cloud-compatible packaging review gate for the **alternate**
`web/native.html` build. It does not package or activate Bex. The default fixture
`web/index.html`, its build and development server are unchanged.

## Run explicitly

From the repository root, with existing web dependencies available:

```sh
(cd web && npm run build:native)
node --test scripts/tests/bex-audit-native-resources.test.mjs
node scripts/bex-audit-native-resources.mjs --dist-native web/dist-native
# Optional: create a NEW manifest outside staging; never overwrite a prior review.
node scripts/bex-audit-native-resources.mjs --dist-native web/dist-native \
  --manifest /absolute/review-output/native-resource-manifest.json
```

The build produces staging; the separate audit **does not write to staging**.
Without `--manifest`, the JSON artifact is emitted only to stdout. Output parents
must already exist. Explicit output uses exclusive creation and must be outside
staging, with no symlink components. No default path, auto-build, dependency
installation, app-resource copy, signing, installation or native invocation occurs.
A failed audit exits nonzero and emits no manifest. A failed output write also
exits nonzero; a filesystem I/O failure may leave an incomplete new output file,
which must not be accepted as an audit artifact.

## Fail-closed profile

`bex-native-vite-single-entry-v1` accepts exactly three regular, singly linked files:

- `native.html`
- `assets/native-<8–64 ASCII letters, digits, underscores or hyphens>.js`
- `assets/native-<8–64 ASCII letters, digits, underscores or hyphens>.css`

Exactly one JS and one CSS file are permitted. No extra files, maps, executables,
subdirectories or empty directories are allowed except `assets`. Symlinks at any
input component, hard links, nonregular files, executable/special permission bits,
group/world-writable files and files larger than 16 MiB are rejected. Paths with
dot segments or backslashes are rejected rather than silently normalized. The
Vite filename suffix is a constrained filename, **not** a verified content hash.
The manifest separately calculates full SHA-256 hashes of every file's bytes.

The complete emitted UTF-8 HTML bytes must equal the small template implemented
in `nativeHTML()`, including whitespace, tag order and exact attributes. This is
an intentionally narrow template verifier, not a general-purpose HTML parser.
It admits one relative `./assets/...js` module and one relative stylesheet matching
the actual inventory. It rejects alternate HTML encodings/formatting, inline code,
event handlers, inline styles, duplicate tags/attributes, comments, remote URLs,
protocol-relative URLs, entities, traversal, query strings, fragments, preloads,
frames, forms and base tags. A future Vite change, code splitting or asset addition
must fail until its profile is explicitly reviewed and updated; do not loosen the
profile merely to make a build pass.

CSP is exactly one meta element immediately after charset and before any resource.
The policy defaults to `none`, permits only `self` scripts/styles, and disallows
inline/eval execution, attribute script/style, connections, images, fonts, media,
objects, frames/children/workers, base URLs and form submissions. No unsupported
meta-only promise such as `frame-ancestors` is made. Native host navigation/frame
controls remain separate requirements. React-driven inline style assignment may
be affected; native UI behavior under this policy has **not** been validated.

## Artifact and trust limits

The artifact includes the profile, exact CSP, sorted relative file paths, byte
counts, SHA-256 hashes and an inventory digest. The inventory digest hashes UTF-8
`JSON.stringify(inventory)` with no trailing newline. It binds the reviewed bytes
for comparison; it is not a signature, provenance attestation or an approval to
copy them into an application. Review and retain the artifact separately. Any
later changes require a new audit and artifact, and a future authorized packaging
step must compare the exact bytes it consumes rather than trust an earlier pass.

Use a trusted, quiescent staging directory and output ancestors. Component checks
and no-follow/nonblocking leaf reads detect static malicious fixtures but do not
provide a filesystem sandbox or protect against concurrent ancestor replacement,
file mutation or changes after the audit. No race-resistant immutable snapshot is
claimed. In particular, an audit is not authority to execute its JS.

The auditor does **not** parse or prove JavaScript/CSS behavior. Local script or
CSS may contain remote references, dynamic imports or network operations; hashes
only record those bytes. A CSP declaration does not prove WebKit enforcement,
`file:` origin semantics, relative resource loading, native endpoint trust or
network isolation. Actual WebKit resource/navigation/frame/network isolation and
CSP behavior remain unverified and are required before any separately authorized
activation. No native build/test, app launch, provider call or permission change
is part of these commands.
