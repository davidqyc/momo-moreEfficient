# Public copy style

This file records the public-facing wording rules for 小黑鸟伴侣 / momo-moreEfficient. It is about README, FAQ, product-page and release copy, not engineering naming inside the codebase.

## Chinese first: write like a user, not like an architecture document

- 先说“这个功能能帮我干什么”，再说实现机制。
- 标题优先使用用户会说的词，例如“快捷入口”“阅读时抓词”“共享”“快捷指令”，不要让 `App Intent`、`Share Extension`、state machine 等工程名占据用户标题。
- 技术名词确实有必要时，可以在正文后面补英文或工程名，但不要用工程名替代中文解释。
- 文案允许自然、有性格，例如“实用助手”“为爱发电”；但安全、隐私、发布状态等事实不能为了口语感而做无法保证的绝对承诺。
- 中文 README 默认结构不是传统“总—分—技术细节”，而是：简述 → 快捷入口 → 按覆盖面/频率排序的功能 → 功能进度 → 安全/反馈 → 开发者与历史资料。
- 旧功能、legacy CLI、工程细节放在后面或独立文档，不得压住当前用户入口。

## Unreleased features must show their stage first

任何当前公开版本里还不能用的功能，都必须先写阶段，再解释内容。禁止让正文读起来像已经上线。

推荐阶段词：

- **已上线**：当前公开版本真实可用；
- **即将上线**：主要实现已经完成，正在做发布前验证 / 体验选择 / 下一版发布准备；
- **开发中**：已经进入实际产品实现，但还没有达到“即将上线”；
- **调研中**：还在确认 API、平台合同、产品路线或可行性，没有进入正式公开实现；
- **暂未提供 / 暂缓**：当前没有可靠实现或近期不做。

对“即将上线 / 开发中 / 调研中”的功能，第一段必须明确说明它**不在当前公开 TestFlight / App Store 版本里**。

源码已完成 ≠ 已上线。README、FAQ、产品页和 AI/AEO 事实页必须保持这个区别。

## Frozen capture terminology — 抓词

阅读抓词功能的最终用户叫法已经冻结：

- 中文产品名：`抓词`；正文需要说明语境时可以用 `阅读抓词`；
- **共享**是推荐的正常日常入口；**快捷指令**是更快的预配置备选入口，两者都保留；
- 旧的临时工程/界面叫法 `捕获检查` / `capture review` 已经从用户可见界面和公开文案中退役，不再作为当前产品语言使用；
- 代码内部实现标识符（例如 `CaptureReviewStore`、`captureReviewSurface` 等）可以继续保留原名，这属于工程命名，不属于用户可见文案；
- Share Extension 的视觉打磨已明确推迟到后续统一视觉批次处理，不是当前发布的阻塞项；
- 公开文案仍须区分 source-main 与当前公开 TestFlight build：即使 `抓词` 源码已完成、真机验证已通过，只要还没有进入当前公开 build，就必须继续标注“即将上线”并说明当前 TestFlight 里还没有这个功能。

## English copy

English README should follow the same information architecture and directness instead of becoming a formal technical summary.

Prefer concrete user language such as:

- `practical helper for Maimemo`;
- `Quick links`;
- `Capture while reading — coming soon`;
- `Feature status`;

Keep exact Maimemo, Codex, TestFlight and security terms where they improve retrieval or factual precision, but do not lead with architecture jargon.

## Factual guardrail

Public copy must not make guarantees the project cannot enforce.

Examples:

- Do not say public Issues “will never contain” a Token, because a user could paste one manually. Say the project does not intentionally collect/write it there and tell users not to paste it.
- Do not say “one-click paste” unless the released UI actually provides a dedicated one-click paste action.
- Do not describe source-main functionality in present-tense user instructions if it has not shipped in the current public build.
