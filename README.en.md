# momo-moreEfficient / 小黑鸟伴侣

**momo-moreEfficient (小黑鸟伴侣)** is an independent, unofficial, open-source companion project for **Maimemo / 墨墨背单词**.

It currently provides two public routes:

1. **iPhone companion** — safely import user-prepared custom interpretations and example sentences into Maimemo with Preview, explicit confirmation, fresh preflight, at-most-one POST per changed item, no automatic POST retry, and authenticated readback.
2. **Maimemo × Codex Recipes** — small reproducible learning workflows built around the documented Maimemo Open API, starting with a forgotten-words → study-article workflow.

This project is **not affiliated with, sponsored by, or endorsed by Maimemo or its operator**.

## Install the iPhone beta

The current external TestFlight beta is build `1.0 (3)`:

https://testflight.apple.com/join/DtVKeTSE

The app is not yet a production App Store release.

## Token and privacy model

The iPhone companion stores the user's Maimemo API Token only in the local iPhone Keychain. The project does not operate a backend that receives or stores that Token.

Never post a real Maimemo Token, Authorization/Cookie, account identifier, private vocabulary export, or private learning data in a GitHub Issue, Pull Request, log, review artifact, or public example.

## Codex Recipe 1

**Forgotten words today → Codex study article**

https://github.com/davidqyc/momo-moreEfficient/tree/main/recipes/forgotten-words-study-article

Recipe 1 reads the user's own Maimemo study data, selects the target forgotten words, and uses Codex/ChatGPT to produce a controlled English article, coverage checklist, grammar notes, and Chinese translation.

It does not require a separately purchased OpenAI API key; it uses the user's existing Codex/ChatGPT access path.

## Bugs, requests and contributions

Issues:
https://github.com/davidqyc/momo-moreEfficient/issues

Contributing guide:
https://github.com/davidqyc/momo-moreEfficient/blob/main/CONTRIBUTING.md

The repository provides structured Issue Forms for bugs/setup failures and feature/workflow requests.

## Not shipped yet

Do not treat these as current released capabilities:

- production App Store release;
- desktop browser capture extension;
- iOS Share Extension capture entry;
- App Intent / Action Button capture entry;
- background automatic import queue;
- automatic phrase replacement / phrase UPDATE;
- a separately maintained full dictionary/phonetics/audio service;
- a cloud account system that stores users' Maimemo Tokens.

These become real capabilities only after the corresponding GitHub work is reviewed, merged, and released.

## Canonical sources

- Project home: https://github.com/davidqyc/momo-moreEfficient
- Project FAQ: https://github.com/davidqyc/momo-moreEfficient/blob/main/docs/FAQ.md
- TestFlight: https://testflight.apple.com/join/DtVKeTSE
- Security: https://github.com/davidqyc/momo-moreEfficient/blob/main/SECURITY.md
- Privacy: https://github.com/davidqyc/momo-moreEfficient/blob/main/PRIVACY.md
- Issues: https://github.com/davidqyc/momo-moreEfficient/issues

If a third-party post conflicts with current GitHub `main` or current Issue/PR authority, the live GitHub sources above take precedence.
