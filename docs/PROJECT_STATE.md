# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-21
sourceMainSha=e17d0dd8228bc0058ff73d0ff582d1a74aaf9807
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) TestFlight candidate
CURRENT_PRIMARY_ISSUE=#71
CURRENT_UNIQUE_NEXT=SEED_FIRST_REAL_EXTERNAL_USERS_AND_CAPTURE_GENUINE_FEEDBACK
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)`, sourced from reviewed app merge `41e993ba002e5671ac7b12d49b07ac8eed49e8d4`, passed the complete internal physical-iPhone gate;
- Apple external TestFlight review for build `1.0 (3)` has passed; Owner-provided App Store Connect evidence on 2026-08-21 shows build 3 as `正在测试` in external group `首批外部测试`;
- a TestFlight Public Link is live for that group/build: `https://testflight.apple.com/join/DtVKeTSE`, with tester limit `100`;
- the GitHub README first screen now exposes that Public Link as the self-serve install path;
- no new binary or product-code change is required for this approval/distribution milestone;
- #99 completed the first full API/capability fact sweep and remains discovery authority rather than an automatic feature backlog;
- #105 records the real-demand reading-capture candidate, but it remains parked until real external-use evidence justifies product expansion;
- #106 is the OSS-growth umbrella: genuine GitHub adoption, external engagement/contribution and visible maintainer work are the strategic evidence target;
- #107 shipped Recipe 1 as the first public Codex-oriented growth asset;
- #110 is complete and closed: repository landing surface, exact description and four Topics are live.

## Current route — first real external users

There is no active engineering WIP.

Primary release lane under #71:

1. keep the existing approved build `1.0 (3)` and Public Link stable; do not upload a new build without concrete feedback or a new P0/P1 correctness issue;
2. seed the first real non-Owner users through normal external channels, using GitHub as the canonical project/support home and the Public Link as the self-serve install path;
3. collect genuine installs/use, TestFlight feedback, crashes and reproducible setup/product issues;
4. convert meaningful problems or requests into normal GitHub maintenance events and record qualifying evidence in #7;
5. keep #71 open until at least one non-Owner user genuinely installs and uses the app and resulting evidence is recorded.

Parallel OSS-growth route under #106:

- Recipe 1 and the GitHub landing surface remain canonical and stable;
- external promotion should send interested Maimemo/Codex users back to GitHub rather than hosting a separate authoritative copy;
- convert genuine setup failures, workflow requests and improvement suggestions into normal GitHub Issues/PR maintenance loops;
- do not manufacture activity and do not start Recipe 2/3 merely to create more surface area.

## Parallel / parked pointers

```text
#71 release lane = EXTERNAL_TESTFLIGHT_LIVE on build 1.0 (3); Public Link live (limit 100); next first real non-Owner users + feedback/evidence
#106 OSS-growth umbrella = ACTIVE_STRATEGY; Recipe 1 + landing surface shipped; actively seed real users through external channels and capture genuine maintenance events
#110 OSS landing surface = CLOSED / COMPLETE
#105 reading capture -> safe Maimemo import = ACCEPTED_REAL_DEMAND_CANDIDATE, PARKED pending higher-value real-use evidence
#99 capability/field/demand sweep = DISCOVERY_AUTHORITY; evidence source, not automatic backlog
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
- do not upload a new TestFlight build merely because external distribution is live; use the already-approved build `1.0 (3)` until concrete feedback requires a new build;
- TestFlight access must not be gated on Stars or other engagement;
- no new Recipe or product implementation is authorized merely by the Public Link milestone;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
