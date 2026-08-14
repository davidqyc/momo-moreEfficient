# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-15
sourceMainSha=3fa9d2b855824980f7b385c24d20b3adc1247e85
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) TestFlight candidate
CURRENT_PRIMARY_ISSUE=#107
CURRENT_UNIQUE_NEXT=AFTER_NEW_CHAT_TAKEOVER_SEND_THE_UNSENT_PR108_B1_B4_CORRECTION_PROMPT_TO_THE_EXISTING_CODEX_SESSION
OPEN_PRODUCT_PR=none
ACTIVE_WIP=PR #108 / codex/issue-107-forgotten-words-recipe / BLOCKED
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)`, sourced from reviewed app merge `41e993ba002e5671ac7b12d49b07ac8eed49e8d4`, passed the complete internal physical-iPhone gate;
- build `1.0 (3)` is submitted to external TestFlight App Review in group `首批外部测试`; latest recorded status is `正在等待审核`, with 0 external testers;
- the release candidate is frozen while Apple reviews it; no new upload/product-code change is planned unless review feedback or a new P0/P1 correctness issue requires one;
- after Apple approves `1.0 (3)`, the first release-line action is to create a TestFlight Public Link (initial cap 50–100, adjustable) and place the self-serve install path prominently in GitHub README; TestFlight access must not be gated on Stars;
- #99 completed the first full API/capability fact sweep and unlocked evidence-driven Phase-2 work;
- #105 records the real-demand reading-capture candidate, but it is not the current active implementation;
- #106 is the OSS-growth umbrella: genuine GitHub adoption, external engagement/contribution and visible maintainer work are the strategic evidence target; the Owner delegates engineering/community mechanics to the Coordinator;
- #107 is the first public Codex-oriented growth asset; Draft PR #108 exists but is not yet accepted;
- PR #108 exact head `6e66b80d96cf41bbaefd511bd67b8ab087ac82ec` was fresh-context re-reviewed and remains BLOCKED on B1–B4. The latest authoritative Coordinator comment is `5297702970`;
- the two commits after the reviewed app release source that advanced `main` to `3fa9d2b...` were an accidental placeholder add/remove with no net product-tree change; they are not a new app build.

## Current route — #107 / PR #108

PR #108 is the current active WIP and stays Draft/unmerged.

The accepted correction scope is narrow:

1. use the first-party-convergent Study route `/open/api/v1/study/get_today_items` rather than the current `/memo/study/...` route, and document the first-party source conflict;
2. normalize only first-party-observed response variants: root or safe `data.today_items`, and `voc_spelling` or `spelling`, while failing closed on contradictory/error envelopes;
3. request the documented forgotten-words scene `{"is_finished": true, "limit": 1000}` and then filter exact `FORGET`;
4. remove unused `voc_id` from the exported Recipe artifact and related public contract/examples;
5. include only the cheap documentation cleanups named in the latest Coordinator review and focused regressions for those exact variants.

Builder boundary for the next correction round:

- use the existing branch/PR #108;
- no real Token and no live Maimemo canary in the Builder round;
- no generic Study client/framework;
- no iOS/TestFlight changes;
- regenerate the requested review ZIP and stop for Coordinator review.

## Parallel / parked pointers

```text
#71 release lane = WAITING_FOR_APPLE_REVIEW on build 1.0 (3); 0 external testers; after approval create Public TestFlight Link -> README; Issue stays open until non-Owner real use + evidence in #7
#106 OSS-growth umbrella = ACTIVE_STRATEGY; #107 is its first execution asset
#105 reading capture -> safe Maimemo import = ACCEPTED_REAL_DEMAND_CANDIDATE, PARKED while #107/PR #108 is active and release candidate is frozen
#99 capability/field/demand sweep = DISCOVERY_AUTHORITY; use its findings as evidence, not as an automatic feature backlog
#7 open-source / external-use evidence = record genuine events only; never manufacture Stars, users, Issues or PRs
```

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST and no automatic POST retry;
- dispatched writes require authenticated readback; uncertain outcomes use GET-only recovery;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- personal API Tokens and private learning data must not enter Git, logs, review artifacts or public examples;
- the current Recipe lane is semantically read-only; HTTP POST used for a documented Study read does not authorize mutation endpoints;
- PR #108 is blocked and must not be merged by chat handoff;
- TestFlight/App Store actions remain frozen during this handoff;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
