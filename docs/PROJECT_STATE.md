# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-04
sourceMainSha=87c5b2c2b027d057bb92919cdf4b6a988697bdb5
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
CURRENT_PRIMARY_GATE=EXACT_FINAL_MAIN_RELEASE_CANDIDATE_CLOSEOUT
CURRENT_RELEASE_GATE_STATUS=READY_FOR_EXACT_FINAL_MAIN_RC
CURRENT_BLOCKER=none in the resolver lane; the real self-added target remains unresolvable through the tested first-party public identity surfaces and is now an accepted provider capability/data-visibility limit
CURRENT_UNIQUE_NEXT=perform the exact-current-main release-candidate closeout with no further resolver engineering; use provider-native physical-device automation wherever proportionate, then make the build-number/TestFlight decision

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true
MACHINE_MIGRATION_HOLD=CLEARED
NEW_MAC_WORKSPACE_READY=yes
OLD_MAC_REPO_RETIREMENT_GATE=PASS
NO_FOURTH_RESOLVER_SURFACE=true
SELF_ADDED_UNRESOLVABLE_POLICY=FAIL_CLOSED_WITH_未读取到可用词条目标
NEXT_TESTFLIGHT_BLOCKED_BY=exact-final-main release-candidate closeout + release decision
```

## Accepted shipping baseline

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

## #164 resolver adjudication — capability lane closed

### Exact main / PR #173

Physical exact-main Preview established:

```text
PHYSICAL_MAIN_SHA=c9c91b3e6191c8d3f6c36595121d75f81328c90b
PREVIEW_COMPLETED=yes
SELF_ADDED_VOCABULARY_RESOLUTION=BLOCKED
REAL_MUTATION_PERFORMED=no
```

PR #173 tested batch-miss exact vocabulary GET:

```text
PR=173
HEAD=6c24e1bc6897b4c2d0d8a9964b44fadbe253d8ae
FULL_SUITE=327 executed / 4 skipped / 0 failures
PHYSICAL_SELF_ADDED_CANARY=BLOCK
STATUS=CLOSED_UNMERGED
```

The fallback was safe but did not resolve the real item.

### PR #174 — Study Records candidate

```text
PR=174
HEAD=f9b90833324f0fa9dc07d9d565ff94c70e773332
BASE=f97c8c175e47fa4dc29b0f8b9c73bfd01b1211d8
FOCUSED_TESTS=46/0
AFFECTED_TESTS=98/0
FULL_SUITE=330/0
STATUS=CLOSED_UNMERGED
```

Candidate representation was batch-first and queried public Study Records only for true vocabulary-batch misses, binding only a unique safe exact-spelling `voc_id`.

Immediate physical canary on the exact PR head:

```text
PREVIEW_COMPLETED=yes
ORDINARY_ROWS=resolved / unchanged (`一致`)
SELF_ADDED_TARGET_RESULT=BLOCKED
SELF_ADDED_BLOCK_REASON=未读取到可用词条目标
GLOBAL_PREVIEW_FAILURE=no
REAL_MAIMEMO_MUTATION_BY_XIAOHEINIAO=no
```

The Owner then added the same item inside Maimemo. Because first-party Maimemo documentation allows learning-data propagation delay, one bounded post-sync retry was authorized.

Final bounded post-sync retry:

```text
MAIMEMO_FOREGROUND_SETTLE=~7.5 minutes
EXACT_PR174_APP_REACTIVATED_WITHOUT_REINSTALL=yes
PHYSICAL_SELF_ADDED_CANARY=BLOCK_POST_SYNC
SELF_ADDED_TARGET_RESULT=blocked
VISIBLE_REASON=未读取到可用词条目标
REAL_MAIMEMO_MUTATION_PERFORMED=no
IPHONE_MIRRORING_USED=no
```

Owning evidence:

```text
PR174_IMMEDIATE_PHYSICAL_COMMENT=5537194917
STUDY_SYNC_DELAY_EXTERNAL_INCREMENT_COMMENT=5537199729
FINAL_RESOLVER_ADJUDICATION_COMMENT=5538213629
PR174_PHYSICAL_COMMENT=5538210122
```

### Final resolver conclusion

The tested first-party public identity surfaces are exhausted for this real item:

```text
POST /open/api/v1/vocabulary/query          -> miss / no safe target
GET  /open/api/v1/vocabulary?spelling=...   -> no safe target
POST /open/api/v1/study/query_study_records -> still no safe target after bounded sync settling
```

Therefore:

```text
SELF_ADDED_TARGET_RESOLUTION_ENGINEERING=STOPPED
PR_173=CLOSED_UNMERGED
PR_174=CLOSED_UNMERGED
FOURTH_RESOLVER_SURFACE=FORBIDDEN
PRIVATE_API=FORBIDDEN
GUESSED_ID=FORBIDDEN
CURRENT_PRODUCT_BEHAVIOR=fail closed for items with no safe public target
REOPEN_CONDITION=later first-party API capability materially changes
```

This is a provider capability/data-visibility limit, not an unresolved local resolver bug.

## Exact-final-main RC equivalence evidence

The prior physical exact-main Preview was run on `c9c91b3e6191c8d3f6c36595121d75f81328c90b` after #168 merged.

A live GitHub compare from that physical-main SHA through `87c5b2c2b027d057bb92919cdf4b6a988697bdb5` shows:

```text
COMMITS_AHEAD=9
CHANGED_FILES=docs/PROJECT_STATE.md only
IOS_PRODUCT_CODE_CHANGED=no
TEST_CODE_CHANGED=no
XCODE_PROJECT_CHANGED=no
```

Thus all intervening merged changes before this state update were governance-only. This evidence may reduce redundant Owner smoke in the final RC, but it does not authorize skipping any still-load-bearing physical release check.

## Machine migration — closed

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
-> exact-main physical Preview exposed self-added blocker
-> PR #173 exact-GET candidate failed / closed unmerged
-> PR #174 Study Records candidate passed tests but failed immediate physical canary
-> one bounded post-sync retry also BLOCKED
-> self-added resolver capability lane closed
-> exact-final-main release-candidate closeout   <-- CURRENT
-> build-number / TestFlight decision
```

`#105` and unrelated backlog remain HOLD until the final release closeout is complete.

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
- vocabulary-query POST is read-semantic;
- personal Maimemo Token and private batch material stay device-local and must not enter Git/logs/review artifacts;
- 429 is a stop/rate-limit signal, not permission to replay a mutation.

## Agent-family routing

Agent family is not sticky. Follow the latest Owner-selected family for the active lane unless the Owner announces a switch or a hard current task/tool constraint requires another family. Re-resolve model / effort / speed / topology from live `agent-skills` for every formal dispatch.

## Handoff rule

Fresh Chat takeover should read:

```text
CHAT_HANDOFF.md
-> this file
-> Issue #164 body + latest final resolver adjudication comment 5538213629
-> PR #174 closed-unmerged state
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.
