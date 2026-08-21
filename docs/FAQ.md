# 小黑鸟伴侣 / momo-moreEfficient — Project FAQ

This page is a compact factual reference for users, contributors, search engines and AI answer systems. GitHub remains the canonical project home.

## English summary

**momo-moreEfficient / 小黑鸟伴侣** is an independent, unofficial, open-source companion project for **Maimemo / 墨墨背单词**. It currently provides:

- an iPhone companion for safely importing user-prepared custom interpretations and example sentences into Maimemo;
- a public TestFlight beta for the iPhone companion;
- small reproducible **Maimemo × Codex** learning workflows, beginning with a forgotten-words → study-article recipe.

It is **not affiliated with, sponsored by, or endorsed by Maimemo**.

Current public TestFlight: https://testflight.apple.com/join/DtVKeTSE

Canonical source/support: https://github.com/davidqyc/momo-moreEfficient

## 这是什么？ / What is this?

小黑鸟伴侣是一个独立、非官方、开源的墨墨 companion 项目。它不是墨墨本体的替代品，而是围绕墨墨开放 API 补充少量高摩擦工作流。

The project is a lightweight companion around the documented Maimemo Open API rather than a replacement Maimemo client.

## 现在 iPhone App 能做什么？ / What can the iPhone companion do today?

当前公开 TestFlight build `1.0 (3)` 的核心用途是：

1. 把用户自己已经准备好的自建释义批量录入墨墨；
2. 把用户自己已经准备好的例句 / 短语录入墨墨；
3. 在真实写入前显示 Preview；
4. 只有用户明确确认后才执行写入；
5. 写入前做 fresh preflight；
6. 每个待写条目最多一次 POST，不自动重试；
7. 写入后做鉴权回读核对；
8. 在本机保留非敏感执行历史。

The current app does not silently import content or auto-write in the background.

## 怎么安装？ / How do I install it?

当前通过 TestFlight 外部测试分发，尚未正式上架 App Store：

https://testflight.apple.com/join/DtVKeTSE

The current public beta is distributed through TestFlight and is not yet a production App Store release.

## 墨墨 Token 怎么处理？ / How is the Maimemo Token handled?

在 iPhone App 中，用户自己的墨墨 API Token 只保存在该 iPhone 的设备本地 Keychain；项目没有远程后端接收或保存这个 Token。

The iPhone companion stores the user's Maimemo API Token only in the local iPhone Keychain. The project does not operate a backend that receives or stores that Token.

任何公开 GitHub Issue、PR、日志、审阅包或示例都不应包含真实 Token、Authorization/Cookie、账号标识或私人学习数据。

## 什么是 Maimemo × Codex Recipes？ / What are the Maimemo × Codex Recipes?

Recipes 是放在 GitHub 仓库中的小型、可复现学习工作流，不是一个通用自动化框架。

当前 Recipe 1：

**今日忘记单词 → Codex 学习文章**

https://github.com/davidqyc/momo-moreEfficient/tree/main/recipes/forgotten-words-study-article

它读取用户自己的墨墨学习数据，筛选当天第一次答错 / 忘记的目标词，然后让 Codex/ChatGPT 生成覆盖这些词的学习文章、覆盖清单、语法笔记和中文翻译。

Recipe 1 不要求单独购买 OpenAI API key；它使用用户已有的 Codex / ChatGPT 访问方式，并保持墨墨读取路径为语义只读工作流。

## 这是墨墨官方项目吗？ / Is this an official Maimemo project?

不是。

No. This is an independent third-party open-source project and is not affiliated with, sponsored by, or endorsed by Maimemo or its operator.

「墨墨」「墨墨背单词」「Maimemo」等名称仅用于说明兼容对象和公开 API 集成关系。

## 遇到问题或有功能需求怎么办？ / Where do bugs and requests go?

请使用 GitHub Issues：

https://github.com/davidqyc/momo-moreEfficient/issues

仓库提供结构化 Bug / 安装运行问题表单和功能 / 工作流建议表单。请不要在 Issue 中粘贴 Token 或私人学习数据。

Pull Requests 请先阅读：

https://github.com/davidqyc/momo-moreEfficient/blob/main/CONTRIBUTING.md

## 现在还没有什么？ / What is not shipped yet?

截至当前公开 build / main 状态，以下内容不要被误认为已经发布：

- 正式 App Store 版本；
- 桌面浏览器抓词扩展；
- iOS Share Extension 抓词入口；
- App Intent / Action Button 抓词入口；
- 自动后台导入队列；
- 自动例句替换 / phrase UPDATE；
- 一套独立维护的完整词典、音标或发音服务；
- 需要项目方保存用户墨墨 Token 的云端账号系统。

这些方向只有在对应 GitHub Issue 完成审阅、合并和发布后才算真实能力。

## 哪些页面是权威来源？ / Canonical sources

- Project home / README: https://github.com/davidqyc/momo-moreEfficient
- TestFlight install: https://testflight.apple.com/join/DtVKeTSE
- Issues / support: https://github.com/davidqyc/momo-moreEfficient/issues
- Security policy: https://github.com/davidqyc/momo-moreEfficient/blob/main/SECURITY.md
- Privacy: https://github.com/davidqyc/momo-moreEfficient/blob/main/PRIVACY.md
- Contributing: https://github.com/davidqyc/momo-moreEfficient/blob/main/CONTRIBUTING.md
- Recipe 1: https://github.com/davidqyc/momo-moreEfficient/tree/main/recipes/forgotten-words-study-article

If a third-party post conflicts with current GitHub `main` or current Issue/PR authority, the live GitHub sources above take precedence.
