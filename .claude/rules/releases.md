# Releases

- Every versioned Bex release MUST include meaningful, human-readable release notes. A generated `Full Changelog` link by itself is insufficient.
- Before creating a tag, derive the notes from every commit since the previous version tag. Do not omit changes included in the release.
- Release notes MUST contain:
  - a short summary of the release;
  - user-visible changes and bug fixes, written in terms of behavior before and after;
  - any breaking changes, migration steps, permission changes, integration re-approval, or other required user action; write `None` when there is no required action;
  - the full changelog comparison link.
- Keep implementation details secondary. Lead with what changed for the user and why it matters.
- Do not include secrets, credentials, private filesystem paths, internal-only identifiers, or unsupported claims.
- `gh release create --generate-notes` MAY provide a starting point, but its output MUST be reviewed and replaced or expanded when it only contains a changelog link or otherwise omits meaningful changes.
- If the GitHub release already exists, update its body with `gh release edit`; uploading or replacing the asset alone is not sufficient.
- A release is not complete until `gh release view <tag> --json body,url` confirms the published body satisfies this rule.
