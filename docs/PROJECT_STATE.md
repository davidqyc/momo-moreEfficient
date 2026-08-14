# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-15
sourceMainSha=1f65786f5aa8e268df356b9e32649a394a092c34
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) TestFlight candidate
CURRENT_PRIMARY_ISSUE=#71
CURRENT_UNIQUE_NEXT=WAIT_FOR_APPLE_EXTERNAL_TESTFLIGHT_REVIEW_AND_OBSERVE_GENUINE_RECIPE1_FEEDBACK
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)`, sourced from reviewed app merge `41e993ba002e5671ac7b12d49b07ac8eed49e8d4`, passed the complete internal physical-iPhone gate;
- build `1.0 (3)` is submitted to external TestFlight App Review in group `首批外部测试`; latest recorded status remains `正在等待审核`, with no later GitHub-recorded Apple approval/rejection/review feedback;
- the release candidate stays frozen while Apple reviews it; no new upload/product-code change is planned unless review feedback or a new P0/P1 correctness issue requires one;
- after Apple approves `1.0 (3)`, the first release-line action is to create a TestFlight Public Link (initial cap 50–100, adjustable) and place the self-serve install path prominently in GitHub README; TestFlight access must not be gated on Stars;
- #99 completed the first full API/capability fact sweep and remains discovery authority rather than an automatic feature backlog;
- #105 records the real-demand reading-capture candidate, but it remains parked while the current release candidate is frozen and real-use evidence has higher information value than speculative implementation;
- #106 is the OSS-growth umbrella: genuine GitHub adoption, external engagement/contribution and visible maintainer work are the strategic evidence target; the Owner delegates engineering/community mechanics to the Coordinator;
- #107 shipped the first public Codex-oriented growth asset through PR #108; Recipe 1 is public on `main` and uses the first-party-convergent Study read route with fail-closed compatibility and no exported `voc_id`;
- #110 is complete and closed: README landing work shipped through PR #112 as squash merge `9bf164e445186d844c1b12dd73980f1e4146b8c4`, and GitHub repository metadata was read back with the exact accepted description plus exactly four Topics (`maimemo`, `openai-codex`, `vocabulary-learning`, `ios`).

## Current route — external wait + real-use observation

There is no active engineering WIP.

Primary release lane:

1. wait for Apple external TestFlight review on the already-submitted build `1.0 (3)`;
2. if Apple approves, create the external TestFlight Public Link and add it prominently to README before inviting broader self-serve installs;
3. if Apple rejects or requests changes, treat that concrete feedback as the next release blocker before any unrelated product work.

Parallel OSS-growth observation under #106:

- keep Recipe 1 and the improved repository landing surface public and stable;
- observe genuine Stars/Forks, non-Owner Issues, setup failures, workflow requests, external PRs/contributions and maintainer follow-through;
- do not manufacture activity and do not start Recipe 2/3 merely to create more surface area;
- only promote the next real-demand asset when external evidence or a clearly superior information gain justifies it.

## Parallel / parked pointers

```text
#71 release lane = WAITING_FOR_APPLE_REVIEW on build 1.0 (3); after approval create Public TestFlight Link -> README; Issue stays open until non-Owner real use + evidence in #7
#106 OSS-growth umbrella = ACTIVE_STRATEGY; Recipe 1 + landing surface are shipped; current mode is OBSERVE_GENUINE_USAGE
#110 OSS landing surface = CLOSED / COMPLETE
#105 reading capture -> safe Maimemo import = ACCEPTED_REAL_DEMAND_CANDIDATE, PARKED
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
- the shipped Recipe is semantically read-only; HTTP POST used for a documented Study read does not authorize mutation endpoints;
- no new TestFlight upload or App Store action while build `1.0 (3)` remains under review;
- no new Recipe or product implementation is authorized merely because #110 closed;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
