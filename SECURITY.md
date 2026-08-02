# Security Policy

## Sensitive data

Do not submit any of the following in commits, issues, pull requests, screenshots, logs, or test fixtures:

- Maimemo access tokens, cookies, refresh credentials, or account identifiers
- Private vocabulary books, full study-history exports, or personal example batches
- Unredacted API requests/responses containing user content
- Private keys, certificates, keychain exports, or `.env` files

Use clearly invalid placeholders in examples. Local credentials must come from environment variables or the operating-system keychain.

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

No production release exists yet. Security support begins with the first public tagged release; until then, the repository is experimental and must not be trusted for unattended bulk writes.
