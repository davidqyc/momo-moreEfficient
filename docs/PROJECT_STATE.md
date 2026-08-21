# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-22
sourceMainSha=7152c9eba2a817e1e41aa399c649f62d6b5bdead
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta
CURRENT_PRIMARY_ISSUE=#139
CURRENT_UNIQUE_NEXT=FIX_FALSE_NEGATIVE_WRITE_CONFIRMATION_AND_ADD_PRIVACY_SAFE_DIAGNOSTICS
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE are production/device validated under the existing Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)` passed external review; Public Link `https://testflight.apple.com/join/DtVKeTSE` is live with tester limit `100`;
- real Owner usage on build `1.0 (3)` produced a phrase batch where the app reported 3 success / 1 failure / 11 not attempted, but the item reported failed was subsequently confirmed present in the Maimemo app with the expected content;
- current phrase and interpretation executors both collapse a dispatched-write readback failure/mismatch to `.notVerified` after one readback attempt; current History stores only spelling + final outcome, so the exact failure layer cannot be reconstructed after the fact;
- #139 is therefore the current correctness/diagnostics priority: keep max-one-POST/no-retry, add the narrowest bounded GET-only confirmation recovery for the observed phrase CREATE false-negative class, and add small privacy-safe per-item diagnostics reusable across real write types;
- #120 is COMPLETE via PR #129: iOS 26+ Shortcut/App Intent capture reaches an editable pre-Preview state without Token/API/Preview/write activity;
- #124 is COMPLETE via PR #132: Share Extension uses one bounded non-secret App Group inbox and reaches the same pre-Preview review boundary without Token/Maimemo/write machinery in the extension;
- Owner expects normal use to compare Shortcut vs Share and then mainly keep whichever UX is better; do not add more cross-entry synchronization complexity without real evidence;
- #125 browser-extension research is `NEEDS-MAIMEMO-CLARIFICATION` before implementation;
- #104/#5 built-in dictionary lookup remains PARKED / NO-GO until Maimemo exposes a concrete supported content contract;
- #126 AEO foundations exist in GitHub and `davidqyc/jiripple-public-site`; Tencent SCF production was updated from public-site main `ffeb49b6717d57429a49eb252224759d0a273d9f` on 2026-08-22, and `/xiaoheiniao/`, its machine-readable surfaces, and existing ReliableReader routes were verified live while repository/admin paths remained 404.

## Current route — write correctness / diagnostics

1. Implement #139 as one focused iOS correctness PR.
2. Never add a POST retry. Once a POST is dispatched, recovery may use authenticated GET only.
3. For the observed phrase CREATE false-negative class, allow a small bounded GET-only confirmation window rather than treating the first visibility/readback miss as final failure.
4. Preserve a compact local diagnostic trail sufficient to distinguish POST dispatch state, readback failure category, decoded-match counts/mismatch category, and final outcome without storing Token/Auth/Cookie/raw Maimemo IDs or raw private batch bodies in shareable diagnostics.
5. Use the existing History/receipt surface if practical; do not build a remote analytics/logging system.
6. Unresolved dispatched writes still stop later writes and must tell the user not to repeat the write blindly; a later re-Preview is the safe manual check.
7. Treat #139 as a fix to include before the next broader TestFlight promotion.

## Parallel route — AI search / public deployment

1. Production entity surface is now live through the existing Tencent SCF function. Keep `https://www.jiripple.com/xiaoheiniao/`, `/xiaoheiniao/context.md`, `/llms.txt`, `/robots.txt`, and `/sitemap.xml` stable while crawlers/indexes catch up.
2. Resume #126's fixed Chinese/English benchmark repeatedly. Separate discovery/retrieval → citation/source selection → answer absorption → factual accuracy; do not interpret one search result as a durable ranking change.
3. Do not keep changing the page merely because indexing is not immediate. Improve entity metadata/content only when repeated benchmark evidence shows a specific gap.
4. Future public-site publishes should reuse the validated package builder and existing SCF code-only deployment boundary; never create replacement infrastructure or touch DNS/certificates/mail as a routine content publish.
5. Public copy follows `docs/PUBLIC_COPY_STYLE.md`: user language first, high-frequency functions first, and unreleased capabilities labeled by stage before explanation.

## Release gate — reading capture

This runs after the correctness fix and does not need more architecture work now:

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
- dispatched writes require authenticated readback; uncertain/unconfirmed outcomes may use bounded GET-only recovery;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- personal API Tokens and private learning data must not enter Git, logs, review artifacts or public examples;
- local diagnostics must not become a remote telemetry path and sanitized export must exclude Token/Auth/Cookie/raw Maimemo IDs/private payloads by default;
- Shortcut/App Intent and Share capture remain pre-Preview input surfaces only;
- Share Extension/App Group must never contain or gain access to the personal Maimemo Token;
- browser-extension work remains blocked on first-party contract evidence;
- public pages must never claim source-main capabilities are already present in TestFlight build `1.0 (3)` unless released;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
