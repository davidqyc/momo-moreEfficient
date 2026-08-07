# 产品需求与 API 验证计划

最后更新：2026-08-03

## 1. 项目目标

本项目不是另做一套背单词系统，而是补齐墨墨现有交互中最耗时间的两个环节：

1. 将已经由用户和 AI 整理完成的释义/例句，安全地批量录入到对应单词下。
2. 在桌面上以一次点击进入更快的查词入口，并显示相近词和个人学习状态。

核心指标是减少实际操作步骤，而不是增加内容生成、复杂知识管理或自动代理流程。

## 2. 当前官方 API 基线

官方文档入口：<https://open.maimemo.com/>

截至本文件日期，从官方开放 API 首页可以确认：

- 使用 OAuth 2.0 Bearer Token；个人凭证可以从墨墨 App 的开放 API 实验功能或官方页面获取。
- API 基础路径示例为 `https://open.maimemo.com/open/api/v1/...`。
- 官方页面列出的请求频控为：10 秒 20 次、60 秒 40 次、5 小时 2000 次。
- 文档覆盖释义、例句、助记、云词本、单词和公测学习数据等类别。

以上只代表接口类别和基础调用方式存在，不代表本项目需要的每个写入字段已经验证。

### 2.1 Issue #2 schema-only 核对（尚未调用 API）

2026-08-03 只读检查官方 `https://open.maimemo.com/api_bundle.yaml`：规范为 OpenAPI 3.1.0、版本 `v1`，文件 SHA-256 为 `7f1a3ebebe9537bed14015151bcebeda3591bcbcb8c4e0f7f1e62f93f52c5e70`。以下仅是公开 schema 事实，不代表服务端、App 展示或跨账号发现已经验证：

- 释义 create/update 请求要求 `tags: string[]`；释义 create 还要求 `status`。更新记录 ID 只放在 `POST /open/api/v1/interpretations/{id}` 路径中，请求体顶层只有 `interpretation`。公开 schema 没有标签枚举或数量限制。
- 例句 create/update 请求要求 `phrase`、`interpretation`、`tags: string[]` 和 `origin: string`；create 另要求 `voc_id`。
- `Phrase.highlight` 只出现在响应模型中，不是 create/update 的可写字段。规范将它建模为范围对象数组，同时描述“实际返回的数据是二维数组”，需要真实回读确认形状和语义。
- 没有发现用于选择中文翻译精确字符位置的公开请求字段。
- 释义和例句列表端点都按 `voc_id` 查询自己创建的内容；没有公开的跨账号标签发现端点。
- 没有发现幂等键。真实阶段不得自动重试写入，必须逐次预览、确认并回读。

因此 schema 审查不能解除 Issue #2 的任何运行时阻断。当前纯离线脚本只生成一条释义和一条例句（后续变体复用同一例句记录）的待审 payload，不读取凭证、不包含 HTTP 或真实写入路径。

### 2.2 Issue #9 分阶段冒烟 harness（本轮仍未联网）

再次逐项核对上述官方 schema 后，**没有找到**可靠的 `self`、`profile`、`account identity` 或等价接口，无法通过公开 API 把 Token 自动绑定到可核验的账号身份。不得猜测或调用未公开接口。后续如获准进入真实阶段，账号防串用必须 fail-closed：凭证只能由独立的副账号来源注入，账号标签必须正向包含 `secondary`、`test`、`副号`、`副账号` 或 `测试` 之一，并拒绝 `main`、`primary`、`owner`、`prod`、`production`、`主号`、`主账号`、`主账户`、`生产` 等主账号/生产含义；操作者还必须输入同时包含该副账号标签和当前凭证非敏感 SHA-256 短指纹的精确确认短语。标签缺失或语义不符、来源不符、指纹变化或确认不精确时，在发出请求前停止。账号标签和 Token 指纹只能防止人工过程中把凭证换错，**不能**证明该 Token 属于哪个墨墨账号，也不能代替官方账号身份接口；真实执行前仍需所有者在墨墨 App 中人工确认副账号。

Issue #9 的最小 harness 将能力分为三层：

1. `offline-plan` 是默认且当前唯一可从命令行完成的模式，只复用 Issue #2 的 fixture 校验和 payload 生成，不实例化 transport。
2. `read-only` 只允许公开 schema 中已核对的 `GET /vocabulary?spelling=...`、`GET /interpretations?voc_id=...` 和 `GET /phrases?voc_id=...`，且必须先通过副账号人工门禁；`/vocabulary/query` 是 POST 语义，本 Issue 不开放。当前命令行没有凭证入口，因此默认阻断。
3. `live-step` 每个执行器最多尝试一个 POST。交互预览在本地当次显示 method、固定在 `/open/api/v1` 下的 path、真实待写内容，以及更新时的完整旧内容；普通摘要只保留哈希/脱敏内容。prepare 后的 path、payload 和旧记录快照被隔离并递归冻结；执行器在 journal 和发送前再次验证 action/path/payload/vocabulary 完整合同，并按最终 method、path、payload 重算精确确认码。每个 create/update 都先按目标 `voc_id` 做一次只读 GET：create interpretation 只允许零条现有自建释义；update interpretation 要求整个列表恰好只有目标 ID 一条，且旧字段与 rollback snapshot 一致；create phrase 保存身份完整的筛选基线，并在存在完全相同内容时阻断重复创建；update phrase 必须唯一命中目标记录 ID、旧字段与 rollback snapshot 一致且记录状态为 `PUBLISHED`。只有 preflight 通过后才允许创建 journal 和尝试 POST。随后立即 GET 回读：释义必须仍然只有本轮唯一目标记录，并比较 `interpretation`、`tags`、`status`；例句比较 `phrase`、`interpretation`、`tags`、`origin`，另要求响应中的只读 `status` 严格为 `PUBLISHED`。phrase `status` 不进入 create/update 请求体，但进入安全结果、私有验证快照和 continuation state。三标签按无重复、无缺失、无额外的精确集合比较，顺序不作为合同；请求/查询字段 `voc_id` 不要求出现在返回记录中。create 响应有安全 ID 时，该 ID 必须不在写前基线并按 ID 唯一回读；响应无 ID 时，只允许通过写前/写后 ID 集合中唯一新增且内容吻合的记录恢复身份。写入超时、多条释义、记录 ID 不明确、例句未发布、回读失败或字段不一致时停止，不自动重试。

