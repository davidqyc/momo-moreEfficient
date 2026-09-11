# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-09-12
sourceMainSha=f9bbc8d1166ee02158391289bccdd4f094a8785f
sourceMainShaIsSnapshotOnly=true

> Current truth only. Live default branch + current Issue/PR/WIP + latest explicit Owner instruction outrank this snapshot. Historical accepted detail remains in the owning Issues/PRs/git history and should be read only when the current task needs it.

## 1. Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true

CURRENT_PRIMARY_ISSUE=#161
CURRENT_PRIMARY_PR=#177
CURRENT_PRIMARY_PR_HEAD=f3c8f33215d965ff381ee674b1c5668808df7dd2
CURRENT_PRIMARY_PR_STATUS=OPEN_DRAFT_UNMERGED

SELF_ADDED_VOCABULARY_PROVIDER_RESEARCH=CLOSED_FOR_NOW
MORE_PROVIDER_CLARIFICATION=no
MORE_PROVIDER_CANARY=no
MORE_RESOLVER_ROUTE_HUNTING=no
PRIVATE_OR_UNDOCUMENTED_API=no
GUESSED_IDS=no

PROVIDER_LIMITATION_MARKER=COMPLETE_ON_CURRENT_PR_HEAD
PROVIDER_LIMITATION_MARKER_BASE=39f424e7bd0fa9c5d31fb0e6158b4bcbbce7d438
PROVIDER_LIMITATION_MARKER_IMPL_COMMIT=19f4924ca130502a6df107981ed9969fad2fd2ed
ACCESSIBILITY_REPAIR_COMMIT=f3c8f33215d965ff381ee674b1c5668808df7dd2
COORDINATOR_FINAL_ADJUDICATION_COMMENT=5641278587

QUERY_TRUTH_INVARIANT=UNAVAILABLE_NE_0
RESOLVER_TAXONOMY_CHANGED=no
SECOND_RESOLVER_ADDED=no

ACTIVE_EXTERNAL_AGENT=0
CURRENT_EXTERNAL_AGENT_TASK=none
CURRENT_UNIQUE_NEXT=wait for Owner's next concrete real-use bug/usability defect; do not invent a roadmap item or automatically reopen provider research
```

## 2. Provider limitation marker now closed

The Owner obtained direct official-provider confirmation that the currently supported public Maimemo Open API does not provide the stable `voc_id` path required by this app for user self-added/custom vocabulary.

The product response is intentionally narrow:

```text
ordinary public-resolver MISS
!= proof that the spelling is self-added
```

Therefore the app does **not** invent a causal `selfAddedUnsupported` resolver state. Instead it keeps the existing safe MISS / UNAVAILABLE semantics and makes the current public-API capability boundary explicit to the user.

At PR #177 head `f3c8f332...`:

- interpretation Preview maps `VOCABULARY_NOT_FOUND` to an explicit Open API limitation message;
- phrase Preview uses the same truthful message;
- Query `targetNotFound` says the current Open API cannot resolve the entry;
- Query result rows surface the row-level reason inline instead of forcing the user to infer it from repeated generic unavailable cells;
- Query detail explains that unresolved does not prove absence in Maimemo, and conditionally states the self-added-word limitation;
- resolver lookup route, target identity contract and failure taxonomy are unchanged;
- resolver MISS remains `UNAVAILABLE`, never numeric `0`.

## 3. Accessibility correction

The first implementation commit `19f4924...` accidentally carried the normal two-line spelling truncation into the accessibility Dynamic Type layout through a shared helper.

The bounded repair `f3c8f332...` restores the intended split:

```text
normal layout
→ at most 2 spelling lines + middle truncation

accessibility two-tier layout
→ unlimited vertical spelling wrapping
```

The row-level inability reason remains visible in both layouts.

Builder-reported verification for the final repair:

```text
MomoMoreEfficientTests=426/426 PASS
MERGE=no
TESTFLIGHT=no
REAL_MAIMEMO_MUTATION=0
```

Coordinator exact source readback accepted the repair. No separate SwiftUI inspection harness was added because the modifier difference is now explicit in the code and a new private-view harness would be disproportionate for this bounded UI correction.

## 4. Current product route

The provider limitation is no longer the main line.

Owner's current route is:

```text
one real-use defect
→ smallest truthful/safe repair
→ proportionate verification
→ next real-use defect
```

Do not auto-select parked roadmap features merely because they are open. In particular, do not automatically start #155 / #157 / #153 / #152 or resume old provider research without a newer Owner instruction.

The older Capture Gate investigation on PR #177 remains historical unresolved PR context, but it is **not** the automatic current next after the Owner explicitly redirected the project to mark the provider limitation and then fix the next real-world defect. If a future Owner instruction returns to release/capture gating, re-read the live Issue/PR evidence at that time rather than relying on the older state text.

## 5. Stable #161 product baseline

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

Publication remains:

```text
公开=PUBLISHED
未发布=UNPUBLISHED
DO_NOT_LABEL_UNPUBLISHED_AS_PRIVATE=true
PHRASE_OR_NOTE_PUBLICATION_SELECTOR_V1=no
```

Do not reopen these frozen product decisions while repairing unrelated real-use defects.

## 6. Safety / authorization boundaries

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

## 7. External-Agent routing

No Builder/Reviewer/Agent task is currently running.

For the next substantive coding round, JIT-read `docs/AGENT_SKILLS_CONNECTOR.md` and live `davidqyc/agent-skills@main`; do not inherit GLM / Claude / Codex model or reasoning depth mechanically from the last round.

The most recent GLM/ZCode experiment is portfolio routing evidence, not a sticky momo-specific family preference.

## 8. Handoff rule

Fresh Chat takeover should read only:

```text
live main
→ CHAT_HANDOFF.md
→ this file
→ Issue #161 metadata/body
→ exact PR #177 metadata/head
→ Issue #161 comment 5641278587
→ latest explicit Owner instruction
```

Do not fetch the full Issue #161 history during takeover.

If the Owner supplies the next screenshot / bug / usability defect, that becomes the immediate next task. If no new defect has been supplied, stop at this natural checkpoint rather than inventing work.
