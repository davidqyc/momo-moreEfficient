# 小黑鸟伴侣

**小黑鸟伴侣momo-moreEfficient**是一个独立、非官方、开源的 **墨墨背单词实用助手 / Maimemo companion**。目的很简单：把墨墨里几件高频但麻烦的事做得更顺手——先是安全录入释义和例句，接着是阅读时抓词，以及可复现的 **Maimemo × Codex** 学习工作流。

> **当前公开版本：** [iPhone TestFlight build `1.0 (3)`](https://testflight.apple.com/join/DtVKeTSE)，尚未正式上架 App Store。
>
> **不是墨墨官方项目。** 为爱发电，与墨墨及其运营方不存在隶属、赞助或背书关系。

## 快捷入口

| 我现在要 | 入口 |
| --- | --- |
| 在 iPhone 上试用小黑鸟伴侣 | **[加入 TestFlight](https://testflight.apple.com/join/DtVKeTSE)** |
| 把今天忘记的词交给 Codex 写成学习文章 | **[Recipe 1：今日忘记单词 → Codex 学习文章](recipes/forgotten-words-study-article/README.md)** |
| 产品说明 | **[www.jiripple.com/xiaoheiniao/](https://www.jiripple.com/xiaoheiniao/)** |
| 报bug、寻求帮助或提建议 | **[GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)** |

[English summary](README.en.md) · [项目 FAQ](docs/FAQ.md) · [隐私说明](PRIVACY.md) · [安全说明](SECURITY.md)

## 功能 1｜释义和例句按格式批量录入墨墨

这是当前公开 TestFlight 版本的第一批功能。

如果你已经在 ChatGPT、Codex、自己的笔记或别的地方把内容整理好了，不必再一条一条去墨墨里重复添加。小黑鸟伴侣负责把**这些内容**带进一个可检查、可确认的录入流程。

当前公开 build `1.0 (3)` 支持：

- **自建释义**：批量新建 / 更新；
- **例句 / 短语**：新建；
- 写入前先预览Preview；
- 只有你明确确认后才会写入；
- POST 前重新做 fresh authenticated preflight；
- 每个变化条目最多一次 POST，**不自动重试**；
- 写后立即做鉴权回读，确认实际结果。

日常逻辑可以理解成：

```text
准备好内容 → 粘贴到小黑鸟伴侣 → 预览Preview →
检查要新建 / 更新的内容 → 明确确认后开始 →
fresh preflight → 写入 → 回读核对
```

### Token 不会被项目方收集

你的个人墨墨 API Token 只保存在你的 iPhone 设备本地 Keychain 里。项目没有远程后端接收或保存这个 Token。

项目不会主动把真实 Token、Authorization/Cookie、账号标识或私人学习数据写进公开 Issue、PR、日志、示例或审阅材料；也请不要自己把这些内容粘贴到公开页面里。

## 功能 2｜阅读时抓词（即将上线）

这部分**源码主线已经完成，真机体验已经验证；当前公开 TestFlight build `1.0 (3)` 里还没有这个功能**。

目标不是做一个庞大的阅读器，而是把这个动作缩短：

```text
看到想记的词 / 句子 → 抓进小黑鸟伴侣
→ 先检查、可编辑 → 再决定是否进入正常 Preview / 录入流程
```

正常推荐入口：

- **共享**：在支持系统共享选中文字的阅读 App 里，把文本交给小黑鸟伴侣，正常打开 App 后进入“抓词”状态；一次性把小黑鸟伴侣加入常用分享目标后，无需为每个来源单独配置。

更快的预配置备选入口：

- **快捷指令（iOS 26+）**：配置一个把文本传给小黑鸟伴侣抓词动作的快捷指令；配置好之后，运行它会自动前台打开到同一个“抓词”状态。

两条入口都停在 **预览Preview 之前**：仅仅抓词，不会读取墨墨 Token、不会访问墨墨、不会自动进行预览Preview，更不会自动写入。

## 功能 3｜把墨墨今天忘记的词交给 Codex

这条路线已经可以用，不依赖 iPhone App，也不是一个“大而全的 AI 平台”。每个 Recipe 都应该是一个小而明确、可以复现的学习工作流。

### Recipe 1：今日忘记单词 → Codex 学习文章

它读取你自己的墨墨学习数据，找出当天目标忘词，然后让 Codex / ChatGPT 生成：

- 一篇覆盖这些词的英文学习文章；
- 覆盖清单；
- 语法笔记；
- 中文翻译。

**[直接看 Recipe 1](recipes/forgotten-words-study-article/README.md)**

这条工作流不要求你另外购买 OpenAI API key；它使用你已有的 Codex / ChatGPT 访问方式。墨墨侧保持语义只读，不执行写入。

## 功能进度

这里按用户真正能不能用来分阶段，不把“源码里有”写成“已经上线”。

| 功能 | 阶段 | 说明 |
| --- | --- | --- |
| iPhone 释义 / 例句批量录入 | **已上线** | TestFlight build `1.0 (3)` 已提供 |
| 阅读时抓词 | **即将上线** | 源码已完成，真机体验已验证；共享为推荐日常入口，快捷指令为更快的预配置备选；下一版发布前还需要同步公开产品页事实，并做一次架构/复杂度复查 |
| 桌面浏览器抓词 | **调研中** | 还没有开始做公开版本；等待墨墨开放平台明确浏览器 OAuth 回调、CORS / API 等规则 |
| 墨墨内置词典 / 发音 | **暂未提供** | 当前公开 API 合同还不足以支持本项目可靠实现 |
| 后台自动导入 | **暂未提供** | 当前没有上线，也不作为近期主线 |

当前工程状态看 [`docs/PROJECT_STATE.md`](docs/PROJECT_STATE.md)。

## 安全底线

无论以后增加什么入口，这几条都不应被绕开：

- **Preview 不是写入授权**；
- 写前必须有明确用户确认；
- 可能受服务端状态变化影响的写入，POST 前重新做鉴权 preflight；
- 每个变化条目最多一次 POST，POST 不自动重试；
- 已发出的写入必须鉴权回读；未知结果只允许 GET-only recovery；
- UPDATE 只针对明确的当前账号自建记录，歧义就阻断；
- 不自动 DELETE、rollback 或 replay；
- 真实 Token 和私人学习数据不得进入 Git、日志或公开材料。

## 遇到问题、想提功能、想贡献

- **Bug / 安装 / 配置失败：**[GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)
- **功能或新工作流建议：**同样走 [GitHub Issues](https://github.com/davidqyc/momo-moreEfficient/issues)
- **贡献代码或文档：**先看 [`CONTRIBUTING.md`](CONTRIBUTING.md)，再提交 Pull Request

仓库已经提供结构化 Issue Forms。请不要在任何公开 Issue / PR 中粘贴真实墨墨 Token 或私人学习数据。

GitHub 是源码、Recipe、Issue、PR 和当前工程状态的 canonical home；[`www.jiripple.com/xiaoheiniao/`](https://www.jiripple.com/xiaoheiniao/) 是稳定的用户 / 搜索 / AI 产品事实页。

## 如果你是开发者

普通用户到这里基本就够了。继续往下主要是工程和历史资料：

- [项目 FAQ / 中英双语事实页](docs/FAQ.md)
- [当前项目状态](docs/PROJECT_STATE.md)
- [AI 搜索可见性 Benchmark](docs/ai-search-benchmark.md)
- [产品与 API 计划](docs/product-and-api-plan.md)
- [决策记录](docs/decision-log.md)
- [Agent / Codex 工作规则](AGENTS.md)
- [贡献说明](CONTRIBUTING.md)
- [变更日志](CHANGELOG.md)

### 旧版 CLI v0.1.0

仓库最早是一个 Python 命令行批量释义导入器。它现在保留作 legacy / reference，不再作为新用户的首页入口。

如果你仍然需要它，完整命令、输入格式、主账号 opt-in、preflight 状态和安全合同都迁到了：

**[`docs/legacy-cli-v0.1.0.md`](docs/legacy-cli-v0.1.0.md)**

历史代码和验证证据仍保留在仓库中；README 不再重复整份旧 CLI 操作手册。

## 免责声明与商标说明

本项目是独立、非官方的第三方开源项目，与墨墨背单词及其运营方不存在隶属、赞助或背书关系。「墨墨」「墨墨背单词」「Maimemo」及相关名称与商标仅用于说明兼容对象及公开 API 集成关系，所有相关名称与商标归各自权利人所有。

本项目只使用公开提供的接口，并遵守对应 API、内容与账号规则。你需要对自己账号中的内容变更负责。

## 许可证

[MIT](LICENSE)
