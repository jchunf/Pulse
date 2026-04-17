# Pulse

> **数字体检 · 本地心跳 · 只有你自己看得到。**

Pulse 是一个 **macOS 本地优先（local-first）** 的后台常驻应用，把你"无意识"的电脑使用行为——前台应用切换、鼠标轨迹、键盘节奏、系统状态——可视化成一份属于你自己的数字体检报告。

**数据 100% 留在你的 Mac 上。没有服务器，没有账户，没有遥测。**

---

## 这是什么阶段？

**B1–B8 数据底子 + A1–A23 MVP + 留存 / 叙事 / 目标 / 隐私自证全部落地**。`reviews/2026-04-17-product-direction.md` 列出的 v1.0 三大缺口（§2.1 留存钩子、§2.2 叙事引擎、§2.3 目标层）已经封口，§3.5 导出、§3.6 会话姿势、§3.7 隐私自审也陆续随附送交付。仓库里现在能跑的东西：

- **采集 (B 段)** — CGEventTap 实时事件流 · 多显示器归一化坐标 · 距离累加 (F-07) · 系统事件 (sleep/wake/lock/lid/power) · AX 窗口标题哈希 · 每秒/每分/每小时 rollup · 前台 app 使用时长 + 切换计数 · idle 时间 · 滚轮计数 · 全保留 WAL SQLite。
- **MVP 三件套 (A 段)** — 应用排行 (F-02) · 24h × N-day 热力图 (F-03, 3/7/14/30 天可调) · 鼠标里程戏剧 (F-07) + Landmark 里程碑横幅 (F-25)。
- **A 段其他 Dashboard / 菜单栏** — 7 日趋势折线 (F-01) · 暂停控件 15/30/60 min (F-46) · 权限恢复助手 (菜单栏 + Dashboard 两处) · Settings 偏好 (刷新频率 + 热力图天数) · 运行健康诊断卡 (F-49) · 6 张 summary 卡 (距离 / 点击 / 滚轮 / 按键 / 活跃 / 空闲) 带 sparkline + delta · 应用显示名自动翻译 · 多 Landmark 进度条 · 热力图渐变 + 峰值时段洞察。
- **A 段留存与叙事（评审 §2）** — **A16** `NarrativeEngine` + 深度专注卡 · **A17** 多 landmark 进度 + summary sparkline / delta · **A18** 首次解锁时弹昨日简报（`NSWorkspace.didWakeNotification` + 当日 UserDefaults 门闩）· **A19 / A19b** 周一自动生成 HTML 周报 + 菜单栏异常红点 (±30% 偏离 7 日中位数)。
- **A 段目标 / 导出 / 隐私（评审 §2.3 / §3.5 / §3.7 / §3.6）** — **A20** 目标 / 意图层 (4 预设 × atLeast/atMost，Dashboard 顶部进度条) · **A21** `ExportBundle` JSON 导出 (菜单栏一键落盘并高亮 Finder) · **A22** 「Show what Pulse has recorded」隐私自审窗 (Settings 入口，直读 SQLite 原始行 + 最近 1h 系统事件账本) · **A23** 今日会话节奏卡 (sessions / 中位数 / 平均 / 最长 + 「Deep-worker / Steady flow / Short-form / Checker」分档标签)。
- **i18n** — String Catalog 跨 A / B 全面本地化，en + zh-Hans 双语随系统语言切换。

路线 **B → A → C**：B 段数据管线 + A 段 MVP + 留存 / 叙事 / 目标 / 隐私自证均已完成；剩下的 A 段主要是 **分发与打包**（Developer ID 签名、notarization、Sparkle）——这些需要完整 Xcode 项目，超出了当前 SPM 工程范围。C 段长尾功能按 `docs/08-roadmap.md` 队列推进。

各 slice 的详细交付 / 推迟清单见下方 `A*-PROGRESS.md` / `B*-PROGRESS.md` 链接。

## 本地构建

需要 macOS 14+、Xcode 16+（Swift Testing 依赖）。

```bash
git clone <this repo> && cd Pulse
swift package resolve
swift build
swift test --parallel --enable-code-coverage
```

或直接在 Xcode 中打开：

```bash
open Package.swift
```

其他常用命令见 `Makefile`（`make help`）。

## 在自己的 Mac 上跑（无需 Apple Developer 账号）

`swift run PulseApp` 出来的是裸二进制，没有 `Info.plist` / bundle ID，macOS 不会给它授予 Input Monitoring / Accessibility 权限，采集管线形同虚设。要真正验证功能，用本仓库的打包脚本生成一个 **ad-hoc 签名的 `.app` bundle**：

```bash
make app          # dist/Pulse.app (native arch)
make run          # 上一步 + 直接 open
```

首次打开时：

