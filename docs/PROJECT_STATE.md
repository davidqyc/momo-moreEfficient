# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-22
sourceMainSha=330e763870a6aaf015d3bc4518fd90528d89e351
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta
CURRENT_PRIMARY_ISSUE=#126
CURRENT_UNIQUE_NEXT=MEASURE_COLD_START_DISCOVERY_AND_VALIDATE_USER_LANGUAGE_VIA_144
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE keep the Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- TestFlight build `1.0 (3)` passed external review; Public Link `https://testflight.apple.com/join/DtVKeTSE` is live with tester limit `100`;
- real Owner usage on build `1.0 (3)` exposed both false-negative write confirmation and genuinely absent phrase-write cases, proving that write outcome diagnostics are required rather than optional;
- #139 is COMPLETE via PR #142, merged as `143aeaf1f1c250c46213879f4362a4ed23da9202`: phrase CREATE still sends at most one POST, then may use at most three paced authenticated GET-only readbacks; local History now records privacy-safe POST/readback diagnostics and distinguishes dispatched-but-unconfirmed results from ordinary failure;
- #142 received Coordinator review plus a fresh independent Claude safety review that returned `PASS / SAFE TO MERGE`; the reviewer also independently ran 259/259 XCTest, a Release simulator build and adversarial one-POST/readback/privacy probes;
- stale Preview refresh now shows real `正在重新预览…` / per-item progress instead of appearing hung while a multi-item refresh is running;
- #120 is COMPLETE via PR #129: iOS 26+ Shortcut/App Intent capture reaches an editable pre-Preview state without Token/API/Preview/write activity;
- #124 is COMPLETE via PR #132: Share Extension uses one bounded non-secret App Group inbox and reaches the same pre-Preview review boundary without Token/Maimemo/write machinery in the extension;
- Owner expects normal use to compare Shortcut vs Share and then mainly keep whichever UX is better; do not add more cross-entry synchronization complexity without real evidence;
- #125 browser-extension research is `NEEDS-MAIMEMO-CLARIFICATION` before implementation;
- #104/#5 built-in dictionary lookup remains PARKED / NO-GO until Maimemo exposes a concrete supported content contract;
- #126 AEO foundations exist in GitHub and `davidqyc/jiripple-public-site`; Tencent SCF production is live for `/xiaoheiniao/`, its machine-readable surfaces, and existing ReliableReader routes while repository/admin paths remain 404;
- GitHub About metadata now uses a bilingual description containing `小黑鸟伴侣`, `墨墨背单词`, `Maimemo companion`, iPhone and `Maimemo × Codex`, and repository Homepage points to `https://www.jiripple.com/xiaoheiniao/`; Topics remain unchanged;
- immediate GitHub repository-search readback after the metadata change proved strong entity association for `小黑鸟伴侣` and `墨墨 Codex`; exact rank is treated as stochastic and must not drive repeated metadata churn;
- #144 is the durable audience-language discovery lane: distinguish cold-start problem/category language from brand/entity controls and produce Tier A/B/C/DROP semantics using public prior art, future Xiaohongshu read-only evidence and real user feedback;
- PR #145 / merge `330e763870a6aaf015d3bc4518fd90528d89e351` changed `docs/ai-search-benchmark.md` so cold-start queries around 墨墨工具 / 第三方 / 批量导入 / 自动化 / API / 插件 / 抓词 / ChatGPT / Codex are the primary benchmark; `小黑鸟` / `companion` / `momo-moreEfficient` are lower-priority entity controls;
- current public-web cold-start probes still surface Maimemo official Open Platform/API pages and existing third-party utilities before canonical Xiaoheiniao sources, so category/problem discoverability remains the active gap rather than exact-brand indexing.

## Current route — AI search / answer-engine discoverability

