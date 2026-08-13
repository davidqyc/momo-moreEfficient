# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-13
sourceMainSha=1c9f27da658c15d5ac50eaf06522115e3b2374db
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#71
CURRENT_UNIQUE_NEXT=UPLOAD_ONE_OWNER_TESTED_TESTFLIGHT_BUILD
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE is production-validated;
- phrase CREATE + final 3/4-line usability path are production/device validated;
- iOS companion stores each user's personal API Token device-locally in `WhenUnlockedThisDeviceOnly` Keychain;
- current write safety floor remains Preview → explicit approval → fresh preflight → max-one-POST/no-retry → authenticated readback → GET-only uncertain recovery;
- Maimemo Open Platform support explicitly clarified that a third-party native iOS app may let each user provide their own personal API Token when it stays only in that user's iPhone Keychain and is never uploaded to the developer/server;
- OIDC/PKCE is therefore not required for the first external cohort and remains a future convenience/enhancement route;
- PR #94 merged: user-visible name `小黑鸟伴侣`, final approved AppIcon, stranger-readable Token onboarding, About/Privacy/Support and public `PRIVACY.md` are on `main`;
- the one Fable 5 visual-polish pass is implemented and closed in #95 / PR #96;
- exact #96 candidate passed physical-iPhone smoke on iPhone 17 Pro Max, including AppIcon/display name/main editor/bottom action/Preferences/About/History/Token sheet; DEBUG rehearsal supplement confirmed interpretation and phrase Preview layouts with zero real Maimemo request/write;
- PR #96 squash-merged to `main` at `1c9f27da658c15d5ac50eaf06522115e3b2374db`.

## Current route — #71 first small TestFlight cohort

Upload exactly one Owner-tested build from current `main` to App Store Connect / TestFlight using the existing Apple Developer signing/account setup.

Keep this lightweight:

- no release automation framework;
- no Fastlane/Xcode Cloud/App Store Connect API integration solely for this cohort;
- use the existing local Xcode account/signing path;
- first attempt archive/validation/upload mechanically;
- if App Store Connect lacks a matching app record, required agreement, role, export-compliance answer or other human-only metadata, stop and report the single concrete blocker instead of inventing values;
- do not create or expose new Apple credentials in Git/docs/chat;
- do not upload as `TestFlight Internal Only` because the route requires a later external cohort;
- after Apple processes the build, provide the minimum TestFlight information and create the smallest required internal/external groups only when needed;
- external testing remains deliberately small; broad/public-link launch is deferred.

For TestFlight App Review, do not build a demo subsystem merely for review. If Apple requires authenticated access, provide a dedicated test credential only through private App Store Connect review information; never put it in Git, source, chat, public documentation, build logs or TestFlight user-facing text.

## Deferred routes

```text
phrase duplicate/conflict UX = FUTURE: align closer to interpretation UX; allow Preview-time removal of redundant incoming candidates from the pending batch; no automatic/server DELETE without separate design/authorization
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
