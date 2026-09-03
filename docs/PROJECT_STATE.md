# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-03
sourceMainSha=c9c91b3e6191c8d3f6c36595121d75f81328c90b
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
CURRENT_PRIMARY_GATE=SELF_ADDED_VOCABULARY_TARGET_RESOLUTION_REPAIR
CURRENT_RELEASE_GATE_STATUS=BLOCKED
CURRENT_BLOCKER=an existing real self-added vocabulary item still blocks during authenticated physical-iPhone Preview target resolution on exact current main
CURRENT_UNIQUE_NEXT=build the smallest batch-first resolver candidate that uses public exact GET only for batch-missed spellings; physically validate the existing self-added item read-only before merge

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true
NEXT_TESTFLIGHT_BLOCKED_BY=#164 self-added target-resolution repair + exact-candidate physical read-only canary + final release-candidate closeout + release decision
```

## Current engineering baseline

### #167 — batch vocabulary / parser foundation

Merged on canonical `main` at:

```text
25e5cd85ea8f436cc66b41e49d6313547b0a6148
```

It established:

- public batch vocabulary query instead of one vocabulary GET per normal item;
- the vocabulary-query POST is read-semantic, not mutation authority;
- no artificial fixed total 30-item cap;
- bounded parser/input safety remains;
- first-party batch-query envelope decoding is accepted as `data.voc` / tolerated unwrapped `voc`.

### #168 — sequential aggregate-window scheduler

Issue #168 is closed through PR #172.

Accepted Builder head:

```text
e7bf2d65e244b9168be6aa01ba656207a23f2be0
```

Canonical merge:

```text
bc03ee03e06bfa23a160e2599bebc9db34635812
```

The merged implementation:

- removes the historical blanket `1.6s` read pacing floor;
- enforces `20/10s`, `40/60s`, `2000/5h` aggregate windows;
- uses `ContinuousClock` elapsed-time semantics;
- reconciles reservations to actual dispatch and removes aborted reservations;
- preserves sequential reads/writes, post-POST readback, no mutation retry and deterministic 429/non-2xx handling.

Final accepted automated evidence:

```text
RequestWindowSchedulerTests=12/12 PASS
focused affected groups=144 executed / 0 failures
full MomoMoreEfficientTests=315 executed / 4 skipped / 0 failures
```

## Physical iPhone evidence — current blocker

Exact-main physical preparation was completed on:

```text
c9c91b3e6191c8d3f6c36595121d75f81328c90b
```

The app built, installed and launched on the physical iPhone with the existing signing configuration and no rehearsal mode.

Owner then ran a real authenticated Preview using existing private material and an already-existing self-added vocabulary item. No real mutation was performed.

Observed result:

```text
PREVIEW_COMPLETED=yes
SELF_ADDED_VOCABULARY_RESOLUTION=BLOCKED
REAL_MUTATION_PERFORMED=no
```

This blocks the self-added-vocabulary acceptance. It does **not** invalidate #168's scheduler.

## #164 — narrow resolver repair authority

Current first-party provider evidence now frozen in Issue #164 establishes two public read-only vocabulary-resolution surfaces:

```text
GET  /open/api/v1/vocabulary?spelling=...
POST /open/api/v1/vocabulary/query
```

The current official Maimemo CLI also keeps these semantics separate:

```text
single spelling -> exact GET
multiple spellings -> batch query
```

Current momo `VocabularyTargetResolver` uses only the batch query and treats a batch miss as `notFound`; the current resolver tests explicitly assert there is no per-item GET fallback.

The real-device result proves that a batch-query miss cannot by itself be treated as proof that the existing self-added vocabulary is unavailable to every public resolution surface.

Current repair representation:

```text
batch query remains the fast path
-> only batch-missed normalized spellings attempt the existing public exact GET
-> exact GET must still return a safe identifier and exact normalized spelling
-> batch match anomaly remains fail-closed; do not override contradictory/unsafe identity
-> global auth/rate/server/transport/cancellation failures remain global
-> no private API
-> no guessed ID
-> no read or mutation concurrency
-> no real mutation
```

Important uncertainty:

```text
EXACT_GET_RESOLVES_THIS_REAL_SELF_ADDED_WORD=NOT_YET_PROVEN
```

Therefore the candidate is not mergeable merely because unit tests pass. It requires a read-only physical canary using the already-existing self-added item. If exact GET also fails, stop and report provider limitation rather than expanding the resolver or guessing identity.

Owning evidence comments:

```text
PHYSICAL_BLOCKER_COMMENT=5527374168
EXTERNAL_INCREMENT_COMMENT=5527393448
```

## Release sequence

Current sequence:

```text
#167 merged
-> #168 merged/closed
-> physical RC found self-added target-resolution blocker
-> #164 narrow batch-miss exact-GET fallback candidate   <-- CURRENT
-> exact-candidate physical read-only self-added canary
-> Coordinator acceptance / merge if proven
-> exact-final-main release-candidate closeout
-> build-number / TestFlight release decision
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
- any exact vocabulary GET fallback is also read-only;
- personal Maimemo Token and private batch material stay device-local and must not enter Git/logs/review artifacts;
- 429 is a stop/rate-limit signal, not permission to replay a mutation.

## Agent-family routing

Agent family is not a sticky project preference. Follow the latest Owner-selected family for the active lane unless the Owner announces a switch or a hard task/tool constraint requires one. Re-resolve model / effort / speed / topology from live `agent-skills` for every formal dispatch.

## Handoff / maintenance rule

This file owns only current state, current unique next and live boundaries. Detailed historical evidence remains in Issues/PRs. Fresh Chat takeover should read:

```text
CHAT_HANDOFF.md
-> this file
-> Issue #164 body + exact current blocker/increment comments named here
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue comment threads merely to reconstruct current truth.