真实 transport 固定生产 host `open.maimemo.com`，连接和读取均要求有限超时；GET 查询统一用 `urlencode` 构造，记录 ID 只接受安全单一路径段。它通过依赖注入与执行逻辑隔离，自动化测试只使用内存 fake transport，并由进程级 socket/URL 断网钩子兜底。本轮没有配置或读取 Token，也没有发送请求。

例句回读把 payload 验证与 `highlight` 观察分开记录。对象范围数组和二维整数范围数组都会规范化，并保留原始形状说明；每个范围须满足 `0 <= start < end <= 英文例句长度`。缺失、空数组、不合法范围或未知结构分别记录为 negative、invalid 或 unknown，但只要例句正文、翻译、标签和来源回读正确，写入本身仍标记为 verified；这不等于自动高亮语义成功，exact、inflected、multiple 三步仍等待所有者在 App 中逐项对照。为保留人工判断证据，私有 journal 只额外保存经过字节数、递归深度、容器项目数、敏感键和当前凭证内容检查的 bounded raw `highlight` 字段；超限或敏感内容只记录结构、大小和 rejected 状态，不保存原值。普通摘要、日志、PR 和 ZIP 永不包含未知 `highlight` 的完整原值。

所有 live write 都必须使用 Git 已忽略的 `artifacts/private/` journal，并在 POST 前先以严格本地权限保存 `prepared-not-sent`，随后只允许转为 `write-attempted-outcome-unknown`、`write-succeeded-readback-unverified` 或 `verified`。POST 非 2xx、GET 失败、记录歧义或字段不一致都会留下 unresolved 状态；同一步存在任何 journal 时默认禁止重放，仅提示人工检查，不提供自动恢复或重试。普通摘要、PR 和 ZIP 不含原始 ID 或私人正文；为支持人工恢复，私有 journal 保存最终 method、完整相对 path、实际待写 payload、完整 rollback snapshot、create 的筛选基线、凭证非敏感指纹、恢复提示，以及服务器唯一确定后的真实记录 ID 和筛选后的可写字段快照。例句 exact 创建后的真实 ID 只从该受保护状态传给 inflected，再传给 multiple；普通输出只显示 ID fingerprint。私有 journal 绝不保存 Token、Authorization、Cookie、账号标签、主账号信息或原始未筛选响应，目录/文件权限分别收紧到 `0700`/`0600`。自动化测试只写入明显虚假的临时私有状态并在测试后移除。

进入真实阶段仍需所有者人工完成：准备专用副账号和合法、真实、愿意保留的单词内容；在 App 中确认当前登录的确为副账号；通过独立的本地私有凭证注入方式启动；逐步核对每次预览、输入精确确认，并在 App 内验证跨账号发现、英文高亮、中文位置和来源展示。主账号 Token 永远不是 Issue #2/#9 的输入。

### 2.3 Issue #11 副账号只读探针（实现与测试仍为零真实请求）

Issue #11 在保留 `offline-plan` 默认行为的同时增加显式 `read-only-probe` 子命令。Token 只允许在交互式终端通过 Python 标准库 `getpass` 隐藏输入；不接受 argv、环境变量、stdin 管道、配置文件或 `.env`，不写入钥匙串、journal、日志或磁盘，只在当前进程内存中短暂存在。普通离线命令不会调用 `getpass`。主账号 Token 继续完全不受支持。

命令行解析层本身也是一道凭证边界。argparse 默认会把无法识别的参数原样写进 stderr，因此误输入的 `--token <真实凭证>` 会被回显。本项目改用 `SanitizedArgumentParser`：所有解析失败路径都汇聚到被覆写的 `error()`，丢弃 argparse 生成的文案，只打印静态 usage 和一句固定提示（说明本 CLI 从不接受命令行 Token，只接受隐藏交互输入）。未知选项、未知选项取值、非法 `--mode` 取值、未知子命令和缺失必填项都以退出码 2 fail closed，不回显任何用户提供的参数名或取值；`prog` 固定为常量，不取自 `sys.argv[0]`。项目自有的固定原因经 `fail_closed()` 输出，仍不含用户输入。

探针把副账号标签、Token 的 16 位 SHA-256 非敏感指纹、查询单词、固定 origin `https://open.maimemo.com`、三条允许的 GET 模板及“已人工复核当前费用与条款”声明绑定为一个精确确认摘要。确认完成前不创建 transport；生产 origin 和端点集合发生任何变化都会 fail closed。确认后只按顺序、无并发、无重试地执行：

1. `GET /open/api/v1/vocabulary?spelling=<word>`
2. `GET /open/api/v1/interpretations?voc_id=<resolved-id>`
3. `GET /open/api/v1/phrases?voc_id=<resolved-id>`

read-only transport 门禁拒绝 POST、PUT、PATCH 和 DELETE；标准库 HTTPS transport 保留证书校验和有限连接/读取超时，遇到 3xx 在读取响应正文或尝试其他地址前停止，因此不会向跳转地址转发 Authorization。401/其他非 2xx、超时、非对象响应、错误数组、重复或不安全 ID、按 NFKC+casefold 规则不匹配的拼写，以及无法识别的 status/highlight 结构都会立即停止当前序列。

记录级 schema 按端点分别 fail closed。`status` 只接受固定枚举：interpretations 仅 `PUBLISHED`、`UNPUBLISHED`、`DELETED`；phrases 仅 `PUBLISHED`、`DELETED`。缺失、非字符串、大小写或空白不同、跨端点错用（例如 phrases 返回 `UNPUBLISHED`）以及任何枚举外取值都会立即停止；不做规范化、trim、猜测或近似匹配，错误文案固定且不回显服务器返回的原值。安全摘要中的状态名只复用项目内置常量，不复用服务器返回的字符串对象。

