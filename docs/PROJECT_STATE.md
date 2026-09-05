# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-05
sourceMainSha=a5706e1206ec632d6684b094761168da09b465ed
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

CURRENT_PRIMARY_ISSUE=#161
CURRENT_PRIMARY_GATE=FINAL_DESIGN_HANDOFF_ACCEPTED_READY_FOR_CLAUDE_CODE
CURRENT_RELEASE_GATE_STATUS=UPLOAD_ACCEPTED_PROCESSING_PENDING_IN_PARALLEL
CURRENT_BLOCKER=none; #161 final Design handoff accepted with Coordinator implementation corrections; TestFlight build 4 remains an independent passive processing/readback lane and must not be re-uploaded
CURRENT_UNIQUE_NEXT=use Claude Design -> Claude Code native handoff to implement #161 from live main on an Issue branch, preserving the accepted Home/Settings/neutral Query/Contextual History/Capture design and stable write-safety floor

IMPLEMENTATION_HOLD_FOR_UNRELATED_FEATURES=cleared_for_#161_by_owner_explicit_workflow_after_design_gate
TESTFLIGHT_BUILD4_REUPLOAD_FORBIDDEN=true
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

### #161 — final Design handoff accepted

Owner-approved Design baseline:

```text
HOME=首页乙
VISUAL_FAMILY=方案一「墨与米」
SETTINGS_OWNS_ACCOUNT_MANAGEMENT=yes
WORK_SURFACE_ACCOUNT_COPY=连接状态
CONTEXTUAL_HISTORY=释义历史 / 例句历史
QUERY_MODEL=neutral numeric 释义/例句/助记 status inspector
QUERY_FILTER=user-composed AND predicates
QUERY_HISTORY_V1=no
CAPTURE_DIRECT_DESTINATIONS=转到释义编辑 / 转到例句编辑
```

Final Design handoff package was mechanically verified by the Coordinator:

```text
ZIP_INTEGRITY=PASS
MANIFEST_HASH_AND_BYTE_MATCH=PASS
UNIQUE_TRANSITION_IDS=136
DUPLICATE_TRANSITION_IDS=0
INTERACTION_COVERAGE=PASS
```

Coordinator implementation corrections before Code:

```text
1. write mode is state inside one write destination; do not encode the current 释义/例句 mode as persistent NavigationStack route identity. Home/Capture set the initial/current ContentMode, then navigate to one write destination. Contextual History may still carry ContentMode.
2. Query detail v1 does not require created/updated timestamps unless a current first-party schema is explicitly verified for the corresponding list resource. Stable required fields remain the current proven text/tags/status/origin/type-style fields. Do not expand transport decoding merely to satisfy an optional timestamp line.
```

Publication preference is approved only for interpretations:

```text
公开=PUBLISHED
未发布=UNPUBLISHED
DO_NOT_LABEL_UNPUBLISHED_AS_PRIVATE=true
PHRASE_OR_NOTE_PUBLICATION_SELECTOR_V1=no
```

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

## Active sequence

```text
TestFlight 1.0 (4) upload ACCEPTED
-> Apple processing / first-small-cohort readback remains passive parallel lane; never re-upload build 4

#161 product lane:
final Design handoff PASS
-> Claude Design -> Claude Code native handoff   <-- CURRENT
-> implementation branch / Draft PR
-> proportional tests + required fresh review for publication/readback semantic change
-> Coordinator adjudication
-> merge / physical smoke only where risk warrants
```

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
-> Issue #161 latest Design/code-handoff comments
-> Issue #71 latest release status only when release work resumes
-> live Owner collaboration preferences
-> live agent-skills JIT routing only when dispatching
-> latest explicit Owner instruction
```

Do not fetch full historical Issue threads merely to reconstruct current truth.
