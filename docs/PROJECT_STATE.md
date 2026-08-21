# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-22
sourceMainSha=25e07e55fdc6791de9179a8b8d68aab61f5470bf
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta
CURRENT_PRIMARY_ISSUE=#126
CURRENT_UNIQUE_NEXT=RESTORE_PUBLIC_XIAOHEINIAO_PAGE_THEN_MEASURE_AI_SEARCH_INDEXING
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)` passed external review; Public Link `https://testflight.apple.com/join/DtVKeTSE` is live with tester limit `100`;
- #120 is COMPLETE via PR #129: iOS 26+ Shortcut/App Intent capture reaches an editable pre-Preview state without Token/API/Preview/write activity;
- #124 is COMPLETE via PR #132: Share Extension uses one bounded non-secret App Group inbox and reaches the same pre-Preview review boundary without Token/Maimemo/write machinery in the extension;
- Owner expects normal use to compare Shortcut vs Share and then mainly keep whichever UX is better; do not add more cross-entry synchronization complexity without real evidence;
- #125 browser-extension research is `NEEDS-MAIMEMO-CLARIFICATION` before implementation;
- #104/#5 built-in dictionary lookup remains PARKED / NO-GO until Maimemo exposes a concrete supported content contract;
- #126 AEO foundations exist in GitHub (`README`, `README.en`, FAQ, fixed benchmark) and in `davidqyc/jiripple-public-site` (`/xiaoheiniao/`, `context.md`, `llms.txt`, robots, sitemap, canonical/structured facts);
- Owner browser validation on 2026-08-22 showed `https://www.jiripple.com/xiaoheiniao/` returning HTTP 404 even though the files exist on public-site `main`; therefore the public entity surface is not yet considered deployed/usable.

## Current route — AI search / answer discoverability

1. P0: restore the actual public deployment of `https://www.jiripple.com/xiaoheiniao/`. Do not treat repository presence as deployment success.
2. After the page returns normally, verify `/xiaoheiniao/`, `/xiaoheiniao/context.md`, `/llms.txt`, `/robots.txt`, and `/sitemap.xml` from an independent client before measuring indexing.
3. Then run the fixed Chinese/English benchmark repeatedly. Separate discovery/retrieval → citation/source selection → answer absorption → factual accuracy.
4. Keep one stable entity page with direct answers to real user questions. Do not generate doorway pages or keep changing copy while waiting for crawl/index signals.
5. Improve high-ROI entity metadata and genuine external authority only when benchmark evidence shows a gap. No keyword stuffing, fake backlinks/reviews, or manufactured community activity.
6. Public copy follows `docs/PUBLIC_COPY_STYLE.md`: user language first, high-frequency functions first, and unreleased capabilities labeled by stage before explanation.

## Release gate — reading capture

This runs in parallel and does not block AEO work:

1. register/verify App Group `group.com.jiripple.xiaoheiniao.capture` for the app and Share Extension, then refresh provisioning as required;
2. physically compare Shortcut vs Share on iPhone, focusing on actual daily friction rather than an interoperability matrix;
3. choose the route that is materially better for normal use; both do not need equal long-term prominence;
4. before a TestFlight build ships capture, perform the copy checkpoint in `docs/release-copy-checkpoint.md`: `捕获检查` / `capture review` is temporary wording and must be renamed consistently across UI + README + FAQ + public site after the route decision;
5. run one fresh Claude architecture/product-complexity review before the next TestFlight release decision;
6. only then decide what enters a new TestFlight build.

## Parallel routes

- #125 waits for written Maimemo clarification on browser-extension OAuth callback/ClientId, direct API/CORS behavior, token storage/offline authorization, and any approved copyright dictionary-content API;
- the Maimemo API watch continues independently and should reopen decisions only on material first-party changes;
- #71 keeps public build `1.0 (3)` stable while the next release is evaluated;
- #106 continues genuine OSS/community evidence; broad promotion may scale after the product story and capture UX are stronger.

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST and no automatic POST retry;
- dispatched writes require authenticated readback; uncertain outcomes use GET-only recovery;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- personal API Tokens and private learning data must not enter Git, logs, review artifacts or public examples;
- Shortcut/App Intent and Share capture remain pre-Preview input surfaces only;
- Share Extension/App Group must never contain or gain access to the personal Maimemo Token;
- browser-extension work remains blocked on first-party contract evidence;
- public pages must never claim source-main capabilities are already present in TestFlight build `1.0 (3)` unless released;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
