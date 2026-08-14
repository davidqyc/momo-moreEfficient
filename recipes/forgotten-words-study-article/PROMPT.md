# Codex workflow: forgotten words → study article

Use this file with the generated `forgotten-words.json`. The JSON is the only learning-data input; do not read `MAIMEMO_TOKEN`, call Maimemo, or use an OpenAI API key.

## Easy settings

Change these values before generating:

- Reader level: `CEFR B1`
- Article length: `350–500 English words`
- Topic or tone: `an engaging realistic story; avoid sensitive personal details`
- Grammar-note limit: `5 concise notes`

## Instructions

1. Read `forgotten-words.json` and validate that:
   - `schema_version` is `1`;
   - `source` is `maimemo`;
   - `selection` is `today-forgotten`;
   - `words` is an array and every entry has non-empty string fields `spelling`, `voc_id`, and `first_response`;
   - every `first_response` is exactly `FORGET`.
2. If validation fails, stop and identify the bad field. Do not guess or repair learning data silently.
3. If `words` is empty, say: “No forgotten words today; there is nothing to generate.” Then stop without inventing vocabulary or an article.
4. Draft one natural English article using the settings above. Cover every target spelling naturally and preserve each spelling exactly (ordinary capitalization or inflection is allowed only when grammatically necessary). Do not force bizarre sentences merely to include a word.
5. If a target cannot be used naturally, do not silently omit it. List it under `Unused target words`, explain why briefly, and suggest one simple user edit (for example, change the topic or allow a longer article).
6. Audit coverage after drafting. Check each target against the final article, not against your plan. Never mark a word covered unless its visible use can be quoted from the article.
7. Return print-friendly Markdown in exactly this section order:

```markdown
# <short title>

## English article
<article>

## Target-word coverage
- [x] `<target>` — “<short exact excerpt showing its natural use>”
- [ ] `<unused target>` — <brief reason, if any>
- Unused target words: none | <comma-separated list>

## Grammar notes
- `<short pattern from the article>` — <concise explanation>

## 中文翻译
<faithful, natural Chinese translation of the complete article>
```

Coverage is the hard audit: the checklist must contain each JSON target exactly once, with the same total count as `words`. The Chinese translation must not introduce information missing from the English article.
