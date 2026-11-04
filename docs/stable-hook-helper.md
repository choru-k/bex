# Stable hook helper lifecycle

UI, provider, and app-side policy updates do not need to reinstall or reconfigure an
already compatible `bex-hook`. Bex retains the installed content-addressed path,
executable bytes and inode, host JSON, ownership manifest, installation timestamp,
and heartbeat. Codex approval remains owned by Codex: Bex neither invents approval
nor clears an existing approval by changing a compatible command.

## Compatibility is explicit and authenticated

The helper target embeds `Config/HelperInfo.plist` in its Mach-O `__TEXT,__info_plist`
section. Code Signing Services returns this secured plist through
`kSecCodeInfoPList`. The manager does **not execute the installed helper** to learn
its version. `--self-check` remains a diagnostic output, not a source of trust.

For every installed helper, reuse requires:

- Its configured path matches the manifest's content-addressed SHA-256 path.
- The path has no symlink artifacts or ancestors, the file is executable, and its
  bytes match the installed digest.
- Existing signature policy passes, including the `bex-hook` identifier and
  production Team ID. No signature, TCC, quarantine, or host-approval bypass is added.
- Both installed and embedded signed contracts satisfy the current app's exact
  contract, protocol, runtime revision, and message limit, with every required
  capability present. An IPC version alone is not evidence of runtime compatibility.
- File identity and digest match before and after metadata inspection. Signature
  validity, signer identity, and metadata are read from the same Code Signing object.
  These are point-in-time checks, not a claim of protection against a compromised
  same-user process swapping and restoring filesystem entries between observations.

An exact byte match may reuse the same verified signed metadata, but never skips
checking the app's required contract. Missing, malformed, or incompatible signed
metadata means **Update available** and
does not permit new delivery receipts. Existing path, JSON, and helper bytes remain
untouched until the user reviews and applies an update. Helpers installed before
this metadata exists therefore need one reviewed migration, not a guessed upgrade.

App launch no longer overwrites the legacy `bin/bex-hook`. Legacy installations
remain removable; a changed legacy helper requires reviewed Update or Repair.
Ad-hoc debug signature policy is unchanged: it only permits the bundled debug
helper, not arbitrary copied debug binaries. Production-style reuse requires a
helper accepted by the existing installation signature policy.

## Changes, review, and removal

Only an explicit reviewed transaction changes an installed helper or host command.
An old descriptor is rebound to the new embedded path for a reviewed Update or
Repair, but an Uninstall always targets the helper actually owned by the manifest.
Removal does not need to execute or trust a helper, and can proceed when the embedded
helper is missing. The source helper changing after review makes Apply stale.
Unchanged helper writes are genuine no-ops, including when two integrations share
one helper. Shared references continue to prevent premature helper removal.

## Maintaining the contract

`HookHelperContract.current` describes this app's requirements. Its matching sealed
copy lives in `Config/HelperInfo.plist`; the bundled-helper unit test requires them
to agree. Increment `runtimeRevision` in **both** whenever the helper or shared
runtime behavior changes, especially security fixes, receipt semantics, prompt
classification, IPC behavior, and delivery acknowledgment. Never reuse the old
revision just because wire JSON remains unchanged. Changes confined to UI, provider
code, or app-side correction policy do not change this helper runtime contract.

The lifecycle tests use inert fixture bytes and injected signature/metadata readers.
They cover compatibility, unknown and incompatible contracts, trust/heartbeat
preservation, path/digest/signature failure, explicit update/removal, stale review,
and launch/legacy no-op behavior. The bundled signed-metadata test must run under
the normal macOS Xcode test target before claiming packaged validation. The portable
`node --test scripts/tests/bex-helper-contract.test.mjs` command only checks source
contract consistency and build wiring; it cannot validate a signed Mach-O.

## Separate Accessibility boundary

This is the terminal hook helper, not an Accessibility agent. Accessibility remains
in `SystemPromptAccessibilityService` inside Bex and is subject to that app's own
macOS trust identity. This change does not promise that rebuilding the Bex app will
preserve its Accessibility authorization. Splitting AX work into a separate stable
signed helper needs a distinct design, IPC authorization, packaging, and macOS tests.

Apple references: [Create Info.plist Section in Binary](https://developer.apple.com/documentation/xcode/build-settings-reference)
and [kSecCodeInfoPList](https://developer.apple.com/documentation/security/kseccodeinfoplist).
