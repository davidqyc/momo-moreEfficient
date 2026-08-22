# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-22
sourceMainSha=bd4b9bc55cb64124135ada9f1a712f8737d831f0
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta
CURRENT_PRIMARY_ISSUE=#126
CURRENT_UNIQUE_NEXT=WAIT_FOR_OWNER_NEXT_COMMAND_AFTER_REMOTE_CLOSEOUT
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
IMPLEMENTATION_HOLD=true
```

No new product implementation should start from this snapshot until the Owner gives the next command.

## What is already proven

- interpretation batch CREATE/UPDATE and phrase CREATE keep the Preview → approval → fresh preflight → max-one-POST/no-retry → authenticated readback safety floor;
- personal Maimemo API Token remains device-local in `WhenUnlockedThisDeviceOnly` Keychain for the iOS app;
- public TestFlight build `1.0 (3)` is live via `https://testflight.apple.com/join/DtVKeTSE`; this is TestFlight, not an App Store release;
- #139 is COMPLETE via PR #142 / merge `143aeaf1f1c250c46213879f4362a4ed23da9202`: phrase CREATE still sends at most one POST, then may use at most three paced authenticated GET-only readbacks; local History records privacy-safe POST/readback diagnostics and distinguishes dispatched-but-unconfirmed results from ordinary failure;
- #142 received Coordinator review plus a fresh independent Claude safety review that returned `PASS / SAFE TO MERGE`; the reviewer independently ran the complete XCTest/Release/adversarial verification set;
- stale Preview refresh now shows real `正在重新预览…` / per-item progress rather than appearing hung;
- #120 and #124 are complete: iOS Shortcut/App Intent and Share Extension capture both terminate at an editable pre-Preview boundary without Maimemo Token/API/write activity;
- #125 browser-extension research remains `NEEDS-MAIMEMO-CLARIFICATION`; #104/#5 built-in dictionary/content lookup remains parked until first-party contracts support it;
- Tencent SCF production is live for `/xiaoheiniao/`, machine-readable discovery surfaces and existing ReliableReader routes; repository/admin paths remain non-public;
- public copy authority remains the Owner-edited README plus `docs/PUBLIC_COPY_STYLE.md`; unreleased source-main capability must never be described as present in TestFlight build `1.0 (3)`.

## GitHub / AI keyword optimization state

This work is **AI keyword optimization / GitHub discovery**, not App Store ASO.

- #147 controlled metadata round 1 is complete and Coordinator-reviewed PASS;
- current About description is:
  `小黑鸟伴侣｜独立非官方的墨墨背单词第三方开源工具 / Maimemo companion & iPhone tool：基于开放 API 安全批量导入/录入释义和例句，支持 ChatGPT / Codex 学习工作流。`;
- Homepage remains `https://www.jiripple.com/xiaoheiniao/`;
- current Topics are exactly: `batch-import`, `chatgpt`, `ios`, `maimemo`, `maimemo-api`, `openai-codex`, `vocabulary-import`, `vocabulary-learning`;
- the controlled change materially improved cold-start GitHub repository matching: queries around `墨墨 工具`, `墨墨 批量导入`, `墨墨 API`, `墨墨 第三方`, `墨墨 ChatGPT`, `Maimemo tool`, `Maimemo API` and `Maimemo ChatGPT` moved from absent/zero-result states into the first result page, while brand/entity controls remained strong;
- exact repository rank is stochastic; #147 is now `FREEZE_METADATA_AND_REPEAT_COLD_START_CHECKPOINTS`, not permission for more keyword stuffing;
- `墨墨 自动化`, `墨墨 插件`, `Maimemo automation` and `Maimemo batch import` remaining absent is not a reason to overstate product behavior or unreleased surfaces;
- #144 owns durable audience-language discovery. Xiaohongshu evidence, public prior art and real users should decide which words survive; bridge implementation/runtime evidence does not become product semantic authority by itself;
- `docs/ai-search-benchmark.md` separates GitHub repository matching from answer-engine retrieval → citation/source selection → answer absorption → factual accuracy;
- bare `jiripple.com` redirect/canonical entry remains separately tracked in `davidqyc/jiripple-public-site#11` and must not be changed as a side effect of normal content work.

