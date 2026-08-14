# Security Policy

## Sensitive data

Do not submit any of the following in commits, issues, pull requests, screenshots, logs, or test fixtures:

- Maimemo access tokens, cookies, refresh credentials, or account identifiers
- Private vocabulary books, full study-history exports, or personal example batches
- Unredacted API requests/responses containing user content
- Private keys, certificates, keychain exports, or `.env` files

Use clearly invalid placeholders in examples.

## How this project accepts a credential

The legacy write-capable CLI accepts a real Maimemo token through **one** channel only: a hidden interactive `getpass` prompt. The token is held in process memory for the duration of the run and is never persisted.

The following are deliberately **not** supported by any write-capable path, and must not be added without an Issue-level security decision:

- command-line arguments / argv (`--token` is rejected, and argument values are never echoed);
- environment variables;
- `.env` or any dotfile;
- configuration files;
- clipboard automation;
- the operating-system keychain (out of scope for v0.1.0).

This is stricter than a general "load secrets from the environment" rule, and it is intentional: an environment variable or `.env` file survives the process, leaks into shell history, subprocess environments, crash dumps and CI logs, whereas a `getpass` prompt does not. Do not relax this boundary to match a more conventional convention.

Issue #107 authorizes one narrow exception: `recipes/forgotten-words-study-article/` makes one documented, semantically read-only Study request and reads `MAIMEMO_TOKEN` from the current session environment. Its documented hidden-input setup keeps the value out of shell history and unsets it after the command. The recipe never supports argv, `.env`, config files, persistence, redirects, or any mutation endpoint. This exception does not change the credential contract of the legacy importer, macOS UI, iOS app, or any present or future write path.

A token, `Authorization` header, cookie, account label, raw `voc_id`, raw record id or raw server response must never reach Git, logs, previews, run reports, or review bundles. Only a non-sensitive 16-hex SHA-256 fingerprint of the token is ever displayed.

## Reporting a vulnerability

Do not open a public issue containing an exploitable vulnerability, credential, or private user content. Contact the maintainer privately through the GitHub profile or GitHub private vulnerability reporting when it is enabled. Include the minimum information needed to reproduce the problem and redact all personal data.

## If a credential is exposed

1. Stop using it immediately.
2. Revoke or rotate it at the provider.
3. Preserve enough local evidence to understand the exposure without copying the secret into an issue.
4. Remove it from the current tree and assess whether Git history must be rewritten.
5. Treat a secret as compromised even if a later commit deletes it.

## Write-safety issues

The following are security-impacting defects for this project:

- A command writes when it claims to be in dry-run mode.
- A retry creates duplicate content or updates the wrong record.
- Built-in dictionary content can be modified by a user-content workflow.
- A batch continues destructive updates after an ambiguous match or partial failure.
- Logs expose tokens or private vocabulary content.

Such defects should block release until resolved or explicitly disabled.

## Supported versions

`v0.1.0` is being prepared as the first public release. Until it is tagged, no released version exists and security support is best-effort.

Regardless of version, this tool must not be trusted for unattended bulk writes: every write path requires an interactive terminal and an explicit batch-level confirmation by design.
