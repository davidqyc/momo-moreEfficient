# 高级别真实调试与 Dogfood 证据台账

status=CANONICAL_PROJECT_EVIDENCE
updatedAt=2026-09-30
scope=momo-moreEfficient
sourceCandidate=e9ff0ca5767011c904d95a7b507916aa962a0a04
owningGate=#183

## 1. 目的

本文件保存**已经真实跑过、代价较高、以后可以复用**的真机调试 / Dogfood 证据。

目标不是把测试结果堆成日志，而是回答未来版本最重要的三个问题：

1. 这个机制以前有没有在真实 iPhone + 真实墨墨网络 + 真实数据库上跑通过？
2. 哪些代码 / provider 语义一旦变化，才需要重新跑？
3. 如果只改了无关功能，哪些昂贵真机实验明确**不用重复**？

原则：

```text
版本号变化 ≠ 证据失效
无关 UI / 文案变化 ≠ 证据失效
相关机制 / provider 合同变化 => 只重跑最小受影响实验
真实 mutation 新增 => 本轮仍需最终 cleanup + residue 0
```

以后任何 Agent 在准备重复的 live dogfood 前，必须先读本文件和对应 Issue 证据；已经证明且未被 invalidation trigger 命中的实验，不得因为“新版本了”机械重跑。

## 2. 证据复用规则

### 2.1 可以直接复用

以下情况默认复用既有 live 证据，不重跑完整矩阵：

- 只改版本号 / build 号；
- 无关页面、视觉、文案、布局；
- 与该机制无关的 read-only feature；
- 只重构未改变下列机制锚点行为；
- DEBUG harness 自身变化，但正常产品路径和 provider contract 未变；
- parked / hidden 功能继续不可达。

### 2.2 必须定向重跑

命中任一才需要重跑**最小相关场景**：

- 正常产品路径的 Preview / Confirmation / Executor / Readback 语义改变；
- 释义或例句 provider route / request shape / response decode 改变；
- phrase identity / smart quote normalization / safety journal / capacity 逻辑改变；
- uncertain-write / crash-recovery / cleanup / ledger 语义改变；
- credential replacement / Keychain / account identity 语义改变；
- provider operation lane / background lifecycle 语义改变；
- 墨墨官方 API 合同或真实 provider 行为出现 material change；
- Apple 大版本或系统行为改变且会影响 Share / XCUI / lifecycle 等系统机制。

### 2.3 任何新 live mutation 的固定收尾

无论是否复用旧证据，只要本轮真实写了数据库，结束前仍必须：

```text
marker-owned cleanup
→ authenticated scan
→ ACTIVE_DOGFOOD_RESIDUAL=0
→ non-marker baseline exact / 或该轮声明的等价恢复证明
```

这一条不能因为旧证据存在而省略。

## 3. 已闭合的真实状态矩阵

主要证据坐标：

- #183 comment 5872051655 — 第一轮真机写删闭环；
- #183 comment 5880428836 — 高级别矩阵 PARTIAL + provider 限流经验；
- #183 comment 5886432864 — Coordinator 独立续跑，C1 产品链闭合、harness 缺陷分类；
- #183 comment 5895846225 — 最终高级别矩阵 PASS；
- candidate head `e9ff0ca5767011c904d95a7b507916aa962a0a04`.

### 3.1 释义

| Evidence ID | 场景 | 真机结果 | 未来复测触发 |
|---|---|---|---|
| B1 | 0 条自建释义 → 正常 UI CREATE | PROVEN ×2；Query 0→1，History，cleanup→0，baseline exact | PreflightPlanner / ConfirmationBinding / WriteExecutor / interpretation transport 改变 |
| B2 | 1 条 marker-owned → 正常 UI UPDATE | PROVEN；Preview=更新；真实 UPDATE；create+0/update+1 | 同上，尤其 UPDATE target binding |
| B3 | already-matching → NO-OP | PROVEN；Preview=全部一致；mutation delta=0 | matching/classification 或 confirmation 行为改变 |
| B4 | 同词 2 条自建释义 → ambiguity | PROVIDER N/A；真实 provider 拒绝第二条自建释义；产品防御由 deterministic test 覆盖 | provider 开始允许第二条，或 interpretation list 语义改变 |
| B5 | provider 无法解析词 | PROVEN；Preview fail-closed；mutation delta=0 | vocabulary resolver / unresolved policy 改变 |

### 3.2 例句

