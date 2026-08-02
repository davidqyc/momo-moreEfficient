# momo-moreEfficient

一个基于墨墨开放 API 的**非官方效率增强工具**，目标是减少查词和批量录入自建释义/例句时的重复操作。

An unofficial Maimemo companion for faster desktop lookup and safer batch publishing of user-curated vocabulary content.

> **当前状态：私有仓库清场期 / API 能力验证阶段。** 目前没有可用于真实批量写入的稳定版本，也不应向仓库提交任何真实 Token 或个人学习数据。

## 要解决的两个高频场景

### 1. 批量录入自建内容（当前第一优先级）

用户通常一次准备 8–15 个单词，释义和例句格式完成度约为 90%–100%。本项目负责解析、预览、选择现有内容、写入和回读验证，不擅自改写已经准备好的语言内容。

- 释义：批量新增，或安全替换**用户本人创建的释义**。
- 例句：只有在标签、英文词义位置和中文翻译位置等阻断项被验证后才进入开发。
- 默认目标标签：`MBA`、`BEC`、`GMAT`。

### 2. 桌面快速查词（第二优先级）

从桌面/Dock 一次点击进入，输入框立即聚焦；输入过程中显示精确匹配、前缀候选和拼写相近词，并标记哪些词已经加入过个人学习数据。候选词预计由本地索引生成，再通过墨墨 API 校验词条和个人状态。

## 已确定的产品顺序

1. [#2 验证 API 写入语义和跨账号标签可发现性](/davidqyc/momo-moreEfficient/issues/2)
2. [#3 构建批量释义录入 MVP](/davidqyc/momo-moreEfficient/issues/3)
3. [#4 仅在阻断项通过后构建例句录入](/davidqyc/momo-moreEfficient/issues/4)
4. [#5 构建桌面快速查词原型](/davidqyc/momo-moreEfficient/issues/5)
5. [#6 完成公开仓库与首个可用版本准备](/davidqyc/momo-moreEfficient/issues/6)
6. [#7 以真实维护和使用证据准备 Codex for Open Source 申请](/davidqyc/momo-moreEfficient/issues/7)

## 不可妥协的安全基线

- 真实墨墨 Token、Cookie、账号标识、个人词库导出和私人例句不得进入 Git 历史。
- 写入工具必须默认 `dry-run`，真实写入前逐批明确确认。
- 不修改墨墨内置词典释义，只处理明确选中的用户自建内容。
- 每次写入后必须回读并核对；部分失败不得静默继续执行破坏性更新。
- 正式批量写入前，只允许使用一条可丢弃测试数据完成冒烟验证。

## 协作方式

GitHub Issue 是工程任务的入口和事实坐标。Codex 开始工作前必须先阅读相关 Issue、`AGENTS.md` 和对应项目文档；不得仅依靠聊天历史推断需求。首轮项目背景由 ChatGPT 写入仓库，后续 Codex 以读取任务、实现代码和轻量更新事实状态为主。

- [Codex/Agent 工作规则](AGENTS.md)
- [产品需求与 API 验证计划](docs/product-and-api-plan.md)
- [Codex for Open Source 路线](docs/codex-for-open-source-plan.md)
- [决策记录](docs/decision-log.md)
- [安全说明](SECURITY.md)
- [贡献说明](CONTRIBUTING.md)

## 开源路径

仓库先保持短期私有，用于清理凭证风险并建立第一条可验证闭环。达到 [#6](/davidqyc/momo-moreEfficient/issues/6) 的公开门槛后尽快转为 Public；不等待所有功能完成，也不以空仓库公开时长作为目标。

## 免责声明

本项目与墨墨背单词及其运营方无官方隶属或背书关系。项目只使用公开提供的接口，并遵守对应 API、内容与账号规则。Maimemo/墨墨相关名称和商标归其权利人所有。
