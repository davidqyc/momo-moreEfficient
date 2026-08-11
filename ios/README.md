# iOS companion（Issue #66，未发布）

这是原生 iOS 日常录入 companion。一个应用内提供独立的“释义 / 例句”进程内草稿；释义保持默认，例句提供经审阅的 CREATE 路径，以及 Issue #89 范围内的单条、显式选择、record-level replacement UPDATE 离线实现。它使用 Swift、SwiftUI、Foundation、CryptoKit 和 XCTest，不含第三方依赖。

安全边界：

- Token 由 `SecureField` 手动输入，保存为产品专用的本设备 Keychain generic-password 项；使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 且不参与同步。
- 不使用 `UserDefaults`、文件、状态恢复、环境变量、argv、日志、自动剪贴板读取或 URL/query 保存 Token。
- 进入 inactive/background 会清除瞬态 session credential、可执行 PreviewSnapshot 和一次性确认，但不删除 Keychain Token；已完成的 PreviewPresentation 只在进程内保留为 stale/read-only，前台恢复连接后仍必须重新预览才能写入。
- “更换 Token”会替换 Keychain 项并使既有预览/确认失效；“移除 Token”会删除 Keychain 项和瞬态凭证状态。
- Production transport 只使用 `URLSessionConfiguration.ephemeral`，host 固定为 `https://open.maimemo.com`。
- Preview 只有 GET；CREATE 与 UPDATE 分开确认，执行前完整 fresh-preflight，严格比较不可变预览快照。
- 每个变更项最多一次 POST、无 POST 重试、立即鉴权 GET 回读；不提供 DELETE 或后台写入。
- phrase/example 开放 reviewed phrase collection GET、CREATE POST，以及仅针对显式选中用户记录 ID 的 `POST /open/api/v1/phrases/{id}` replacement UPDATE；不开放 phrase DELETE、回滚或 replay。`origin`、英文、中文、`PUBLISHED`、目标 ID 与唯一 same-English readback 是 hard gate，tags/highlight 是结构安全的非阻断观察。
- replacement UPDATE 仅允许单输入、单候选、单次确认；任何多输入且存在 replacement 的预览都会禁止全部 phrase 写入。Issue #89 只完成 fake/rehearsal 离线实现与评审准备，未经独立评审和 Owner 新授权不得连接真实 Token 或执行真实 phrase UPDATE。

Issue #84/#89 的 UI integration 与测试全程使用 fake/rehearsal transport，未读取真实 Token、未发送真实墨墨请求；独立评审与 Owner 实体 iPhone DEBUG rehearsal 通过前不得执行真实 phrase POST。

## 实体 iPhone DEBUG 演练（零网络）

在 Xcode 的 Scheme → Run → Arguments 中加入 `-MomoRehearsalMode`，再把 DEBUG app 运行到 iPhone。顶部必须显示紫色“演练模式”横幅；看不到横幅就立即停止，不要继续。

切到“例句”，粘贴以下合成数据：

```markdown
## acquisition
EN: The acquisition strengthened the company's position in the market.
ZH: 这次收购加强了公司在市场中的地位。
SOURCE: 自编
```

依次确认 `预览 → 新建 1 条例句 → 原生确认 → 安全确认中… → 正在新建 1/1 → 正在收尾…`。完成后应只清空例句草稿，History 显示“例句 · 新建”，释义草稿不变。演练 transport、placeholder credential 和 History 全在进程内；不读取 production Keychain/History，不创建 `URLSession` 网络请求。

Issue #89 的容量满 replacement 演练使用固定合成词 `capacity`。输入一条例句并预览后，应看到 5 条本地合成 CURRENT 候选；显式选择其中一条后，确认页展示 CURRENT / PROPOSED，操作标题为“替换 1 条例句”。完成后 History 显示“例句 · 更新”。该流程仍完全在内存中执行，禁止用真实学习数据替换合成内容。

## 本地构建与测试

先确认本机已安装的 Simulator：

```bash
xcrun simctl list devices available
```

然后选择实际存在的 iOS 18.0+ 设备运行：

```bash
xcodebuild \
  -project ios/MomoMoreEfficient.xcodeproj \
  -scheme MomoMoreEfficient \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  test
```

测试 target 只注入内存 fake transport；不会调用 production transport 的 `send`。
