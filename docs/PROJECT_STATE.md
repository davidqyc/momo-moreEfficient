# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-12
sourceMainSha=7ea6b0082babafae349437aa0b3d985b588eea85
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#71
CURRENT_UNIQUE_NEXT=ONE_LIGHT_UI_POLISH_THEN_TESTFLIGHT_UPLOAD
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
- OIDC/PKCE is therefore not required for the first external cohort and remains a future convenience/enhancement route;
- PR #94 merged at `7ea6b0082babafae349437aa0b3d985b588eea85`: user-visible name `小黑鸟伴侣`, final approved AppIcon, stranger-readable Token onboarding, About/Privacy/Support and public `PRIVACY.md` are now on `main`.

## Current route — #71 first small TestFlight cohort

Before TestFlight upload, perform exactly one short visual-polish pass over the current iPhone interface using Fable 5 / Claude Design as a design reviewer.

Target quality is intentionally modest: bring the current functional UI to a clean, coherent ~60/100 visual baseline suitable for a first small external cohort.

Constraints:

- preserve current information architecture and product behavior;
- prefer spacing, hierarchy, grouping, typography, control emphasis and small native SwiftUI adjustments;
- no redesign system, custom component library, animation system, illustration program, onboarding framework or navigation rewrite;
- no API / Token / write-authority changes;
- one small implementation PR only after the design recommendation is accepted;
- after Owner smoke on-device, upload the resulting build to TestFlight and invite a deliberately small external cohort.

For TestFlight App Review, do not build a new demo subsystem merely for review. If Apple requires credentials to exercise the authenticated workflow, provide a dedicated test credential only through private App Store Connect review information; never put it in Git, source, chat, public documentation, build logs or TestFlight user-facing text.

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