| Evidence ID | 场景 | 真机结果 | 未来复测触发 |
|---|---|---|---|
| C1 | effective count 0 → 第 1 条 | PROVEN；正常 UI→Preview→确认→真实 POST→History→Query 0→1→cleanup 0 | PhrasePreflight / executor / transport 改变 |
| C2 | effective count 1 → 第 2 条 | PROVEN；Query 1→2；phrase POST +1；cleanup→0 | phrase count / capacity / executor 改变 |
| C3 | effective count 4 → 第 5 条 | PROVEN；Query 4→5；phrase POST +1；cleanup→0 | capacity rule 改变 |
| C4 | effective count 5 → 第 6 条 | PROVEN；Preview 前阻断；phrase POST delta=0 | capacity threshold / block surface 改变 |
| C5 | exact duplicate / smart quote equivalent / material conflict | PROVEN；exact=0 写；smart quote=0 写；same-English conflict=0 写；原始 CREATE 仅 1 次 | PhraseEnglishIdentity / smart quote canonicalization / hard-match semantics 改变 |

### 3.3 批次、崩溃与恢复

| Evidence ID | 场景 | 真机结果 | 未来复测触发 |
|---|---|---|---|
| D | mixed interpretation batch | PROVEN；新建1/更新1/一致1/阻断1；真正 mutation 恰 create+1/update+1 | batch approval / phase order / fresh preflight 改变 |
| E1 | interpretation POST 2xx 后、readback 前杀进程 | PROVEN；重启 GET 重发现；同输入不再 CREATE；cleanup 归零 | uncertain write / interpretation recovery 改变 |
| E2 | phrase POST 2xx 后、journal close 前杀进程 | PROVEN；重启防 duplicate CREATE；cleanup 归零 | PhraseSafetyJournal / phrase recovery 改变 |
| E3 | DELETE 2xx 后、ledger retire 前杀进程 | PROVEN；重启 GET-only reconcile；无盲重复 DELETE；residue 0 | dogfood cleanup / ledger reconciliation 改变 |

### 3.4 Study / Token / Lifecycle

| Evidence ID | 场景 | 真机结果 | 未来复测触发 |
|---|---|---|---|
| F2 | study plan membership dimension | PARTIAL-PROVEN；真实分类 in=0/out=25；out-of-plan 正常 CREATE 成功；unresolvable 由 B5 覆盖；in-plan 因当日无安全候选 N/A | 产品开始依赖 plan membership，或有安全 in-plan 候选时需要补一次 |
| F3 | 无效 Token replacement | PROVEN；新 Token 失败可见，旧连接保持，随后真实 read 成功 | CredentialSession / validation / replace flow 改变 |
| F4 | 取消 replacement | PROVEN；authority 不变，旧连接继续工作 | Settings token flow 改变 |
| F5 | background/foreground + provider lane release | PROVEN | ProviderOperationLane / QueryReadLease / lifecycle 语义改变 |
| ZZ | final residual + baseline | PROVEN；ACTIVE_DOGFOOD_RESIDUAL=0；NON_MARKER_BASELINE=EXACT | 每次新 live mutation 都必须重新做本轮收尾，不可只引用旧 ZZ |

## 4. 已验证的 provider / 真实环境事实

这些事实以后遇到相同症状时先复用，不重新从零猜：

1. **墨墨列表存在最终一致性滞后。** CREATE/DELETE 后立即 list GET 可能短暂看不到新状态；使用 bounded GET-only settle，不允许盲重发 mutation。
2. **聚合窗口真实会打满。** 客户端已有 20/10s、40/60s、2000/5h 调度；长时间大规模 dogfood 仍可能触发 provider 429。遇 429 应停止新增 live 场景，而不是继续 hammer。
3. **昂贵状态矩阵应 one-by-one。** 每个场景：pre-clean → 单场景 → cleanup/baseline → 下一场景；不要再跑十小时大批量。
4. **例句正文必须包含词头。** 真实 provider 曾对不包含 headword 的 phrase CREATE 返回 HTTP 400；包含 headword 后成功。
5. **同一词第二条自建释义在当前真实 provider 上不可达。** provider 拒绝第二条；因此 B4 当前是 provider N/A，不应为制造测试状态继续攻击接口。
6. **智能引号/撇号 identity 等价已真机证明。** exact duplicate、smart quote equivalent 都不会新增；同英文但 material content 不同会冲突阻断。
7. **StudyRecord 全量枚举当前不可靠。** 曾真实得到 parent count 与 disjoint child counts 不守恒；依赖 full StudyRecord enumeration 的 preset 已从正常 UI 收起。
8. **精确 study 查询可用作局部状态判定。** `get_today_items` / `query_study_records` 支持 exact spellings/voc_ids；需要判断一个具体词的 plan 状态时优先用 bounded exact query，不回到全量枚举。