例句记录还必须包含非空字符串 `phrase`。该正文只在内存中用于取长度，用来校验每个可识别 highlight 范围满足 `0 <= start < end <= len(phrase)`；对象范围数组和二维整数范围数组使用同一个范围校验器。空数组仍是合法的“本次未返回 highlight”结构观察。负值、`start == end`、`start > end`、超出例句长度、把布尔当整数、结构混用，以及缺失、空或非字符串 `phrase` 都会 fail closed。例句正文和不合法的原始 highlight 值都不会进入普通输出、错误信息或任何持久化状态；本 Issue 的只读探针不保存例句正文。

顶层响应形状同样只用项目自有元数据描述。服务器返回的顶层键名本身可能携带私人内容（例如把整段释义当作 key），因此普通输出不再复制任何原始键名。三条响应各自只报告项目常量化的 `canonical_key`（依次为 `voc`、`interpretations`、`phrases`）、该 canonical key 是否存在，以及未知顶层字段的**数量**。未知字段按 Issue #11 允许的方式忽略，其键名和取值都不进入普通输出、`repr`、`str`、stderr、日志或持久化状态。含 `authorization`、`cookie`、`token` 语义的顶层字段仍然直接 fail closed，且错误文案固定、不回显字段名。

普通输出只包含请求/返回拼写、`voc_id` 指纹、自建释义/例句数量、状态计数、highlight 形状计数、HTTP 状态与上述项目自有的响应形状摘要；不输出原始 ID、原始顶层键名、释义、例句、翻译或未知字段内容，也不默认保存响应。本 Issue 的实现、测试和审阅使用明显虚假的 credential 与 fake transport，并由进程级 no-network guard 兜底，**没有发送任何真实墨墨请求**；针对独立审阅四项阻断项（端点固定 status 枚举、highlight 越界校验、argv 解析错误回显 Token、原始顶层键名进入普通输出）的两轮修复同样为零真实请求、零真实 Token。

未来第一次实际只读运行仍需单独获得所有者明确授权。届时操作者应先在墨墨 App 人工确认登录的是专用副账号，再重新检查官方平台是否仍无强制按量 API 费用、当前条款是否允许个人测试账号用途；任一项不明确或出现强制收费即停止。随后在本地交互式终端运行显式子命令、隐藏输入副账号 Token、核对脱敏确认绑定并逐字确认。该指纹门禁只能防止过程中换错凭证，不能代替仍然**没有找到**的官方账号身份接口。

### 2.4 Issue #14 只读失败的脱敏诊断（本轮同样为零真实请求）

Issue #13 的第一次真实副账号 GET-only 运行在本地隐藏 Token 与逐字确认之后失败，但当时 CLI 把所有确认后失败都压成一句 `ERROR: read-only probe stopped safely; no retry was attempted.`，无法区分是 transport 初始化、三条 GET 中的哪一条、HTTP 状态校验还是 schema 校验。Issue #14 用一个项目自有的窄诊断替换该文案，使第二次运行有证据依据，而不是盲目重试。

失败时普通输出只打印一个脱敏 JSON 对象，然后以非零退出码结束：

```json
{
  "mode": "read-only-probe",
  "status": "failed",
  "failure_stage": "vocabulary",
  "failure_class": "http-status",
  "http_status": 403,
  "requests_attempted": 1,
  "requests_completed": 1
}
```

`failure_stage` 只取项目自有固定枚举 `transport-init`、`vocabulary`、`interpretations`、`phrases`。`transport-init` 表示第一条已复核 GET 尚未派发（transport 构造失败，或 origin/门禁等本地前置校验失败）。

`failure_class` 只取项目自有固定枚举，映射规则固定且可测：

- `transport`：没有拿到可用响应——transport 构造失败、transport 抛出、或返回的对象不是带纯数字状态的结构合法响应；
- `http-status`：收到了响应但数字状态不在 2xx。3xx 也归入此类，只报状态数字，绝不读取或输出跳转目标；
- `schema`：收到 2xx，但既有的结构校验拒绝了它（对象形状、记录数组、记录 ID、端点固定 status 枚举、拼写匹配、例句/highlight 结构、正文无法解析为 JSON 对象）；
- `safety`：本地不变量拒绝了本次运行——origin/门禁/逐字确认校验、read-only 门禁拒绝派发的请求，或最终凭证残留自检。

绝不把 `http.client`、socket、SSL、JSON decoder 或其他库的异常类型名当作 `failure_class`。

`http_status` 只在 `http-status` 和 `schema` 两类出现，因为按构造它们必然发生在收到响应之后；`transport` 和 `safety` 一律为 `null`。输出只含数字状态码，不含 reason phrase、响应正文、正文片段、JSON 错误、响应头、`Location`、服务器字符串或服务器自定义错误码。

计数器语义固定：`requests_attempted` 在把一条已复核 GET 交给受门禁 transport 之前立即加一；`requests_completed` 只在该 transport 返回带纯数字状态的响应之后加一，即 transport 层完成边界，早于 status 与 schema 校验。典型取值：transport 初始化失败为 0/0；vocabulary 连接失败为 1/0；vocabulary 返回 403 或 2xx 后 schema 失败均为 1/1；vocabulary 成功后 interpretations 连接失败为 2/1；三条 GET 都返回后 phrases schema 失败为 3/3。任何失败都立即停止，不自动重试以“补齐”计数。

为了让真实运行也能区分“响应存在”与“连不上”，标准库 transport 在 `getresponse()` 之后只记住数字状态。这里有一条关键分界线（PR #15 独立审阅提出的阻断项）：

**transport I/O 未完成 ≠ 完整响应但内容非法。**

