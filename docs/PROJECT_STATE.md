# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-12
sourceMainSha=0541c239acfa6d2585f3fc8eaeed9a00646c718b
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#87
CURRENT_UNIQUE_NEXT=NATIVE_FOUR_LINE_PHRASE_INPUT_PLUS_NEUTRAL_ACCOUNT_WORDING
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE is production-validated on the intended account;
- iOS companion is in real use; iOS Token follows D-016 device-only Keychain policy;
- phrase CREATE core + iPhone UI are merged and production-validated;
- first real main-account phrase CREATE canary passed exact English/Chinese/source/`PUBLISHED` hard readback; current run also round-tripped `MBA/BEC/GMAT`;
- Maimemo App visually highlighted the English target although Open API readback did not return highlight; Chinese semantic range remains manual/unavailable through documented writable API;
- #89 / PR #91 merged as `0541c239acfa6d2585f3fc8eaeed9a00646c718b`: only `PUBLISHED` phrases count active, `DELETED` tombstones do not consume capacity or block re-creation, 5 active phrases block another CREATE with a manual fallback, and >5 fails closed;
- current merged safety floor remains Preview → explicit approval → fresh preflight → max-one-POST/no-retry → authenticated readback → GET-only uncertain recovery.

## Lightweight architecture reset

Owner accepted the 2026-08-12 fresh Fable 5 audit and Coordinator adjudication:

- current merged app stays mostly as-is; no broad refactor;
- low-frequency edge cases with cheap manual fallback default to guard/defer, not complete automation;
- scope subtraction is preferred over generic abstraction;
- review/rehearsal/evidence strength must match realistic risk;
- real use should interrupt feature accumulation when it is more informative than the next hypothetical feature.

Durable routing lives in `AGENTS.md`, `docs/CODEX_REASONING_DEPTH_POLICY.md`, `docs/AGENT_SKILLS_CONNECTOR.md`, and `davidqyc/agent-skills`; do not duplicate those rules here.

## Current primary — #87

Accept the Owner's native phrase paste format directly:

```text
spelling
English sentence
Chinese translation
source/origin
```

Keep the existing strict labeled grammar for backward compatibility, but the Owner must not have to add `##`, `EN:`, `ZH:` or `SOURCE:` for ordinary use.

In the same small UI-touching round, complete the minimum #88 correction:

```text
主账号 -> 墨墨账号
```

Do not build nickname/profile fetching, local account labels, OAuth/OIDC, account switching, or identity frameworks in this round.

After #87 + the neutral account wording reach the Owner's iPhone, pause feature work and use the app for real batches. Re-open engineering from repeated real friction, a safety incident, or an explicit external-distribution decision.

## Deferred routes

```text
phrase automatic replacement / phrase UPDATE = DEFER; closed PR #90 remains shelf only
#71 public distribution = DEFER until Owner still wants external users after real-use pause
#72 OAuth/OIDC = DEFER until real external onboarding friction exists
#5 desktop quick lookup = DROP UNLESS REQUESTED
#7 open-source evidence = passive ledger only
#88 local labels / verified nickname = DEFER; neutral wording only is current minimum
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

Keep this file to current state, one next step, and live boundaries only. Update it at real merged milestones, preferably inside the same product PR; do not create standalone chronology commits between micro-steps.
