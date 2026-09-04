# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-04
sourceMainSha=e16e892bbd984d1213bc5815a98a572a1bb49e8a
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (3) external TestFlight beta

LAST_COMPLETED_PRODUCT_ISSUE=#164
CURRENT_PRIMARY_ISSUE=#105
CURRENT_PRIMARY_GATE=PHYSICAL_SHARE_EXTENSION_TO_MAIN_PICKUP_REPAIR
CURRENT_RELEASE_GATE_STATUS=BLOCKED_ON_CAPTURE_SHARE_JOIN
CURRENT_BLOCKER=exact-main physical RC passes build/sign/install/normal launch and direct-seeded pending-review pickup, but CaptureShareSheetUITests fails after real Share Sheet -> extension -> Save: the main app does not surface captureReviewStatus after Home + activate
CURRENT_UNIQUE_NEXT=one bounded diagnostic/repair that first proves extension Save completion/dismissal, then only if that succeeds isolates main foreground pickup; use existing XCUIAutomation and synthetic payloads, no new capture architecture

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true
MACHINE_MIGRATION_HOLD=CLEARED
NEW_MAC_WORKSPACE_READY=yes
OLD_MAC_REPO_RETIREMENT_GATE=PASS
NO_FOURTH_RESOLVER_SURFACE=true
SELF_ADDED_UNRESOLVABLE_POLICY=FAIL_CLOSED_WITH_未读取到可用词条目标
NEXT_TESTFLIGHT_BLOCKED_BY=#105 Share Extension join repair + exact-final-main physical RC rerun + release decision
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

## Exact-final-main physical RC — current failure

Exact RC execution:

```text
LIVE_MAIN_SHA=e16e892bbd984d1213bc5815a98a572a1bb49e8a
RC_EXECUTION_HEAD=e16e892bbd984d1213bc5815a98a572a1bb49e8a
PRODUCT_EQUIVALENCE_FROM_C9C91B3=PASS
PRODUCT_EQUIVALENCE_CHANGED_PATHS=docs/PROJECT_STATE.md only
EXACT_MAIN_BUILD_SIGN=PASS
PHYSICAL_INSTALL=PASS
NORMAL_LAUNCH=PASS
VERSION_BUILD=1.0 (3)
CAPTURE_SHARE_SHEET_UI_TEST=FAIL
CAPTURE_PENDING_REVIEW_UI_TEST=PASS
FINAL_DEVICE_NORMAL_EXACT_MAIN=PASS
REAL_MAIMEMO_MUTATION_PERFORMED=no
IPHONE_MIRRORING_USED=no
TESTFLIGHT_UPLOADED=no
```

Load-bearing physical failure:

```text
real system Share Sheet
-> accessibility-selectable 小黑鸟伴侣 row
-> real Share Extension UI
-> 保存 tap
-> Home
-> main app activate
-> captureReviewStatus missing after 10s
```

This is a release blocker. It is not yet assigned to a final root cause.

### What is already separated by evidence

`CapturePendingReviewUITests` passed physically using a synthetic capture seeded into the real App Group inbox before the initial active transition. From that seed onward it exercises production:

```text
PendingCaptureInbox.consume
-> CaptureReviewForegroundGate.activate
-> CaptureReviewStore
-> ContentView capture-review UI
```

So the main-side consume/render path works under direct seed.

Current `ShareViewController.saveCapture()` performs:

```text
PendingCaptureInbox.appGroup().save(...)
-> only on success: extensionContext.completeRequest(...)
-> on error: keep extension UI visible and show an error
```

The current `CaptureShareSheetUITests` taps Save and immediately presses Home; it does not first assert that the Share Extension actually completed/dismissed. Therefore the present failure does not yet prove whether the defect is extension persistence/signing/runtime App Group access or later host-app pickup/lifecycle sequencing.

## Fresh external decision increment — #105 Share join blocker

Owning Issue comment: `5539035466`.

Fresh Apple first-party facts:

- App Groups provide a shared container for an app extension and host app;
- `XCUIApplication.activate()` is synchronous; on successful return the app is ready for events / running foreground;
- `NSExtensionContext.completeRequest(...)` eventually dismisses the extension view controller.

Decision impact:

```text
DO NOT explain the failure as ordinary shared-container propagation delay
DO NOT explain it as activate() returning before foreground readiness
FIRST split extension Save completion from main pickup
```

Current bounded diagnostic representation:

```text
A. verify signed runtime App Group entitlement/profile identity for main + embedded Share Extension
B. real Share Sheet -> extension -> Save
C. wait for extension completion/dismissal before Home
D1. if extension remains/error -> diagnose extension save/App Group runtime boundary
D2. if extension dismisses -> then Home + activate and diagnose host pickup/lifecycle
```

Use only synthetic payloads and the existing XCUIAutomation target. No coordinates, private Owner content, Maimemo token use, Maimemo mutation, backend, polling framework, second entry mechanism, or iPhone Mirroring.

If simply waiting for extension completion makes the physical test pass, treat it as test sequencing and keep production code unchanged. If a production defect is proven, make the smallest evidence-backed fix and targeted tests.

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
NEW_MAC_WORKSPACE_READY_FOR_164=yes
```

`artifacts/private/` remains local/private and must never be pushed for review or migration.

## Release sequence

```text
#167 merged
-> #168 merged/closed
-> #164 provider-resolution lane closed / Issue completed
-> exact-final-main RC build/install/launch PASS
-> exact-main Share Sheet physical gate FAIL   <-- CURRENT BLOCKER
-> bounded #105 Share-join diagnostic/repair
-> exact-final-main physical RC rerun
-> build-number / TestFlight decision
```

Unrelated backlog remains HOLD until this release blocker is closed.

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
-> Issue #105 body + comment 5539035466 + latest physical RC blocker evidence
-> Issue #164 closed status
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.