- `connect()`、`request()`、`getresponse()` 和响应正文读取阶段的 I/O 失败——超时、连接重置、SSL 失败、`http.client.IncompleteRead`、远端断开——一律保持普通 `TransportError`，**即使状态行已经到达**。这类请求没有跨过既定的 transport 完成边界，因此诊断为 `failure_class = transport`、`http_status = null`，且当前这条请求**不计入** `requests_completed`（例如 vocabulary 为 1/0）。
- 只有在正文已经完整取得（或按规定根本不读取）之后，响应才可能带着数字状态被拒绝：抛出只携带该数字的项目自有 `TransportResponseError`。适用情形为 3xx 跳转（不读正文）、非 2xx、完整读取后超长、非法 UTF-8、非法 JSON、解码结果不是对象。2xx + 完整正文但内容不合约映射为 `schema` + 数字 2xx；非 2xx 映射为 `http-status` + 数字状态码。

`TransportResponseError` 是 `TransportError` 的子类，写入路径的所有 `except TransportError` 处理保持原样，写入安全语义本轮未改动。两类异常的原始文案都不外泄。

原始外部错误信息全程不外泄：诊断对象只包含固定枚举常量和本地计数的小整数；异常文案是固定的项目自有句子；所有内部转换使用 `raise ... from None`，并在离开 executor 前显式断开 `__cause__`/`__context__`，使被拒绝的库异常对象无法再从诊断异常上取回。诊断不写入 `artifacts/private/`，不落盘，不新增任何打印原始网络数据的 debug 模式。成功路径输出保持不变。

Issue #14 的实现、测试与审阅全部使用明显虚假的 credential 与 fake transport，并由进程级 no-network guard 兜底，**没有发送任何真实墨墨请求，也没有读取任何真实 Token**。第二次真实 GET-only 运行仍属 Issue #13，需要单独授权。

### 2.5 Issue #16 定位 vocabulary schema 失配（本轮同样为零真实请求）

第二次所有者授权的副账号 GET-only 运行返回的脱敏结果是：`failure_stage = vocabulary`、`failure_class = schema`、`http_status = 200`、`requests_attempted = 1`、`requests_completed = 1`。也就是说，凭证已被接受到足以让第一条 GET 收到**完整的 HTTP 200 响应**，失败发生在本项目自己的 vocabulary 结构校验，且 interpretations 与 phrases 从未发出。

`failure_class` 只能告诉我们“schema 失败”，不能指出违反了哪一条规则。Issue #16 因此增加**一个**可选的项目自有脱敏字段 `schema_reason`，让下一次真实运行直接给出失败的检查点：

```json
{
  "mode": "read-only-probe",
  "status": "failed",
  "failure_stage": "vocabulary",
  "failure_class": "schema",
  "http_status": 200,
  "schema_reason": "voc-id-local-policy",
  "requests_attempted": 1,
  "requests_completed": 1
}
```

`schema_reason` 取值只能是 `null` 或下列封闭固定枚举中的成员，且始终按 identity 从模块常量中选取，因此任何服务端 key、字段值、解码器文案或字节片段都不可能成为它：

| `schema_reason` | vocabulary 阶段对应的检查点 |
| --- | --- |
| `body-invalid-utf8` | 正文完整接收，但不是合法 UTF-8 |
| `body-invalid-json` | 正文完整接收且是合法 UTF-8，但不是合法 JSON |
| `body-not-object` | 完整解码后的 JSON 不是对象；或顶层不是字符串键映射 |
| `body-too-large` | 正文完整接收但超过已复核的大小上限 |
| `missing-voc` | 顶层对象没有文档约定的 `voc` 字段 |
| `voc-not-object` | 存在 `voc`，但它不是对象 |
| `voc-id-missing-or-not-string` | `voc.id` 缺失或不是字符串 |
| `voc-id-empty` | `voc.id` 是空字符串 |
| `voc-id-local-policy` | `voc.id` 是非空字符串，但不满足本项目 `_safe_record_id` 的 `[A-Za-z0-9_-]+` 策略 |
| `spelling-missing-or-not-string` | `voc.spelling` 缺失或不是字符串 |
| `spelling-local-policy` | `voc.spelling` 是字符串，但不满足本项目探测词策略（首尾空白、控制字符、超长等） |
| `spelling-mismatch` | `voc.spelling` 归一化后与请求词不一致 |
| `top-level-response-policy` | 顶层出现 `authorization`/`cookie`/`token` 类敏感字段名 |
| `other-reviewed-schema` | 其余已复核的 schema 拒绝（含 interpretations/phrases 阶段的既有校验） |

契约固定并在 `ReadOnlyFailureDiagnostic.__post_init__` 中强制：`schema_reason` 对 `transport`、`http-status`、`safety` 必须为 `null`，对 `schema` 必须非 `null`。PR #15 的 body I/O 修复不受影响——正文读取 I/O 失败仍是 `failure_class = transport`、`http_status = null`、`schema_reason = null`。

失败输出的完整字段集固定为：`mode`、`status`、`failure_stage`、`failure_class`、`http_status`、`schema_reason`、`requests_attempted`、`requests_completed`。账号标签、Token 指纹、voc_id 指纹、服务端 key 名、任何字段值和任何异常文案都不出现。

**当前最可能的假设**：一方文档只把 `voc.id` 定义为 `string`，并未记录本项目额外施加的 path-segment 字符限制。因此一个存在、非空、但含有标点的 ID 会被 `_safe_record_id` 拒绝。本轮**没有**放宽该规则，只是让它在被违反时报出 `voc-id-local-policy`，并且不打印、不持久化、不哈希该原始 ID。等下一次真实运行给出确切 `schema_reason` 之后，再单独决定兼容性修复。

vocabulary 校验只做了“足以定位失败检查点”的拆分：检查顺序和接受集合与此前完全一致，此前被拒绝的响应本轮不会被静默接受。成功路径输出、interpretations/phrases 语义和全部写入行为均未改动。

