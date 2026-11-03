# Cooperative account and settings barrier implementation

Draft implementation against choru-k/bex `49852a47dc0cdd21e2924f46c0b3c9cc97ee3a2e`. Swift compilation and native runtime tests have NOT been run. No activation, credentials, provider calls, Mac execution were performed for this work.

## Production scope

`AccountMutationCoordinator.shared` is the single process-wide domain. Every KeychainStore and PreferencesStore uses it unconditionally; there is no injected coordinator option in production store constructors. Overlapping services and preferences suites therefore cannot accidentally select disjoint gates. A standalone coordinator initializer exists for synthetic tests but is never selected by production stores or the production host.

The guarantee covers cooperative writes through these stores and drains only lifetimes registered by the inactive packaged native host. Existing non-native GrammarService jobs are not registered and are not promised revoked by this change. It does not cover external Keychain writers, direct UserDefaults changes, other processes, or bytes already sent. Native Codex remains unsupported because its self-refresh can otherwise wait for its own host lifetime.

## Host contract

All host APIs are MainActor isolated:

- `reserveAdmission() throws -> AdmissionReservation`: obtains an opaque coordinator identity and epoch only while admission is open.
- `validateAdmission(_:) throws`: call after every suspension while reading configuration/building the candidate. No stale reservation can be admitted, including after a write fails or is cancelled.
- `registerHost(reservation:revoke:drain:) throws -> UUID`: validates and registers atomically, with synchronous MainActor revoke and asynchronous MainActor drain closures.
- The document must not load before registration. After successful registration, load without another suspension.
- `removeHost(_:)`: call only after complete lifetime termination, including all cancelled-but-running provider work, consent work and transport callbacks. Synchronous revoke and Task.cancel are not termination.
- Internal read-only diagnostics expose admission closure, registered lifetime count and queued mutation count for tests.

`PreferencesStore.nativeCorrectionConfiguration()` returns `(destination: OutboundDestination, effort: ReasoningEffort)`. Its multi-key read is synchronous under the common backing lock; the host must still validate its reservation after awaiting this actor method.

## Mutation contract and cancellation

The first queued mutation synchronously closes admission, replaces the epoch, snapshots ALL registered lifetimes, and revokes each before awaiting any drain. An unstructured MainActor worker awaits their complete termination and does not inherit the writer's cancellation. No timeout or cancellation fallback permits a write. A nonterminating host deliberately leaves writes/admission blocked.

FIFO is defined by arrival at the coordinator's enqueue operation. After drain, one writer is resumed at a time. Each complete storage operation executes in a synchronous MainActor closure, with no suspension or actor hop between generation comparison and physical write. Synchronous Security operations now run in this MainActor commit turn; their responsiveness and platform behavior require native validation. A defer releases ownership on success and failure. Admission stays closed between queued writes.

- Existing nonthrowing preference setters are async nonthrowing: once enqueued, they complete even if the caller is cancelled. They do not silently return success without applying the setting.
- Throwing Keychain writes check cancellation after acquiring the turn and before beginning the synchronous commit. A cancelled waiter remains queued through the required drain; its turn is safely skipped and released. Once the synchronous write begins, it runs to completion even if cancellation arrives. There is no rollback claim for partially completed storage failures.
- `withMutation` and `withThrowingMutation` accept synchronous closures, so callers cannot suspend or nest an async setter while owning the barrier.

All 22 public preference mutation entry points, plus explicit retired-model migration, route their complete bodies through the barrier. The correction-model override writes the selected-model key directly in the same transaction rather than calling another setter. The selected-model getter returns the effective replacement without persisting anything. `migrateRetiredModels()` is the explicit gated persistence operation and re-reads inside its transaction before replacing a value. It is not invoked automatically on a read or Settings load; the stored historical model may remain until an explicit model write or migration. This deliberately avoids revoking hosts simply by opening Settings.

The original initialization-only retention migration is the documented exception: it only changes legacy draft/history retention keys, none of the admitted native account/destination/consent configuration. It remains synchronous under the backing lock to preserve existing initialization/read behavior.

## Backing ownership and reads

Stores remain actors. A private KeychainBacking wrapper contains immutable service/inMemory fields and uses synchronous Security APIs. Its synthetic backing is keyed by service and every dictionary read/write is NSLock protected. Explicit equal synthetic services share storage. An omitted service in `KeychainStore(inMemory: true)` gets a unique synthetic domain, preserving existing isolated fixtures; an omitted real service retains `com.bex.desktop.credentials`.

