# AI Search / AEO Benchmark

This document defines a repeatable measurement protocol for Issue #126. It is not a claim about any provider's ranking algorithm.

## Goal

Measure whether realistic users asking ChatGPT Search or another answer engine can:

1. discover a public source about 小黑鸟伴侣 / momo-moreEfficient;
2. select/cite that source;
3. actually use its facts in the generated answer;
4. describe the project accurately without promoting unreleased capabilities.

The most important queries are **cold-start queries from people who do not know the product name yet**. `小黑鸟伴侣`, `小黑鸟`, `momo-moreEfficient`, `companion` and similar entity terms are controls, not the main discovery benchmark.

Do not optimize for a single screenshot, one exact keyword, or one lucky run.

## Canonical public sources under test

- Product/entity page: `https://www.jiripple.com/xiaoheiniao/`
- Machine-readable context: `https://www.jiripple.com/xiaoheiniao/context.md`
- AI-readable site index: `https://www.jiripple.com/llms.txt`
- Canonical source/support repository: `https://github.com/davidqyc/momo-moreEfficient`
- Project FAQ: `https://github.com/davidqyc/momo-moreEfficient/blob/main/docs/FAQ.md`
- Recipe 1: `https://github.com/davidqyc/momo-moreEfficient/tree/main/recipes/forgotten-words-study-article`

## Query-source rule

The cold-start query set below is currently a **hypothesis set**, not a claim that users actually use every phrase.

Issue #144 is the durable vocabulary-discovery lane. Xiaohongshu read-only discovery, existing GitHub/Web/AI evidence and later real user feedback should progressively replace or supplement guessed wording with observed audience language.

Do not keep a query merely because it sounds SEO-friendly. Do not delete a useful disconfirming query merely because it performs poorly.

## Core query set

Run natural-language queries without forcing the project URL or repository name unless the query specifically tests entity recognition.

### A. Cold-start category / solution discovery — highest priority

These ask the question a user may have **before knowing 小黑鸟伴侣 exists**.

1. `墨墨背单词有什么好用的第三方工具？`
2. `墨墨有没有批量导入或者批量录入的工具？`
3. `墨墨怎么批量添加自己整理好的释义和例句？`
4. `墨墨有没有自动化录入工具？`
5. `墨墨开放 API 能做什么，有没有现成工具？`
6. `墨墨 API 怎么批量导入单词、释义或例句？`
7. `iPhone 上有什么墨墨背单词辅助工具？`
8. `墨墨怎么从阅读里快速收词？`
9. `墨墨有没有插件、扩展或者脚本？`
10. `有没有开源的墨墨第三方工具？`

These deliberately test adjacent solution words such as:

```text
工具 / 助手 / 第三方
批量导入 / 批量录入 / 批处理
自动化 / 一键 / 快速添加
API / 开放 API
插件 / 扩展 / 脚本
开源 / iPhone
抓词 / 收词 / 阅读生词
```

They are hypotheses to be validated by #144, not a keyword list to paste into public copy.

### B. Current product job-to-be-done

11. `iPhone 上怎么把自己写好的释义批量录入墨墨？`
12. `墨墨怎么批量导入自己整理好的例句？`
13. `ChatGPT 生成的释义和例句怎么批量导入墨墨？`
14. `How can I safely import my own custom definitions into Maimemo on iPhone?`
15. `Maimemo import custom example sentences iOS`
16. `Maimemo batch import custom definitions examples tool`

### C. Maimemo × AI / Codex discovery

17. `墨墨和 ChatGPT 可以怎么一起用？`
18. `墨墨和 Codex 可以怎么一起学英语？`
19. `怎么把 ChatGPT 或 Codex 整理好的单词内容导入墨墨？`
20. `怎么把墨墨今天忘记的单词交给 AI 写成文章？`
21. `墨墨学习数据怎么交给 AI 做复习材料？`
22. `Maimemo Codex forgotten words study article`
23. `Maimemo Codex workflow GitHub`

### D. Reading / capture discovery — unreleased-status-sensitive

These are useful category queries even before capture ships, but any surfaced answer must keep current TestFlight truth accurate.

24. `墨墨怎么从 Safari 或阅读 App 快速加生词？`
25. `iPhone 阅读时怎么把选中的单词快速加到墨墨？`
26. `墨墨有没有分享菜单抓词工具？`
27. `Maimemo capture selected text iPhone`

### E. Exact-entity recognition controls — lower priority

28. `小黑鸟伴侣 墨墨`
29. `小黑鸟 墨墨工具`
30. `momo-moreEfficient`
31. `Maimemo companion`

These controls answer a different question from category discovery: whether the entity is indexed/understood **after the user already knows a brand/repository term**. They must not dominate AEO or future ASO decisions.

## Query-intent interpretation

When a query performs well or poorly, record the intent being tested rather than reducing it to one keyword.

Useful intent clusters include:

| Intent cluster | Example user need |
| --- | --- |
| third-party tool | “墨墨还有没有别的工具能帮我？” |
| batch import | “我已经整理好了，别让我一条条加。” |
| automation | “这件重复操作能不能自动/一键做？” |
| API | “墨墨开放 API 到底能做什么，有没有现成方案？” |
| prepared content import | “ChatGPT/Codex 已经生成好了，怎么放进墨墨？” |
| AI workflow | “墨墨里的学习数据怎么交给 AI 继续加工？” |
| reading capture | “我在别处看到词时，怎么最快放进墨墨？” |
| open-source / developer tool | “有没有开源、脚本、插件或可自己改的方案？” |