## Competitive evidence and product backlog

#149 is the umbrella competitive-feature harvest. The repeated signal is not “more raw API power”; it is low-friction capture, interoperability, preserved context, safe batch operations and useful learning-data reuse.

### Strong public demand signals observed

- `busiyiworld/maimemo-export`: roughly 950 stars / 196 forks — very strong demand for export, portability and cross-tool use; its Root/database/copyright-wordbook path is **not** a model for this project;
- `viazure/EudicSyncToMaiMemo`: roughly 57 stars / 8 forks — mature multi-platform Release, scheduled sync, logging/notification and OpenAPI migration evidence;
- `chriscurrycc/bob-plugin-maimemo-notebook`: roughly 53 stars / 6 forks — strong evidence for “query/capture a word while preserving the sentence + translation/context”;
- official `maimemo/memo-skills`: roughly 38 stars — first-party evidence that Maimemo × Agent/AI workflows such as today/progress/forgotten words and creating note/interpretation/phrase are real ecosystem surfaces;
- `eMUQI/eudic-maimemo-sync`: roughly 13 stars / 2 forks plus tutorial/Docker distribution — repeated evidence for external-source → Maimemo sync;
- official `maimemo/memo-api-cli`: broad official API surface, OIDC and npm distribution; low GitHub-star count does not negate first-party ecosystem importance.

### Focused candidate issues created from that evidence

- #152 — **Universal Inbox / 墨墨 × 一切**: source-agnostic adapters produce candidate content into one local inbox; adapters never gain write authorization. Phase A targets text/JSON/CSV/TSV/Markdown/TXT/iOS Share/AI-output schemas before live external connectors. The public adapter/schema surface is also intended to create genuine OSS reuse/fork value.
- #153 — **助记 / Note import with respect/content review**: demand is proven by official API/Skills and AI-sync prior art, but content review is part of the feature. Use a deterministic high-risk pass + extensible semantic review hook + mandatory per-item human Preview. Sexist/sexualizing/objectifying/stereotype-based mnemonics from generated candidates cannot be batch-approved; user-imported text is never silently rewritten. Content review never replaces write authorization.
- #154 — **context-preserving capture**: preserve selected word + surrounding sentence/translation/source where the source surface can provide them safely; keep only minimal local context and route through normal Preview/approval. This is the natural next refinement of the existing capture feature.
- #155 — **read-only Today / forgotten / vague / progress → AI handoff**: use first-party study read surfaces and the existing Recipe direction; do not mutate study state merely because official CLI exposes write commands.
- #156 — **user-owned data export/backup/interoperability**: export only contractually supported user-owned content (custom interpretations/phrases/notes/user notepads and selected read-only learning data) to JSON/CSV/Markdown/TXT; no Root/database extraction and no export of Maimemo copyrighted built-in wordbook databases. Round-trip with #152 where practical.
- #157 — **notepad picker/create + safe batch add**: replace `np-...` developer UX with user-facing list/select/create and new-vs-existing Preview. If the API requires whole-notepad replacement, treat it as a higher-risk conflict-aware write rather than a blind append.
- #150 — **README/distribution conversion**: the next GitHub growth pass should emphasize privacy-safe visual demo, compact differentiation from raw CLI/scripts and durable GitHub Release records for promoted public TestFlight builds rather than adding more prose/keywords.
- #158 — **Codex for Open Source readiness**: accumulate genuine adoption, reusable OSS surfaces and maintenance evidence; do not invent a star threshold or manufacture activity.

## Product ordering — not yet authorized for implementation

Unless the Owner changes direction, the current planning preference is:

