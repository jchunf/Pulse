# 04 — 技术架构 Architecture

> 本文档记录 Pulse 的技术栈决策、模块边界、关键数据流，以及在设计阶段就必须拍板的工程陷阱（多显示器坐标系、CGEventTap 电量、降采样策略、可观测性、数据可移植性）。

## 一、技术栈决策

| 领域 | 选择 | 备选 | 放弃备选的原因 |
|---|---|---|---|
| 主语言 | **Swift 5.9+** | Swift + Rust 混合 | Rust 在 MVP 阶段没有性能瓶颈值得 FFI；CGEventTap 必须 Swift/ObjC |
| UI 框架 | **SwiftUI**（macOS 13+） | AppKit 原生 | SwiftUI 迭代快、Charts 直接可用；AppKit 只在需要精细控制的视图（鼠标热力图）里内嵌 |
| 图表 | **Swift Charts** | Core Plot / 自绘 | 原生、与 SwiftUI 无缝、够用 |
| 鼠标热力图渲染 | **Metal**（可选 `MetalKit.MTKView` 内嵌 SwiftUI） | Core Graphics | 数据量大（数十万点）时只有 Metal 够快；CG 作为 fallback |
| 数据库 | **SQLite + GRDB.swift** | SQLite.swift / Core Data | GRDB 原生、写性能好、有事务与 WAL 良好支持；Core Data 对裸 SQL 聚合不友好 |
| 登录启动 | **SMAppService**（macOS 13+） | launchd plist | SMAppService 是 Apple 官方推荐 API，权限管理干净 |
| 打包 | Xcode Build + `codesign` + `notarytool` | Homebrew cask（仅分发，不打包） | 签名+公证是分发硬要求 |
| 自动更新 | **Sparkle 2.x** | 自研 | 业界标准，支持 EdDSA 签名的更新包 |
| CI | GitHub Actions（macOS runner） | Xcode Cloud | 免费、写好的脚本可复用到本地 |
| 依赖管理 | **Swift Package Manager** | CocoaPods / Carthage | SPM 已足够成熟 |

## 二、进程模型

**单进程 app，不拆独立守护进程。**

- `Info.plist`：`LSUIElement = 1` → 不显示 Dock 图标，只出现在菜单栏
- 登录启动：`SMAppService.mainApp.register()`（用户可在系统设置里关闭）
- 崩溃恢复：launchd `KeepAlive` 由 SMAppService 自动处理

**为什么不拆独立守护进程？** 理论上 XPC 独立 daemon 能在 UI 挂掉时继续采集，但：
1. 多一层 XPC 增加开发/调试复杂度
2. macOS 13+ 对非签名 daemon 越来越严格
3. 采集进程崩了 UI 不崩，本身就是个 bug；就近用同一 app 内部 actor 隔离即可

## 三、模块边界

```
┌─────────────────────────────────────────────────────────────┐
│                      Pulse.app (单进程)                     │
├───────────────────┬────────────────┬────────────────────────┤
│ CollectorCore     │ Aggregator     │  UI (SwiftUI)          │
│ (采集层)          │ (聚合/降采样)  │                        │
│                   │                │                        │
│  - EventTapWorker │  - RollupJob   │  - DashboardView       │
│  - AppWatcher     │  - PurgeJob    │  - AppRankingView      │
│  - WindowWatcher  │  - VacuumJob   │  - TimeHeatmapView     │
│  - SystemWatcher  │                │  - MouseTrailView      │
│  - IdleDetector   │                │  - HealthPanel (自检)  │
├───────────────────┴────────────────┴────────────────────────┤
│                      Storage (GRDB)                         │
│  - MigrationRegistry / Pool / WAL                           │
├─────────────────────────────────────────────────────────────┤
│                PermissionService / UpdateService            │
└─────────────────────────────────────────────────────────────┘
```

**通信方式**：采集 → Storage 用 Swift Concurrency 的 actor 隔离；UI ← Storage 用 Combine/AsyncStream 订阅变更。

## 四、关键工程决策（在此落地，避免实现时返工）

### 4.1 多显示器 / HiDPI / Retina 坐标系

**决策：存归一化 [0,1] + 显示器元数据 + 物理 DPI。**

- 每次 `CGEventTap` 得到的绝对坐标，先查当前 `displayID` 和其分辨率 → 转成 `(x_norm, y_norm) ∈ [0,1]`
- 显示器元数据存在 `display_snapshots` 表，带 `ts`，每次显示器配置变化写新快照
- 渲染热力图时：`x_px = x_norm * resolution.width @ snapshot_at(ts)`
- 物理里程：`mm = pixel_distance * (25.4 / dpi @ snapshot_at(ts))`

**为什么不用绝对像素？** 用户插拔外显、改分辨率、从 MacBook 切到外接 4K → 历史数据全部失真。归一化方案一次搞定。

### 4.2 CGEventTap 电量与性能策略

