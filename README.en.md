# Xiaoheiniao / momo-moreEfficient

**Xiaoheiniao (momo-moreEfficient)** is an independent, unofficial, open-source **practical helper for Maimemo / 墨墨背单词**. It focuses on a few high-friction jobs: safely importing interpretations and examples, making reading-time capture quicker, and turning Maimemo study data into reproducible **Maimemo × Codex** workflows.

> **Current public version:** [iPhone TestFlight build `1.0 (3)`](https://testflight.apple.com/join/DtVKeTSE). It is not yet a production App Store release.
>
> **Not an official Maimemo project.** It is an independent community-built side project and is not affiliated with, sponsored by, or endorsed by Maimemo or its operator.

## Quick links

| I want to… | Go here |
| --- | --- |
| Try Xiaoheiniao on iPhone | **[Join TestFlight](https://testflight.apple.com/join/DtVKeTSE)** |
| Turn today's forgotten words into a Codex study article | **[Recipe 1](recipes/forgotten-words-study-article/README.md)** |
| Read the product page | **[www.jiripple.com/xiaoheiniao/](https://www.jiripple.com/xiaoheiniao/)** |
| Report a bug, ask for help, or suggest something | **[GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)** |

[中文 README](README.md) · [Project FAQ](docs/FAQ.md) · [Privacy](PRIVACY.md) · [Security](SECURITY.md)

## Feature 1 | Batch-import prepared interpretations and examples

This is the first feature set in the current public TestFlight.

If you already prepared content in ChatGPT, Codex, your own notes, or somewhere else, you do not have to add everything to Maimemo one item at a time. Xiaoheiniao puts that prepared content into a reviewable, explicit import flow.

Public build `1.0 (3)` supports:

- **custom interpretations:** batch create and update;
- **examples / phrases:** create;
- Preview before any write;
- an explicit confirmation before writing;
- a fresh authenticated preflight immediately before POST;
- at most one POST per changed item, with **no automatic POST retry**;
- authenticated readback after a dispatched write.

The everyday flow is:

```text
prepare content → paste it into Xiaoheiniao → Preview
→ check create / update results → explicitly confirm
→ fresh preflight → write → authenticated readback
```

### The project does not collect your Maimemo Token

Your personal Maimemo API Token stays in the local Keychain on your iPhone. This project does not operate a remote backend that receives or stores that Token.

The project does not intentionally write real Tokens, Authorization/Cookie values, account identifiers, or private learning data into public Issues, PRs, logs, examples, or review material. Please do not paste those values into public pages yourself either.

## Feature 2 | Capture while reading — coming soon

The source implementation is complete and is now waiting for a practical physical-device comparison before release. **This feature is not in the current public TestFlight build `1.0 (3)`.**

The goal is simply to shorten this flow:

```text
see a word / sentence worth keeping → send it to Xiaoheiniao
→ review and edit it → decide whether to continue into the normal Preview / import flow
```

Two candidate entry points are implemented:

- **Shortcut (iOS 26+):** pass selected text to Xiaoheiniao and open the app in the current temporary capture-review screen;
- **Share (iOS 18+):** save text from the system share sheet and review it when Xiaoheiniao is normally opened.

Both stay before Preview. Capturing text alone does not read the Maimemo Token, contact Maimemo, run Preview, or write anything.

The next step is a real-device usability comparison. The project will favor whichever daily path is actually simpler; both entry points do not have to remain equally prominent forever.

## Feature 3 | Turn today's forgotten Maimemo words into a Codex study article

This route is already available and does not depend on the iPhone app. Recipes are intentionally small, reproducible learning workflows rather than a general automation platform.

### Recipe 1: Forgotten words today → Codex study article

Recipe 1 reads your own Maimemo study data, selects the target forgotten words for today, then uses Codex / ChatGPT to produce:

- an English study article covering those words;
- a coverage checklist;
- grammar notes;
- a Chinese translation.

**[Open Recipe 1](recipes/forgotten-words-study-article/README.md)**

It does not require a separately purchased OpenAI API key; it uses your existing Codex / ChatGPT access path. The Maimemo side is semantically read-only and performs no write.

## Feature status

The table below is about what users can actually use, not merely what exists somewhere on the source branch.

| Feature | Stage | Current status |
| --- | --- | --- |
| iPhone interpretation / example batch import | **Shipped** | Available in TestFlight build `1.0 (3)` |
| Reading-time capture | **Coming soon** | Source is complete; physical-device Shortcut vs Share comparison comes before the next release decision |
| Desktop browser capture | **Research** | No public implementation yet; waiting for Maimemo Open Platform clarification on browser OAuth callback, CORS / direct API access, and related contracts |
| Built-in Maimemo dictionary / pronunciation | **Not offered** | The current public API contract is not sufficient for this project to claim a reliable implementation |
| Automatic background import | **Not offered** | Not shipped and not a near-term primary route |

Current engineering state: [`docs/PROJECT_STATE.md`](docs/PROJECT_STATE.md).

## Safety floor

These rules remain in place as the product grows:

- Preview is not write authorization;
- writes require explicit user confirmation;
- state-sensitive writes get a fresh authenticated preflight before POST;
- each changed item gets at most one POST and POST is never automatically retried;
- dispatched writes require authenticated readback; uncertain outcomes use GET-only recovery;
- UPDATE only targets an unambiguous authenticated-user record;
- no automatic DELETE, rollback, or replay;
- real Tokens and private learning data must not enter Git, logs, or public review material.

## Bugs, help, ideas, and contributions

- **Bug / install / setup problem:** [GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)
- **Feature or workflow idea:** use the same [GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)
- **Code or documentation contribution:** read [`CONTRIBUTING.md`](CONTRIBUTING.md) first, then open a Pull Request

GitHub is the canonical source for code, Recipes, Issues, PRs, and current engineering status. [`www.jiripple.com/xiaoheiniao/`](https://www.jiripple.com/xiaoheiniao/) is the stable public product-facts page for users, search engines, and answer systems.

## For developers

Most users can stop above. Engineering and historical material lives here:

- [Project FAQ](docs/FAQ.md)
- [Current project state](docs/PROJECT_STATE.md)
- [AI-search benchmark](docs/ai-search-benchmark.md)
- [Product and API plan](docs/product-and-api-plan.md)
- [Decision log](docs/decision-log.md)
- [Agent / Codex rules](AGENTS.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

### Legacy CLI v0.1.0

The repository originally shipped as a Python command-line interpretation importer. It remains available for legacy/reference use, but it is no longer the recommended first entry point for new users.

Full CLI commands, input format, main-account opt-in, preflight states, and its safety contract are preserved in:

**[`docs/legacy-cli-v0.1.0.md`](docs/legacy-cli-v0.1.0.md)**

## Disclaimer and trademarks

This is an independent, unofficial third-party open-source project. It is not affiliated with, sponsored by, or endorsed by Maimemo or its operator. “Maimemo”, “墨墨”, “墨墨背单词”, and related names are used only to identify the compatible service and its public API; all related names and trademarks belong to their respective owners.

This project uses publicly provided interfaces and follows the corresponding API, content, and account rules. You are responsible for changes made to your own account data.

## License

[MIT](LICENSE)
