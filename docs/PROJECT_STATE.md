# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-12
sourceMainSha=f7647ffae086e6141c6ef50244df01b1acd52fbd
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#71
CURRENT_UNIQUE_NEXT=TESTFLIGHT_PREP_PR_THEN_OWNER_TEST
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE is production-validated;
- phrase CREATE + final 3/4-line usability path are production/device validated;
- iOS companion stores each user's personal API Token device-locally in `WhenUnlockedThisDeviceOnly` Keychain;
- final physical-iPhone smoke passed: neutral account wording, persisted tag preference, mixed 3/4-line Preview, optional-source UI;
- current write safety floor remains Preview → explicit approval → fresh preflight → max-one-POST/no-retry → authenticated readback → GET-only uncertain recovery;
- Maimemo Open Platform support explicitly clarified that a third-party native iOS app may let each user provide their own personal API Token when it stays only in that user's iPhone Keychain and is never uploaded to the developer/server;
- OIDC/PKCE is therefore not required for the first external cohort and remains a future convenience/enhancement route.

## Current route — #71 first small TestFlight cohort

Current user-visible product name: `小黑鸟伴侣`.

Prepare one narrow TestFlight-prep PR before the first invite:

- set only the user-visible iOS display name; keep internal target/module/repository identifiers unchanged;
- make personal-Token onboarding understandable to a stranger and state the device-local storage boundary;
- add a small in-app About / Privacy / Support surface;
- add a public repository privacy policy and update the README first screen to the actual iPhone workflow;
- prepare only the Apple/TestFlight metadata text that is actually needed;
- leave the final AppIcon asset pending until the Owner approves the dedicated visual-design result, then add that asset as a small delta to the same PR if practical;
- no OIDC, analytics, backend, database, marketing site, demo video, account dashboard or broad launch work.

For TestFlight App Review, do not build a new demo subsystem merely for review. If Apple requires credentials to exercise the authenticated workflow, provide a dedicated test credential only through App Store Connect review information; never put it in Git, source, chat, public documentation, build logs or TestFlight user-facing text.

After the PR is merged, build/upload one Owner-tested TestFlight build, invite a deliberately small external cohort, and learn from real use.

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
