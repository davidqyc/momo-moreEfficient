# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-15
sourceMainSha=9bf164e445186d844c1b12dd73980f1e4146b8c4
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) TestFlight candidate
CURRENT_PRIMARY_ISSUE=#110
CURRENT_UNIQUE_NEXT=OWNER_SET_EXACT_REPOSITORY_DESCRIPTION_AND_TOPICS_THEN_COORDINATOR_READBACK_CLOSE_110
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
- #110 README landing slice passed Coordinator review and shipped through PR #112 as squash merge `9bf164e445186d844c1b12dd73980f1e4146b8c4`; the first screen now routes strangers to the iPhone companion, Recipe 1, GitHub Issues and contribution guidance before legacy CLI material;
- #110 remains open only because repository About/description and Topics have not yet been set; the Builder's local `gh` authentication was invalid, so no metadata write was attempted or claimed.

## Current route — #110 repository metadata closeout

The README portion of Issue #110 is complete and merged. Do not repeat or redesign it.

The only remaining acceptance work is to set and then read back these exact repository metadata values:

Description:

`Independent Maimemo companion for safe vocabulary imports + reproducible Maimemo × Codex learning recipes.`

Topics, exactly these four:

- `maimemo`
- `openai-codex`
- `vocabulary-learning`
- `ios`

After authenticated readback proves those values, close #110. Do not start Recipe 2/3 merely because #110 closes; first re-check #71 and observe genuine usage/feedback under #106.

Execution boundary:

- no README rework unless a concrete correctness defect is found;
- no iOS product code;
- no Maimemo live operation or real Token;
- no TestFlight/App Store Connect action;
- no badges/bots/dashboards merely to look active;
- no manufactured engagement or Star gate;
- no TestFlight Public Link until Apple approval under #71;
- Discussions only if a real return loop justifies them, not as empty decoration.

## Parallel / parked pointers

```text
#71 release lane = WAITING_FOR_APPLE_REVIEW on build 1.0 (3); 0 external testers; after approval create Public TestFlight Link -> README; Issue stays open until non-Owner real use + evidence in #7
#106 OSS-growth umbrella = ACTIVE_STRATEGY; #107 is shipped; #110 awaits metadata-only closeout
#105 reading capture -> safe Maimemo import = ACCEPTED_REAL_DEMAND_CANDIDATE, PARKED while release candidate is frozen and #110 is open
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
- current #110 remaining work is GitHub repository metadata only and must not touch iOS/TestFlight or live Maimemo;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
