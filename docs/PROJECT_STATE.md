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
CURRENT_UNIQUE_NEXT=WAIT_FOR_APPLE_PROCESSING_THEN_CONFIGURE_SMALL_TESTFLIGHT_COHORT
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
- organization release identity is now frozen and merged through #97 / PR #98: Team `W26LH686PD`, Bundle ID `com.jiripple.xiaoheiniao`, version `1.0 (1)`;
- organization App ID and App Store Connect iOS app record `小黑鸟伴侣` exist;
- CLI upload attempts were blocked pre-dispatch by Xcode account-session handling, with zero binary dispatch and zero retries;
- Xcode Organizer GUI upload then succeeded on 2026-08-13: `MomoMoreEfficient 1.0 (1) uploaded`; Organizer status shows `Uploaded to Apple`;
- canonical public project home is GitHub (`davidqyc/momo-moreEfficient`); TestFlight/App Store are distribution channels, not project authority. Project-specific release identity is recorded in `docs/RELEASE_IDENTITY.md`.

## Current route — #71 first small TestFlight cohort

Do not upload another build unless a new code/build-number change is intentionally authorized.

Next:

1. Wait for Apple to finish processing build `1.0 (1)` and confirm it appears under the TestFlight tab.
2. If Apple requests export-compliance or other human judgment, stop at that single field and answer deliberately; do not invent values.
3. Configure only the minimum TestFlight information required for the first small cohort.
4. Internal testing may be used for a quick Owner/account-holder sanity check, but the actual goal is a deliberately small external cohort.
5. For external testing, create one small external group, add build `1.0 (1)`, complete required Test Information / TestFlight App Review information, and invite only a few known testers by email at first; no public link/broad launch yet.
6. Record genuine installs/use/feedback in #7.

Keep this lightweight:

- no Fastlane/Xcode Cloud/App Store Connect API framework solely for the first cohort;
- do not create/expose new Apple credentials in Git/docs/chat;
- no additional product/visual work before the first cohort unless Apple processing reveals a concrete binary defect;
- no public App Store submission in this phase;
- #99 Phase-2 discovery remains parked until the uploaded build is processed and the release path is proven end-to-end enough to start testing.

## OSS / distribution boundary

- GitHub repo = canonical source/project/issues/releases home and primary OSS evidence;
- TestFlight/App Store = install/distribution channel and supporting real-usage evidence;
- organization ownership of the iOS binary does not replace the GitHub maintainer/project identity;
- marketing URL may point to the GitHub repo; support/privacy may use zero-cost public GitHub pages/files when Apple requirements are satisfied.

## Deferred routes

```text
#99 Phase 2 capability/field/demand sweep = NEXT PRODUCT DISCOVERY AFTER TESTFLIGHT PROCESSING / RELEASE PATH PROOF
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