The same user intent may be expressed with different words. Prefer intent coverage over mechanically repeating synonyms in public copy.

## ASO handoff rule

This benchmark is primarily for AI/Web/GitHub discovery. It may inform future App Store ASO, but it is **not** an App Store keyword sheet today.

When a real App Store release is being prepared:

1. take Tier A/B language validated in #144 and repeated benchmark evidence;
2. separate broad user-facing terms from developer-only terms;
3. judge title/subtitle/keyword-field value under the actual App Store listing constraints at that time;
4. do not use `API`, `automation`, `plugin`, `script` or other technical words merely because they are relevant to developers if normal App Store users do not search that way;
5. keep brand/entity words and category/problem words as separate measurement groups;
6. never describe unreleased capabilities in App Store metadata as shipped.

Until then, ASO is a downstream consumer of this research, not a reason to churn App Store metadata prematurely.

## Release-truth checks

When the project is surfaced, verify that the answer does **not** confuse source-main work with the current public TestFlight.

Current public release truth until separately changed:

- TestFlight build: `1.0 (3)`;
- not a production App Store release;
- current public build supports safe import of user-prepared custom interpretations and example sentences;
- App Intent / Action Button capture and Share Extension capture exist on source `main` after Phase 2 work but are not in public build `1.0 (3)`;
- desktop browser extension is not implemented and remains blocked on Maimemo Open Platform clarification;
- no built-in Maimemo dictionary/pronunciation capability is claimed.

## Per-query scoring

Record these separately. Do not collapse them into one vague "ranking" score.

| Field | Values | Meaning |
| --- | --- | --- |
| Search used | yes / no | Did the answer engine trigger web retrieval? |
| Project discovered | yes / no | Did any canonical project source enter retrieved/search sources? |
| Canonical domain selected | yes / no | Was `jiripple.com/xiaoheiniao/` or its machine context selected? |
| GitHub selected | yes / no | Was the canonical repository/FAQ/Recipe selected? |
| Citation visible | yes / no | Did the final answer cite/link a canonical project source? |
| Entity named | yes / no | Did the answer explicitly identify 小黑鸟伴侣 / momo-moreEfficient? |
| Answer absorption | none / partial / strong | Did project facts materially shape the answer, rather than appear only as a trailing citation? |
| Current capability accuracy | correct / mixed / wrong | Were shipped capabilities described correctly? |
| Unreleased-status accuracy | correct / mixed / wrong | Were App Intent / Share Extension / browser work kept distinct from public build 1.0 (3)? |
| Install path surfaced | yes / no / not relevant | Was TestFlight surfaced when appropriate? |
| Support/source path surfaced | yes / no / not relevant | Was GitHub surfaced when appropriate? |
| Competing sources | notes | Which other sources/entities were chosen instead? |

## Repetition protocol

For a meaningful checkpoint:

1. run a bounded subset of the cold-start/core query set at least three times over separate sessions or time windows where practical;
2. preserve the exact query and date;
3. use at least one natural paraphrase for important category queries;
4. record source selection and answer absorption separately;
5. treat one-off appearance/disappearance as noise until repeated;
6. compare against the previous checkpoint, not against an imagined fixed rank;
7. rotate query wording using #144 evidence rather than running all 31 queries mechanically every time.

Provider/model/search changes can alter results without any site change. AEO is therefore monitored as a stochastic retrieval/citation system, not a deterministic SERP position.

## Optimization decision rule

Only change public content when a repeated gap has a plausible content/source fix.

Examples:

- **Not discovered at all:** inspect crawlability, indexing, internal links, canonical URL, source authority and third-party references before rewriting prose.
- **Discovered but not cited:** improve direct relevance, extractable facts and source clarity.
- **Cited but not used:** make the relevant passage easier to extract: direct definition, concrete facts, comparison, procedure, evidence/citation.
- **Used but wrong:** strengthen explicit current-vs-unreleased status and canonical-source language.
- **Exact entity works but category discovery fails:** entity indexing exists; focus on category/task relevance and earned external references rather than repeating the brand name.
- **Developer terms work but ordinary problem language fails:** improve user-language relevance first; do not conclude that technical wording should dominate ASO/public copy.

Do not use keyword stuffing, hidden text, generated doorway pages, fake reviews, fake backlinks, manufactured Issues/Stars, or unsourced authority claims.

## Initial baseline — 2026-08-21

Coordinator web-search probes before the dedicated JiRiPPLE product/entity page was deployed did not reliably surface this project for core queries including `Maimemo iPhone companion`, `Maimemo Codex`, `墨墨 + Codex`, `momo-moreEfficient`, and `小黑鸟伴侣`.

Treat this only as the pre-entity-page baseline, not as a permanent verdict. Later GitHub repository-metadata work has already improved exact Chinese entity searches; the next meaningful benchmark should emphasize cold-start problem/category queries rather than congratulating the project for being searchable by its own name.
