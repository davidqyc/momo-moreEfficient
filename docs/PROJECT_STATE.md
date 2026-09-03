# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-03
sourceMainSha=25e5cd85ea8f436cc66b41e49d6313547b0a6148
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta

CURRENT_PRIMARY_ISSUE=#168
CURRENT_ARCHITECTURE=A_SEQUENTIAL_AGGREGATE_WINDOW_SCHEDULER
OWNER_DECISION_COMMENT=5524418123
CURRENT_PROMPT_REVIEW_GATE=Issue #168 comment 5524641284
OLD_PREPARED_RETURN_BRIDGE=5524523317
OLD_PROMPT_DISPATCHED=no_owner_confirmed

CURRENT_UNIQUE_NEXT=fresh Coordinator reviews the prepared #168 Builder dispatch against live Owner preferences + live agent-skills; release only a corrected/validated prompt, then wait for the Builder result

IMPLEMENTATION_HOLD_FOR_OTHER_FEATURES=true
NEXT_TESTFLIGHT_BLOCKED_BY=#168 + exact-final-main physical validation + later release decision
```

## Current engineering baseline

PR #167 is merged on canonical `main` at:

```text
25e5cd85ea8f436cc66b41e49d6313547b0a6148
```

That merge established the batch vocabulary resolver / parser / crash-test foundation required before #168:

- vocabulary lookup uses the public vocabulary-query surface instead of one lookup per item;
- the query POST is explicitly read-semantic and does not consume mutation authority;
- the artificial product-wide 30-item cap is removed while existing byte/field/control-character/duplicate safety bounds remain;
- the first-party vocabulary-query envelope is decoded as `data.voc` / tolerated unwrapped `voc`;
- the recurring Simulator XCTest host traps were test-harness failures, not Release-app crashes.

No real Maimemo network or mutation was used for that Builder lane.

## #168 — current product lane

Goal: remove the project-owned blanket `1.6s` delay from normal Preview/preflight reads without weakening write safety.

Fresh first-party evidence already frozen in #168 establishes:

```text
Maimemo aggregate windows:
20 requests / 10 seconds
40 requests / 60 seconds
2000 requests / 5 hours

provider minimum 1.6s/request:
NOT_DOCUMENTED

public batch interpretation/phrase read route:
NOT_FOUND_IN_CURRENT_FIRST_PARTY_EVIDENCE
```

Owner selected **A** in Issue #168 comment `5524418123`:

```text
reads remain sequential
next read starts immediately after prior response unless a real aggregate window requires waiting
no read concurrency
no mutation concurrency
no private endpoint / batch content-read invention
mutating writes remain conservative and serial
if ordinary 8–15 item Preview becomes materially fast enough, stop; do not chase marginal speed with B
```

This decision is accepted and must not be reopened unless new empirical evidence shows A is still materially too slow.

## Prepared Prompt state — important rollover gate

The old Coordinator prepared a #168 Builder dispatch and wrote Return Bridge `5524523317`, but the Owner explicitly confirmed the Prompt was **not sent**.

Current exact gate is Issue #168 comment `5524641284`:

```text
PROMPT_PREPARED=yes
EXTERNAL_AGENT_DISPATCHED=no_owner_confirmed
AGENT_RUN_COMPLETED=no
RESULT_RETURNED=no
CURRENT_GATE=FRESH_COORDINATOR_PROMPT_REVIEW_BEFORE_RELEASE
```

A fresh Coordinator must not infer a running Builder from the old Return Bridge and must not simply copy the old inline Prompt. It must re-derive the dispatch from current authority, current Owner preferences and live agent-skills.

## Why the old prepared Prompt needs fresh review

The project itself is intentionally lightweight. `AGENTS.md` requires a simplification checkpoint when a small mechanism's implementation contract grows beyond roughly one screen, and task contracts should stay compact unless the risk genuinely requires more.

The #168 implementation is narrow:

```text
remove blanket read sleep
+ add smallest aggregate-window guard
+ deterministic focused tests
+ preserve mutation safety
```

Do not turn it into a generic scheduler/networking framework, broad historical Issue replay, or a long multi-lane governance exercise.

## Release / backlog ordering

Current intended sequence:

```text
#167 merged
-> #168 throughput implementation
-> exact-final-main physical iPhone validation
-> build-number / TestFlight release decision
```

`#164` and `#105` remain open/hold until #168 and final exact-main device gates complete.

Do not start unrelated product lanes while #168 is the release blocker. In particular, #161/#154/#153/#152 and later backlog work remain deferred unless the Owner explicitly changes sequencing.

## Safety boundaries still current

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
- no real Maimemo network/mutation is needed for the #168 Builder implementation;
- TestFlight/release is outside #168 Builder authority.

## Handoff / maintenance rule

This file owns only **current state + current unique next + live boundaries**. Historical milestones, competitive research and backlog rationale remain in their Issues, decision log, CHANGELOG and other durable project docs; do not re-expand this file into an archive.

Fresh Chat takeover should read:

```text
CHAT_HANDOFF.md
-> this file
-> Issue #168 metadata/body
-> exact comments 5524418123 and 5524641284
-> live Owner collaboration preferences
-> latest explicit Owner instruction
```

Do not fetch all historical Issue comments just to reconstruct the present state.
