# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-04
sourceMainSha=df3f64479493e110df09e1f6e4f4e067e3ba84ee
sourceMainShaIsSnapshotOnly=true

## Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_PRODUCT_VERSION=1.0 (4) uploaded to App Store Connect; Apple processing pending

LAST_COMPLETED_PRODUCT_ISSUE=#105
LAST_MERGED_PR=#176
LAST_MERGE_SHA=df3f64479493e110df09e1f6e4f4e067e3ba84ee
LAST_MERGE_SCOPE=mechanical TestFlight build-number bump 3 -> 4 for app + ShareExtension only

CURRENT_PRIMARY_ISSUE=#71
CURRENT_PRIMARY_GATE=TESTFLIGHT_BUILD_1_0_4_PROCESSING_AND_FIRST_COHORT
CURRENT_RELEASE_GATE_STATUS=UPLOAD_ACCEPTED_PROCESSING_PENDING
CURRENT_BLOCKER=none; Apple delivery accepted exact build 1.0 (4), App Store Connect visibility not yet independently read back
CURRENT_UNIQUE_NEXT=do not re-upload build 4; wait for Apple processing/visibility, then continue #71 first-small-cohort evidence without expanding tester/public-link/App-Review scope unless separately authorized

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=true_until_build4_processing_or_owner_changes_route
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

The accepted capture RC ultimately established:

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

PR #175 corrected only the physical UI-test substrate (`XCUIDevice.shared.press(.home)` was inert on the physical iPhone); no product code/config/lifecycle behavior changed.

Accepted PR #175 evidence:

```text
PR=175
HEAD=0763f9184bd28871010b379306cdb213ef8350e0
MERGE_SHA=5abfe6fbea342f209c5920a162f8c5710cc66748
TARGETED_CAPTURE_UNIT_TESTS=24/0
SIMULATOR_UI=3/0
PHYSICAL_UI=3/0
CAPTURE_SHARE_SHEET_PHYSICAL=PASS
CAPTURE_PENDING_REVIEW_PHYSICAL=PASS
PRODUCT_CODE_CHANGED=no
PRODUCT_CONFIG_CHANGED=no
```

### TestFlight 1.0 (4) release upload

Owner authorized build 4 and TestFlight upload.

PR #176 changed exactly one repository file and only the app/ShareExtension build number:

```text
PR=176
HEAD=5158473776421e1e61d110d65ee78c7d8b8a9c60
MERGE_SHA=df3f64479493e110df09e1f6e4f4e067e3ba84ee
MARKETING_VERSION=1.0
CURRENT_PROJECT_VERSION=4
MAIN_BUNDLE_ID=com.jiripple.xiaoheiniao
EXTENSION_BUNDLE_ID=com.jiripple.xiaoheiniao.ShareExtension
DISTRIBUTION_TEAM=W26LH686PD
```

The exact merged-main archive passed identity validation and was uploaded exactly once after Xcode account re-authentication:

```text
ARCHIVE=PASS
ARCHIVE_IDENTITY=PASS
CLOUD_MANAGED_SIGNING_USED=yes
UPLOAD_DISPATCHED=yes
UPLOAD_ACCEPTED=yes
APPLE_DELIVERY_RECEIPT=d7e3f368-ed80-49e4-b1fc-d093d50d7031
APPLE_DELIVERY_BYTES=1871341
APPLE_PROCESSING_STATUS=Uploaded package is processing
TESTER_GROUP_CHANGED=no
BETA_APP_REVIEW_SUBMITTED=no
APP_STORE_REVIEW_SUBMITTED=no
```

Apple's delivery payload recorded `cfBundleShortVersionString=1.0` and `cfBundleVersion=4`; Xcode did not renumber the build. App Store Connect/TestFlight UI visibility was not independently read back because no already-authenticated first-party UI/API surface was available in the Agent session. This is not a retry signal. Do not re-upload build 4.

## Non-blocking tooling note

`MomoMoreEfficientTests` currently has no repository `DEVELOPMENT_TEAM`, so physical test commands may require a command-line team override. Treat this as non-blocking tooling debt unless it causes recurring real friction.

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
-> capture exact-main physical RC PASS
-> PR #175 merged / #105 closed
-> PR #176 build 3 -> 4 merged
-> exact merged-main archive PASS
-> TestFlight 1.0 (4) upload ACCEPTED
-> Apple processing / build visibility
-> #71 first-small-cohort evidence   <-- CURRENT
```

Planning may continue in parallel, but unrelated implementation remains on hold until build 4 processing is visible or the Owner explicitly changes the route.

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
-> Issue #71 latest release comment
-> PR #176 merged state
-> Issue #105 final capture evidence
-> Issue #164 closed status
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.
