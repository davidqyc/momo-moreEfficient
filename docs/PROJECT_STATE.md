# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-03
sourceMainSha=9012a3b74f86f7895908c16c29bcd62ba4ce3f79
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

CURRENT_DISPATCH_AUTHORITY=Issue #168 comment 5525021657
CURRENT_AGENT=Claude Sonnet 5 / High / Standard / Single Agent
CURRENT_PROMPT_ARTIFACT=momo_168_Sequential_Read_Window_Speedup_Claude_Prompt_2026-09-03.md
CURRENT_PROMPT_PREPARED=yes
CURRENT_PROMPT_DISPATCHED=unknown_until_owner_or_matching_result_evidence

PREVIOUS_CODEX_DISPATCH_COMMENT=5524832107
PREVIOUS_CODEX_PROMPT_DISPATCHED=no_owner_confirmed
PREVIOUS_CODEX_PROMPT_SUPERSEDED=yes
OLD_PREPARED_RETURN_BRIDGE=5524523317

CURRENT_UNIQUE_NEXT=Owner relays the current Claude #168 Prompt if not already sent; then Coordinator waits for the matching Builder result and ingests/reviews it without duplicate dispatch

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

## Current Builder dispatch

The original long inline #168 Prompt was never dispatched. A fresh Coordinator reviewed it and replaced it. The first replacement incorrectly defaulted to Codex; the Owner corrected the stable project preference to Claude-family. Current dispatch authority is Issue #168 comment `5525021657`.

Current route:

```text
TASK_ID=XHN-168-SEQUENTIAL-READ-WINDOW-SCHEDULER-20260903
TARGET_AGENT=Claude Sonnet 5 / High / Standard / Single Agent
TARGET_CONVERSATION=NEW_CONVERSATION
CONVERSATION_TITLE=【XHN】#168 Sequential Read-Window Speedup
PROMPT_ARTIFACT=momo_168_Sequential_Read_Window_Speedup_Claude_Prompt_2026-09-03.md
PROMPT_PREPARED=yes
EXTERNAL_AGENT_DISPATCHED=unknown
RESULT_RETURNED=no
DUPLICATE_DISPATCH_ALLOWED=no_by_default
```

Do not send the superseded Codex Prompt. Do not treat `PROMPT_PREPARED` as proof of dispatch. Advance execution state only from Owner confirmation or a matching returned result.

## Why this implementation stays small

The project is intentionally lightweight. `AGENTS.md` requires a simplification checkpoint when a small mechanism's implementation contract grows beyond roughly one screen, and task contracts should stay compact unless the risk genuinely requires more.

The #168 implementation is narrow:

```text
remove blanket read sleep
+ add smallest aggregate-window guard
+ deterministic focused tests
+ preserve mutation safety
```

Do not turn it into a generic scheduler/networking framework, broad historical Issue replay, or a long multi-lane governance exercise.

## Stable Builder routing

momo's stable project-specific coding preference is now Claude-family first. Exact Claude model / Effort / Speed are still JIT-resolved through the live agent-skills Claude routing skill.

Do not silently fall back to Codex on a fresh Chat. Codex requires an explicit Owner request or a current task/tool-specific authority with a clear reason to override the project default.

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
-> exact comments 5524418123 and 5525021657
-> live Owner collaboration preferences
-> live fresh-chat preference application policy
-> latest explicit Owner instruction
```

Do not fetch all historical Issue comments just to reconstruct the present state.