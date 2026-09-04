# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-04
sourceMainSha=f97c8c175e47fa4dc29b0f8b9c73bfd01b1211d8
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
CURRENT_PRIMARY_GATE=PR174_POST_SYNC_PHYSICAL_CANARY
CURRENT_RELEASE_GATE_STATUS=BLOCKED_ON_ONE_BOUNDED_POST_SYNC_RETRY
CURRENT_BLOCKER=exact PR #174 physically completes Preview and ordinary rows remain healthy, but the real self-added target still blocks with `未读取到可用词条目标`; the Owner then added that same target in Maimemo and an immediate same-minute retry still blocked, while official Maimemo documentation says learning-data propagation can be delayed
CURRENT_UNIQUE_NEXT=perform exactly one post-sync read-only retry on exact PR #174 with no code changes; if the same target still blocks after normal Maimemo sync/init, stop this capability lane and close PR #174 unmerged unless later first-party API capability materially changes

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true
MACHINE_MIGRATION_HOLD=CLEARED
NEW_MAC_WORKSPACE_READY=yes
OLD_MAC_REPO_RETIREMENT_GATE=PASS
NO_FOURTH_RESOLVER_SURFACE=true
NEXT_TESTFLIGHT_BLOCKED_BY=#164 final capability adjudication + exact-final-main release-candidate closeout + release decision
```

## Accepted baseline

### #167 — batch vocabulary / parser

Merged at `25e5cd85ea8f436cc66b41e49d6313547b0a6148`.

- normal vocabulary resolution uses the public batch query;
- query POST is read-semantic;
- no artificial fixed 30-item cap;
- interpretation and phrase formats accept unambiguous batches with or without blank lines;
- bounded parser/input safety remains.

### #168 — aggregate-window scheduler

Merged through PR #172 at `bc03ee03e06bfa23a160e2599bebc9db34635812`.

- no blanket 1.6s read floor;
- `20/10s`, `40/60s`, `2000/5h` enforced;
- `ContinuousClock` elapsed-time semantics;
- actual-dispatch reconciliation and aborted-reservation removal;
- sequential reads/writes, no mutation retry, mandatory post-POST readback preserved.

Final accepted automated evidence: `315 executed / 4 skipped / 0 failures`.

## #164 resolver evidence

### Exact-main / PR #173

Exact-main physical Preview established:

```text
PREVIEW_COMPLETED=yes
SELF_ADDED_VOCABULARY_RESOLUTION=BLOCKED
REAL_MUTATION_PERFORMED=no
```

PR #173 tested a batch-miss exact-vocabulary-GET fallback:

```text
PR=173
HEAD=6c24e1bc6897b4c2d0d8a9964b44fadbe253d8ae
FULL_SUITE=327 executed / 4 skipped / 0 failures
PHYSICAL_SELF_ADDED_CANARY=BLOCK
STATUS=CLOSED_UNMERGED
```

The fallback was fail-closed but did not solve the real target and was not merged.

### PR #174 — Study Records candidate

Current Draft candidate:

```text
PR=174
HEAD=f9b90833324f0fa9dc07d9d565ff94c70e773332
BASE=f97c8c175e47fa4dc29b0f8b9c73bfd01b1211d8
BRANCH=claude/issue-164-study-records-fallback
FOCUSED_TESTS=46/0
AFFECTED_TESTS=98/0
FULL_SUITE=330/0
STATUS=DRAFT_UNMERGED
```

Frozen representation:

```text
normal vocabulary batch hit -> unchanged/final
batch match anomaly -> blocked/final
true vocabulary batch misses -> one bounded Study Records query per <=1000 miss chunk
Study Record bind -> exact normalized voc_spelling + unique safe voc_id only
Study API miss / unsafe / duplicate -> remain blocked
no exact-GET stacking
no guessed id
no private API
no read or mutation concurrency
```

Frozen request body for each miss chunk:

```text
voc_ids=[]
spellings=<deduplicated true misses>
as_count=false
limit=1000
```

The Study POST is read-semantic and uses the existing shared scheduler.

## PR #174 physical evidence — current

On the exact PR #174 head, normal-mode physical iPhone Preview completed without a global error:

```text
PREVIEW_COMPLETED=yes
ORDINARY_ROWS=resolved / unchanged (`一致`)
SELF_ADDED_TARGET_RESULT=BLOCKED
SELF_ADDED_BLOCK_REASON=未读取到可用词条目标
GLOBAL_PREVIEW_FAILURE=no
REAL_MAIMEMO_MUTATION_BY_XIAOHEINIAO=no
IPHONE_MIRRORING_USED=no
```

The Owner then searched the same target in the Maimemo app, added it to the Owner's current selected/learning set, and immediately repeated Preview. The target still blocked with the same per-item reason while ordinary rows remained healthy.

This immediate post-add miss is not yet treated as permanent provider incapability because a fresh first-party Maimemo FAQ states that learning-data synchronization can have propagation delay and depends on `学习数据自动同步`; it advises checking again later when data has not updated.

Important scope of that evidence:

- it proves Maimemo learning-data propagation is not guaranteed immediate;
- it does **not** prove OpenAPI `query_study_records` will eventually expose the target;
- therefore only one bounded post-sync retry is justified;
- no code change, new fallback, private endpoint, ID guessing, or repeated canary loop is justified.

Owning Issue evidence:

```text
PR174_IMMEDIATE_PHYSICAL_COMMENT=5537194917
STUDY_SYNC_DELAY_EXTERNAL_INCREMENT_COMMENT=5537199729
```

## Final post-sync decision rule

```text
normal Maimemo app foreground/init/sync settling
-> exact PR #174 read-only Preview retry

if target resolves:
  physical canary PASS
  -> Coordinator exact-diff adjudication
  -> merge only if candidate remains acceptable

if target still shows `未读取到可用词条目标`:
  PHYSICAL_SELF_ADDED_CANARY=BLOCK_POST_SYNC
  -> stop self-added target-resolution engineering
  -> close PR #174 unmerged
  -> no fourth resolver surface
```

If automatic-sync state itself is proven disabled, that is a provider-data precondition rather than evidence for a new resolver. Resolve only the minimum sync precondition necessary for the single bounded retry.

## Machine migration — closed

New-Mac takeover passed:

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

`artifacts/private/` remains local/private and must never be pushed merely for migration or review.

## Release sequence

```text
#167 merged
-> #168 merged/closed
-> exact-main physical RC exposed self-added blocker
-> PR #173 exact-GET candidate failed / closed unmerged
-> machine migration closed
-> PR #174 Study Records candidate built/tested
-> immediate physical canary blocked per-item
-> one bounded post-sync physical retry   <-- CURRENT
-> PASS: adjudicate/merge candidate
   OR
   BLOCK: close candidate and stop resolver lane
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
- vocabulary-query and Study query POSTs are read-semantic;
- personal Maimemo Token and private batch material stay device-local and must not enter Git/logs/review artifacts;
- 429 is a stop/rate-limit signal, not permission to replay a mutation.

## Agent-family routing

Agent family is not sticky. Follow the latest Owner-selected family for the active lane unless the Owner announces a switch or a hard task/tool constraint requires another family. Re-resolve model / effort / speed / topology from live `agent-skills` for every formal dispatch.

## Handoff rule

Fresh Chat takeover should read:

```text
CHAT_HANDOFF.md
-> this file
-> Issue #164 body + comments 5537194917 and 5537199729
-> PR #174 current head/status
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.
