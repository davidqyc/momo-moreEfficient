# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-21
sourceMainSha=4655538841e104ca48da659dee6fc6de1e04dd75
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta
CURRENT_PRIMARY_ISSUE=#124
CURRENT_UNIQUE_NEXT=IMPLEMENT_124_SHARE_EXTENSION_REUSING_SHIPPED_CAPTURE_REVIEW_BOUNDARY
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)` passed external review; Public Link `https://testflight.apple.com/join/DtVKeTSE` is live with tester limit `100`;
- #120 is COMPLETE via PR #129 / merge `f749653ef041f1b7ed37b57afca9536740cf8caf`: on iOS 26+, App Intent deferred capture installs exact text into an explicit editable pre-Preview `CaptureReviewStore`; the intent path performs zero Token read, credential validation, Maimemo request, Preview or write; the app itself still supports iOS 18+;
- #124 is now the next implementation slice: iOS Share Extension → non-secret App Group capture inbox → the same in-app capture-review boundary on next app foreground/open;
- #125 research memo shipped via PR #130 / merge `4655538841e104ca48da659dee6fc6de1e04dd75`; verdict is `NEEDS-MAIMEMO-CLARIFICATION` before any public browser-extension implementation. Exact support questions live in `docs/phase2-browser-extension-feasibility.md`;
- #104/#5 dictionary lookup remains PARKED / NO-GO until Maimemo exposes and approves a concrete built-in dictionary-content contract;
- #106 OSS-growth route, Recipe 1, structured Issue Forms and repository landing surface remain live;
- #126 AEO slice 1 is shipped through `docs/FAQ.md` and `README.en.md`; future work remains factual/crawlable rather than keyword stuffing.

## Current route — Phase 2 capture

1. implement #124 as one focused Codex PR, reusing the shipped `CaptureReviewStore` rather than creating a second review/authorization state machine;
2. keep the Share Extension strictly transport-only: no Token access, no Maimemo API, no Preview, no write, no unsupported attempt to foreground the containing app;
3. after #124 passes Coordinator review, perform one combined physical-iPhone capture smoke covering the iOS 26 App Intent/Shortcut/Action Button route and the Share Extension route;
4. after #120 + #124 form a stable Phase-2 capture milestone, run a fresh Claude architecture/product-complexity review before the next TestFlight release decision;
5. only then decide whether to upload a new TestFlight build; do not upload merely because code exists.

Parallel routes:

- #125 waits for written Maimemo clarification on extension OAuth callback/ClientId, direct API/CORS behavior, token storage/offline authorization, and any approved copyright dictionary-content API;
- the Maimemo API watch continues independently and should reopen affected decisions only on material first-party changes;
- #71 keeps build `1.0 (3)` and the current Public Link stable while Phase 2 develops;
- broad promotion can wait for stronger Phase-2 utility; small real-user beta feedback remains useful.

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST and no automatic POST retry;
- dispatched writes require authenticated readback; uncertain outcomes use GET-only recovery;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- personal API Tokens and private learning data must not enter Git, logs, review artifacts or public examples;
- App Intent and Share Extension capture are pre-Preview input surfaces only;
- Share Extension/App Group must never contain or gain access to the personal Maimemo Token;
- do not use responder-chain/openURL hacks to force the Share Extension to open the containing app;
- browser-extension work remains blocked on first-party contract evidence; do not invent auth/redirect/CORS/token-storage behavior;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
