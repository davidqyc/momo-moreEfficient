# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-03
sourceMainSha=26ed0f7a908a71ac5c60a67bb21712fad0f83c36
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta

LAST_COMPLETED_PRODUCT_ISSUE=#168
LAST_PRODUCT_MERGE=PR #172
LAST_PRODUCT_MERGE_SHA=bc03ee03e06bfa23a160e2599bebc9db34635812

CURRENT_PRIMARY_ISSUE=#164
CURRENT_PRIMARY_GATE=MACHINE_MIGRATION_HOLD
CURRENT_RELEASE_GATE_STATUS=PAUSED_FOR_MACHINE_MIGRATION
CURRENT_BLOCKER=Owner is switching Macs; no further Builder/canary execution should start on the old machine
CURRENT_UNIQUE_NEXT=finish one non-destructive local-repository closure audit on the old Mac; then, on the new Mac, re-establish the workspace from live remote truth and resume #164 from the Study Records identity route

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true
STUDY_RECORDS_BUILDER_ON_OLD_MACHINE=DO_NOT_START
NEXT_TESTFLIGHT_BLOCKED_BY=#164 Study Records resolution canary + exact-final-main release-candidate closeout + release decision
```

## Accepted baseline

### #167 — batch vocabulary / parser

Merged at `25e5cd85ea8f436cc66b41e49d6313547b0a6148`.

- normal vocabulary resolution uses the public batch query;
- query POST is read-semantic;
- no artificial fixed 30-item cap;
- bounded parser/input safety remains.

### #168 — aggregate-window scheduler

Merged through PR #172 at `bc03ee03e06bfa23a160e2599bebc9db34635812`.

- no blanket 1.6s read floor;
- `20/10s`, `40/60s`, `2000/5h` enforced;
- `ContinuousClock` elapsed-time semantics;
- actual-dispatch reconciliation and aborted-reservation removal;
- sequential reads/writes, no mutation retry, mandatory post-POST readback preserved.

Final accepted automated evidence: `315 executed / 4 skipped / 0 failures`.

## Physical evidence and failed PR #173

Exact-main physical Preview established:

```text
PREVIEW_COMPLETED=yes
SELF_ADDED_VOCABULARY_RESOLUTION=BLOCKED
REAL_MUTATION_PERFORMED=no
```

PR #173 tested the smallest public exact-GET fallback:

```text
PR=173
HEAD=6c24e1bc6897b4c2d0d8a9964b44fadbe253d8ae
FOCUSED_TESTS=43/0
FULL_SUITE=327 executed / 4 skipped / 0 failures
PHYSICAL_SELF_ADDED_CANARY=BLOCK
REAL_MUTATION_PERFORMED=no
STATUS=CLOSED_UNMERGED
```

The repair was fail-closed but did not solve the real blocker, so it was not merged. Its exact head is already remote-backed on branch `claude/issue-164-self-added-exact-get-fallback`; do not retain the fallback speculatively in main.

## #164 — parked Study-Records route

Fresh first-party evidence frozen in Issue #164 comment `5527731297` establishes an independent public read-only surface:

```text
POST /open/api/v1/study/query_study_records
request: spellings[] (max 1000)
response identity: StudyRecord.voc_id + StudyRecord.voc_spelling
```

The official `memo-api-cli` exposes `study records --spelling ...` and sends those spellings directly to `query_study_records`; it does not first resolve them through the vocabulary API.

Provider constraints:

- Study API is Beta;
- it depends on synced study data / study-plan presence;
- deterministic tests alone cannot establish the real Owner self-added-word result.

Frozen next representation after migration:

```text
normal vocabulary batch hit -> unchanged/final
batch match anomaly -> blocked/final
true vocabulary batch misses -> one bounded Study Records spelling query for the missed set
Study Record bind -> exact normalized voc_spelling + unique safe voc_id only
Study API miss / unsafe / duplicate -> remain blocked
no exact-GET stacking
no guessed id
no private API
no read or mutation concurrency
no real mutation
```

Decisive uncertainty remains:

```text
STUDY_RECORDS_RESOLVES_THIS_REAL_SELF_ADDED_WORD=NOT_YET_PROVEN
```

If this public Study surface also misses on the future physical canary, stop engineering self-added target resolution unless later first-party API capabilities materially change.

Owning evidence:

```text
INITIAL_PHYSICAL_BLOCKER_COMMENT=5527374168
STUDY_API_ADJUDICATION_COMMENT=5527731297
PARKED_OLD_MACHINE_RETURN_BRIDGE_COMMENT=5527775536
MACHINE_MIGRATION_HOLD_COMMENT=5527985154
FAILED_PR=173
```

The pre-migration Owner instruction supersedes execution on the old Mac. The previously prepared Study-Records Builder Prompt is parked, not a migration artifact to execute mechanically later. On the new Mac, re-read live `main`, Owner preferences and `agent-skills`, then regenerate/revalidate the dispatch if #164 is still current.

## Pre-migration local closure gate

Before retiring the old Mac, perform one non-destructive audit of `/Users/david/Documents/GitHub/momo-moreEfficient` for:

- tracked working-tree changes;
- staged changes;
- non-ignored untracked files;
- local commits not reachable from any remote;
- local branches ahead of an existing upstream;
- stashes;
- extra worktrees.

Do not use `reset`, `clean`, destructive checkout, history rewrite, or blind `stash`. Do not push private/secret material merely to make the tree clean. Existing remote-backed branches/commits do not need to be merged merely for migration safety.

The old Mac copy may be considered disposable only after this audit proves there is no project-relevant local-only state that still needs safe remoteization or separate migration.

## Resume sequence on the new Mac

```text
old-Mac local closure audit
-> stop project execution on old Mac
-> establish/verify new Mac workspace and repository identity
-> non-destructively fetch live remote
-> read CHAT_HANDOFF.md + this file + Issue #164 current comments
-> JIT re-resolve Agent family/model/effort
-> resume #164 Study Records candidate only if still current
-> physical read-only self-added canary
-> merge only if proven
-> exact-final-main release-candidate closeout
-> build-number / TestFlight decision
```

`#105` and unrelated backlog remain HOLD while this release blocker is open.

## Stable safety boundaries

- Preview is not write authorization;
- explicit approval before mutation;
- fresh authenticated preflight when stale state could change the write target;
- each changed item gets at most one mutating POST;
- no automatic mutating-POST retry;
- authenticated readback after dispatched mutation;
- uncertain mutation recovery is GET-only;
- UPDATE requires an explicit authenticated-user target;
- no automatic delete/rollback/replay;
- vocabulary-query POST remains read-semantic;
- Study Records fallback, if later implemented, is read-only;
- personal Maimemo Token and private batch material stay device-local and must not enter Git/logs/review artifacts;
- 429 is a stop/rate-limit signal, not permission to replay a mutation.

## Agent-family routing

Agent family is not sticky. Follow the latest Owner-selected family for the active lane unless the Owner announces a switch or a hard current task/tool constraint requires one. Re-resolve model / effort / speed / topology from live `agent-skills` for every formal dispatch.

## Handoff rule

Fresh Chat / new-Mac takeover should read:

```text
CHAT_HANDOFF.md
-> this file
-> Issue #164 body + comments 5527731297 and 5527985154
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.