- 运行频率：**事件驱动 + 自适应降频**
  - 有活动时按系统原生速率
  - 无事件 30 秒后：进入"低功耗采样"，仅记录下次活动的首个事件
- App Nap：**主动拒绝** — 采集 app 永远不能被挂起。用 `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep)`
- 写库策略：事件先入内存 ring buffer，每 1 秒批量 flush（减少 I/O）；崩溃时最多丢 1s 事件
- Intel Mac 警示：Intel Mac 持续 CGEventTap 对电池影响明显，提供"节能模式"开关（只记分钟级聚合，不记 L0 原始流）

### 4.3 降采样（Rollup）策略

见 `03-data-collection.md` 第二节。工程要点：

- Rollup 作业不锁采集写入：用 SQLite 的 WAL + 按分区拷贝再删除
- 分维度策略：
  - **坐标流**（L0 `raw_mouse_moves`）：7 天硬清理，因为热力图只在近期有意义
  - **统计指标**（L2/L3）：分钟 → 小时降采样可以长留，不牺牲趋势
- Rollup 幂等：作业失败重跑不会重复计数（用 `(ts_minute, bundle_id)` 做 PK）

### 4.4 自检与可观测性（HealthPanel）

采集类 app 最怕"静默失败"。提供内部状态页，用户可见：

- 当前采集状态（运行/暂停/无权限）
- 近 1h/24h/7d 的事件数（分别显示鼠标/键盘/应用切换）
- 最近一次成功写入时间（> 60s 无写入 → 红色告警）
- 数据库大小 + 各表行数
- 权限清单 + 每项是否已授权
- 最近 10 条错误日志
- 手动触发 Rollup / Purge / Vacuum 按钮（给高级用户/调试用）

### 4.5 数据可移植性

- 导出：整库 SQLite 文件 + AES-256-GCM 加密（密码由用户提供）→ 单文件 `.pulse` 备份
- 导入：支持从 `.pulse` 文件恢复；检测目标库已有数据时询问"合并/覆盖"
- Schema 版本号：每次迁移 `PRAGMA user_version = N`；迁移脚本 `migrations/V{n}__desc.sql`
- 降级兼容：只保证向前兼容（新版能读旧数据）；从新版降级到旧版不保证

### 4.6 数据目录与配置

| 路径 | 内容 |
|---|---|
| `~/Library/Application Support/Pulse/pulse.db` | 主数据库 |
| `~/Library/Application Support/Pulse/pulse.db-wal` / `-shm` | WAL 文件 |
| `~/Library/Application Support/Pulse/backups/` | 自动备份（每周 1 个，保留 4 周） |
| `~/Library/Preferences/com.pulse.app.plist` | 用户偏好设置 |
| `~/Library/Logs/Pulse/` | 运行日志（10MB 循环） |

## 五、数据流示例：一次鼠标移动

```
CGEventTap callback
  └─> EventTapWorker.handle(event)
        └─> 计算 displayID + 归一化坐标
        └─> 投递到 Actor: MouseCollector
              └─> ring buffer 累加（秒级计数 + 距离）
              └─> 每 1 秒 flush 到 `raw_mouse_moves` + `sec_mouse`
       (异步)
Aggregator.rollRawToSec (每 60s)
  └─> 查 raw_* → 写 sec_*
Aggregator.rollSecToMin (每 5min)
  └─> 查 sec_* → 写 min_*
Aggregator.purgeExpired (每日凌晨)
  └─> DELETE FROM raw_mouse_moves WHERE ts < now - 14d
```

## 六、测试策略

| 层 | 手段 |
|---|---|
| Collector | 伪造 `CGEvent` 注入，断言事件入库形状正确 |
| Aggregator | Fixture DB + 时间冻结，断言聚合幂等 |
| Storage | 迁移测试：V1 → V2 → V3 数据无损 |
| UI | SwiftUI preview + XCUITest 截图快照 |
| 性能 | Instruments Time Profiler 跑 24h 模拟负载 |
| 端到端 | 手动 smoke test：空权限启动 → 引导 → 授权 → 看仪表盘有数据 |

## 七、不做的架构选择

- ❌ 独立守护进程（见 §二）
- ❌ Rust 存储/计算后端（见 §一）
- ❌ iCloud / 账户系统（违反"零上传"，见 `05-privacy.md`）
- ❌ 插件系统（MVP 阶段增加太多攻击面和测试负担）
- ❌ 集成 AI 分析（本地跑 LLM 成本高，云端违反隐私原则；未来可做端侧小模型）

---

## 相关文档

- 采集什么数据、什么粒度 → `03-data-collection.md`
- 敏感数据的处理细节 → `05-privacy.md`
- 权限申请流程 → `06-onboarding-permissions.md`
- 签名/公证/更新如何打通 → `07-distribution.md`
- 自检状态页的具体展示 → `02-features.md#F-49`