## 5. Harness 调试记录 — 以后不要重复踩

### H-01 READY 早于 lane release
症状：scenario 已显示 READY，但正常 Preview 长时间 disabled。

根因：DEBUG prep report 发布时，`performLiveExperiment` 的 defer 尚未释放 `isBusy` / provider lane。

修复：`e9ff0ca` 后，experiment/dogfood report 只在 support idle 后发布，并携带 `ready_state support=idle/busy + connected/lane`。

以后看到类似症状：先查 semantic idle，不要改产品 Preview。

### H-02 DEBUG Settings 按钮不可达
症状：产品 mutation 已经完整成功，最后只因为「核对基线」等 DEBUG 按钮滚不到而失败。

结论：setup/cleanup/scan/baseline/classify 是 test-support，不是产品机制。

修复：使用 launch-argument automation：
- `-MomoDogfoodAction`
- `-MomoExperimentAction`
- `-MomoExperimentArm`

以后不把 DEBUG 按钮的 scroll/hittability 当 release-quality contract。

### H-03 陈旧 fault arm
症状：前一轮失败留下 I1/D1 持久武装，后续 clean run 被意外杀掉。

修复：加入 `-MomoExperimentArm cancel`，开始新 live 场景前确保旧 arm 已清。

### H-04 provider eventual consistency
setup interpretation/phrase 的 readback 不应使用过窄即时窗口。当前实验 helper 已扩大 bounded settle；仍不得 mutation retry。

### H-05 physical XCUI 系统波动
已出现：
- device 短暂 unavailable；
- automation session enable timeout；
- 系统剪贴板 / 通用剪贴板干扰；
- SwiftUI 过渡期点击丢失。

只有在直接证据显示产品状态错误时才定 PRODUCT_DEFECT；否则先区分 OS/SYSTEM_FLAKE 与 HARNESS_DEFECT。

## 6. 未来版本最小复测映射

### 只改 Study Export / TodayItems
重跑：
- 5 个公开 preset 的 simulator/UI；
- 受影响 preset 的真机 read-only；
- Export→Query handoff。

**不重跑 B/C/D/E mutation matrix。**

### 只改释义写入链
最小 live：
- B1 CREATE；
- B2 UPDATE；
- B3 NO-OP；
- B5 unresolved；
- 若 batch 逻辑也变：D；
- 若 uncertain readback 也变：E1；
- 最后 ZZ。

### 只改例句写入 / identity / capacity
最小 live：
- C1；
- C3 或 C4（按改动触及 capacity 哪侧）；
- C5；
- 若 safety journal / response recovery 变：E2；
- 最后 ZZ。

### 只改 batch approval / phase order
重跑：
- D；
- 一个 B1/B2 focused smoke；
- ZZ。

### 只改 crash / journal / cleanup
按触及面重跑：
- E1 / E2 / E3；
- ZZ。

### 只改 Token / account identity
重跑：
- F3；
- F4；
- 受影响的 account-derived result invalidation 单测/UI。
不重跑 phrase/interpretation capacity matrix。

### 只改 lifecycle / provider lane
重跑：
- F5；
- 一个 Query read；
- 一个 Preview read。
不做真实数据库 mutation，除非写入 lifecycle 语义也变。

### 只改版本号 / 文案 / 无关 UI
```text
LIVE_DOGFOOD_REQUIRED=no
```

## 7. 成本事实

最终收口的单个真机场景曾耗时约：

- B3 590.9s
- C2 683.4s
- C3 682.9s
- C5 704.9s
- D 639.5s
- E1 658.2s
- E3 439.9s
- F2 732.5s
- ZZ 161.4s

因此“已有证据未失效时不机械重跑”不是偷懒，而是本项目明确的时间 / provider 配额优化。

## 8. 当前结论

截至 candidate `e9ff0ca5767011c904d95a7b507916aa962a0a04`：

```text
HIGH_LEVEL_LIVE_MATRIX=PASS
PRODUCT_DEFECT_FOUND_IN_FINAL_MATRIX=0
ACTIVE_DOGFOOD_RESIDUAL=0
NON_MARKER_BASELINE=EXACT
NORMAL_PRODUCT_PATH_MUTATION=PROVEN
CRASH_RECOVERY=PROVEN
DUPLICATE_PROTECTION=PROVEN
CAPACITY_BOUNDARY=PROVEN
TOKEN_REPLACEMENT_SAFETY=PROVEN
LIFECYCLE_LANE_RELEASE=PROVEN
```

以后先做 impact analysis，再按 §6 选择最小复测，不从整套矩阵重新开始。
