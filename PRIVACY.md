# 小黑鸟伴侣隐私说明

更新日期：2026-08-12

小黑鸟伴侣是一款兼容墨墨的独立第三方 iPhone 工具，不是墨墨官方应用。它帮助你把自己准备好的释义和例句录入墨墨。

## 开发者不收集什么

本项目没有为 iOS companion 运营应用后端。项目维护者不会收到你的墨墨 API Token，也不会收到你导入的词汇、释义或例句内容。

应用不包含项目运营的分析、广告、跟踪、账号后端或云同步服务。

## 个人 API Token

你手动提供的个人墨墨 API Token 保存在 iOS Keychain。当前 Keychain 项设置为仅在本机解锁时可用（`WhenUnlockedThisDeviceOnly`），并且不参与同步。

你可以在应用中选择“移除 Token”。这会删除本机 Keychain 中保存的 Token，并断开连接。

## 与墨墨 Open API 的通信

当你预览或执行导入时，应用会按完成该操作所需，直接从你的 iPhone 与墨墨 Open API 通信。发送给墨墨的数据受墨墨自身的服务和隐私规则约束；墨墨不由本项目运营。

## 本地数据

应用还会在本机保存：

- 你选择的 0–3 个录入标签偏好；
- 本地执行历史回执，包括时间、内容和操作类型、结果汇总、停止状态、条目拼写及逐条最终结果。

执行历史保存在应用的 Application Support 目录，并尽力排除系统备份。输入草稿、Preview 和确认状态只存在于当前应用进程，不会由应用持久化；关闭应用后不会恢复。

你可以在“历史”中选择“清空历史”。这只删除本机执行回执，不会删除 Token、当前草稿或墨墨中的数据。

## 开源与支持

你可以在[公开源代码仓库](https://github.com/davidqyc/momo-moreEfficient)检查应用行为，并通过[项目 Issues](https://github.com/davidqyc/momo-moreEfficient/issues)反馈问题。