Issue #16 的实现与测试全部使用明显虚假的 credential 与 fake transport，并由进程级 no-network guard 兜底，**没有发送任何真实墨墨请求，也没有读取任何真实 Token**。下一次真实 GET-only 运行仍属 Issue #13，需要单独授权。

### 2.6 Issue #18 分类 vocabulary 响应外层形状（本轮同样为零真实请求）

第三次所有者授权的副账号 GET-only 运行返回的脱敏结果是：

```json
{
  "failure_stage": "vocabulary",
  "failure_class": "schema",
  "http_status": 200,
  "schema_reason": "missing-voc",
  "requests_attempted": 1,
  "requests_completed": 1
}
```

即：第一条 GET 完成、HTTP 状态 200、正文完整接收并解码为 JSON 对象，失败点精确落在**顶层对象没有文档约定的 `voc` 字段**；interpretations 与 phrases 从未发出。这排除了 Issue #16 记录的 `voc-id-local-policy` 假设。

当前一方文档（`maimemo/memo-skills`）仍把 `GET /vocabulary?spelling=apple` 记为返回 `{"voc": {"id": "...", "spelling": "..."}}`。生产行为与该文档不一致，但**不得**据此假定生产的实际外层结构。

`missing-voc` 只说明“文档形状不在顶层”，没有说明疑似 vocabulary 记录到底在哪一层。Issue #18 因此再增加**一个**项目自有脱敏字段 `response_envelope`，让下一次真实运行凭证据而不是凭猜测做兼容性修复。它的取值只能是 `null` 或下列封闭固定枚举中的成员，且始终按 identity 从模块常量中选取：

| `response_envelope` | 含义（只看结构，不看取值） |
| --- | --- |
| `direct-voc-object` | 顶层 `voc` 存在且形似 vocabulary 记录（正常不会与 `missing-voc` 并存，仅为分类完整性保留） |
| `direct-vocabulary-object` | 顶层对象自身形似 vocabulary 记录 |
| `data-voc-wrapper` | 顶层 `data` 是对象，且 `data.voc` 形似 vocabulary 记录 |
| `data-vocabulary-object` | 顶层 `data` 自身形似 vocabulary 记录 |
| `result-voc-wrapper` | 顶层 `result` 是对象，且 `result.voc` 形似 vocabulary 记录 |
| `result-vocabulary-object` | 顶层 `result` 自身形似 vocabulary 记录 |
| `vocabulary-wrapper` | 顶层 `vocabulary` 形似 vocabulary 记录 |
| `business-error-like` | 没有匹配到任何形似 vocabulary 的结构，但出现了小型固定允许清单中的业务元数据键名 |
| `unknown-object` | 以上已复核形状都不匹配 |

分类顺序是确定性的，按上表自上而下取**第一个**命中项。因此一个同时包含 `data`（形似 vocabulary 记录）和 `status` 的响应必然分类为 `data-vocabulary-object`，不会是 `business-error-like`；`business-error-like` 永远只是 `unknown-object` 之前的最后兜底。

“形似 vocabulary 记录”只做结构判断：是映射、含允许清单内的 `id` 与 `spelling`、且两者是预期的宽泛类型（`id` 为字符串或普通整数，`spelling` 为字符串）。它**不**调用 `_safe_record_id`、不校验 ID 取值、不归一化或比较 spelling、不返回任何取值。它只回答“疑似 vocabulary 对象在哪一层”，不回答“这条记录是否可以接受”。

分类器在内存中可以查阅的键名是一份完整、显式、封闭的允许清单，共 11 个：`voc`、`id`、`spelling`、`data`、`result`、`vocabulary`、`code`、`message`、`error`、`status`、`success`。除此之外的任何键名都不被读取、不被复制、不被排序、不被计数、不被哈希、不被指纹化，也不进入异常文案或持久化；未复核的键只能通过“不匹配”让整体塌缩为 `unknown-object`。业务元数据键的**取值**同样从不读取或输出。

契约固定并在 `ReadOnlyFailureDiagnostic.__post_init__` 中强制：`response_envelope` 仅在 `failure_stage = vocabulary`、`failure_class = schema` 且 `schema_reason = missing-voc` 时必须非 `null`，其余全部为 `null`——包括 `transport`、`http-status`、`safety`、`body-invalid-utf8`、`body-invalid-json`、`body-not-object`、`body-too-large`，以及 interpretations/phrases 阶段的所有 schema 失败。PR #15 的 body I/O 修复不受影响：正文读取 I/O 失败仍是 `failure_class = transport`、`http_status = null`、`schema_reason = null`、`response_envelope = null`。

失败输出的完整字段集因此固定为：`mode`、`status`、`failure_stage`、`failure_class`、`http_status`、`schema_reason`、`response_envelope`、`requests_attempted`、`requests_completed`。账号标签、Token 指纹、voc_id 指纹、服务端 key 名、任何字段值和任何异常文案都不出现。成功路径输出完全未变，不含这两个诊断字段。

**本 Issue 只做诊断，不改验收**：`direct-vocabulary-object`、`data-voc-wrapper`、`data-vocabulary-object`、`result-voc-wrapper`、`result-vocabulary-object`、`vocabulary-wrapper` 一律**不是**可接受的成功响应，成功合同仍然是文档约定的顶层 `voc`。因此下一次真实运行仍会以 `schema_reason = missing-voc` 安全失败，只是额外给出 `response_envelope`。拿到该观测值后再单独开兼容性修复任务。

Issue #18 的实现与测试全部使用明显虚假的 credential 与 fake transport，并由进程级 no-network guard 兜底，**没有发送任何真实墨墨请求，也没有读取任何真实 Token**。下一次真实 GET-only 运行仍属 Issue #13，需要单独授权。

> 后续更新：该观测值已在第四次真实运行中拿到，兼容性修复见 2.7。本节保留为当时的诊断口径记录。