1. finish the existing capture release gate and real-iPhone Shortcut-vs-Share comparison;
2. #154 context-preserving capture as the closest extension of work already built;
3. #153 mnemonic/Note import with the respect/content-review gate;
4. #155 read-only Today/forgotten/vague → AI;
5. #157 notepad picker/create and safe batch membership;
6. progressively extract #152 Universal Inbox / adapter contract as multiple real sources converge on it;
7. #156 export/backup/interoperability as the larger reusable OSS/data-portability surface;
8. #150 README demo/release conversion and #158 OSS-readiness evidence proceed as appropriate without fake stars/reviews/backlinks.

This order is a planning snapshot only; the next Owner command may supersede it.

## Codex for Open Source / stop-loss position

Current evidence does **not** support stopping the project merely because Maimemo is niche.

- the ecosystem contains ~50-star utility/workflow projects and one ~950-star portability/export project;
- official Maimemo CLI + Agent Skills show ecosystem importance beyond stars;
- the strongest eventual application story is not “an iPhone helper for one vocabulary app”, but a truthful safety-first interoperability layer connecting Maimemo, user-owned learning data, iOS capture and reusable AI/agent workflows;
- that story must become real in the product before it is used in an application;
- current weakness is external adoption proof: genuine external users/testers, Issues, stars/forks/PRs, reusable adapter/schema/Recipe use, public release records and external tutorials/references are still early;
- #158 owns the evidence trigger. Re-read OpenAI's live program rules only when real usage + ecosystem reuse + sustained maintainer workload are all demonstrable;
- if broader distribution over time produces almost no external use/reuse despite good discoverability and a stronger product, that would be actual stop-loss evidence.

## Release gate — reading capture

No new capture architecture is needed before real-device validation:

1. register/verify App Group `group.com.jiripple.xiaoheiniao.capture` for app + Share Extension and refresh provisioning as needed;
2. compare Shortcut vs Share on physical iPhone for actual daily friction;
3. choose the materially better normal route; both do not need equal long-term prominence;
4. before any capture-enabled TestFlight release, replace temporary `捕获检查` / `capture review` wording consistently across UI + README/README.en + FAQ + public site;
5. run one fresh Claude architecture/product-complexity review before the next TestFlight release decision; Claude prompts must follow central `claude-external-retrieval-discipline` and must not block completion on WebFetch/WebSearch/browser `Fetching`;
6. only then make a separate TestFlight release decision.

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST and no automatic POST retry;
- once a POST send has been attempted, HTTP rejection or transport failure remains dispatched for no-retry safety; recovery is GET-only;
- phrase CREATE uses only the bounded readback recovery accepted in #139/#142; do not mechanically copy that retry policy to other content types without evidence;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- personal Tokens and private learning data must not enter Git, public logs, review artifacts or public examples;
- diagnostics stay local/privacy-safe and do not become telemetry;
- Shortcut/App Intent/Share capture remain pre-Preview input surfaces only; Share Extension/App Group never gains access to Maimemo Token;
- source adapters in #152 may produce candidates only and can never bypass the safety core;
- mnemonic content review in #153 is separate from and cannot substitute for write authorization;
- user-data export in #156 must stay within public API/data-ownership/legal boundaries;
- browser work remains blocked on first-party contract evidence;
- public pages must not claim source-main capabilities are already present in TestFlight build `1.0 (3)` unless released;
- live remote and current Issue/PR authority outrank this snapshot.

## Remote closeout note

- no product PR is open at this closeout;
- the accidental root `dummy` file created during Coordinator tooling was immediately deleted in the next commit; the current tree contains no `dummy` file and no product residue from that mistake;
- the create/revert commits remain in normal Git history; do not force-rewrite published history merely to hide the mistake;
- newly created #149, #150, #152–#158 are backlog/planning authority only, not implementation status.

## Maintenance rule

Keep this file to current state, one next step and live boundaries only. Update at real milestones, not micro-steps.
