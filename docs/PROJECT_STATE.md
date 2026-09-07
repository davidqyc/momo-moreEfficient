# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-08
sourceMainSha=39b464641910f781173de4deb730f631678f334c
sourceMainShaIsSnapshotOnly=true

> Current truth only. Live default branch + current Issue/PR/WIP + latest explicit Owner instruction outrank this snapshot. Historical accepted detail remains in the owning Issues/PRs/git history and should be read only when the current task needs it.

## 1. Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true

CURRENT_PRIMARY_ISSUE=#161
CURRENT_PRIMARY_PR=#177
CURRENT_PRIMARY_PR_HEAD=4dc2a53522a3b9dd4ec9e88a5b6e295872229734
CURRENT_PRIMARY_PR_STATUS=OPEN_DRAFT_UNMERGED

CONNECTION_LIFECYCLE_REPAIR=COMPLETE_ON_CURRENT_PR_LINE
TEST_ISOLATION_REPAIR=COMPLETE_ON_CURRENT_PR_HEAD
LATEST_TEST_ISOLATION_COMMIT=4dc2a53522a3b9dd4ec9e88a5b6e295872229734
LATEST_TEST_ISOLATION_COMMIT_SCOPE=TEST_ONLY

NORMAL_TESTS_CI=PASS
iOS_CAPTURE_RELEASE_GATE=FAIL
CAPTURE_GATE_RUN_ID=34130642290
CAPTURE_GATE_RERUN_ATTEMPT=2

CURRENT_GATE=CAPTURE_GATE_OBSERVATION_SUBSTRATE_REPAIR
TEST_SUBSTRATE_FAILURE_STRONGLY_SUSPECTED=yes
PRODUCT_REGRESSION_ESTABLISHED=no
PRODUCT_REGRESSION_EXCLUDED=no
CURRENT_UNIQUE_NEXT=release exactly one bounded Capture Gate Test Substrate Repair Builder task after fresh-chat JIT prompt preflight, then adjudicate the returned diff/evidence

ACTIVE_EXTERNAL_AGENT=0
CURRENT_EXTERNAL_AGENT_TASK=none
NEXT_CAPTURE_GATE_TASK_DISPATCHED=no
CURRENT_CAPTURE_GATE_RETURN_BRIDGE=none_until_actual_prompt_release

CURRENT_ROLLOVER_ADJUDICATION_COMMENT=5573587756
PREVIOUS_CI_TRIAGE_COMMENT=5572405173
```

## 2. What is already proven on the current PR line

The latest completed `【XHN】#161 PR177 Test Isolation Repair` changed test isolation only. Its returned evidence was admitted before this rollover:

```text
TARGETED_TESTS=126_PASS
FULL_TEST_SUITE=425_OF_425_PASS
FULL_SUITE_REPEAT_COUNT=5
FULL_SUITE_CRASHES=0
REMOTE_PR_HEAD_PUSHED=yes
PR_REMAINS_DRAFT_OPEN_UNMERGED=yes
```

This closes the shared-`UserDefaults.standard` test-state contamination problem strongly enough to move on. It does **not** make the Capture Release Gate green.

The current capture failure is narrower:

```text
real system Share Sheet opens
→ 小黑鸟伴侣 Share Extension is found
→ extension is tapped
→ UI test then waits for Button "保存"
→ host-app-rooted XCUIApplication never observes that button
→ gate fails
```

The same-head Capture Gate was rerun exactly once and failed again. Ordinary tests remain green.

## 3. Current adjudication of the red Capture Gate

Fresh external increment and rollover adjudication are frozen in Issue #161 comment `5573587756`.

Apple's current app-extension model makes the existing observation route structurally suspect: the extension is invoked through extension context / separate extension execution, while the current gate continues querying the host-app `XCUIApplication` after entering the Share Extension.

Therefore current classification is deliberately narrower than the prior Chat's wording:

```text
TEST_SUBSTRATE_FAILURE_STRONGLY_SUSPECTED=yes
PRODUCT_REGRESSION_ESTABLISHED=no
PRODUCT_REGRESSION_EXCLUDED=no
```

Do **not** mutate production code merely to make the gate green. First reproduce/classify the extension observation boundary. Production code may be touched only if direct evidence establishes a product defect.

The latest isolation commit being test-only is useful scope evidence, but it is not by itself causal proof: the last known-green Capture Gate predates both the preceding connection-lifecycle production repair and the isolation commit.

## 4. Next Builder contract shape

The next task is one bounded Builder round:

```text
TASK_CLASS=CAPTURE_GATE_TEST_SUBSTRATE_REPAIR
PRIMARY_SCOPE=UI_TEST / TEST_OBSERVATION_SUBSTRATE
REPRODUCE_AND_CLASSIFY_BEFORE_MUTATION=yes
PREFER_PROVIDER_NATIVE_XCUITEST_OBSERVATION=yes
MINIMUM_SAFE_TEST_HOOK_ONLY_IF_NEEDED=yes
PRODUCTION_CODE=only_if_direct_product_defect_is_proven
MERGE=no
```