### 2.7 Issue #20 窄口径接受观测到的 `data.voc` 外层（本轮同样为零真实请求）

第四次所有者授权的副账号 GET-only 运行返回的脱敏结果是：

```json
{
  "failure_stage": "vocabulary",
  "failure_class": "schema",
  "http_status": 200,
  "schema_reason": "missing-voc",
  "response_envelope": "data-voc-wrapper",
  "requests_attempted": 1,
  "requests_completed": 1
}
```

据此，生产 vocabulary 响应在**结构层面**被安全归类为：

```json
{
  "data": {
    "voc": {
      "id": "<value>",
      "spelling": "<value>"
    }
  }
}
```

这是第四条脱敏真实观测（前三条见 2.4–2.6），且**只记录结构**：本仓库不记录 Token 指纹，也不记录任何原始响应正文、键名或取值。

当前一方 MaiMemo 文档仍把 `GET /vocabulary?spelling=apple` 记为返回顶层 `{"voc": {"id": "...", "spelling": "..."}}`。也就是说：**文档形状在顶层，生产形状在 `data` 之下**。Issue #20 因此不再新增诊断层，而是做兼容性修复本体。

**接受的外层位置恰好两处**：

| 外层 | 来源 |
| --- | --- |
| `{"voc": <vocabulary-record>}` | 一方文档约定的形状 |
| `{"data": {"voc": <vocabulary-record>}}` | 本次生产观测到的形状 |

**没有启用任何其他外层**：`direct-vocabulary-object`、`data-vocabulary-object`、`result-voc-wrapper`、`result-vocabulary-object`、`vocabulary-wrapper`、`business-error-like`、`unknown-object` 全部继续 fail-closed，并继续以 `schema_reason = missing-voc` 加对应 `response_envelope` 报告。

**优先级不可颠倒**：顶层 `voc` 存在时一律走既有顶层路径；**不会**因为顶层 `voc` 畸形就回退到 `data.voc`。只有顶层 `voc` 缺失时，兼容层才考虑 `data.voc`，且要求 `data` 确实是 Mapping 且确实包含 `voc`。这样可以避免一个畸形的文档形状响应被第二候选静默绕过。

归一化边界是全部改动：

```text
raw vocabulary response
    ↓
选择文档顶层 voc，或（仅在顶层缺失时）观测到的 data.voc
    ↓
项目自有 canonical vocabulary body：{"voc": <原值>}
    ↓
既有的严格 vocabulary 校验（完全未变）
```

该边界只**搬运**取值：不修改、不复制、不持久化原始响应，不读取两个允许键名之外的任何键名，不打印、不计数、不哈希、不指纹化任何未知嵌套键。canonical body 只有一个键，其取值就是原始嵌套对象本身。

**内层 vocabulary 校验完全未变**：`voc` 必须是 Mapping、`voc.id` 的三段检查、`_safe_record_id`、spelling 类型/本项目探测词策略/与请求词一致、credential containment、响应大小/UTF-8/JSON 校验，一条都没有放宽。特别地，Issue #18 的定位分类器为了回答“疑似记录在哪一层”而允许了较宽的类型（`id` 可为字符串或普通整数），它**没有**成为验收校验器：一个能被定位到的 `data.voc.id` 若不满足既有验收规则，仍会在那条既有规则上失败。

因此修复后的诊断口径是：

- 合法的 `data.voc` 响应不再以 `missing-voc / data-voc-wrapper` 失败，而是通过 vocabulary 阶段并继续发出 interpretations GET；
- 畸形的嵌套记录仍按既有精确 `schema_reason` 失败：`voc-not-object`、`voc-id-missing-or-not-string`、`voc-id-empty`、`voc-id-local-policy`、`spelling-missing-or-not-string`、`spelling-local-policy`、`spelling-mismatch`；
- `data-voc-wrapper` 这个 `response_envelope` 取值本身保留在封闭枚举中（分类器未改），只是端到端上不再可达——它已经被接受路径提前接管。

成功输出保持稳定：`response_shapes.vocabulary` 仍是项目自有摘要 `{"canonical_key": "voc", "canonical_key_present": true, "unknown_top_level_field_count": 0}`，两种外层的成功摘要**逐字段完全相同**。外层 wrapper 的键名、数量和取值都不进入成功输出，原始生产正文不被暴露。

**interpretations 与 phrases 的响应解析本轮未改动**：我们目前只有 vocabulary 端点的生产证据。如果下一次真实运行越过 vocabulary 后显示这两个端点也使用类似包裹，再凭该证据单独处理，不预先泛化。PR #15 的 body I/O 行为同样未变：正文读取 I/O 失败仍是 `failure_class = transport`、`http_status = null`、`schema_reason = null`、`response_envelope = null`。

Issue #20 的实现与复核全部使用明显虚假的 credential 与 fake transport，并由进程级 no-network guard 兜底，**没有发送任何真实墨墨请求，也没有读取任何真实 Token**。下一次真实 GET-only 运行仍属 Issue #13，需要单独授权。

> 后续更新：该修复已在第五次真实运行中验证生效（vocabulary 阶段通过），collection 端点的同口径兼容见 2.8。本节保留为当时的 vocabulary 兼容口径记录。

### 2.8 Issue #22 窄口径接受 collection GET 的 `data` 外层（本轮同样为零真实请求）

#### 已确认事实（第五次所有者授权运行）

合并 `data.voc` 兼容修复后，第五次副账号 GET-only 运行返回的脱敏结果是：

```json
{
  "failure_class": "schema",
  "failure_stage": "interpretations",
  "http_status": 200,
  "requests_attempted": 2,
  "requests_completed": 2,
  "response_envelope": null,
  "schema_reason": "other-reviewed-schema",
  "status": "failed"
}
```

这是**事实**，不是推断：

- `data.voc` 兼容在生产环境确实生效；
- **vocabulary 阶段已经成功通过**（这是本项目第一次越过第一条 GET）；
- interpretations GET 已发出并完整完成，HTTP 状态 **200**；
- 失败点现在落在 interpretations 的 collection / schema 解析内部；
- phrases GET **未被发出**（`requests_attempted = 2`）。

