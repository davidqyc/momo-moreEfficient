# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-13
sourceMainSha=30196c1653129902312ce74b53fb5ac3e139fef6
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#95
CURRENT_UNIQUE_NEXT=IMPLEMENT_ACCEPTED_LIGHT_UI_POLISH_THEN_OWNER_SMOKE
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
- PR #94 merged: user-visible name `小黑鸟伴侣`, final approved AppIcon, stranger-readable Token onboarding, About/Privacy/Support and public `PRIVACY.md` are on `main`;
- the one Fable 5 visual-polish pass is complete and Owner-accepted as the ~60/100 TestFlight baseline; implementation is frozen in #95.

## Current route — #95 final light UI polish

Implement exactly one small native SwiftUI polish PR from the accepted Fable comparison boards / #95 scope.

Primary visible change: the paste/input editor becomes materially larger and reads as the main working surface.

Also apply the accepted lightweight hierarchy/readability cleanup for Preview, progress, Token sheet, preferences, About and History.

Constraints:

- preserve information architecture, navigation and product behavior;
- no API / Token / write-authority changes;
- no phrase duplicate/conflict behavior changes in #95;
- no design system, custom component library, onboarding framework, dashboard or animation system;
- one PR only;
- after Coordinator review, install the candidate on the physical iPhone for a visual smoke;
- after smoke PASS, stop visual iteration and proceed directly to TestFlight upload under #71.

For TestFlight App Review, do not build a demo subsystem merely for review. If Apple requires credentials to exercise the authenticated workflow, provide a dedicated test credential only through private App Store Connect review information; never put it in Git, source, chat, public documentation, build logs or TestFlight user-facing text.

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
