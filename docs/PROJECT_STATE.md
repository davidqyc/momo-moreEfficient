# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-04
sourceMainSha=7ca843e458aa688282da6adadd2ada60982c3a14
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
CURRENT_PRIMARY_GATE=SELF_ADDED_VOCABULARY_STUDY_RECORDS_RESOLUTION
CURRENT_RELEASE_GATE_STATUS=BLOCKED_ON_PRODUCT_CANARY
CURRENT_BLOCKER=the real existing self-added vocabulary item is unresolved by both public vocabulary/query and exact vocabulary GET; the final bounded public candidate is Study Records by spelling
CURRENT_UNIQUE_NEXT=build one smallest batch-first candidate that uses public Study query_study_records only for true vocabulary-batch misses; physically validate the same existing self-added item read-only before merge

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true
MACHINE_MIGRATION_HOLD=CLEARED
NEW_MAC_WORKSPACE_READY=yes
OLD_MAC_REPO_RETIREMENT_GATE=PASS
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

The repair was fail-closed but did not solve the real blocker, so it was not merged. Its exact head remains remote-backed on branch `claude/issue-164-self-added-exact-get-fallback`; do not retain the fallback speculatively in main.

## #164 — current Study-Records route

First-party evidence frozen in Issue #164 establishes an independent public read-only surface:

```text
POST /open/api/v1/study/query_study_records
request filtering: spellings[] (max 1000)
response identity: StudyRecord.voc_id + StudyRecord.voc_spelling
```

The official `memo-api-cli` exposes `study records --spelling ...` and sends those spellings directly to `query_study_records`; it does not first resolve them through the vocabulary API.

Current provider constraints:

- Study API is Beta;
- it depends on synced study data / study-plan presence;
- deterministic tests alone cannot establish the real Owner self-added-word result;
- official CLI request shape uses explicit `voc_ids`, `spellings`, `as_count`, and `limit`; `as_count=false` is the record-returning mode.

Frozen representation:

```text
normal vocabulary batch hit -> unchanged/final
batch match anomaly -> blocked/final
true vocabulary batch misses -> one bounded Study Records spelling query for the missed set
Study request -> voc_ids=[] + spellings=<misses> + as_count=false + bounded limit
Study Record bind -> exact normalized voc_spelling + unique safe voc_id only
Study API miss / unsafe / duplicate -> remain blocked
no exact-GET stacking
no guessed id
no private API
no read or mutation concurrency
no real mutation
```

Decisive uncertainty:

```text
STUDY_RECORDS_RESOLVES_THIS_REAL_SELF_ADDED_WORD=NOT_YET_PROVEN
```

If this public Study surface also misses on the physical canary, stop engineering self-added target resolution unless later first-party API capabilities materially change.

## Machine migration — closed

Old-Mac closure audit proved no Git-managed local-only WIP requiring migration. One intentionally gitignored private directory was selected for preservation:

```text
PRIVATE_MIGRATION_ITEM=artifacts/private/
EXPECTED_FILE_COUNT=11
OLD_MAC_APPROX_SIZE=68 KB allocation-based
```

New-Mac read-only takeover audit passed:

```text
ACTUAL_HOME=/Users/david
WORKSPACE_ROOT=/Users/david/Documents/GitHub/momo-moreEfficient
REPOSITORY_IDENTITY=davidqyc/momo-moreEfficient
MIGRATED_PRIVATE_DIRECTORY_PRESENT=yes
MIGRATED_PRIVATE_FILE_COUNT=11
MIGRATED_PRIVATE_LOGICAL_BYTES=44083
MIGRATED_PRIVATE_DU_SIZE=68K
PRIVATE_CONTENT_OPENED=no
PRIVATE_CONTENT_PUBLISHED=no
PRIVATE_DIRECTORY_GITIGNORED=yes
TRACKED_UNCOMMITTED=none
STAGED_UNCOMMITTED=none
UNTRACKED_NONIGNORED=none
STASHES=none
BRANCH_AHEAD_EXISTING_UPSTREAM=no
OLD_MAC_REPO_RETIREMENT_GATE=PASS
NEW_MAC_WORKSPACE_READY_FOR_164=yes
```

The migrated checkout is currently the remote-backed closed-PR #173 branch at `6c24e1bc...`; it is 0/0 against its own upstream and carries no local-only WIP. Fresh #164 work must start from live `origin/main` via a new branch, without reset/rebase/salvage.

## Release sequence

```text
#167 merged
-> #168 merged/closed
-> physical RC found self-added blocker
-> PR #173 exact-GET candidate failed physical canary / closed unmerged
-> machine migration closed / new Mac workspace verified
-> #164 Study Records batch-miss candidate   <-- CURRENT
-> exact-candidate physical read-only canary
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
- Study Records fallback, if implemented, is read-only;
- personal Maimemo Token and private batch material stay device-local and must not enter Git/logs/review artifacts;
- 429 is a stop/rate-limit signal, not permission to replay a mutation.

## Agent-family routing

Agent family is not sticky. Follow the latest Owner-selected family for the active lane unless the Owner announces a switch or a hard task/tool constraint requires one. Re-resolve model / effort / speed / topology from live `agent-skills` for every formal dispatch.

## Handoff rule

Fresh Chat takeover should read:

```text
CHAT_HANDOFF.md
-> this file
-> Issue #164 body + latest Study-Records external increment / dispatch receipt
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.