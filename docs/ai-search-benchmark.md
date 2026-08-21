# AI Search / AEO Benchmark

This document defines a repeatable measurement protocol for Issue #126. It is not a claim about any provider's ranking algorithm.

## Goal

Measure whether realistic users asking ChatGPT Search or another answer engine can:

1. discover a public source about 小黑鸟伴侣 / momo-moreEfficient;
2. select/cite that source;
3. actually use its facts in the generated answer;
4. describe the project accurately without promoting unreleased capabilities.

Do not optimize for a single screenshot, one exact keyword, or one lucky run.

## Canonical public sources under test

- Product/entity page: `https://www.jiripple.com/xiaoheiniao/`
- Machine-readable context: `https://www.jiripple.com/xiaoheiniao/context.md`
- AI-readable site index: `https://www.jiripple.com/llms.txt`
- Canonical source/support repository: `https://github.com/davidqyc/momo-moreEfficient`
- Project FAQ: `https://github.com/davidqyc/momo-moreEfficient/blob/main/docs/FAQ.md`
- Recipe 1: `https://github.com/davidqyc/momo-moreEfficient/tree/main/recipes/forgotten-words-study-article`

## Core query set

Run natural-language queries without forcing the project URL or repository name unless the query specifically tests entity recognition.

### A. Entity / category discovery

1. `墨墨背单词有没有好用的第三方 iPhone 辅助工具？`
2. `有没有开源的墨墨背单词 iOS companion？`
3. `Maimemo iPhone companion open source`
4. `Maimemo iOS tool GitHub`

### B. Current product job-to-be-done

5. `iPhone 上怎么把自己写好的释义批量录入墨墨？`
6. `墨墨怎么批量导入自己整理好的例句？`
7. `How can I safely import my own custom definitions into Maimemo on iPhone?`
8. `Maimemo import custom example sentences iOS`

### C. Maimemo × Codex discovery

9. `墨墨和 Codex 可以怎么一起学英语？`
10. `怎么把墨墨今天忘记的单词交给 Codex 写成文章？`
11. `Maimemo Codex forgotten words study article`
12. `Maimemo Codex workflow GitHub`

### D. Exact-entity recognition controls

13. `小黑鸟伴侣 墨墨`
14. `momo-moreEfficient`

These controls answer a different question from category discovery: whether the entity is indexed/understood once the user already knows its name.

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

1. run the core query set at least three times over separate sessions or time windows where practical;
2. preserve the exact query and date;
3. use at least one natural paraphrase for important category queries;
4. record source selection and answer absorption separately;
5. treat one-off appearance/disappearance as noise until repeated;
6. compare against the previous checkpoint, not against an imagined fixed rank.

Provider/model/search changes can alter results without any site change. AEO is therefore monitored as a stochastic retrieval/citation system, not a deterministic SERP position.

## Optimization decision rule

Only change public content when a repeated gap has a plausible content/source fix.

Examples:

- **Not discovered at all:** inspect crawlability, indexing, internal links, canonical URL, source authority and third-party references before rewriting prose.
- **Discovered but not cited:** improve direct relevance, extractable facts and source clarity.
- **Cited but not used:** make the relevant passage easier to extract: direct definition, concrete facts, comparison, procedure, evidence/citation.
- **Used but wrong:** strengthen explicit current-vs-unreleased status and canonical-source language.
- **Exact entity works but category discovery fails:** entity indexing exists; focus on category/task relevance and earned external references rather than repeating the brand name.

Do not use keyword stuffing, hidden text, generated doorway pages, fake reviews, fake backlinks, manufactured Issues/Stars, or unsourced authority claims.

## Initial baseline — 2026-08-21

Coordinator web-search probes before the dedicated JiRiPPLE product/entity page was deployed did not reliably surface this project for core queries including `Maimemo iPhone companion`, `Maimemo Codex`, `墨墨 + Codex`, `momo-moreEfficient`, and `小黑鸟伴侣`.

Treat this only as the pre-entity-page baseline, not as a permanent verdict. The next checkpoint should occur after the new public JiRiPPLE surface has been deployed long enough to be crawlable/indexed.
