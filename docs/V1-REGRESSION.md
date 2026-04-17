# v1.0 回归测试 Checklist

> Swift 层的单元测试（PulseCore / PulseTestSupport）只覆盖读侧查询和
> 引擎逻辑，**不覆盖**用户实际看到的界面以及只有真机上才能验证的系
> 统集成。这份文档是打 `v1.0.0` tag 之前必须人工走一遍的回归清单。
>
> 请在一台 **已经使用 Pulse ≥ 7 个真实日**的 Mac 上跑这份清单（周
> 报 + 「与昨日对比」这两条路径都需要历史数据）。逐项确认时勾选方
> 框；如果某一项有问题，**单独提一个 issue**，**不要直接跳过那个
> 方框**。

---

## 0. 前置条件

- [ ] 从 `main` 干净编译：`swift build -c release` 在 macOS 14 与
      macOS 15 上都成功。
- [ ] `swift test --parallel` 在两个 OS 版本上全绿（CI 已经卡这一
      条，但还是用你本机的 toolchain 再跑一次）。
- [ ] 当前在跑的二进制已被授予 Input Monitoring + Accessibility 两
      项权限，且 `~/Library/Application Support/Pulse/pulse.sqlite`
      里有 ≥ 7 天的数据。
- [ ] 系统语言切换：分别切到 `en` 和 `zh-Hans`，确认 app 都能跟随
      切换且不需要重启。

## 1. 菜单栏

- [ ] 图标在亮色 / 暗色菜单栏下都正常渲染。
- [ ] A19b 的异常红点：当任意指标偏离 7 日中位数 ±30% 时出现。可
      以临时改 `AnomalyDetector` 的阈值，或选一个历史数据满足条件
      的日子来验证。
- [ ] 暂停菜单：15 / 30 / 60 min 三档分别能正确暂停采集对应时长，
      并到点自动恢复（A5）。打开 health 面板确认 `PauseController`
      的状态。
- [ ] 「显示昨日简报」菜单项点了能立即弹出 A18 窗口。
- [ ] 「生成本周报告」菜单项把 HTML 写到
      `~/Library/Application Support/Pulse/reports/weekly-YYYY-MM-DD.html`
      并在 Finder 里高亮（A19）。
- [ ] 「导出数据」会写出一份 `ExportBundle` JSON 并在 Finder 里高
      亮（A21）。对比 `Sources/PulseCore/Reports/DataExport.swift`
      抽查一下 JSON 字段结构。
- [ ] 「Show what Pulse has recorded」打开 A22 自审窗口，能流式拉
      出原始行；在全新安装的空数据库上也不能崩。

## 2. Dashboard 窗口

- [ ] 从菜单栏打开：M 系列芯片上首次渲染应在 2 秒内完成（对应
      `docs/11-ux-principles.md` 的「3 分钟 wow」预算）。
- [ ] A8 权限横幅只在 Input Monitoring 或 Accessibility 被吊销时
      才出现；点击它能 deep-link 跳到对应的系统设置面板（A6）。
- [ ] Dashboard 顶部的目标行（A20）—— 启用每个预设、让一天累积下
      来，确认 ✅ / ❌ 标识和进度条与原始查询输出一致。
- [ ] 6 张 summary 卡片（距离 / 点击 / 滚动 / 按键 / 活跃 / 空
      闲）每张都有 7 日 sparkline + 「与昨日对比」delta（A17b）。
      delta 颜色在 0 处应该翻转。
- [ ] 热力图（A2 / A12）—— 在 3 / 7 / 14 / 30 天之间切换窗口大
      小，渐变色和「峰值小时」副标题（A17a）应当无闪烁地更新。
- [ ] 应用排行图（A7 / A14）使用了友好的显示名；一个还没收录到查
      找表里的全新 app 应当能优雅 fallback。
- [ ] 鼠标里程 hero 卡（A3）：当今天跨过任意 landmark 阈值时，会
      亮一个里程碑（F-25 / A17a）。
- [ ] 深度专注卡（A16）—— 「今日最长片段」应当与你手动扫描某一已
      知日 `min_switches` 表得到的结果一致。
- [ ] 会话节奏卡（A23）—— 「Deep-worker / Steady flow / Short-form
      / Checker」分档标签会随当天进展翻转。
- [ ] 空闲时长卡（A15）应当与今天的
      `hour_summary.idle_seconds` 一致。
