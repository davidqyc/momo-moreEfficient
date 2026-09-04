# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-04
sourceMainSha=5abfe6fbea342f209c5920a162f8c5710cc66748
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta

LAST_COMPLETED_PRODUCT_ISSUE=#105
LAST_MERGED_PR=#175
LAST_MERGE_SHA=5abfe6fbea342f209c5920a162f8c5710cc66748
LAST_MERGE_SCOPE=UI-test-only physical Share-join gate correction; no production code/config change

CURRENT_PRIMARY_ISSUE=none
CURRENT_PRIMARY_GATE=BUILD_NUMBER_TESTFLIGHT_RELEASE_DECISION
CURRENT_RELEASE_GATE_STATUS=PHYSICAL_RC_PASS_READY_FOR_RELEASE_DECISION
CURRENT_BLOCKER=none
CURRENT_UNIQUE_NEXT=make the build-number / TestFlight release decision from live release authority; do not reopen #164 or #105 unless new evidence materially changes the accepted behavior

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true_until_release_decision
MACHINE_MIGRATION_HOLD=CLEARED
NEW_MAC_WORKSPACE_READY=yes
OLD_MAC_REPO_RETIREMENT_GATE=PASS
NO_FOURTH_RESOLVER_SURFACE=true
SELF_ADDED_UNRESOLVABLE_POLICY=FAIL_CLOSED_WITH_未读取到可用词条目标
```

## Accepted shipping baseline

### #167 — batch vocabulary / parser

Merged at `25e5cd85ea8f436cc66b41e49d6313547b0a6148`.

- public batch vocabulary query is the normal resolver;
- query POST is read-semantic;
- no artificial fixed 30-item total cap;
- interpretation and phrase inputs accept unambiguous batches with or without blank lines;
- bounded input/content safety remains.

### #168 — aggregate-window scheduler

Merged through PR #172 at `bc03ee03e06bfa23a160e2599bebc9db34635812`.

- no blanket 1.6s read floor;
- `20/10s`, `40/60s`, `2000/5h` enforced with `ContinuousClock` semantics;
- sequential reads/writes, no mutating retry, mandatory post-POST readback preserved.

Accepted automated evidence: `315 executed / 4 skipped / 0 failures`.

### #164 — completed with provider visibility limit

Issue #164 is closed completed.

Real physical evidence exhausted the bounded first-party public target-resolution surfaces for the Owner's self-added item:

```text
POST /open/api/v1/vocabulary/query          -> no safe target
GET  /open/api/v1/vocabulary?spelling=...   -> no safe target
POST /open/api/v1/study/query_study_records -> no safe target after bounded sync settling
```

PR #173 and PR #174 were both closed unmerged. No fourth resolver, private endpoint, or guessed id is allowed. Items without a safe public target remain fail-closed with `未读取到可用词条目标`.

### #105 — capture workflow completed

Issue #105 is closed completed after the final physical release gate.

The first exact-main RC on `e16e892bbd984d1213bc5815a98a572a1bb49e8a` established:

```text
BUILD_SIGN=PASS
PHYSICAL_INSTALL=PASS
NORMAL_LAUNCH=PASS
VERSION_BUILD=1.0 (3)
CAPTURE_PENDING_REVIEW_UI_TEST=PASS
CAPTURE_SHARE_SHEET_UI_TEST=initially FAIL
FINAL_DEVICE_NORMAL_EXACT_MAIN=PASS
REAL_MAIMEMO_MUTATION_PERFORMED=no
IPHONE_MIRRORING_USED=no
```

The initial Share Sheet failure was then proven to be a **test-substrate mismatch**, not a product capture defect.

Physical diagnosis on PR #175 established:

```text
SIGNED_MAIN_APP_GROUP=PASS
SIGNED_EXTENSION_APP_GROUP=PASS
EXTENSION_SAVE_COMPLETION_PROVEN=PASS
ROOT_CAUSE_CLASS=TEST_SUBSTRATE_MISMATCH
ROOT_CAUSE=XCUIDevice.shared.press(.home) was inert on the physical iPhone, so the app never left runningForeground and the scenePhase-driven pickup was never asked to run
```

The repair changed exactly one UI-test file:

```text
ios/MomoMoreEfficientUITests/CaptureShareSheetUITests.swift
```

It now:

- waits for the real Share Extension to complete/dismiss before testing host pickup;
- uses SpringBoard activation to create the required physical-device background transition instead of assuming the Home-button primitive worked;
- explicitly waits for the app to leave foreground;
- reactivates the app and asserts foreground state;
- verifies the exact synthetic payload reaches `抓词 · 尚未预览`.

No product code, App Group configuration, signing configuration, lifecycle implementation, credential handling, or Maimemo behavior changed.

Accepted PR #175 evidence:

```text
PR=175
HEAD=0763f9184bd28871010b379306cdb213ef8350e0
MERGE_SHA=5abfe6fbea342f209c5920a162f8c5710cc66748
MERGE_METHOD=squash
TARGETED_CAPTURE_UNIT_TESTS=24/0
SIMULATOR_UI=3/0
PHYSICAL_UI=3/0
CAPTURE_SHARE_SHEET_PHYSICAL=PASS
CAPTURE_PENDING_REVIEW_PHYSICAL=PASS
PRODUCT_CODE_CHANGED=no
PRODUCT_CONFIG_CHANGED=no
UI_TEST_ONLY_CHANGED=yes
REAL_MAIMEMO_MUTATION_PERFORMED=no
IPHONE_MIRRORING_USED=no
```

Because PR #175 changes only the UI-test target, the installed physical product candidate and merged-main production source/config are equivalent. Another private vocabulary canary or another product reinstall is not required merely because the merge commit contains the corrected test source.

Owning evidence:

```text
INITIAL_CAPTURE_RC_BLOCKER_COMMENT=5539035466
PR175_EXTERNAL_INCREMENT_COMMENT=5539653860
PR175_FINAL_ADJUDICATION_COMMENT=5539690037
```

Fresh Apple decision fact used for adjudication:

- `XCUIApplication.activate()` is synchronous and returns when the app is ready to handle events;
- `XCUIApplication.state` is system-monitored and successful `activate()` / `launch()` guarantees `runningForeground`.

This makes the corrected state-based lifecycle assertions load-bearing evidence instead of an unchecked button-press assumption.

## Release gate status

The capture-enabled production tree has now passed the proportional exact-final physical release candidate evidence required by the project:

```text
PRODUCT_BUILD_SIGN=PASS
PHYSICAL_INSTALL_LAUNCH=PASS
NORMAL_MODE=PASS
SHARE_EXTENSION_REAL_SAVE=PASS
APP_GROUP_RUNTIME_IDENTITY=PASS
MAIN_PENDING_CAPTURE_PICKUP=PASS
REAL_SYSTEM_SHARE_SHEET_ROUTE=PASS
NO_REAL_MAIMEMO_MUTATION_DURING_RC=PASS
```

The final merge after the physical pass is UI-test-only; production source/config remained unchanged. Therefore the next decision is release mechanics, not another product-debugging or Owner-smoke loop.

## Non-blocking tooling note

`MomoMoreEfficientTests` currently has no repository `DEVELOPMENT_TEAM`, so physical test commands may require a command-line team override. PR #175 deliberately did not change this because it is a test-signing convenience, not the capture product defect.

Treat this as non-blocking tooling debt. Do not create a new engineering lane unless it causes recurring real friction or blocks the release workflow.

## Machine migration — closed

```text
WORKSPACE_ROOT=/Users/david/Documents/GitHub/momo-moreEfficient
REPOSITORY_IDENTITY=davidqyc/momo-moreEfficient
MIGRATED_PRIVATE_DIRECTORY_PRESENT=yes
MIGRATED_PRIVATE_FILE_COUNT=11
MIGRATED_PRIVATE_LOGICAL_BYTES=44083
MIGRATED_PRIVATE_DU_SIZE=68K
PRIVATE_CONTENT_OPENED=no
PRIVATE_CONTENT_PUBLISHED=no
PRIVATE_DIRECTORY_GITIGNORED=yes
OLD_MAC_REPO_RETIREMENT_GATE=PASS
NEW_MAC_WORKSPACE_READY=yes
```

`artifacts/private/` remains local/private and must never be pushed for review or migration.

## Release sequence

```text
#167 merged
-> #168 merged/closed
-> #164 provider-resolution lane closed / Issue completed
-> exact-main build/install/launch PASS
-> initial Share Sheet physical gate false-blocked on inert XCUIDevice Home primitive
-> PR #175 isolated test-substrate mismatch
-> corrected Share Sheet physical gate PASS 3/3
-> PR #175 merged / #105 closed
-> build-number / TestFlight release decision   <-- CURRENT
```

Unrelated backlog remains HOLD until the release decision is made.

## Stable safety boundaries

- Preview is not write authorization;
- explicit approval before mutation;
- fresh authenticated preflight when stale state could change the write target;
- each changed item gets at most one mutating POST;
- no automatic mutating-POST retry;
- authenticated readback after dispatched mutation;
- uncertain mutation recovery is GET-only;
- UPDATE requires an explicit authenticated-user target;
- no automatic delete/rollback/replay;
- vocabulary-query POST is read-semantic;
- personal Maimemo Token and private batch material stay device-local and must not enter Git/logs/review artifacts;
- 429 is a stop/rate-limit signal, not permission to replay a mutation.

## Agent-family routing

Agent family is not sticky. Follow the latest Owner-selected family for the active lane unless the Owner announces a switch or a hard current task/tool constraint requires another family. Re-resolve model / effort / speed / topology from live `agent-skills` for every formal dispatch.

## Handoff rule

Fresh Chat takeover should read:

```text
CHAT_HANDOFF.md
-> this file
-> Issue #105 final comment 5539690037
-> PR #175 merged state
-> Issue #164 closed status
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.
