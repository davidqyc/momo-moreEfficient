# Contributing

本项目目前处于 API 验证和早期实现阶段。贡献应优先提高真实可用性、安全性和可验证性，而不是扩大架构。

## Before coding

1. Search existing Issues.
2. For non-trivial work, open or update an Issue describing the user problem, scope, blockers, acceptance criteria, and privacy risks.
3. Wait for scope confirmation when the change affects API writes, content ownership, public behavior, or project architecture.
4. Read `AGENTS.md`, `docs/decision-log.md`, and the relevant product document.

## Running the tests

No dependencies, no build step, standard-library `unittest` only. Always run under the process-level no-network guard:

```bash
MOMO_TEST_NETWORK_DISABLED=1 PYTHONPATH=tests/no_network_guard python3 -m unittest discover -s tests -p 'test_*.py'
```

The guard replaces `socket.socket`, `socket.create_connection` and `urllib.request.urlopen` with raising stubs, so the suite cannot reach the network. A change that needs a real request to pass is a change that needs an Issue first.

## Credential boundary

The CLI accepts a real token only through a hidden interactive `getpass` prompt, held in process memory. Do **not** add loading from argv, environment variables, `.env`, config files, the clipboard, or the OS keychain — see `SECURITY.md` for why this is stricter than the usual convention. A PR that widens this boundary will be rejected without an Issue-level security decision.

## Pull requests

- Keep each PR focused on one Issue or one coherent fix.
- Explain what changed, what did not change, and how it was verified.
- Include tests for parsers, matching, idempotency, and write-safety behavior when applicable.
- Use sanitized fixtures only.
- Do not include real tokens, account data, study exports, or private example content.
- Mark incomplete work as Draft.
- Do not combine unrelated refactors with functional changes.

## API experiments

Public test evidence must be sanitized. A useful report contains:

- endpoint and HTTP method
- request-field names with fake values
- relevant response-field names with fake or redacted values
- observed app behavior
- expected behavior
- conclusion and remaining uncertainty

Never paste an Authorization header or raw private payload.

## Product boundaries

- The project does not modify Maimemo built-in dictionary interpretations.
- Write-capable tools must default to dry-run.
- Phrase/example automation remains blocked until the semantic-position requirements in Issue #2 and Issue #4 are resolved.
- Do not introduce UI automation, cloud infrastructure, a database, or a cross-platform framework without a confirmed need and Issue-level decision.

## Commit messages

Use concise imperative messages with a clear area, for example:

- `feat: add dry-run interpretation planner`
- `fix: stop on ambiguous custom interpretations`
- `test: cover partial batch failure`
- `docs: record phrase highlight experiment`

## License

By contributing, you agree that your contribution will be licensed under the repository's MIT License.
