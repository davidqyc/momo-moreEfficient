# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-03
sourceMainSha=bf0c914191d4ed7d3bfc5b1ee764d8538c5f63b3
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
CURRENT_UNIQUE_NEXT=complete Migration Assistant transfer, then on the new Mac verify the migrated private receipts directory before retiring the old Mac repo copy; after that re-establish live workspace truth and resume #164 only if still current

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

## Pre-migration local closure result

Old-Mac non-destructive audit completed successfully for Git-managed state:

```text
TRACKED_UNCOMMITTED=none
STAGED_UNCOMMITTED=none
UNTRACKED_NONIGNORED=none
BRANCHES_AHEAD_EXISTING_UPSTREAM=none
STASHES=none
LOCAL_ONLY_GIT_STATE_REQUIRING_MIGRATION=none
```

Legacy local commits not present under current `origin/*` refs were verified as pre-squash source history for already-merged PRs; stale `/private/tmp` worktree registrations contain no live local-only content.

One non-Git private directory remains intentionally local-only:

```text
PRIVATE_MIGRATION_ITEM=artifacts/private/
PRIVATE_MIGRATION_ITEM_COUNT=11 files
PRIVATE_MIGRATION_ITEM_SIZE_APPROX=68 KB
PRIVATE_MIGRATION_CLASS=SENSITIVE_OR_PRIVATE_DO_NOT_PUBLISH
```

It contains historical real-run Maimemo execution receipts plus one TestFlight export-options plist. It is intentionally gitignored and must never be pushed merely for migration.

Owner decision:

```text
PRIVATE_MIGRATION_DECISION=PRESERVE
MIGRATION_METHOD=Apple Migration Assistant
OLD_MAC_REPO_RETIREMENT_ALLOWED_BEFORE_NEW_MAC_VERIFY=no
```

Apple Migration Assistant is expected to carry user-account files/folders when the corresponding user data is selected, but project retirement does not rely on expectation alone.

### New-Mac preservation verification gate

Before erasing/retiring the old Mac repository copy, verify on the migrated new Mac:

```text
/Users/<migrated-user>/Documents/GitHub/momo-moreEfficient/artifacts/private/
```

Acceptance:

```text
DIRECTORY_PRESENT=yes
EXPECTED_FILE_COUNT=11
APPROX_TOTAL_SIZE≈68 KB
PRIVATE_CONTENT_NOT_OPENED_OR_PUBLISHED=yes
```

If the path migrated under a different home-directory name, verify the equivalent repository-relative path `artifacts/private/` inside the migrated `momo-moreEfficient` workspace.

Only after that verification may the old Mac repo copy be considered disposable.

## Migration hold / owning evidence

```text
INITIAL_PHYSICAL_BLOCKER_COMMENT=5527374168
STUDY_API_ADJUDICATION_COMMENT=5527731297
PARKED_OLD_MACHINE_RETURN_BRIDGE_COMMENT=5527775536
MACHINE_MIGRATION_HOLD_COMMENT=5527985154
LOCAL_CLOSURE_AUDIT_COMMENT=5528400497
FAILED_PR=173
```

The pre-migration Owner instruction supersedes execution on the old Mac. The previously prepared Study-Records Builder Prompt is parked, not a migration artifact to execute mechanically later. On the new Mac, re-read live `main`, Owner preferences and `agent-skills`, then regenerate/revalidate the dispatch if #164 is still current.

## Resume sequence on the new Mac

```text
Migration Assistant transfer
-> verify migrated artifacts/private/ (11 files, ~68 KB)
-> only then permit old-Mac repo retirement/erase
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
-> Issue #164 body + comments 5527731297, 5527985154, 5528400497
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.