- [ ] 诊断 / 健康卡（A11）在采集正常时应该是绿色；强制 quit + 重
      启 writer，确认它能识别并标出这段空缺。

## 3. 留存钩子（这是 v1.0 之所以存在的理由）

- [ ] A18 每日简报：锁屏，等到第二天再解锁。简报窗口应当**仅出现
      一次**（latch 落在 `UserDefaults` 里）。文案应当走
      NarrativeEngine 的故事化句式，不是裸数字。
- [ ] A19b 周一自动周报：在任何一个周一第一次解锁时，HTML 周报应
      当无需用户操作就生成，菜单栏异常红点在你查看后清除。要在周
      中验证，把 `weeklyReport.lastAutoRun` 的 default 删掉重试。
- [ ] A19 周报 HTML：用 Safari + Chrome 各打开一次，确认图表能渲
      染，**且没有任何远程资源请求**（在 Web Inspector → Network
      里看，应该是空的——这是隐私承诺的一部分）。

## 4. 隐私承诺面板（评审 §3.7）

- [ ] `05-privacy.md` 的红线列表：每一条都对照对应的 schema / 代码
      路径抽查一遍，确认它声称不存的东西真的没存。
- [ ] A22 自审窗口：确认你最近一小时的 `events.payload` 里**绝不
      包含任何字符或剪贴板内容**。
- [ ] `TitleHasher` —— `min_app` 里的窗口标题默认应当是哈希后的；
      如果你在偏好里临时切换到明文模式（如果该开关已经暴露），明
      文应当**只出现在当前 session**。
- [ ] 出站网络：在 Pulse 运行时跑 `lsof -i -nP | grep Pulse`。应
      该是**零**连接（更新检查目前还没接，确认这个状态保持）。

## 5. 系统事件

- [ ] 合上盖子，再打开：`system_events` 里应当出现对应行，时间戳
      正确（B4）。
- [ ] 笔记本拔掉电源：`power_state` 切换被记录。
- [ ] `caffeinate -i` 持续 2 min 然后停掉：空闲检测（B3 / B6）应
      当正确框出活跃窗口。
- [ ] 多显示器：在两块显示器之间拖拽，鼠标里程使用归一化坐标系累
      加（B3）—— 跟单显示器下做相似动作的累加值对比。

## 6. i18n

- [ ] 系统设置 → 语言与地区切到「简体中文」。所有可见字符串应当
      切换；不能回退到 `en` 占位符。
- [ ] 在会话中途切回英语。窗口应当重新渲染，不需要重启。
- [ ] 周报 HTML 使用的是它**渲染时**的 locale（不是当前 UI 的
      locale —— 这是有意为之的）。

## 7. 已知未实现的 v1.0.0 tag 阻塞项

这些**不是**回归，是从来没做过的事。列在这里是为了在它们 land 之
前（或者 scope 被明确推到 v1.0.1）不要打 tag。

- [ ] ~~评审 §5 立刻 #1 —— `docs/06-onboarding-permissions.md` 的
      欢迎屏 → 隐私承诺 checkbox → 引导 Input Monitoring 授权 →
      引导 Accessibility 授权。~~ ✅ A25 已 land（PR #45）。
- [ ] 评审 §5 立刻 #2 —— Developer ID 签名、`notarytool` 上传、
      Sparkle appcast。`Makefile` 当前没有 `sign` / `release`
      target。`docs/07-distribution.md` 描述了预期流程。**这是
      v1.0.0 正式 tag 唯一剩下的 blocker**；rc1 用 ad-hoc 签名先
      让你拿到包做回归。
- [ ] 更新检查的出站调用（必须在 Sparkle ship 之前存在，并且
      §4 隐私审计文案要更新成「除更新检查外零出站」）。

## 8. Sign-off

- [ ] §§0–6 所有框都打勾。
- [ ] §7 的剩余项要么 land 了，要么在 `CHANGELOG.md` 里**显式推
      迟**到下一个版本，并附 issue 链接。
- [ ] `CHANGELOG.md` 把 `[1.0.0-rc1]` 升级成 `[1.0.0] — <date>`。
- [ ] 通过 `tag-release` workflow 创建 tag `v1.0.0` 并推送（或者
      `git tag -s v1.0.0 && git push origin v1.0.0` 如果你本地有签
      名密钥）。
- [ ] `package` workflow 跑完后，去 GitHub Release 页面把生成的
      pre-Release 升级成正式 Release，并把 §7 #2 完成后的签名
      DMG 也附上去。