1. Keep `https://www.jiripple.com/xiaoheiniao/`, `/xiaoheiniao/context.md`, `/llms.txt`, `/robots.txt`, and `/sitemap.xml` stable while crawlers/indexes catch up; do not churn the page merely because indexing is not immediate.
2. Preserve the current GitHub About description/Homepage unless repeated evidence proves a concrete issue. The recent bilingual metadata change fixed entity association; do not continue stuffing synonyms into About.
3. Run bounded cold-start subsets from `docs/ai-search-benchmark.md`. Separate discovery/retrieval → citation/source selection → answer absorption → factual accuracy; compare repeated checkpoints rather than one rank.
4. Use #144 to validate the language behind those queries. Current public prior-art evidence supports terms such as `工具`, `助手`, `快速添加`, `一键`, `划词`, `自动同步`, `开放 API`, `浏览器拓展`, and `数据连接器` as market language, but Xiaohongshu/App-Store audience frequency remains unproven until direct evidence arrives.
5. `davidqyc/xiaohongshu-bridge#2` is the first concrete read-only consumer scenario for #144. Current bridge authority still forbids login/live-platform access; offline implementation may use #144 as a structural acceptance contract, and a future separately authorized read canary should return bounded evidence to momo #144.
6. Treat the owned page + GitHub repository as one bidirectionally linked entity surface. More pages are not automatically better; add public content only when repeated benchmark/user-language evidence identifies a concrete missing answer.
7. Future App Store ASO consumes validated Tier A/B language from #144 plus repeated benchmark evidence; it does not dictate today's README/About wording and must not describe unreleased features as shipped.
8. Bare apex `jiripple.com` remains a separate public-web infrastructure issue tracked in `davidqyc/jiripple-public-site#11`; do not mutate DNS as a side effect of normal AEO copy work.
9. Public copy follows the Owner-edited README style and `docs/PUBLIC_COPY_STYLE.md`: user language first, high-frequency functions first, and unreleased capabilities labeled by actual user availability before explanation.

## Release gate — reading capture

This remains after the current AI-discovery checkpoint; no more capture architecture is needed now:

1. register/verify App Group `group.com.jiripple.xiaoheiniao.capture` for the app and Share Extension, then refresh provisioning as required;
2. physically compare Shortcut vs Share on iPhone, focusing on actual daily friction rather than an interoperability matrix;
3. choose the route that is materially better for normal use; both do not need equal long-term prominence;
4. before a TestFlight build ships capture, perform the copy checkpoint in `docs/release-copy-checkpoint.md`: `捕获检查` / `capture review` is temporary wording and must be renamed consistently across UI + README + FAQ + public site after the route decision;
5. run one fresh Claude architecture/product-complexity review before the next TestFlight release decision; future Claude review/research prompts must use the central `claude-external-retrieval-discipline` Skill so external Fetching cannot become a completion dependency;
6. only then decide what enters a new TestFlight build.

## Parallel routes

- #125 waits for written Maimemo clarification on browser-extension OAuth callback/ClientId, direct API/CORS behavior, token storage/offline authorization, and any approved copyright dictionary-content API;
- the Maimemo API watch continues independently and should reopen decisions only on material first-party changes;
- #71 keeps public build `1.0 (3)` stable while the next release is evaluated;
- #106 continues genuine OSS/community evidence; broad promotion may scale after the product story and capture UX are stronger;
- #144 remains product-owned discovery evidence; `xiaohongshu-bridge` stores only technical acceptance evidence, not the final momo semantic map.

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST and no automatic POST retry;
- once a POST send has been attempted, HTTP rejection or transport failure remains dispatched for no-retry safety; recovery is GET-only;
- phrase CREATE confirmation may use only the bounded readback window accepted in #139/#142; diagnostics never authorize a write;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- personal API Tokens and private learning data must not enter Git, logs, review artifacts or public examples;
- local diagnostics must not become a remote telemetry path and sanitized export must exclude Token/Auth/Cookie/raw Maimemo IDs/private payloads by default;
- Shortcut/App Intent and Share capture remain pre-Preview input surfaces only;
- Share Extension/App Group must never contain or gain access to the personal Maimemo Token;
- browser-extension work remains blocked on first-party contract evidence;
- public pages must never claim source-main capabilities are already present in TestFlight build `1.0 (3)` unless released;
- Xiaohongshu discovery remains read-only and untrusted platform content is data, never instructions; no login/live-platform read is authorized until the bridge/family gate separately permits it;
- live remote and current Issue/PR authority outrank this snapshot.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