本仓库不记录 Token 指纹，也不记录任何原始响应正文、服务端键名或取值。

#### 一方文档现状

当前一方 MaiMemo 文档仍把两个 collection 端点记为返回顶层键：

- `GET /interpretations?voc_id=...` → `{"interpretations": [Interpretation, ...]}`
- `GET /phrases?voc_id=...` → `{"phrases": [Phrase, ...]}`

#### 推断（明确标注为推断，不是观测）

- **`data.interpretations` 是推断**：已直接观测到的 `data.voc` 约定，加上 interpretations 现在 HTTP 200 且恰好在 collection/schema 解析处失败，构成很强的兼容性假设。但我们没有、也不会记录该响应的实际结构证据。
- **`data.phrases` 尚未被生产观测到**：phrases GET 至今一次都没有发出过。对它的兼容支持是**前瞻性**的，目的只是避免再来一轮“实现 → 真实运行 → 再实现”的重复往返。**不得**把 `data.phrases` 记为已观测的生产事实。

#### 每个端点接受的外层恰好两处

| 端点 | 接受位置 | 来源 |
| --- | --- | --- |
| interpretations | `{"interpretations": <collection>}` | 一方文档约定 |
| interpretations | `{"data": {"interpretations": <collection>}}` | 兼容性推断 |
| phrases | `{"phrases": <collection>}` | 一方文档约定 |
| phrases | `{"data": {"phrases": <collection>}}` | 前瞻性兼容，未观测 |

**没有任何其他外层变成可接受**：`result.<key>`、`items`、`records`、裸数组、`vocabulary` 包裹、泛化的 `data` 内容以及任何未复核的 wrapper 全部继续 fail-closed。每个端点只查自己的 canonical 键——`data.phrases` 永远不能满足 interpretations GET，反之亦然。

#### 优先级不可颠倒

- 顶层文档键存在时一律走既有顶层路径；
- **不会**因为顶层文档键的取值畸形（不是数组、记录非法、ID 重复、状态越界等）就回退到 `data.<key>`；
- 只有顶层 canonical 键缺失时兼容层才考虑 `data.<key>`，且要求 `data` 确实是 Mapping、且确实包含该端点自己的那个 canonical 键。

#### 归一化边界

```text
raw collection response
    ↓
文档顶层 interpretations / phrases，
或（仅在顶层缺失时）data.interpretations / data.phrases
    ↓
项目自有 canonical body：{<canonical key>: <原值>}
    ↓
既有严格 collection 校验（完全未变）
```

该边界与 2.7 的 vocabulary 边界共用同一个只读搬运函数：只**搬运**取值，不修改、不复制、不持久化原始响应，不读取两个允许键名之外的任何键名，不打印、不计数、不哈希、不指纹化任何未知嵌套键。canonical body 只有一个键，键名是模块常量本身（按 identity 选取），取值就是原始那个对象。

#### 内层校验完全未变

collection 必须是 list、每条记录必须是 Mapping、`_safe_record_id`、重复 ID 拒绝、interpretation 状态枚举 `PUBLISHED / UNPUBLISHED / DELETED`、phrase 状态枚举 `PUBLISHED / DELETED`、phrase 必须是非空字符串、highlight 必须是已复核的 range 形状之一、每个 highlight range 必须被 phrase 长度约束——一条都没有放宽。正常输出中不出现任何原始记录内容，credential 含纳、无重试、无持久化同样未变。

Issue #18 的外层分类器**没有**被用作验收校验器：collection 路径既不调用它，也永远不报告 `response_envelope`（collection 阶段的 schema 失败一律 `response_envelope = null`）。

#### 成功输出保持稳定

`response_shapes.interpretations` / `response_shapes.phrases` 仍是项目自有摘要 `{"canonical_key": <key>, "canonical_key_present": true, "unknown_top_level_field_count": 0}`。三条 GET 全部使用 `data` 外层的假流程，其脱敏成功摘要与全部使用文档顶层形状的假流程**逐字段完全相同**——这是下一次真实运行前的关键回归目标。

Issue #22 的实现与复核全部使用明显虚假的 credential 与 fake transport，并由进程级 no-network guard 兜底，**没有发送任何真实墨墨请求，也没有读取任何真实 Token**。下一次真实 GET-only 运行仍属 Issue #13，需要单独授权。

## 3. 真实用户工作流

### 3.1 内容准备阶段

用户在学习过程中：

1. 将自己的例句和单词释义放入 ChatGPT 专用对话。
2. 按近五年的真实商业/学习语境筛选义项和用法。
3. 在其他 AI 中进一步修饰和润色。
4. 得到一次约 8–15 个词、格式完成度约 90%–100% 的批次。

本工具不应重新发明或大幅改写这些内容。主要职责是解析、校验、预览、录入和回读验证。

### 3.2 释义录入目标

释义线路可以独立于例句线路推进，要求：

- 批量解析单词与释义。
- 将单词解析为墨墨词条 ID。
- 展示已有自建释义与新释义的差异。
- 支持新增用户自建释义。
- 支持替换**明确选中的、属于当前用户的自建释义**。
- 不修改或删除墨墨内置词典释义。
- 默认添加 `MBA`、`BEC`、`GMAT` 三个标签。
- 写入前完整预览，写入后回读核对。
- 记录脱敏操作日志，支持人工判断如何回滚。
- 同一批次重复执行时，不产生失控重复数据。

“替换目前的单词释义”在本项目中必须解释为：更新用户明确选择的自建释义记录；不得解释为覆盖官方词典内容。

### 3.3 例句录入要求与阻断项

例句和释义是两条独立线路。例句自动化必须逐项满足：

