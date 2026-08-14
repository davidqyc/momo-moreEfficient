# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-15
sourceMainSha=eec177812c715e4b18b19af642cb0e7fefbcde53
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) TestFlight candidate
CURRENT_PRIMARY_ISSUE=#110
CURRENT_UNIQUE_NEXT=EXECUTE_THE_SMALL_OSS_LANDING_SURFACE_SLICE_UNDER_ISSUE_110
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)`, sourced from reviewed app merge `41e993ba002e5671ac7b12d49b07ac8eed49e8d4`, passed the complete internal physical-iPhone gate;
- build `1.0 (3)` is submitted to external TestFlight App Review in group `首批外部测试`; latest recorded status is `正在等待审核`, with 0 external testers;
- the release candidate is frozen while Apple reviews it; no new upload/product-code change is planned unless review feedback or a new P0/P1 correctness issue requires one;
- after Apple approves `1.0 (3)`, the first release-line action is to create a TestFlight Public Link (initial cap 50–100, adjustable) and place the self-serve install path prominently in GitHub README; TestFlight access must not be gated on Stars;
- #99 completed the first full API/capability fact sweep and remains discovery authority rather than an automatic feature backlog;
- #105 records the real-demand reading-capture candidate, but it remains parked while the current release candidate is frozen and OSS landing work is active;
- #106 is the OSS-growth umbrella: genuine GitHub adoption, external engagement/contribution and visible maintainer work are the strategic evidence target; the Owner delegates engineering/community mechanics to the Coordinator;
- #107 shipped the first public Codex-oriented growth asset through PR #108; squash merge `eec177812c715e4b18b19af642cb0e7fefbcde53` is on `main` and #107 is closed;
- the Recipe uses the first-party-convergent `/open/api/v1/study/get_today_items` route, exact forgotten-words request `{"is_finished": true, "limit": 1000}`, fail-closed compatibility for the observed root/wrapped and spelling variants, and exports no `voc_id`;
- Coordinator incremental review on exact head `ce8906b985276c7f94cd1975eeedf5c84f5bc17f` passed; a real-Token canary was judged unnecessary for merge because current first-party executable/reference evidence is sufficient and the public-beta source conflict is explicitly documented;
- #110 is the next bounded OSS-growth execution slice: make the repository itself a credible landing surface before broader promotion or another Recipe.

## Current route — #110 OSS landing surface

Issue #110 is the current primary route.

The accepted scope is small:

1. set an accurate concise repository About/description;
2. add a restrained set of relevant GitHub Topics;
3. tighten README first-screen routing to the iOS companion, public Codex Recipes, and Issue/contribution paths;
4. keep GitHub as the canonical home;
5. do not start Recipe 2/3 or product-feature work inside this Issue.

Execution boundary:

- no iOS product code;
- no Maimemo live operation or real Token;
- no TestFlight/App Store Connect action;
- no badges/bots/dashboards merely to look active;
- no manufactured engagement or Star gate;
- no TestFlight Public Link until Apple approval under #71;
- Discussions only if a coherent landing surface plus the first public Recipe creates a real return loop, not as empty decoration.

## Parallel / parked pointers

```text
#71 release lane = WAITING_FOR_APPLE_REVIEW on build 1.0 (3); 0 external testers; after approval create Public TestFlight Link -> README; Issue stays open until non-Owner real use + evidence in #7
#106 OSS-growth umbrella = ACTIVE_STRATEGY; #107 is shipped; #110 is the current execution slice
#105 reading capture -> safe Maimemo import = ACCEPTED_REAL_DEMAND_CANDIDATE, PARKED while release candidate is frozen and #110 is active
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
- current #110 work is repository packaging/discovery only and must not touch iOS/TestFlight or live Maimemo;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