The repair must preserve the original release proof chain:

```text
real system Share Sheet
→ actual 小黑鸟伴侣 Share Extension
→ deterministic text saved through the extension
→ main app receives the real result
→ Capture Review appears
→ exact payload equality proven
```

Forbidden shortcut:

```text
make CI green by bypassing the real Share Sheet / actual Share Extension / post-save main-app exact-payload proof
```

### External-Agent routing

```text
LAST_OWNER_SELECTED_AGENT_FAMILY=Claude
NEXT_TASK_AGENT_FAMILY=Claude_unless_hard_current_constraint_requires_switch
MODEL_EFFORT_SPEED_TOPOLOGY=JIT_UNRESOLVED
TARGET_WORKSPACE_CONTINUITY=/Users/david/Documents/GitHub/momo-moreEfficient
```

Fresh Chat must live-read current `agent-skills` before release, prove workspace identity/freshness, establish exactly one Return Bridge, and return one Owner-relay dispatch. Do not inherit a previous Claude model/effort mechanically.

## 5. Product-value route after the gate

If the repaired candidate restores a green Capture Release Gate without weakening the proof:

```text
PR_177_CANDIDATE_CONFIRMED_FOR_DEVICE_USE
→ Development install to Owner iPhone
→ Owner real-use smoke / daily use
→ later merge/release decisions from actual evidence
```

Do not let low-value deferred evidence block this device-use step:

```text
D-03=DEFERRED_LOW_PRIORITY
UNPUBLISHED_REAL_ACCOUNT_EVIDENCE=NOT_A_BLOCKER_FOR_DEVELOPMENT_INSTALL
```

The current route does **not** require iPhone Mirroring. If a future task ever proposes Mirroring, notify Owner before launching it and re-evaluate whether a shorter manual check is cheaper.

## 6. Stable safety / non-authorization boundaries

```text
MERGE_AUTHORIZED_BY_THIS_STATE=false
TESTFLIGHT_NEW_UPLOAD_AUTHORIZED=false
TESTFLIGHT_BUILD4_REUPLOAD_FORBIDDEN=true
REAL_MAIMEMO_WRITE_AUTHORIZED=false
TOKEN_READ_AUTHORIZED=false
IPHONE_MIRRORING_AUTHORIZED=false
AUTOMATION_AUTHORIZED=false
MONITORING_AUTHORIZED=false
```

Stable product write floor remains:

- Preview is not write authorization;
- explicit approval before mutation;
- fresh authenticated preflight when stale state could change the write target;
- each changed item gets at most one mutating POST;
- no automatic mutating-POST retry;
- authenticated readback after dispatch;
- uncertain mutation recovery is GET-only;
- UPDATE requires an explicit authenticated-user target;
- no automatic delete/rollback/replay;
- personal Maimemo Token and private batch material stay device-local and out of Git/logs/review artifacts;
- 429 is a stop/rate-limit signal, not permission to replay a mutation.

## 7. Accepted historical anchors still relevant

### Capture / Share baseline

Issue #105 previously closed the original capture workflow with a real system Share Sheet and Share Extension physical gate. That historical proof remains relevant as a baseline, but it does not override the current failing PR #177 Capture Release Gate.

### TestFlight build 4

TestFlight `1.0 (4)` was uploaded and accepted previously. Do not re-upload build 4 merely because PR #177 is under repair.

### #161 Design/product baseline

The accepted #161 product shape remains:

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

Publication preference remains interpretations-only:

```text
公开=PUBLISHED
未发布=UNPUBLISHED
DO_NOT_LABEL_UNPUBLISHED_AS_PRIVATE=true
PHRASE_OR_NOTE_PUBLICATION_SELECTOR_V1=no
```

Do not reopen these during the Capture Gate repair.

## 8. Active sequence

```text
#161 / PR #177:
implementation
→ connection-lifecycle repair
→ test-isolation repair at 4dc2a535... PASS
→ normal tests green
→ Capture Release Gate red after one same-head rerun
→ bounded Capture Gate Test Substrate Repair   <-- CURRENT
→ Coordinator exact-diff/evidence adjudication
→ green Capture Gate
→ Development install to Owner iPhone
→ real-use evidence
```

No new Builder/Reviewer/Agent task is currently running at this snapshot.

## 9. Handoff rule

Fresh Chat takeover should read only:

```text
live main
→ CHAT_HANDOFF.md
→ this file
→ Issue #161 metadata/body
→ exact PR #177 metadata/head
→ Issue #161 comment 5573587756
→ Issue #161 comment 5572405173 only if CI-history context is needed
→ live Owner collaboration preferences
→ live fresh-chat preference application policy
→ latest explicit Owner instruction
```

Do not fetch the full Issue #161 history during takeover.

After takeover, if live evidence is unchanged, do **not** wait for another procedural `继续`: JIT-read the applicable prompt-release/workspace/model/Return-Bridge Skills and prepare/release exactly one bounded Capture Gate Test Substrate Repair task. Stop at that dispatch checkpoint and wait for its returned result.
