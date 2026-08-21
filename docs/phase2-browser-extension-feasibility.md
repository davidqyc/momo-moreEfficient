# Phase 2 浏览器扩展可行性备忘录

> Issue: [#125](https://github.com/davidqyc/momo-moreEfficient/issues/125)<br>
> 调研日期：2026-08-21<br>
> 基线：`origin/main@94cd126238338263d6dc162b949d54319a66553b`<br>
> 性质：research / architecture discovery；不授权产品实现

## 结论摘要

**最终结论：`NEEDS-MAIMEMO-CLARIFICATION`。**

墨墨的当前一方文档明确把“浏览器插件”列为开放平台场景，也给出了纯前端应用使用 OIDC Authorization Code + PKCE 的方向；因此现在不应把路线永久判为 `NO-GO`。但当前自助注册规则与 Chrome、Firefox 的扩展 OAuth 回调域名模型直接冲突，墨墨也没有公开确认扩展后台发出的请求能否获得 Open API 的 CORS/Origin 放行。两个问题都会决定扩展能否在**不新增云端凭证代理**的前提下安全工作，所以现在同样不能判为 `GO`。

关于 Issue [#104](https://github.com/davidqyc/momo-moreEfficient/issues/104) / [#5](https://github.com/davidqyc/momo-moreEfficient/issues/5)：现有支持接口仍只证明词汇对象包含 `id` 与 `spelling`，没有证明墨墨内置释义、例句、助记或发音字段可取。服务协议新增的“版权内容接口”条款只证明存在需要申请审批的能力概念，不等于当前已有可调用的接口合同。因此词典路线继续保持 **PARKED / NO-GO**；浏览器扩展若解阻，也只进入“选中文本捕获与确认后录入”范围。

## A. 范围与裁决标准

本备忘录只回答三个问题：

1. 墨墨当前公开平台是否支持浏览器扩展完成用户授权、令牌交换和必要 API 调用；
2. 若支持，最小安全架构是什么，是否需要 HTTPS 后端桥；
3. 浏览器路线是否出现足以重开 #104 / #5 词典能力的证据。

裁决含义：

- `GO`：一方资料已覆盖关键合同，可以进入一个受限实现切片；
- `NO-GO`：一方资料明确否定关键合同，或安全可行方案与项目边界冲突；
- `NEEDS-MAIMEMO-CLARIFICATION`：平台表达支持该场景，但决定性合同缺失或相互冲突，必须先得到墨墨的书面确认。

证据标签：

- **事实**：当前一方文档、当前可执行注册界面、机器可读接口定义或一方仓库直接证明；
- **推断**：基于事实得出的推荐设计，不冒充平台承诺；
- **未知**：一方材料未说明，不能靠浏览器通用能力补齐。

## B. 一方证据快照

| 来源 | 当前证据 | 对本 Issue 的意义 |
| --- | --- | --- |
| [墨墨开放平台说明](https://memodocs.maimemo.com/docs/open/)（2026-08-21 读取） | 明列浏览器插件；公开第三方应用经开放平台授权；纯前端应用使用 OIDC PKCE；获批主页域名可跨域访问 Open API；主页必须是可在线访问的 HTTPS 地址，且与登录回调同域 | 证明产品意图，但没有给扩展专用回调、扩展 Origin 或存储规则 |
| [开放平台应用注册页](https://open.maimemo.com/app/)（2026-08-21 读取） | 当前 UI 要求主页和每条回调均为 HTTPS，拒绝 `localhost`、IP、通配符与 fragment，并要求所有回调 hostname 等于主页 hostname；最多 5 条回调。公开 bundle SHA-256：`c9a0985c89b87ea68e1035b0192275e00514e3d318f769ca72652d9bfaa22fa8` | Chrome/Firefox 生成的扩展身份回调域名通常不可能与开发者拥有的在线主页同域；回调数量上限不能解决 hostname 冲突。这是当前自助 UI 的可执行规则，不宣称它是永久书面政策 |
| [OIDC discovery](https://accounts.maimemo.com/oidc/.well-known/openid-configuration)（2026-08-21 读取） | 支持 authorization code、refresh token、`S256` PKCE 和 public client 的 token auth method `none`；discovery 文档本身返回宽松 CORS | 证明标准 PKCE 所需协议元数据；discovery 的 CORS 不能外推为业务 API 或扩展 Origin 已放行 |
| [Open API OpenAPI bundle](https://open.maimemo.com/api_bundle.yaml)（2026-08-21，Last-Modified `2026-08-21 09:15:49 GMT`，SHA-256 `e269bd13abe882864aa22c481bed5449dfb85ad6069503af7b407140432bd85d`） | `GET /api/v1/memo/vocabulary` 和 `POST /api/v1/memo/vocabulary/query` 的 `Vocabulary` 只有必填 `id`、`spelling`；释义、例句、笔记接口分别描述为当前用户自己创建的数据 | 支持捕获/录入路线；不支持“已公开内置词典字段”的结论 |
| [开放接口功能介绍](https://memodocs.maimemo.com/docs/PNvOw2E1AivPtlkRlQgce1W1n2c/)（2026-08-21 读取） | 宣传“词汇查询”可取得释义、例句、助记；个人开发者自用可用个人 token，分发给第三方用户的应用应走开放平台授权 | 宣传文字与机器可读 schema 存在张力；不能用宣传文字替代字段、scope 和审批合同；公共扩展不应要求用户粘贴个人 token |
| [墨墨开放平台服务协议](https://memodocs.maimemo.com/docs/open-terms/)（2026-06-26 生效） | 禁止收集墨墨账号或其他认证凭证；要求最小必要处理、安全保护与删除路径；“版权内容接口”需申请获批，只可在绑定 ClientId 的获批应用向授权用户展示，临时缓存不超过 168 小时，并要求来源/作者标注，禁止沉淀语料、改编分发、批量抓取或用于 AI 训练/分析 | 排除“让用户粘贴个人 token”的公共产品方案；证明版权内容可能有受审能力，但仍未给出可用 endpoint、字段、scope 或当前开放状态 |
| [官方 `memo-api-cli`](https://github.com/maimemo/memo-api-cli/tree/e883862e54d718ef4cebe6612be6f72b19c166f7)（HEAD `e883862...`） | CLI 使用 PKCE、固定官方 ClientId 和 `http://localhost:18884/callback`，令牌保存到本地权限受限文件；词汇类型仍只有 `id`、`spelling` | 证明墨墨自己的受控客户端获准使用 loopback；不能证明第三方注册页也会接受 loopback 或扩展回调 |
| [官方 `memo-skills`](https://github.com/maimemo/memo-skills/tree/6ea37d43ffba2770e7d95d00a6cbc81d08da117e)（HEAD `6ea37d4...`） | `memo-api` skill v1.2.0 的 vocabulary 参考仍只有 `id`、`spelling`，用户释义/例句/笔记走独立接口 | 与当前 OpenAPI 合同一致，继续阻断内置词典路线 |

本次只做匿名、只读读取；未登录墨墨、未创建应用、未申请 scope、未获取 token、未调用真实账号写接口。

## C. Gate 1：浏览器扩展授权与 Open API 调用

### C1. 平台表达的预期授权模型

**事实：** 面向公众分发的纯前端应用，墨墨当前指向 OIDC Authorization Code + PKCE，而不是个人 API token。注册 UI 中可见固定身份 scope `openid profile`，内容 scope 包括 `open.memo.content:read` 与 `open.memo.content`，另有 `offline_access` 和学习相关 scope。

**推断：** 捕获并录入的最小权限应为 `openid profile open.memo.content`；只有在预览确需读取现有用户自建内容时才增加 `open.memo.content:read`。首个切片不需要学习 scope，也不应默认请求 `offline_access`。

**事实：** [Chrome Identity API](https://developer.chrome.com/docs/extensions/reference/api/identity) 的 `getRedirectURL()` 生成 `https://<extension-id>.chromiumapp.org/...`，`launchWebAuthFlow()` 会在流程到达该地址时把最终 URL 返回给扩展。[Firefox Identity API](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/identity) 同样生成绑定固定 add-on ID 的回调；Mozilla 还提示其 dummy domain 可能被要求域名所有权的 OAuth provider 拒绝。

**冲突：** 墨墨当前自助注册 UI 要求回调 hostname 与开发者在线 HTTPS 主页相同。开发者不能把主页部署在 `chromiumapp.org`，Firefox 的生成 hostname 也不同。登记五条回调不改变这个域名所有权冲突。

**未知：** 墨墨是否会为浏览器扩展人工放行生成的回调，是否允许同一 ClientId 覆盖多个浏览器，或要求每个平台独立申请。公开文档没有给出扩展专用注册流程。

### C2. 直接 API、CORS 与 HTTPS 桥

**事实：** [Chrome 跨域请求文档](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests) 允许拥有 `host_permissions` 的扩展 service worker / extension page 发起跨域请求；content script 仍受页面上下文限制。[Firefox host permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions) 也可授予扩展页跨域能力。

**未知：** 浏览器允许发请求，不等于墨墨同意扩展 Origin 或无 `Origin` 请求。墨墨只公开承诺“获批主页域名”的 CORS，尚未说明 `chrome-extension://...`、`moz-extension://...` 或扩展后台实际请求形态是否会通过业务 API 网关与平台审核。

**决策：`DEFER / NO BRIDGE`。**

- 若墨墨书面确认扩展回调和后台直接 API 调用：首选浏览器内 PKCE + 后台直接调用，无云端后端；
- 若墨墨要求 HTTPS 后端持有或转发令牌：当前 Issue 停止，不为绕过合同而自行设计 bridge；
- “只做一个 HTTPS 回调中转页”也不是已获批方案。它会引入回调绑定、授权码转发和域名信任边界，必须由墨墨明确允许后才能重新评估。

这样处理的原因是：云端桥会新增服务端凭证、用户 token、运维、删除与事故响应面，超出最小捕获功能的必要复杂度；它不能被当作解决平台合同缺口的默认技巧。

### C3. Gate 1 裁决

**`NEEDS-MAIMEMO-CLARIFICATION`。** 决定性未知项是“回调能否注册”和“扩展后台能否直接访问业务 API”。在两项获得肯定答复前，不创建扩展工程、不注册应用、不实现登录。

## D. 获准后的最小安全架构（条件式，不代表 GO）

```text
用户主动选择文本
      │
      ▼
content script：只读取本次 selection
      │ 发送一次性结构化消息；不持有 token
      ▼
extension review UI：展示词语、可选来源标题/URL，允许编辑或取消
      │ 用户显式点击 Preview / Submit
      ▼
trusted background/service worker
  ├─ 用户触发 OIDC PKCE
  ├─ 会话内持有 access token
  ├─ 预检并展示最终 payload
  └─ POST 一次 → 回读逐字段核对；unknown outcome 不自动重试
      │
      ▼
墨墨 Open API（仅在平台明确批准直接访问后）
```

最小实现边界：

- Chromium Manifest V3（Chrome/Edge）先行；入口限右键菜单或扩展按钮；
- 默认只捕获用户本次明确选择的文本；页面标题和 URL 为可见、可删除的可选来源；
- 不抓取整页正文、浏览历史、剪贴板、其他 tab、账号页面或后台浏览行为；
- 复用现有写入安全语义：明确 dry-run / preview、最终 payload、显式确认、单次写入、回读核对、unknown outcome 停止；
- content script 不接触 token，不直接调用墨墨 API；只有受信扩展上下文可访问认证状态；
- MVP 不需要 AI、云同步、数据库、分析 SDK、通用状态机或新设计系统。

这是一项**架构推断**，仍受 C 节平台合同确认约束。

## E. 凭证与数据存储建议

Chrome 的 [Storage API](https://developer.chrome.com/docs/extensions/reference/api/storage) 区分 `session`、`local` 与 `sync`；`storage.session` 只驻留内存，且可将访问限制为 trusted contexts。该能力并不等价于加密保险箱。

建议按最小暴露排序：

1. 首个切片只把短期 access token 放在 background/service worker 的内存或仅 trusted contexts 可见的 `storage.session`；
2. 不把 token 放入 content script、页面 `localStorage`、`storage.sync`、日志、URL query、崩溃报告或剪贴板；
3. 首个切片不请求 `offline_access`，不持久保存 refresh token。只有墨墨明确批准扩展本地持有 refresh token、并给出轮换/撤销要求后才另行设计；
4. 登出、撤销授权、扩展禁用/卸载说明和本地待提交内容清理必须有明确路径；
5. 未提交 selection 只在本地短暂存在，取消或成功录入后清除；不建立捕获历史库。

**未知：** 墨墨对公共扩展的 token 有效期、refresh token 存储、撤销和 `offline_access` 审批是否有额外要求。

## F. Chromium、Firefox 与 Safari 的适配差异

| 平台 | 可复用部分 | 必须隔离的适配 | 当前判断 |
| --- | --- | --- | --- |
| Chromium MV3 | selection 捕获、review UI、payload、安全状态语义 | `chrome.identity` 回调、service worker 生命周期、权限声明 | 条件式最小首发目标；先等墨墨确认 |
| Firefox WebExtension | content script、review UI、绝大多数 WebExtension 逻辑 | `browser.*` 适配、固定 add-on ID、不同 identity redirect、打包签名 | API 形态接近，但同一墨墨 ClientId 当前无法假定可复用；不需先引入跨平台框架 |
| Safari Web Extension | 业务 UI 和捕获逻辑可从 WebExtension 版本迁移 | Xcode containing app、native app extension、签名/App Store、认证与 native messaging | 明显是独立包装；不应阻塞 Chromium discovery |

[Apple 的分发文档](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension) 要求 Safari Web Extension 装入签名的 macOS/iOS containing app。[Apple 的消息文档](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension) 把 containing app、原生 extension 与 JavaScript web extension 视为隔离部分，并提供 native messaging/app group 协作。[ASWebAuthenticationSession HTTPS callback](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https%28host%3Apath%3A%29) 可使用与 app associated domain 绑定的 HTTPS host/path。

因此，Safari 存在一条与 Chromium 不同但原则上合理的条件式路线：由 containing app 完成 OIDC，把凭证存入 Keychain，再由原生层直接访问 API 或通过 native messaging 为 web extension 提供最小能力。它不需要云端 token bridge，但需要薄原生适配、Xcode 工程和独立平台审核。当前 Apple 一方资料不足以让本项目依赖 Chrome 风格 identity redirect 在 Safari 上兼容工作。

## G. Gate 2：内置词典内容是否已受支持地暴露

### G1. 已证明的合同

- 当前 OpenAPI `Vocabulary` 只有 `id`、`spelling`；
- 官方 CLI 类型和官方 memo skill 与该 schema 一致；
- 释义、例句、笔记 endpoint 的公开描述指向已授权用户自己创建的数据；
- 开放平台服务协议定义了经申请审批的“版权内容接口”使用条件。

### G2. 仍未证明的内容

- 没有一方机器可读合同给出内置释义、内置例句、助记、发音/音频字段；
- 没有公开 endpoint、response schema、业务 scope、错误码或审批流程把“版权内容接口”落实为当前可调用能力；
- “获取完整词汇信息”等宣传文字，以及官方 demo 对未知额外字段的宽松渲染，均不能替代上述合同；
- OIDC discovery 的 `scopes_supported` 也没有给出这项业务能力的权威 scope。

### G3. Gate 2 裁决

**`NO-GO`（维持 #104 结论，#5 继续 PARKED）。**

只有当墨墨提供并批准以下完整合同后，才新开一个隔离 discovery 重审：确切 endpoint、字段、scope、ClientId 审批状态、来源/作者标注要求、缓存上限和删除规则。即使解阻，也必须遵守 168 小时临时缓存上限与禁止语料沉淀、批量抓取、改编分发、AI 训练/分析等条款，不能把它并入本次捕获 MVP 默默扩张范围。

## H. 总体 GO / NO-GO / NEEDS-MAIMEMO-CLARIFICATION

| 判定对象 | 结论 | 理由 |
| --- | --- | --- |
| 浏览器选中文本捕获 + 用户确认后录入 | **NEEDS-MAIMEMO-CLARIFICATION** | 平台明列浏览器插件和 PKCE，但回调注册及扩展后台 API/CORS 合同缺失且与当前注册 UI 冲突 |
| 自建 HTTPS token/API bridge | **NO-GO（当前范围）** | 不是已批准要求，并新增不必要的凭证和运维风险 |
| 浏览器内置词典查询 | **NO-GO / PARKED** | 当前支持 schema 仍只有 `id`、`spelling`，版权内容接口没有可执行合同 |
| Issue #125 总体 | **NEEDS-MAIMEMO-CLARIFICATION** | 四个精确问题得到书面答复后再作 GO/NO-GO 更新 |

## I. MVP 非目标

即使 Gate 1 后续转为 GO，首个浏览器切片也明确不做：

- 内置词典、发音、助记或外部词典聚合；
- 整页抓取、自动识别、后台监控、浏览历史或剪贴板采集；
- AI 释义、AI 例句、云端内容处理或模型训练；
- HTTPS token 代理、通用后端、账号系统、数据库或跨设备同步；
- 自动批量写入、静默重试、并发绕过频控或多候选记录自动覆盖；
- 同时首发 Chromium、Firefox、Safari；
- 对现有 iOS 客户端、Issue #120 App Intent 或 #124 Share Extension 的实现改动。

## J. 若墨墨确认支持：最小可实现目标

这不是当前 `GO`，而是收到肯定答复后的最小切片定义：

**Chromium（Chrome/Edge）Manifest V3 扩展：用户右键选择一个单词或短语，进入本地 review UI，完成一次 OIDC PKCE 授权后，按现有安全语义 preview、显式确认、单次写入并回读验证一条用户自建内容。**

约束：

- 使用墨墨批准的扩展回调和 ClientId；
- 仅请求已批准的最小内容写 scope；
- access token 仅会话内保存；不请求 refresh token；
- background/service worker 在得到墨墨明确批准后直接访问 Open API；
- 无服务器、无持久捕获历史、无词典内容；
- 只用一个可丢弃测试记录完成首次真实验证。

若墨墨只批准“必须经后端”的模式，不自动把本节改成后端方案，而是回到架构评审并重新作成本/安全裁决。

## K. 发给墨墨支持的精确问题

建议一次只发送以下四组问题，并要求对生产公开应用给出书面答复：

1. **扩展回调与 ClientId**：纯前端 OIDC PKCE 应如何登记 Chrome/Edge 的 `https://<extension-id>.chromiumapp.org/<path>` 与 Firefox `browser.identity.getRedirectURL()` 生成的地址？当前注册页要求回调与在线 HTTPS 主页同 hostname。可否人工放行；Chromium、Firefox、Safari 是否可共用一个 ClientId，还是必须分别申请？
2. **直接 API 与 CORS/Origin**：获批扩展的 background/service worker 能否用 bearer token 直接调用 `https://open.maimemo.com/api/...`？请求的 `Origin` 为 `chrome-extension://...`、`moz-extension://...` 或未携带 `Origin` 时是否支持？若不支持，官方要求的是静态 HTTPS 回调 relay，还是持有/交换 token 并代理 API 的后端？
3. **token 存储与离线授权**：公共扩展是否可只在本机扩展受信上下文存 access token / refresh token？对 `offline_access`、token 持久化、过期、轮换、撤销、登出和删除有哪些强制要求？
4. **版权词典内容接口**：当前是否已有获批第三方可用的墨墨内置释义、例句、助记或发音接口？如有，请提供确切 endpoint、response 字段、scope、申请步骤、来源/作者标注与缓存规则；如没有，请确认当前公开“词汇查询”是否仅保证 `id`、`spelling` 以及用户自己创建的释义/例句/笔记。

在 1、2 未得到明确肯定答复前，捕获扩展不进入实现；在 4 未得到完整可执行合同前，#104 / #5 不重开。
