# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-12
sourceMainSha=f61adf88a68af7a2c2e9f626dc460cb102314bf0
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#89
CURRENT_UNIQUE_NEXT=REDUCED_CAPACITY_GUARD_AND_DELETED_FIX
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE is production-validated on the intended account;
- iOS companion is in real use; iOS Token follows D-016 device-only Keychain policy;
- phrase CREATE core + iPhone UI are merged and production-validated;
- first real main-account phrase CREATE canary passed exact English/Chinese/source/`PUBLISHED` hard readback; current run also round-tripped `MBA/BEC/GMAT`;
- Maimemo App visually highlighted the English target although Open API readback did not return highlight; Chinese semantic range remains manual/unavailable through documented writable API;
- current merged safety floor remains Preview → explicit approval → fresh preflight → max-one-POST/no-retry → authenticated readback → GET-only uncertain recovery.

## Architecture reset — 2026-08-12

Owner accepted a fresh Fable 5 architecture/governance audit and Coordinator adjudication:

- current merged app = keep mostly as-is; no broad refactor;
- engineering/governance had begun to drift overweight;
- low-frequency edge cases with cheap manual fallback default to guard/defer, not complete automation;
- scope subtraction is preferred over generic abstraction;
- review/rehearsal/evidence strength must match realistic risk;
- real use should interrupt feature accumulation when it is more informative than the next hypothetical feature.

`AGENTS.md`, `docs/CODEX_REASONING_DEPTH_POLICY.md`, `docs/AGENT_SKILLS_CONNECTOR.md`, and `davidqyc/agent-skills` carry the durable routing rules. Do not duplicate them here.

## Current primary — #89

#89 is reduced to **phrase CREATE capacity guard + DELETED tombstone handling**.

Required behavior:

```text
exact active hard match -> ALREADY_MATCHING / 0 POST
0-4 active, no active same-English conflict -> current CREATE
5 active -> BLOCKED / 0 POST / tell user to edit or delete one old phrase in Maimemo and Preview again
>5 active -> BLOCKED / server-rule mismatch
DELETED -> not active, not capacity, not same-English CREATE conflict
```

Closed PR #90 (`b65e21e...`) is intentionally **unmerged** and preserved only as a shelf. Automatic phrase replacement/UPDATE is deferred until real usage proves it is worth reviving.

#89 is a block-only guard + existing CREATE correctness fix. It does **not** require fresh independent review, replacement rehearsal, or any real phrase UPDATE.

## Next after #89

1. #87 — accept Owner-native four-line phrase paste format;
2. implement the minimal #88 correction in the same UI-touching round: change static `主账号` wording to neutral `墨墨账号`; optional local labels / nickname/OAuth are deferred;
3. then pause feature work and use the app for several real batches. Re-open engineering from repeated real friction, a safety incident, or an explicit decision to start external distribution.

## Deferred routes

```text
#71 public distribution = DEFER until Owner still wants external users after real-use pause
#72 OAuth/OIDC = DEFER until real external onboarding friction exists
#5 desktop quick lookup = DROP UNLESS REQUESTED
#7 open-source evidence = passive ledger only
#88 local account labels / verified nickname = DEFER; neutral wording only is current minimum
phrase automatic replacement = DEFER; closed #90 branch is shelf only
```

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST; never auto-retry POST;
- dispatched POST gets immediate authenticated readback; uncertain outcome gets GET-only recovery;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- source/origin mismatch remains hard failure; structurally-valid tags/highlight differences remain observations;
- unknown/malformed server schema fails closed;
- no new product feature is justified merely because an Issue already exists.

## Maintenance rule

Keep this file to current state, one next step, and live boundaries only. Update it at real merged milestones, preferably inside the same product PR; do not create standalone `docs: advance...` chronology commits between micro-steps.
