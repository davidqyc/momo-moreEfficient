# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-12
sourceMainSha=51ec2be7259a14e6756ae27dfeb6762d983c33d3
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#71
CURRENT_UNIQUE_NEXT=PREPARE_FIRST_SMALL_TESTFLIGHT_COHORT
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE is production-validated;
- phrase CREATE + final 3/4-line usability path are production/device validated;
- iOS companion stores personal API Token device-locally in `WhenUnlockedThisDeviceOnly` Keychain;
- final physical-iPhone smoke passed: neutral account wording, persisted tag preference, mixed 3/4-line Preview, optional-source UI;
- current write safety floor remains Preview → explicit approval → fresh preflight → max-one-POST/no-retry → authenticated readback → GET-only uncertain recovery;
- on 2026-08-12, Maimemo Open Platform support explicitly clarified that a third-party native iOS app may let each user provide their own personal API Token when it stays only in that user's iPhone Keychain and is never uploaded to the developer/server: `第一种用法是完全没问题的，开放平台目前主要是更方便进行授权，后续一些功能可能会只在开放平台上提供`.

## Current route — #71 first small TestFlight cohort

OIDC is no longer a prerequisite.

Use the existing local personal-Token flow for the first external cohort. Before the first invite, do only what is actually needed for a safe low-friction TestFlight:

- make Token onboarding understandable to a stranger and state the local-only storage boundary;
- use an independent non-official app identity suitable for TestFlight;
- provide only the privacy/support/repository explanation actually required;
- produce one Owner-tested TestFlight build;
- invite a deliberately small cohort and learn from real use;
- record genuine external-use evidence in #7.

Do not add a backend, database, analytics stack or paid infrastructure solely for distribution.

## Deferred routes

```text
#72 OIDC/PKCE = OPTIONAL FUTURE ENHANCEMENT; reopen only for real auth friction or Open-Platform-only features
phrase automatic replacement / phrase UPDATE = DEFER
nickname/avatar account identity = DEFER with OIDC
study/profile dashboard = DEFER
broad public launch / demo / social campaign = DEFER until small-cohort evidence
#5 desktop quick lookup = DEFER unless explicitly requested
#7 open-source evidence = passive ledger for real events only
```

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST; never auto-retry POST;
- dispatched POST gets immediate authenticated readback; uncertain outcome gets GET-only recovery;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- personal API Token remains device-local and inaccessible to the developer/server;
- source/origin equality is hard when supplied; no-source semantics follow D-019 / #87;
- unknown/malformed server schema fails closed;
- no new feature is justified merely because an Issue already exists.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