| 项目 | 优先级 | 当前状态 | 决策 |
|---|---|---|---|
| 可同时选择 `MBA`、`BEC`、`GMAT` | 绝对阻断 | 文档/前序分析显示可能支持，尚未真实写入和跨账号验证 | 未通过前不开发正式发布流程 |
| 伙伴账号可通过上述标签找到内容 | 绝对阻断 | 未验证 | 失败则释义和例句的共享发布目标均停止 |
| 英文例句中准确标记目标词义位置 | 绝对阻断 | 返回模型可能存在 highlight range，但写入控制权不明确 | 无可靠路径则停止例句自动化 |
| 中文翻译中标记具体汉字/标点位置 | 高难度、当前实质阻断 | 尚未发现明确写入字段 | 无法传入精确范围时，除非所有者接受手工收尾，否则保持阻断 |
| 添加来源/origin | 非阻断 | 前序分析显示可能支持，待实测 | 可缺失，但应尽量保留 |

中文位置不需要 AI 自行猜测。用户可以提前完成高难度语义判断，但 API 必须能接收明确的字符范围或等价结构，否则预处理没有意义。

### 3.4 桌面查词目标

目标交互：

1. 桌面或 Dock 点击一次。
2. 输入框自动获得焦点。
3. 输入过程中即时显示精确匹配、前缀候选和拼写相近词。
4. 显示候选词中哪些已经添加或产生过个人学习记录。
5. 点击候选后查看紧凑详情。

当前工作假设：官方单词查询更偏向完整拼写/ID 查询，不承担完整模糊联想。因此：

- 本地词表负责候选生成、前缀匹配和拼写距离。
- 墨墨 API 负责验证词条、获取详情和附加用户状态。
- 输入采用 debounce，候选批量校验并缓存。
- 不依赖尚未公开确认的单词详情 Deep Link。

该假设必须在实现前从当前 OpenAPI schema 和真实请求中再次确认。

## 4. Issue #2 的最小真实验证

真实阶段只使用一个可丢弃单词，并遵守以下记录范围：

- 只创建一条自建释义记录和一条例句记录。
- 允许为了验证 exact、inflected、multiple 三种行为，对同一条例句做最少量、逐次确认的更新，不另外创建例句记录。
- 每次写入前展示最终 payload 并明确确认；写入后立即回读并逐字段核对，再继续下一步。

当前离线 fixture 必须继续使用明显虚假的内容，离线脚本禁止联网；fixture 内容不得用于真实发布。后续真实测试必须使用合法、真实、符合平台规则、所有者愿意保留或在验证后删除的释义、例句和来源，不发布无意义测试内容。

首次真实写入前及公开发布前必须重新核对官方收费和平台条款。当前只能表述为“没有公开记录的 API 使用费”，不能承诺永久免费；若出现强制按量 API 收费，项目默认停止，除非所有者明确变更决定。

### 4.1 标签与共享验证

- 给一条自建释义写入 `MBA`、`BEC`、`GMAT`。
- 给一条例句写入同样三个标签。
- 在内容创建者账号确认保存结果。
- 由伙伴账号在 App 内通过每个标签检查是否可发现。
- 记录“API 返回成功但 App 不可发现”等差异。

### 4.2 英文目标词位置

依次测试：

1. 例句含一次完全相同拼写。
2. 例句含词形变化。
3. 例句含两次相同拼写。
4. 如适用，例句需要标记短语或特定一次出现。

检查：

- 创建请求是否接受调用方提供的范围。
- 返回对象是否自动生成范围。
- App 实际显示是否与返回范围一致。
- 更新接口是否允许修正范围。

只有能够可靠选择正确位置，例句线路才可解除该阻断。

### 4.3 中文翻译位置

从当前 OpenAPI 导出或运行时 schema 中查找所有与 translation/interpretation/highlight/range/token 相关的请求字段。若没有调用方可写字段，则记录为“不支持”，不要通过未公开接口猜测或 UI 自动点击绕过。

### 4.4 来源

写入一个合法、真实且所有者愿意保留或在验证后删除的来源，确认：

- 请求字段名称和长度/格式限制。
- 回读值是否一致。
- App 中是否在用户查看例句时显示。

## 5. 最小实现边界

第一阶段只需要：

1. API 客户端和凭证加载。
2. 批次解析器。
3. dry-run 预览。
4. 单条测试写入与回读。
5. 释义批量新增/安全更新。
6. 脱敏日志和失败恢复提示。

暂不默认建设：

- 云服务或账号系统
- 多用户数据库
- 多代理编排
- 复杂状态机
- 完整跨平台 UI 框架
- 自动生成或自动润色释义/例句
- 基于屏幕坐标的脆弱 App 自动化

## 6. 建议的内部层次（非技术栈承诺）

无论最终采用何种语言，优先保持以下边界：

- `parser`：把用户批次转换为结构化草稿，不访问网络。
- `validator`：检查必填字段、标签、重复和歧义。
- `maimemo-client`：封装鉴权、频控、请求和响应，不包含 UI。
- `planner`：把草稿与现有记录比较，生成 create/update/skip 计划。
- `executor`：默认 dry-run；执行前确认；写后回读。
- `audit`：输出脱敏结果和人工回滚所需信息。
- `ui/cli`：只负责交互，不直接拼写 API 请求。

先验证最小 API 客户端和解析器，再决定 macOS 原生应用、菜单栏应用、本地 Web UI 或其他分发形态。

## 7. 未解决问题

- 当前 OpenAPI 中释义和例句写入请求的完整 schema。
- 三标签是否能同时写入以及伙伴账号是否可发现。
- 例句英文 highlight 是自动生成、调用方可控，还是只读展示字段。
- 中文翻译位置是否存在未被首页搜索结果显示的公开写入能力。
- 自建释义的所有权/作者字段如何可靠识别。
- API 是否提供稳定的幂等键；如没有，需要本地指纹和回读策略。
- 查词所需学习状态接口的覆盖范围和延迟。

以上问题统一通过 GitHub Issue 记录结论，不以聊天中的临时判断替代。
