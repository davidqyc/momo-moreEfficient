# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-21
sourceMainSha=bcefe0eb59d6f7c8ef8d75a358ec26b20b071186
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta
CURRENT_PRIMARY_ISSUE=#126
CURRENT_UNIQUE_NEXT=MEASURE_AND_IMPROVE_AI_SEARCH_DISCOVERABILITY_FROM_PUBLIC_JIRIPPLE_ENTITY_SURFACE
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)` passed external review; Public Link `https://testflight.apple.com/join/DtVKeTSE` is live with tester limit `100`;
- #120 is COMPLETE via PR #129 / merge `f749653ef041f1b7ed37b57afca9536740cf8caf`: iOS 26+ App Intent capture enters the explicit editable pre-Preview `CaptureReviewStore` without Token/API/Preview/write activity;
- #124 is COMPLETE via PR #132 / merge `bcefe0eb59d6f7c8ef8d75a358ec26b20b071186`: Share Extension stores one bounded non-secret App Group capture and hands it to the same review boundary before credential restoration; the extension target has no Token/Maimemo/write machinery;
- cross-transport chronological ordering is correct, but Owner expects normal use to compare both capture routes and then primarily keep whichever UX is better; do not add more synchronization complexity without real evidence;
- #125 research memo shipped via PR #130; browser-extension verdict remains `NEEDS-MAIMEMO-CLARIFICATION` before implementation;
- #104/#5 dictionary lookup remains PARKED / NO-GO until Maimemo exposes and approves a concrete built-in dictionary-content contract;
- #106 OSS-growth route, Recipe 1, structured Issue Forms and repository landing surface remain live;
- #126 AEO slice 1 shipped in this repo through `docs/FAQ.md` and `README.en.md`;
- #126 AEO slice 2 now has an Owner-controlled HTTPS entity surface under `www.jiripple.com`: `davidqyc/jiripple-public-site` PR #2 / merge `e56ae640c663fc2047c312e825068ff8497c625c` added `/xiaoheiniao/`, machine-readable `context.md`, `llms.txt`, OAI-SearchBot-aware `robots.txt`, sitemap, canonical metadata/structured facts and a crawlable home-page link. GitHub remains canonical for source/Issues/Recipes/current engineering authority.

## Current route — AI search / answer discoverability

1. Treat #126 as the current strategic route. Optimize for accurate discovery, source selection, citation and answer absorption rather than keyword density.
2. Keep one stable public product/entity URL with direct answers to real questions: identity, official/unofficial status, install path, current capabilities, Token/privacy boundary, Maimemo × Codex workflow, support path and explicitly unshipped capabilities.
3. Maintain machine-consumable paths (`context.md`, `llms.txt`) as retrieval aids, not as claimed ranking hacks. Keep ordinary crawlable HTML, internal links, canonical URLs, robots and sitemap healthy because ChatGPT Search may use both its own crawler and search partners.
4. Benchmark a fixed set of realistic Chinese/English queries repeatedly over time. Separate: discovered/retrieved → cited → substantively used in the answer. Do not infer success from one run.
5. Improve answer usefulness with extractable definitions, concrete facts, comparisons, procedural steps and authoritative external references where they genuinely support a claim. No keyword stuffing, fake backlinks, fake reviews or manufactured community activity.
6. Build third-party authority only through genuine usage, OSS maintenance and external publishing that points back to the stable entity/GitHub sources.

## Release gate — Phase 2 capture

This runs in parallel and does not block AEO work:

1. register/verify App Group `group.com.jiripple.xiaoheiniao.capture` for App IDs `com.jiripple.xiaoheiniao` and `com.jiripple.xiaoheiniao.ShareExtension`, then refresh provisioning as required;
2. perform one pragmatic physical-iPhone comparison: App Intent/Shortcut/Action Button vs Share Extension, focusing on actual capture friction rather than an interoperability matrix;
3. Owner chooses the route that is materially better for normal use; keeping both shipped is not automatically required;
4. run one fresh Claude architecture/product-complexity stage review of the completed #120/#124 milestone before the next TestFlight release decision;
5. only then decide what enters a new TestFlight build; do not upload merely because code exists.

## Parallel routes

- #125 waits for written Maimemo clarification on browser-extension OAuth callback/ClientId, direct API/CORS behavior, token storage/offline authorization, and any approved copyright dictionary-content API;
- the Maimemo API watch continues independently and should reopen affected decisions only on material first-party changes;
- #71 keeps public build `1.0 (3)` stable while the next release is evaluated;
- #106 continues genuine OSS/community evidence; broad promotion may scale after the product story and capture UX are stronger.

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST and no automatic POST retry;
- dispatched writes require authenticated readback; uncertain outcomes use GET-only recovery;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- personal API Tokens and private learning data must not enter Git, logs, review artifacts or public examples;
- App Intent and Share Extension capture remain pre-Preview input surfaces only;
- Share Extension/App Group must never contain or gain access to the personal Maimemo Token;
- do not use responder-chain/openURL hacks to force the Share Extension to open the containing app;
- browser-extension work remains blocked on first-party contract evidence;
- public AEO pages must never claim unreleased source-main features are already present in TestFlight build `1.0 (3)`;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
