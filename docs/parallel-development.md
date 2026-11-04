# Isolated cloud verification

Use Linux cloud workspaces for this workflow. Do not run native applications,
install helpers, change host permissions, or test on the user's Mac without
separate explicit permission. Linux platform checks are workflow guards, not an
OS security boundary. No GitHub Actions workflow is required or added.

## Ownership and lanes

One integration owner handles build scripts, manifests, contracts and lockfiles.
UI owns web/src/App.tsx and styles; core owns domain/coaching modules and tests;
helper owns its separate native/helper changes. Agree on shared-file ownership
before editing. Do not write the same file in two lanes.

Commit the workflow in a complete checkout before creating lanes from the same
full 40-character commit SHA:

```
BASE=$(git rev-parse HEAD)
node scripts/bex-parallel.mjs create ui "$BASE"
node scripts/bex-parallel.mjs create core "$BASE"
node scripts/bex-parallel.mjs create helper "$BASE"
node scripts/bex-parallel.mjs create integration "$BASE"
```

The script creates sibling Git worktrees and branches without overwriting existing
paths. Each lane has independent dependencies, cache, reports and temporary files.
Loopback ports: ui 5271, core 5272, helper 5273, integration 5274. Concurrent copies
of the same lane require separate containers. Do not share writable browser profiles.

## Checks

Node baseline: .node-version; preserve the exact committed package-lock.json.
Run inside the appropriate worktree:

```
node scripts/bex-parallel.mjs fast core
```

Fast runs runner regressions and dependency-free core, coaching and extracted
native-smoke JavaScript tests. It does not compile Swift or test browser rendering.

The integration owner prepares official test browser artifacts in its own cloud
worktree and runs the full gate:

```
cd web
npm ci --no-audit --no-fund
PLAYWRIGHT_BROWSERS_PATH="$PWD/.parallel/browsers" npm run test:e2e:install
cd ..
node scripts/bex-parallel.mjs integrated integration
```

Integrated runs locked dependency installation, TypeScript, all Node unit suites,
production web build, and both Chromium/WebKit projects. Missing binaries or blocked
browser runtime fail the gate; never count discovery or unit tests as browser passes.
No network or sandbox restriction should be bypassed to obtain a pass.

## Evidence and handoff

An exclusive per-worktree lock prevents overlapping gate operations. If a process
was terminated, confirm its children stopped before manually removing the lock;
there is no automatic stale-lock deletion. Normal setup/test failures release the
lock and record failure evidence under web/.parallel.

Evidence records source hashes, commit, dirty state, runtime, stages and native-test
exclusion. Source/HEAD changes during checks fail verification, even on test failure.
NUL-delimited Git filenames preserve leading whitespace; file symlinks are hashed
as link text and symlink ancestors are rejected. These are checkout hygiene checks,
not defenses against hostile concurrent filesystem replacement.

Handoffs include exact base/head, patch, pass/fail/not-run results and remaining
limits. Browser discovery is not browser execution; extracted JavaScript tests are
not a Swift or WKWebView build. Never infer host trust, helper safety or live-model
quality from fixture tests. Public push, merge and release remain separately scoped
actions; a local clean gate does not authorize deployment or a Mac test.
