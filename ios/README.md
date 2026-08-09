# iOS companion（Issue #66，未发布）

这是第一版原生 iOS 释义录入 companion。它使用 Swift、SwiftUI、Foundation、CryptoKit 和 XCTest，不含第三方依赖。

安全边界：

- Token 由 `SecureField` 手动输入，保存为产品专用的本设备 Keychain generic-password 项；使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 且不参与同步。
- 不使用 `UserDefaults`、文件、状态恢复、环境变量、argv、日志、自动剪贴板读取或 URL/query 保存 Token。
- 进入 inactive/background 会清除瞬态 session credential、可执行 PreviewSnapshot 和一次性确认，但不删除 Keychain Token；已完成的 PreviewPresentation 只在进程内保留为 stale/read-only，前台恢复连接后仍必须重新预览才能写入。
- “更换 Token”会替换 Keychain 项并使既有预览/确认失效；“移除 Token”会删除 Keychain 项和瞬态凭证状态。
- Production transport 只使用 `URLSessionConfiguration.ephemeral`，host 固定为 `https://open.maimemo.com`。
- Preview 只有 GET；CREATE 与 UPDATE 分开确认，执行前完整 fresh-preflight，严格比较不可变预览快照。
- 每个变更项最多一次 POST、无 POST 重试、立即鉴权 GET 回读；不提供 DELETE、phrase 路由或后台写入。

本 Issue 的实现与测试必须全程离线。不要在独立评审通过前输入真实 Token 或运行真实请求。

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