PreferencesBacking contains an immutable UserDefaults reference and a process-wide NSRecursiveLock. Complete public instance getters and complete writes hold that lock synchronously; nested model/outbound getters compose safely. The common lock also covers separate wrappers for the same suite. The static standardAppearance startup helper is the one single-key MainActor-only read exception; cooperative appearance writes are also synchronous on MainActor. Private read helpers are called only within the locked public getters. Foundation per-call thread safety alone would not preserve multi-key snapshot coherence after moving commits to MainActor, hence the additional lock.

These two wrappers are explicitly `@unchecked Sendable` with immutable/locked ownership. There are no isolation casts. No backing lock is held while awaiting mutation admission or drain. Reads never acquire the mutation permit, so draining tasks can read the stores and finish. A read can only briefly contend with a synchronous read/commit, not with a host lifetime.

## OAuth/session API

Opaque token alias: `KeychainStore.CodexOperationToken`.

- `beginCodexLogin() async -> CodexOperationToken`: immediately starts a fresh service-domain generation, invalidating earlier login/refresh completions. No gate is held over network work.
- `cancelCodexLogin(_:) async -> Bool`: only invalidates the matching current login token in this store's service. A stale service instance cannot cancel a newer login or another domain.
- `invalidateCodexOperations() async`: unconditional service-domain invalidation without storage mutation.
- `codexSessionSnapshot() async throws -> CodexSessionSnapshot?`: returns `session` and `token`. The session read and token's generation/exact session version are captured in one synchronous coordinator turn, with no mutation permit.
- `saveCodexSession(_:ifCurrent:) async throws -> Bool`: false means stale; no write occurs. It checks the token at entry AND after waiting for drain/its queue turn. Login tokens compare generation. Refresh tokens compare both generation and the precise coordinator-issued session version, not only account ID.
- Existing unconditional `saveCodexSession`, `deleteCodexSession`, API-key save and API-key delete invalidate all earlier Codex work in the same service at intent entry, before awaiting drain. They invalidate again immediately before attempted storage commit to reject operations started against old storage while they were waiting.
- A conditional login consumes its generation before the attempted write. A conditional refresh consumes its session version before the attempted write. Storage failure, including partial failure, cannot revive a consumed token.
- A cancelled replacement invalidates tokens that existed at intent entry, but if no commit occurs an explicitly newer login intent issued during the drain remains current. Tests distinguish this from an attempted failed commit.

## Authored tests, not executed

AccountMutationCoordinatorTests covers reservation foreign/stale rejection, all-host synchronous revoke, complete noncooperative drain, FIFO across failed/cancelled/successful writes, no admission between queued writes, login generation replacement, token consumption on storage failure, refresh exact-version rejection, rechecking after drain, failed replacement invalidation, partial-write failure without rollback claims, and cancellation/new-intent semantics.

AccountStoreBarrierTests covers separate same-service Keychain instances, reads from draining work, separate PreferencesStore instances, correction override without nested acquisition, preference cancellation completion, retired-model read purity and explicit migration drain, account/consent setters invalidating reservations, and cancelled Keychain mutation leaving old data with the queue reopened safely after drain.

The OAuth and host tests exercise their corresponding integration APIs. A compiler and permitted synthetic native test route are still required before treating any of these tests as passing or activating the host.

## OAuth, Settings and loopback integration

`CodexOAuthService` owns an attempt identity, a shared-store login token and a captured listener. Each suspension rechecks the attempt before proceeding. Only one manual/loopback route can claim an exchange; malformed callback input fails closed, including duplicate query keys. Captured listener shutdown occurs before the conditional storage commit. Scoped cancellation of an old flow cannot cancel a newer attempt. `OpenAICodexClient` refreshes from a versioned session snapshot and conditionally saves the result; a stale refresh cannot resurrect a removed session or overwrite a newer login. Network work never owns a mutation permit. The successful storage commit is the linearization point, not a promise that a later cross-service mutation cannot precede delivery of its acknowledgement.

Settings uses one logical login generation across manual and loopback routes, separate tracked task identities, and a completed-generation guard. Manual handover does not cancel the shared login owner. Older success/error callbacks cannot overwrite a newer action or a successful sibling route. Sign-out remains tracked and is not abandoned merely because newer UI work supersedes it; a new connect waits for requested sign-out to complete.

The actual loopback listener now refuses waits after terminal shutdown and duplicate waiters; cancelled start/wait registration is checked instead of leaving a continuation behind. Synthetic listener tests construct, stop and wait without starting a socket. These tests do not establish Network.framework runtime behavior.

New native test source totals: 8 coordinator, 6 store, 7 registered-host lifetime, and 30 OAuth/Settings/listener lifecycle tests (51 methods). All are **UNCOMPILED / UNRUN**. The existing Node endpoint suite adds two source-order/shape assertions; these are not Swift execution, actor scheduling or platform verification. Application-hosted BexTests may launch the app if executed through its normal native test workflow; this document does not authorize such execution.
