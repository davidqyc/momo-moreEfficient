# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-21
sourceMainSha=94e4de0ed11a90dd72ecc2b446de93775dd981b8
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta
CURRENT_PRIMARY_ISSUE=#120
CURRENT_UNIQUE_NEXT=IMPLEMENT_120_APP_INTENT_CAPTURE_REVIEW_THEN_124_SHARE_EXTENSION
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)`, sourced from reviewed app merge `41e993ba002e5671ac7b12d49b07ac8eed49e8d4`, passed the complete internal physical-iPhone gate;
- Apple external TestFlight review for build `1.0 (3)` has passed and the Public Link `https://testflight.apple.com/join/DtVKeTSE` is live with tester limit `100`;
- GitHub README exposes that Public Link as the self-serve install path; #71 stays open until at least one non-Owner user genuinely installs/uses the app and meaningful evidence is recorded;
- #99 completed the first API/capability fact sweep and later demand synthesis: dictionary/lookup is parked after #104 NO-GO unless the official Maimemo contract materially changes, while reading capture and Maimemo × Codex workflows have stronger evidence;
- #105 is now the active Phase-2 reading-capture umbrella;
- #120 is the first implementation slice: App Intent / Shortcut capture → foreground app → explicit editable capture/review state, with zero Maimemo/Token/Preview/write activity in the intent itself;
- #124 is the sibling second slice: iOS Share Extension → non-secret App Group capture inbox → explicit in-app review on next app open; it must not share the Maimemo Token or use unsupported open-main-app hacks;
- #125 is a parallel discovery route for a desktop browser capture extension; no implementation begins until official Maimemo browser-extension auth/redirect/CORS/token-storage and API-contract questions are resolved;
- #106 remains the OSS-growth umbrella; Recipe 1 is shipped and the repository landing surface is live;
- #119 shipped structured GitHub Issue Forms and a focused PR template via PR #123 so external users can create actionable maintenance events without exposing credentials/private data;
- #126 AEO/AI-answer discoverability slice 1 shipped via PR #127: `docs/FAQ.md` plus `README.en.md` provide a bilingual factual, machine-readable project reference without keyword stuffing or unsupported ranking claims.

## Current route — Phase 2 capture while external beta remains live

Primary engineering route:

1. implement #120 in one focused Codex PR; design the in-app captured-text/review state as a small reusable boundary for #124, but do not add a Share Extension/App Group inside #120;
2. Coordinator reviews #120; only after it is accepted/merged, implement #124 as a separate PR that reuses the capture-review state and adds only the share-sheet transport/persistence layer;
3. keep both capture entry paths strictly pre-Preview: captured text may be edited/cancelled, but neither entry mechanism may read the Maimemo Token, call Maimemo, auto-run Preview or authorize a write;
4. after both paths are reviewed and physically validated as needed, make a separate release decision for the next TestFlight build; do not upload merely because development exists.

Parallel discovery/growth routes:

- #125 researches the smallest safe desktop browser-extension architecture against current first-party Maimemo Open Platform/auth/API contracts before any browser product code;
- #71 keeps the existing approved external build `1.0 (3)` and Public Link stable while small real-user seeding/feedback continues;
- #106 keeps Recipe 1/GitHub public and converts genuine setup failures, requests and contributions into normal Issues/PRs; do not manufacture activity;
- #126 may receive only low-cost factual AEO improvements (for example a natural README link or future Owner-controlled HTTPS landing page); do not create doorway pages or cargo-cult `llms.txt` as an assumed ranking signal;
- broad promotion can wait for stronger Phase-2 product utility; small external beta availability remains useful during development.

## Parallel / parked pointers

```text
#120 App Intent capture = CURRENT_PRIMARY_IMPLEMENTATION; one focused PR, no TestFlight upload
#124 Share Extension capture inbox = NEXT_AFTER_120; separate target/App Group, non-secret capture data only
#125 desktop browser capture extension = ACTIVE_DISCOVERY; no code until official auth/API gates resolve
#105 reading capture -> safe Maimemo import = ACTIVE_PHASE2_UMBRELLA
#71 release lane = EXTERNAL_TESTFLIGHT_LIVE on build 1.0 (3); Public Link live (limit 100); keep stable while Phase 2 develops
#106 OSS-growth umbrella = ACTIVE_STRATEGY; Recipe 1 + landing + structured intake shipped
#126 AEO / AI-answer discoverability = SLICE1_SHIPPED; factual follow-up only
#104/#5 dictionary/lookup = PARKED / NO-GO unless official Maimemo dictionary-content contract materially changes
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
- App Intent capture and Share Extension capture are transport/input surfaces only: zero Maimemo request/write before the existing Preview path;
- the Share Extension/App Group must never contain or gain access to the personal Maimemo Token in the accepted first slice;
- do not use unsupported responder-chain/openURL tricks to force a Share Extension to foreground the containing app;
- desktop browser-extension work must not invent auth/redirect/CORS/token-storage behavior before first-party contract evidence exists;
- do not upload a new TestFlight build merely because Phase-2 code exists; use build `1.0 (3)` until a reviewed change and separate release decision justify a new build;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
