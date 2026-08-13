# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-13
sourceMainSha=5dd4c12d42e01bce4fb738b14f623e331554f0f2
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#97
CURRENT_UNIQUE_NEXT=ALIGN_XCODE_RELEASE_IDENTITY_THEN_UPLOAD_TESTFLIGHT
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
- the first TestFlight archive attempt succeeded technically but upload failed because it used a non-App-Store Team identity;
- App Store Connect access is confirmed under organization `Awaiting Aesthetic Living Arts (Shenyang) Co., Ltd.` with Team ID `W26LH686PD`;
- historical Bundle ID `com.davidqyc.momoMoreEfficient` is already owned by an earlier non-release signing path and is not available to the organization Team;
- organization App ID `XiaoHeiNiaoCompanion` with explicit Bundle ID `com.jiripple.xiaoheiniao` is now registered;
- App Store Connect iOS app record `小黑鸟伴侣` exists for version 1.0 under the organization Team;
- canonical public project home is GitHub (`davidqyc/momo-moreEfficient`); TestFlight/App Store are distribution channels, not project authority. Project-specific release identity is recorded in `docs/RELEASE_IDENTITY.md`.

## Current route — #97 then #71

First complete one narrow configuration PR under #97:

- app target Bundle ID → `com.jiripple.xiaoheiniao`;
- signed device/archive Team → organization `W26LH686PD`;
- no target/module/repository rename;
- no capability expansion;
- no product/API/Token/write/UI changes;
- verify Debug/Release effective build settings, tests, device signing and archive.

After #97 Coordinator review/merge, resume #71 and upload exactly one Owner-tested build through the normal App Store Connect/TestFlight path.

Keep release work lightweight:

- no Fastlane/Xcode Cloud/App Store Connect API framework solely for the first cohort;
- do not create/expose new Apple credentials in Git/docs/chat;
- do not use `TestFlight Internal Only` because the route requires later external testing;
- if Apple requests human-only agreement/export-compliance/review metadata, stop at the single concrete blocker rather than inventing answers;
- external testing remains deliberately small; public-link/broad launch is deferred.

## OSS / distribution boundary

- GitHub repo = canonical source/project/issues/releases home and primary OSS evidence;
- TestFlight/App Store = install/distribution channel and supporting real-usage evidence;
- organization ownership of the iOS binary does not replace the GitHub maintainer/project identity;
- marketing URL may point to the GitHub repo; support/privacy may use zero-cost public GitHub pages/files when Apple requirements are satisfied.

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
