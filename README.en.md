# Xiaoheiniao / momo-moreEfficient

**Xiaoheiniao (小黑鸟伴侣 / momo-moreEfficient)** is an independent, unofficial, open-source **Maimemo / 墨墨背单词 companion**. The point is simple: make a few frequent but annoying Maimemo workflows much easier — first importing prepared interpretations and examples, then capture while reading, plus reproducible **Maimemo × Codex** learning workflows.

> **Current public version:** [iPhone TestFlight build `1.0 (3)`](https://testflight.apple.com/join/DtVKeTSE). It is not yet a production App Store release.
>
> **Not an official Maimemo project.** This is an independent community/open-source project and is not affiliated with, sponsored by, or endorsed by Maimemo or its operator.

## Quick start

| I want to | Go here |
| --- | --- |
| Try Xiaoheiniao on iPhone | **[Join TestFlight](https://testflight.apple.com/join/DtVKeTSE)** |
| Turn today's forgotten words into a Codex study article | **[Recipe 1: forgotten words → Codex study article](recipes/forgotten-words-study-article/README.md)** |
| Read the stable product page | **[www.jiripple.com/xiaoheiniao/](https://www.jiripple.com/xiaoheiniao/)** |
| Report a bug, get help, or suggest something | **[GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)** |

[中文 README](README.md) · [Project FAQ](docs/FAQ.md) · [Privacy](PRIVACY.md) · [Security](SECURITY.md)

## Feature 1 | Batch-import prepared interpretations and examples

This is the first group of features already available in the public TestFlight.

If you already prepared content in ChatGPT, Codex, your notes, or somewhere else, you do not need to add it to Maimemo item by item. Xiaoheiniao puts that prepared content into a review-and-confirm flow before anything is written.

Public build `1.0 (3)` supports:

- **custom interpretations:** batch create / update;
- **examples / phrases:** create;
- Preview before any write;
- explicit confirmation before writing;
- fresh authenticated preflight immediately before POST;
- at most one POST per changed item, with **no automatic POST retry**;
- authenticated readback after dispatched writes.

The normal flow is:

```text
prepare content → paste once → Preview
→ check create / update items → confirm
→ fresh preflight → write → authenticated readback
```

### Your Maimemo Token stays on your iPhone

The personal Maimemo API Token is stored only in the local iPhone Keychain. This project does not run a remote backend that receives or stores that Token.

Real Tokens, Authorization/Cookie values, account identifiers, private vocabulary exports, and private learning data should never be put into public Issues, PRs, logs, examples, or review material.

## Feature 2 | Capture while reading — coming soon

This work is **complete on source `main`, but it is not in public TestFlight build `1.0 (3)` yet**.

The goal is to shorten one common action:

```text
see a word / sentence worth keeping → send it to Xiaoheiniao
→ review and edit → then decide whether to enter the normal Preview/import flow
```

Two candidate entries currently exist:

- **Shortcut (iOS 26+)**: pass selected text to Xiaoheiniao and open the app into the separate pre-Preview review state;
- **Share (iOS 18+)**: save selected text from the iOS share sheet, then review it the next time Xiaoheiniao is opened normally.

Both stop **before Preview**. Capturing text alone does not read the Maimemo Token, call Maimemo, run Preview, or write anything.

The next step is a physical-iPhone UX comparison. The project will prefer whichever route is actually less work in daily use rather than keeping two entry paths prominent just for technical symmetry.

## Feature 3 | Maimemo × Codex learning workflows

This route does not depend on the iPhone app. Each Recipe is meant to be small, clear, and reproducible rather than part of a large automation platform.

### Available now: Recipe 1 — forgotten words → Codex study article

Recipe 1 reads your own Maimemo study data, identifies the target forgotten words, and asks Codex / ChatGPT to produce:

- an English study article covering the words;
- a coverage checklist;
- grammar notes;
- a Chinese translation.

**[Open Recipe 1](recipes/forgotten-words-study-article/README.md)**

It does not require a separately purchased OpenAI API key; it uses your existing Codex / ChatGPT access path. The Maimemo side is read-only for this workflow.

## What is next?

Unreleased work is labeled by stage so source code is not mistaken for something users can already install:

| Capability | Stage |
| --- | --- |
| iPhone interpretation / example import | **Available now** in TestFlight build `1.0 (3)` |
| Shortcut capture | **Coming soon** — source implementation complete; pending physical UX comparison and release decision |
| Share-sheet capture | **Coming soon** — source implementation complete; pending App Group / physical validation and release decision |
| Desktop browser capture extension | **Researching** — not implemented; waiting for Maimemo Open Platform clarification on OAuth redirect / CORS / API contracts |
| Built-in Maimemo dictionary / pronunciation service | **Not available** |
| Background automatic import queue | **No current plan** |

Current engineering state: [`docs/PROJECT_STATE.md`](docs/PROJECT_STATE.md).

## Safety floor

These rules remain in force as the project grows:

- Preview is not write authorization;
- writes require explicit user confirmation;
- state-sensitive writes get fresh authenticated preflight before POST;
- each changed item gets at most one POST and POST is not automatically retried;
- dispatched writes require authenticated readback; uncertain outcomes use GET-only recovery;
- UPDATE targets only an unambiguous authenticated-user record;
- no automatic DELETE, rollback, or replay;
- real Tokens and private learning data must not enter Git, logs, or public artifacts.

## Bugs, help, requests, contributions

- **Bug / install / setup problem:** [GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)
- **Feature or workflow idea:** also [GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)
- **Code or docs contribution:** read [`CONTRIBUTING.md`](CONTRIBUTING.md), then open a Pull Request

GitHub is the canonical home for source, Recipes, Issues, PRs, and current engineering truth. [`www.jiripple.com/xiaoheiniao/`](https://www.jiripple.com/xiaoheiniao/) is the stable user/search/AI product-facts page.

## For developers / historical material

Normal users can stop here. Engineering and historical references:

- [Project FAQ](docs/FAQ.md)
- [Current project state](docs/PROJECT_STATE.md)
- [AI-search benchmark](docs/ai-search-benchmark.md)
- [Product/API plan](docs/product-and-api-plan.md)
- [Decision log](docs/decision-log.md)
- [Agent/Codex rules](AGENTS.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)
- [Legacy CLI v0.1.0](docs/legacy-cli-v0.1.0.md)

## Trademark / disclaimer

This is an independent, unofficial third-party open-source project. “Maimemo”, “墨墨”, and “墨墨背单词” are referenced only to identify the compatible service and public API integration. All related names and trademarks belong to their respective owners.

## License

[MIT](LICENSE)
