# Legacy CLI v0.1.0

> Historical/reference documentation for the original command-line importer. New users should start from the root [`README.md`](../README.md) and the iPhone TestFlight instead.

`v0.1.0` was the first public slice of this project. Its supported product interface had one job: **safely import a batch of already-written custom interpretations into Maimemo**.

It is kept for reproducibility, engineering history, and users who still need the CLI. It is not the recommended entry point for the current project.

## What it does

- parses one Markdown batch format;
- `dry-run` previews each item with zero POST requests;
- `create` creates a user-owned custom interpretation;
- `update` replaces the one unambiguous custom interpretation owned by the authenticated account;
- uses fixed tags `MBA`, `BEC`, `GMAT` and state `PUBLISHED`;
- sends at most one POST per changed item and never retries a POST;
- performs authenticated readback after each dispatched write;
- writes a local redacted run report under Git-ignored `artifacts/private/`.

The importer does **not** rewrite, polish, translate, or summarize the interpretation body supplied by the user.

## Requirements

- Python **3.13**;
- Python standard library only;
- an interactive terminal;
- a Maimemo Open API Token entered through hidden interactive input.

The CLI intentionally does not accept the Token from argv, environment variables, `.env`, config files, clipboard automation, or Keychain.

## Input format

```markdown
## <spelling>
<interpretation body>
```

Synthetic example:

```markdown
## amortization
n. 摊销；分期偿还

## covenant
n. 契约条款；（贷款协议中的）限制性条款
```

See [`examples/sample-batch.md`](../examples/sample-batch.md).

## Basic commands

### Preview only

```bash
python3 scripts/interpretation_batch_importer.py \
  --mode dry-run \
  --input examples/sample-batch.md \
  --account-label "secondary-test" \
  --allow-network
```

`dry-run` performs GET-only preflight and sends **0 POST** requests.

### Create

```bash
python3 scripts/interpretation_batch_importer.py \
  --mode create \
  --input examples/sample-batch.md \
  --account-label "secondary-test" \
  --allow-network
```

### Update

```bash
python3 scripts/interpretation_batch_importer.py \
  --mode update \
  --input examples/sample-batch.md \
  --account-label "secondary-test" \
  --allow-network
```

## Main-account opt-in

Main-account use is deliberately harder to enter. It requires both:

1. `--allow-main-account`;
2. an accepted main-account label such as `主账号` or `main-account`.

```bash
python3 scripts/interpretation_batch_importer.py \
  --mode <dry-run|create|update> \
  --input batch.md \
  --account-label "主账号" \
  --allow-main-account \
  --allow-network
```

The Maimemo Open API does not provide a reliable account-identity endpoint for this importer, so the operator must verify that the Token was obtained while logged into the intended account.

## Preflight states

| State | Meaning |
| --- | --- |
| `READY_CREATE` | no custom interpretation exists; create is eligible |
| `READY_UPDATE` | exactly one authenticated-user record exists and differs from target |
| `ALREADY_MATCHING` | target state already exists; no POST |
| `BLOCK_EXISTING` | create would collide with an existing custom interpretation |
| `BLOCK_MISSING` | update has no target record |
| `BLOCK_AMBIGUOUS` | multiple candidate records; tool refuses to choose |
| `BLOCK_ERROR` | transport / HTTP / structural validation failure |

Any `BLOCK_*` aborts the batch before the first POST.

## Safety contract

- Preview is not write authorization.
- Confirmation is bound to the exact batch and operation.
- Every changed item gets at most one POST.
- POST is never automatically retried.
- Each dispatched write is followed by authenticated GET readback.
- Unknown POST outcomes use GET-only recovery; the tool does not resend.
- No DELETE / automatic rollback / automatic replay path exists.
- Only explicit authenticated-user custom records are eligible for update; ambiguity blocks.

## Unsupported / historical surfaces

The other files under `scripts/` include historical API probes and diagnostics. They are **internal / unsupported** and should not be treated as product commands. In particular, old phrase probes may have real network capability; their presence does not mean phrase automation was supported in `v0.1.0`.

The later macOS local UI work tracked under [Issue #54](https://github.com/davidqyc/momo-moreEfficient/issues/54) was an unreleased development path, not the `v0.1.0` public interface.

## Tests

```bash
MOMO_TEST_NETWORK_DISABLED=1 \
PYTHONPATH=tests/no_network_guard \
python3 -m unittest discover -s tests -p 'test_*.py'
```

The test guard replaces socket / connection / urllib network paths with throwing stubs so the suite cannot make real network requests.

## Historical source

For the exact repository state associated with the original release, use the [`v0.1.0` tag](https://github.com/davidqyc/momo-moreEfficient/tree/v0.1.0).

Current product behavior and current release status are defined by live `main`, current Issues/PRs, and the root [`README.md`](../README.md), not by this legacy guide.