1. Finder 里 **右键 Pulse.app → 打开 → 打开** 一次（绕过 Gatekeeper 的"无法验证"提示，后续双击即可）。  
   或者 `xattr -dr com.apple.quarantine dist/Pulse.app` 一键清除检疫属性。
2. 菜单栏出现 Pulse 图标。打开 Dashboard 后，权限横幅 (A8) 会深链到系统设置；依次给 **Input Monitoring** 和 **Accessibility** 勾选。
3. 授权 Input Monitoring 后 macOS 会重启 Pulse，正常现象。

> **注意**：ad-hoc 签名没有稳定的 Team ID；如果你重新 `make app` 且 Gatekeeper 认为 codesign identity 变了，可能需要再授权一次权限。正式 Developer ID 签名后就会稳定下来（见 `docs/07-distribution.md`，仍是 v1.0 blocker）。

完整的 v1.0 回归清单见 [`docs/V1-REGRESSION.md`](docs/V1-REGRESSION.md)。

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
| B1 | [B1-PROGRESS](docs/B1-PROGRESS.md) | 数据底子：SPM 骨架 + 协议 + V1 schema + CI |
| B2 | [B2-PROGRESS](docs/B2-PROGRESS.md) | 实时采集：runtime + writer + scheduler + HealthPanel |
| B3 | [B3-PROGRESS](docs/B3-PROGRESS.md) | 采集补完：距离累加 + idle-tick 钩子 + 系统事件 emitter |
| B4 | [B4-PROGRESS](docs/B4-PROGRESS.md) | IOKit lid/power observer + AX 标题变更监听 |
| B5 | [B5-PROGRESS](docs/B5-PROGRESS.md) | App 使用 rollup 管线（system_events → min_app → hour_app）|
| B6 | —（见下方"未单独立档的 slice"）| 空闲时长 rollup（system_events → min_idle → hour_summary.idle_seconds）|
| B7 | —（见下方"未单独立档的 slice"）| 滚轮 rollup 全管线 + V3 迁移 + 第 6 张 summary 卡 |
| B8 | —（见下方"未单独立档的 slice"）| foregroundAppToMin 顺带填 min_switches.app_switch_count |
| A1 | [A1-PROGRESS](docs/A1-PROGRESS.md) | Dashboard 窗口 + 应用使用排行 + 读侧查询层 |
| A2 | [A2-PROGRESS](docs/A2-PROGRESS.md) | 24h × 7d 热力图（F-03，三件套完工）|
| A3 | [A3-PROGRESS](docs/A3-PROGRESS.md) | 鼠标里程 hero card（F-07 "核心上瘾点"）|
| A4 | [A4-PROGRESS](docs/A4-PROGRESS.md) | 7 日趋势折线 (F-01 基础版) |
| A5 | [A5-PROGRESS](docs/A5-PROGRESS.md) | 暂停控件 15/30/60 min + Resume (F-46 基础版) |
| A6 | [A6-PROGRESS](docs/A6-PROGRESS.md) | 菜单栏权限恢复助手 (F-49 深化) |
| A7 | [A7-PROGRESS](docs/A7-PROGRESS.md) | 应用排行查询切到 min_app / hour_app |

### 未单独立档的 slice

早期 slice 每一个都写了 PROGRESS 文档；后续小步快跑节奏下，若改动本身已在 PR 描述 + commit message 里讲清，就直接合入 main 而不再新增 `Ai-PROGRESS.md`。完整列表（按合入顺序）：

- A8 Dashboard 权限警告横幅 · A9 应用激活时刷新 · A10 Settings 面板 + 刷新频率偏好 · A11 诊断卡 (F-49) · A12 热力图天数可配置 · A13 里程碑成就横幅 (F-25) · A14 应用排行显示名解析 · A15 Dashboard idle 时长 · B6 idle rollup · B7 scroll rollup + V3 · B8 min_switches 填充
- A16 `NarrativeEngine` + 深度专注卡 · A17 多 landmark 进度 / summary sparkline + delta / 热力图渐变 · A18 首次解锁时弹昨日简报 · A19 / A19b 每周一自动生成 HTML 周报 + 菜单栏异常红点 · A20 目标 / 意图层 · A21 JSON 数据导出 + Swift 6 并发告警清理 · A22 隐私自审窗口 · A23 今日节奏 / 会话姿势卡
- i18n PR #31 引入 String Catalog；后续 A16–A23 每个 PR 顺带补充双语 key
- 一次修复：`todaySummary` 分层查询漏掉 `hour_summary` 层导致跨小时数据被丢

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

macOS 14+（Sonoma 及以后；Swift Testing + SwiftUI Charts 的最低要求）。不上 Mac App Store（原因见 [07-distribution.md](docs/07-distribution.md)）。

## 贡献与反馈

当前为私人设计阶段。待 MVP（v0.1）发布后开放内测邀请。
