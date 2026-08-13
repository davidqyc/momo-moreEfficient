# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-13
sourceMainSha=98b1338dc1b4654cbb248f569f9db86c84a19206
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#71
CURRENT_UNIQUE_NEXT=FIX_FIRST_RUN_PASTE_THEN_UPLOAD_BUILD_2_FOR_EXTERNAL_TESTFLIGHT
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE is production-validated;
- phrase CREATE + final 3/4-line usability path are production/device validated;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain;
- current write safety floor remains Preview → explicit approval → fresh preflight → max-one-POST/no-retry → authenticated readback → GET-only uncertain recovery;
- Open Platform support explicitly allowed the device-local personal-Token route for third-party native iOS distribution;
- PR #94 delivered user-visible name `小黑鸟伴侣`, approved AppIcon, stranger-readable Token onboarding, About/Privacy/Support and public `PRIVACY.md`;
- #95 / PR #96 completed the single ~60/100 UI polish and passed physical-iPhone smoke;
- organization release identity is frozen and merged through #97 / PR #98: Team `W26LH686PD`, Bundle ID `com.jiripple.xiaoheiniao`, version `1.0 (1)`;
- organization App ID and App Store Connect iOS app record `小黑鸟伴侣` exist;
- CLI upload attempts were blocked pre-dispatch by Xcode account-session handling, with zero binary dispatch and zero retries; Xcode Organizer GUI upload then succeeded;
- build `1.0 (1)` processed in TestFlight, export compliance was resolved as exempt/system-only encryption, an internal group was created, and the Owner installed the real TestFlight build on iPhone;
- real TestFlight smoke proved the core workflow: the Owner successfully created 2 real interpretations;
- one first-run usability defect was found only on the real TestFlight interaction path: credential entry currently relies on the bare SecureField/system paste UI and needs an explicit in-app Chinese paste affordance before external invites;
- canonical public project home is GitHub (`davidqyc/momo-moreEfficient`); TestFlight/App Store are distribution channels, not project authority. Project-specific release identity is recorded in `docs/RELEASE_IDENTITY.md`.

## Current route — #71 first small TestFlight cohort

Before external TestFlight review, make exactly one tiny onboarding/release-plumbing fix:

1. Add an explicit user-initiated in-app Chinese paste affordance next to the existing credential SecureField. Pasting fills the existing draft only; it must not auto-connect, auto-save, log, inspect in background, or change TokenStore/Keychain semantics.
2. Set `ITSAppUsesNonExemptEncryption = NO` / generated Info.plist equivalent so the already-resolved system-only encryption exemption does not require the same questionnaire for each new build.
3. Treat this as the only intended pre-external code change. No broad UI redesign or product-feature work.
4. After review/merge, increment build number once and upload `1.0 (2)` through the proven Organizer/App Store Connect path.
5. Install `1.0 (2)` through internal TestFlight and perform a short real-device smoke including copy-from-another-app → in-app paste → connect, plus one ordinary Preview. Do not require a real write solely for this smoke.
6. Use `1.0 (2)` for the first external TestFlight group/review; invite only a few known testers by email, no public link.
7. Record genuine external installs/use/feedback in #7.

Interaction-validation rule learned from `1.0 (1)`: OS-owned interactions such as keyboard, clipboard/paste, share sheets and permission prompts require an actual device gesture-chain smoke when they are essential to onboarding; static Design boards/screenshots alone are not sufficient.

Keep this lightweight:

- no Fastlane/Xcode Cloud/App Store Connect API framework solely for the first cohort;
- do not create/expose new Apple credentials in Git/docs/chat;
- no additional product/visual work before the first external cohort unless a concrete binary/onboarding defect is found;
- no public App Store submission in this phase;
- #99 Phase-2 discovery remains parked until the first external-cohort route is proven.

## OSS / distribution boundary

- GitHub repo = canonical source/project/issues/releases home and primary OSS evidence;
- TestFlight/App Store = install/distribution channel and supporting real-usage evidence;
- organization ownership of the iOS binary does not replace the GitHub maintainer/project identity;
- marketing URL may point to the GitHub repo; support/privacy may use zero-cost public GitHub pages/files when Apple requirements are satisfied.

## Deferred routes

```text
#99 Phase 2 capability/field/demand sweep = NEXT PRODUCT DISCOVERY AFTER FIRST EXTERNAL TESTFLIGHT ROUTE PROOF
phrase duplicate/conflict UX = FUTURE: align closer to interpretation UX; allow Preview-time removal of redundant incoming candidates from the pending batch; no automatic/server DELETE without separate design/authorization
#72 OIDC/PKCE = OPTIONAL FUTURE ENHANCEMENT; reopen only for real auth friction or Open-Platform-only features
phrase automatic replacement / phrase UPDATE = DEFER
nickname/avatar account identity = DEFER with OIDC
study/profile dashboard = DEFER
broad public launch / demo / social campaign = DEFER until small-cohort evidence
#5 word lookup = re-sequence only after #99 discovery synthesis
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
