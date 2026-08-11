# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-12
sourceMainSha=f8a5fcd6e78bf52fa48af311160bb5f089d555f1
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#4
CURRENT_UNIQUE_NEXT=REAL_USE_PAUSE
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

## What is already proven

- interpretation batch CREATE/UPDATE is production-validated on the intended account;
- iOS companion is in real use; iOS Token follows D-016 device-only Keychain policy;
- phrase CREATE core + iPhone UI are merged and production-validated;
- #89 / PR #91 added active-capacity + DELETED-tombstone handling without phrase UPDATE;
- #87 + #92 + #88 final usability shipped in PR #93; fresh Opus review passed;
- merged `main` @ `f8a5fcd6e78bf52fa48af311160bb5f089d555f1` built, installed and launched successfully on the Owner's physical iPhone;
- `墨墨账号 ✓ 已连接` neutral wording is correct on device;
- shared `MBA / BEC / GMAT` tag preference persisted across app termination/relaunch;
- mixed native 3-line + 4-line phrase input parsed correctly on device;
- no-source Preview displayed `SOURCE 未填写`, source-present Preview preserved `Financial Times`, and the selected tag summary displayed correctly;
- final smoke reached `新建 2 / 一致 0 / 阻断 0` with Preview only; no synthetic phrase write was executed;
- first real main-account phrase CREATE canary previously passed exact English/Chinese/source/`PUBLISHED` hard readback and round-tripped `MBA/BEC/GMAT`;
- current merged safety floor remains Preview → explicit approval → fresh preflight → max-one-POST/no-retry → authenticated readback → GET-only uncertain recovery.

## Current route — REAL_USE_PAUSE

No further feature-building step is scheduled.

Use the app for real batches. Re-open engineering only from:

- repeated real friction;
- a safety incident;
- an explicit decision to start external distribution.

The first genuinely wanted 3-line/no-source phrase may naturally validate production handling of empty `origin`. Do not create a synthetic extra write merely for characterization.

## Deferred routes

```text
phrase automatic replacement / phrase UPDATE = DEFER; closed PR #90 remains shelf only
#71 public distribution = DEFER until Owner still wants external users after real-use pause
#72 OAuth/OIDC = DEFER until real external onboarding friction exists
#5 desktop quick lookup = DEFER unless explicitly requested after real-use pause
#7 open-source evidence = passive ledger only
#88 local labels / verified nickname / identity framework = DEFER; neutral wording only is current minimum
separate interpretation/phrase tag profiles = DEFER unless real users need them
```

## Safety boundaries still current

- Preview is not write authorization;
- changed items max one POST; never auto-retry POST;
- dispatched POST gets immediate authenticated readback; uncertain outcome gets GET-only recovery;
- UPDATE targets only explicit authenticated-user records; ambiguity blocks;
- no automatic delete/rollback/replay;
- source/origin equality is hard when the user supplied source; no-source semantics are governed by D-019 / #87;
- unknown/malformed server schema fails closed;
- no new product feature is justified merely because an Issue already exists.

## Maintenance rule

Keep this file to current state, one next step, and live boundaries only. During `REAL_USE_PAUSE`, do not update it for ordinary successful batches; update only when the project re-enters engineering for a real reason.
