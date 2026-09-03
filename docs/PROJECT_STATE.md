# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-03
sourceMainSha=bc03ee03e06bfa23a160e2599bebc9db34635812
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

CURRENT_PRIMARY_GATE=EXACT_FINAL_MAIN_PHYSICAL_IPHONE_VALIDATION
CURRENT_UNIQUE_NEXT=validate the exact current main build on the physical iPhone for the merged #167 + #168 capture/Preview path; if accepted, make the build-number / TestFlight release decision

IMPLEMENTATION_HOLD_FOR_OTHER_FEATURES=true
NEXT_TESTFLIGHT_BLOCKED_BY=exact-final-main physical validation + later release decision
```

## Current engineering baseline

The capture/Preview foundation required for the next release is now merged on canonical `main`.

### #167 — batch vocabulary / parser / crash-test foundation

Merged at:

```text
25e5cd85ea8f436cc66b41e49d6313547b0a6148
```

It established:

- vocabulary lookup uses the public vocabulary-query surface instead of one lookup per item;
- the query POST is explicitly read-semantic and does not consume mutation authority;
- the artificial product-wide 30-item cap is removed while existing byte/field/control-character/duplicate safety bounds remain;
- the first-party vocabulary-query envelope is decoded as `data.voc` / tolerated unwrapped `voc`;
- recurring Simulator XCTest host traps were identified as test-harness failures, not Release-app crashes.

### #168 — sequential aggregate-window read scheduler

Issue #168 is closed completed through PR #172. Exact accepted Builder head:

```text
e7bf2d65e244b9168be6aa01ba656207a23f2be0
```

Canonical merge:

```text
bc03ee03e06bfa23a160e2599bebc9db34635812
```

Owner architecture A remains the accepted representation:

```text
reads remain sequential
next request starts immediately unless a real provider aggregate window requires waiting
no read concurrency
no mutation concurrency
no private/batch content-read invention
write safety unchanged
```

The merged implementation:

- removes the blanket project-owned `1.6s` pacing floor;
- enforces the documented aggregate windows `20/10s`, `40/60s`, `2000/5h` with a small in-memory sliding-window scheduler;
- uses `ContinuousClock` elapsed-time semantics rather than civil/system time;
- reconciles reservations to actual dispatch time and removes aborted/non-dispatched reservations;
- preserves mandatory post-POST readback under cancellation;
- keeps 429/non-2xx handling deterministic and does not add an automatic retry engine.

Final Builder evidence at the accepted head:

```text
RequestWindowSchedulerTests=12/12 PASS
focused affected groups=144 executed / 0 failures
full MomoMoreEfficientTests=315 executed / 4 skipped / 0 failures
bounded foreground run=no hang
real Maimemo network/mutation=NO
```

No additional fresh independent Reviewer is required for #168 under the lightweight project review rule; Coordinator exact-diff review and targeted external timing-semantics checks are complete.

## Current release gate

Current sequence is now:

```text
#167 merged
-> #168 merged/closed
-> exact-final-main physical iPhone validation   <-- CURRENT
-> build-number / TestFlight release decision
```

The physical validation should be narrow and product-facing. It is not another architecture round or a reason to build a GUI automation harness.

Validate the exact current `main` product build, with emphasis on:

- ordinary 8–15 item Preview no longer feeling like a tens-of-seconds artificial wait;
- Preview content/target correctness remains intact;
- cancellation/background behavior does not silently corrupt Preview or write safety;
- no unexpected user-visible regression in the capture -> Preview flow.

Do not perform real mutations merely to validate pacing unless a later explicit validation contract requires them. Existing write safety remains authoritative.

## Backlog ordering

`#164` and `#105` remain open/hold until the exact-final-main physical gate is accepted and the subsequent release decision is made.

Do not start unrelated backlog while this release gate is open. In particular, #161/#154/#153/#152 and later feature work remain deferred unless the Owner explicitly changes sequencing.

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
- personal Maimemo Token stays device-local and must not enter Git/logs/review artifacts;
- 429 is a stop/rate-limit signal, not permission to replay a mutation.

## Agent-family routing

Do not keep a sticky Claude- or Codex-first project default.

For the active lane, Agent-family selection follows current Owner/tool continuity plus live JIT routing. The latest explicit Owner tool switch outranks generic defaults; once the family is resolved, exact model / effort / speed / topology are selected from live `agent-skills` for that round.

## Handoff / maintenance rule

This file owns only **current state + current unique next + live boundaries**. Historical milestones and detailed prompt/Return-Bridge history remain in Issues, PRs and other durable authorities; do not re-expand this file into a chat archive.

Fresh Chat takeover should read:

```text
CHAT_HANDOFF.md
-> this file
-> exact current gate object(s) named here
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue comment threads merely to reconstruct current truth.
