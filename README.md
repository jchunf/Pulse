# Pulse

> **数字体检 · 本地心跳 · 只有你自己看得到。**

Pulse 是一个 **macOS 本地优先（local-first）** 的后台常驻应用，把你"无意识"的电脑使用行为——前台应用切换、鼠标轨迹、键盘节奏、系统状态——可视化成一份属于你自己的数字体检报告。

**数据 100% 留在你的 Mac 上。没有服务器，没有账户，没有遥测。**

---

## 这是什么阶段？

当前仓库处于 **设计阶段**。暂无代码，只有设计文档。

实现将按 **B → A → C** 顺序推进：先打数据底子（`04-architecture.md`），再串通 MVP（三件套：应用排行 + 时段热力 + 鼠标里程表），最后扩展 UI 与长尾功能。

---

## 文档索引

| # | 文档 | 内容 |
|---|---|---|
| 00 | [产品愿景 Vision](docs/00-vision.md) | 定位、目标用户、核心价值、和同类产品差异 |
| 01 | [需求记录 Requirements](docs/01-requirements.md) | 原始对话需求 + 结构化 FR/NFR/约束 |
| 02 | [功能清单 Features](docs/02-features.md) | 49 项功能，按 A/B/C/D 分组 + 版本路线 |
| 03 | [数据采集 Data Collection](docs/03-data-collection.md) | 采集项明细、分层降采样、SQLite schema |
| 04 | [技术架构 Architecture](docs/04-architecture.md) | 技术栈、模块边界、多显示器坐标系、电量策略 |
| 05 | [隐私设计 Privacy](docs/05-privacy.md) | 红线清单、分级、用户控制、PR 审计 checklist |
| 06 | [启动引导 Onboarding](docs/06-onboarding-permissions.md) | 首次启动流程、权限申请、自检恢复 |
| 07 | [分发与更新 Distribution](docs/07-distribution.md) | 签名、公证、Sparkle、为什么不上 App Store |
| 08 | [路线图 Roadmap](docs/08-roadmap.md) | MVP 范围、里程碑、后续版本队列 |
| 09 | [待决策问题 Open Questions](docs/09-open-questions.md) | 设计阶段遗留问题、建议答案、**优先级快查表** |
| 10 | [测试与 CI Testing & CI](docs/10-testing-and-ci.md) | TDD 工作流、测试金字塔、CI 流水线、性能基准 |
| 11 | [用户中心设计原则 UX Principles](docs/11-ux-principles.md) | 3 分钟哇、≤3 次点击、数据故事化、无障碍、可用性测试 |

---

## 核心原则

1. **本地优先** —— 数据不出你的磁盘
2. **最小化采集** —— 能聚合不原始，能哈希不明文
3. **隐私默认保守** —— 中/高敏感项默认关闭
4. **有趣 > 有用** —— 把枯燥统计变成戏剧性可视化
5. **可审计** —— 代码结构经得起隐私审查
6. **TDD + CI** —— 测试先行，每次推送自动验证
7. **用户中心** —— 3 分钟哇、≤3 次点击、无障碍全覆盖

---

## 产品名

**Pulse**（脉搏）—— 电脑是你工作与生活的另一副身体。它每天都在产生数据，但很少有人定期"测一次脉搏"。

---

## 平台

macOS 13+（Ventura 及以后）。不上 Mac App Store（原因见 [07-distribution.md](docs/07-distribution.md)）。

## 贡献与反馈

当前为私人设计阶段。待 MVP（v0.1）发布后开放内测邀请。
