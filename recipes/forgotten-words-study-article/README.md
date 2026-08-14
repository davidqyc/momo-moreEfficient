# Forgotten words → Codex study article

This small read-only recipe fetches today's Maimemo study items, keeps the words whose first response was `FORGET`, and writes a local JSON file. You then ask Codex or ChatGPT to turn that file into an English article, a coverage checklist, grammar notes, a Chinese translation, and print-friendly Markdown.

It uses one documented Study API operation. That operation is HTTP `POST`, but it is semantically read-only: this recipe cannot add, advance, update, or delete Maimemo data. It also does not call an OpenAI API or require an OpenAI API key; you bring your own Codex/ChatGPT access.

## Prerequisites

- Python 3.13 (the version tested by this repository's CI); no packages to install.
- A personal Maimemo Open API Token.
- Your own Codex or ChatGPT access for the article step.

Get your Token while signed in to the intended Maimemo account:

1. Open the Maimemo app.
2. Go to **我的 → 更多设置 → 实验功能 → 开放 API**.
3. Copy the personal Token shown there. Do not paste it into an Issue, chat prompt, screenshot, committed file, or shell command.

The same setup guidance and current API reference are on the [official Maimemo Open API site](https://open.maimemo.com/).

## Run it

Clone the repository, open a terminal in it, and enter the recipe directory:

```bash
cd recipes/forgotten-words-study-article
```

Set the Token only in the current terminal session. The hidden-input form below avoids placing the Token itself in shell history.

macOS/Linux (`zsh` or `bash`):

```bash
printf 'Maimemo Token (hidden): '
IFS= read -r -s MAIMEMO_TOKEN
printf '\n'
export MAIMEMO_TOKEN
python3 fetch_words.py
unset MAIMEMO_TOKEN
```

PowerShell:

```powershell
$secureToken = Read-Host "Maimemo Token" -AsSecureString
$env:MAIMEMO_TOKEN = [System.Net.NetworkCredential]::new("", $secureToken).Password
python fetch_words.py
Remove-Item Env:MAIMEMO_TOKEN
Remove-Variable secureToken
```

Success creates `forgotten-words.json` in this directory. The file is ignored by Git and contains:

```json
{
  "schema_version": 1,
  "source": "maimemo",
  "selection": "today-forgotten",
  "generated_at": "2026-08-15T00:00:00Z",
  "words": [
    {
      "spelling": "adapt",
      "voc_id": "synthetic-voc-001",
      "first_response": "FORGET"
    }
  ]
}
```

`generated_at` is UTC. Words are ordered deterministically by Maimemo's study order; identical duplicate `voc_id` entries collapse, while conflicting duplicates stop safely. Use a different local destination with `python3 fetch_words.py --output /safe/local/path/words.json`.

## Ask Codex to generate the article

Keep `forgotten-words.json` local. In Codex, open this repository and ask:

> Follow `recipes/forgotten-words-study-article/PROMPT.md` using `recipes/forgotten-words-study-article/forgotten-words.json`. Write the final Markdown to a new local file. Do not read `MAIMEMO_TOKEN` or call Maimemo.

Before running, edit the four plain-language settings near the top of [`PROMPT.md`](PROMPT.md) to change difficulty, length, topic, or grammar-note count. The workflow makes coverage auditable and reports a word it cannot use naturally instead of silently dropping it.

See the small, entirely synthetic [sample input](examples/sample-forgotten-words.json) and [sample result](examples/sample-study-article.md).

## If there are no forgotten words

The command exits successfully, writes a valid artifact with an empty `words` array, and prints that there is nothing to generate. The prompt then stops without fabricating vocabulary or an article.

## Study API beta caveats

Maimemo documents Study APIs as public beta. To obtain today's list:

- enable automatic sync in Maimemo;
- open the Maimemo app that day so today's study state is initialized;
- expect the API shape or availability to change during beta.

The recipe makes one request with the documented maximum `limit` of 1000, well within the published global limits (20 requests/10 seconds, 40/60 seconds, and 2000/5 hours). It refuses redirects, limits the response to 4 MiB, validates the documented structure, and writes nothing if the response is malformed.

Current documented operation (verified against the [official OpenAPI bundle](https://open.maimemo.com/api_bundle.yaml)):

```text
POST https://open.maimemo.com/open/api/v1/memo/study/get_today_items
body: {"limit": 1000}
```

The official schema does not require `first_response` on every item. The recipe therefore accepts an absent field but does not select that entry. An unknown or wrongly typed response value fails closed.

## Privacy and security model

- `MAIMEMO_TOKEN` is read only from the current process environment, used only for the Authorization header, and never printed or written to disk by the script.
- Redirects are rejected so Authorization stays on the reviewed host.
- The generated JSON contains word spellings and Maimemo vocabulary IDs. Treat it as personal learning data: keep it local, review it before sharing, and delete it when no longer needed.
- The example files are synthetic. Tests use an obviously invalid placeholder and run offline.
- Codex consumes the generated JSON, not the Token. This project pays for or hosts no model and needs no OpenAI API key.
- This is an independent third-party recipe, not an official Maimemo product.

This environment-variable flow is deliberately isolated to this read-only recipe. It does not change the legacy write-capable importer's stricter hidden `getpass` credential contract.

## Troubleshooting

- **`MAIMEMO_TOKEN is missing`** — set it in the same terminal that runs Python. Do not put it in `.env`, a source file, or a command-line argument.
- **HTTP 401/403** — obtain a fresh Token while signed in to the intended account. Never post the Token in a bug report.
- **Empty list when you expected words** — open Maimemo today, enable automatic sync, finish at least one response, wait for sync, and rerun. Only the day's first response `FORGET` qualifies.
- **Malformed JSON/response** — the beta API may have changed. Keep the bad response private; open an Issue with the script error, Python version, date/time/timezone, and reproduction steps, but no Token, Authorization header, response body, vocabulary IDs, or learning records.
- **More than 1000 daily items** — the documented endpoint caps one request at 1000 and exposes no pagination here. This recipe does not bypass that limit; open an Issue to discuss a documented strategy.
- **Network/TLS failure** — verify that `https://open.maimemo.com/` opens normally and that your system clock and Python certificate store are current.

Run the focused offline tests with:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

## Contribute / request a variation

- Open a GitHub Issue for reproducible setup or Study API failures. Remove all credentials and private learning data first.
- Open an Issue to request another selection strategy; describe the documented field and the learning workflow it would help.
- Pull requests that improve safety, tests, prompts, platform instructions, or synthetic examples are welcome.
- If the project is useful, a Star is an optional support signal—not a requirement for anything.
