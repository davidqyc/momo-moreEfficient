# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-03
sourceMainSha=4990060bf193d27e0594a1e672f36b3a6621e975
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
CURRENT_RELEASE_GATE_STATUS=BLOCKED
CURRENT_BLOCKER=the real existing self-added vocabulary item is unresolved by both public vocabulary/query and exact vocabulary GET on physical iPhone
CURRENT_UNIQUE_NEXT=build one smallest batch-first candidate that uses public Study query_study_records only for true vocabulary-batch misses; physically validate the same existing self-added item read-only before merge

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true
NEXT_TESTFLIGHT_BLOCKED_BY=#164 study-records resolution canary + final release-candidate closeout + release decision
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

Exact-main physical Preview first established:

```text
PREVIEW_COMPLETED=yes
SELF_ADDED_VOCABULARY_RESOLUTION=BLOCKED
REAL_MUTATION_PERFORMED=no
```

PR #173 then tested the smallest public exact-GET fallback:

```text
PR=173
HEAD=6c24e1bc6897b4c2d0d8a9964b44fadbe253d8ae
FOCUSED_TESTS=43/0
FULL_SUITE=327 executed / 4 skipped / 0 failures
PHYSICAL_SELF_ADDED_CANARY=BLOCK
REAL_MUTATION_PERFORMED=no
STATUS=CLOSED_UNMERGED
```

The repair was technically fail-closed but did not solve the real blocker, so it was not merged. Do not retain the exact-GET fallback speculatively.

## #164 — current public Study-API route

Fresh first-party evidence frozen in Issue #164 comment `5527731297` establishes an independent public read-only surface:

```text
POST /open/api/v1/study/query_study_records
request: spellings[] (max 1000)
response identity: StudyRecord.voc_id + StudyRecord.voc_spelling
```

The official `memo-api-cli` exposes `study records --spelling ...` and sends those spellings directly to `query_study_records`; it does not first resolve them through the vocabulary API.

Important provider constraints:

- Study API is Beta;
- it depends on synced study data / study-plan presence;
- therefore it is not accepted merely because deterministic tests pass.

Frozen next representation:

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

Decisive uncertainty:

```text
STUDY_RECORDS_RESOLVES_THIS_REAL_SELF_ADDED_WORD=NOT_YET_PROVEN
```

A candidate must pass a physical read-only Preview using the same existing self-added word before merge. If this public Study surface also misses, stop engineering self-added target resolution and record a provider-surface limitation unless later first-party API capabilities materially change.

Owning evidence:

```text
INITIAL_PHYSICAL_BLOCKER_COMMENT=5527374168
FAILED_EXACT_GET_INCREMENT_COMMENT=5527393448
STUDY_API_ADJUDICATION_COMMENT=5527731297
FAILED_PR=173
```

## Release sequence

```text
#167 merged
-> #168 merged/closed
-> physical RC found self-added blocker
-> PR #173 exact-GET candidate failed physical canary / closed unmerged
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
-> Issue #164 body + comments 5527731297 and latest current dispatch receipt
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.
