# 03 — 数据采集 Data Collection

> 本文档定义 Pulse 采集哪些数据、以什么频率、以什么粒度、保留多久、隐私分级、以及每项数据支撑哪些功能。所有 SQLite schema 以本文档为事实来源。

## 一、采集源总览

| 源 | 来源 API | 事件/状态 | 用到的功能 |
|---|---|---|---|
| 鼠标 | `CGEventTap`（Input Monitoring 权限） | 移动、点击、滚轮 | F-04, F-07, F-15, F-16, F-17, F-18, F-25 |
| 键盘 | `CGEventTap`（Input Monitoring 权限） | 按键事件（只取元数据） | F-08, F-12, F-19, F-20, F-33 |
| 前台应用 | `NSWorkspace.didActivateApplicationNotification` | 前台切换 | F-01, F-02, F-03, F-05, F-09~F-11, F-13, F-14, F-21~F-23 |
| 窗口标题 | Accessibility API（Accessibility 权限） | 前台窗口标题 | F-10, F-22 |
| 系统状态 | `NSWorkspace` / `IOPowerSources` / `DNServer` | 睡眠/唤醒/锁屏/合盖/电源/专注模式 | F-26~F-28, F-37, F-38 |
| 硬件指标 | `host_statistics64` / `task_info` | CPU/GPU/内存/电池百分比 | F-29 |
| 外设 | `AVCaptureDevice` / IOKit | 麦克风/摄像头占用 | F-30 |
| 输入法 | `TISCopyCurrentKeyboardInputSource` | 输入法切换 | F-31 |
| 剪贴板 | `NSPasteboard.changeCount` | 剪贴板事件计数（**不读内容**） | F-32 |
| 环境光 | `IOServiceGetMatchingService(AppleLMUController)` | 亮度 / 环境光 | F-34 |
| 网络 | `CoreWLAN`（需位置权限，默认关闭） | WiFi SSID 名称 | F-35 |
| 日历 | EventKit（需授权，默认关闭） | 开会时段 | F-36 |
| 显示器 | `CGDisplayRegisterReconfigurationCallback` | 分辨率/DPI/数量变化 | 所有鼠标相关功能 |

## 二、数据分层与保留策略

采用 **L0→L3 四级降采样**，不同层保留期不同，避免长期数据爆磁盘。

| 层 | 粒度 | 保留期 | 典型表 | 估算体积（重度用户/年） |
|---|---|---|---|---|
| **L0** 原始事件流 | 单次事件 | 7–14 天 | `raw_mouse_moves`, `raw_key_events` | 滚动保持 ~20MB |
| **L1** 秒级聚合 | 1 秒一行 | 30 天 | `sec_activity`, `sec_mouse`, `sec_key` | ~30MB / 30 天 |
| **L2** 分钟级聚合 | 1 分钟一行 | 1 年 | `min_app`, `min_mouse`, `min_key`, `min_idle` | ~40MB / 年 |
| **L3** 小时级聚合 | 1 小时一行 | **永久** | `hour_app`, `hour_summary` | ~5MB / 年 |
| **状态快照** | 事件触发 | 永久 | `system_events` | 可忽略 |

**总体目标**：重度用户（每天 12h+ 使用）第 1 年磁盘占用 ≤ 100MB；之后每年新增 ~50MB。

## 三、采集项明细（D-XX）

> 每项字段：`ID / 名称 / 描述 / 频率 / 是否敏感 / 默认开启 / 所需权限 / 对应功能`

### 鼠标类 D-M

| ID | 字段 | 描述 | 频率 | 敏感 | 默认 | 权限 |
|---|---|---|---|---|---|---|
| D-M1 | 累计位移 | 每秒累计像素位移（→毫米） | 1 Hz 聚合（L1） | 低 | 开 | Input Monitoring |
| D-M2 | 坐标采样 | `(x,y,displayID,ts)` 归一化到 [0,1] | 10–30Hz 可变 | 中 | 开 | Input Monitoring |
| D-M3 | 点击事件 | `(button_type, double_click?, ts, displayID)` | 事件触发 | 低 | 开 | Input Monitoring |
| D-M4 | 滚轮事件 | `(delta, horizontal?, ts)` | 事件触发 | 低 | 开 | Input Monitoring |

### 键盘类 D-K

| ID | 字段 | 描述 | 频率 | 敏感 | 默认 | 权限 |
|---|---|---|---|---|---|---|
| D-K1 | 按键总数 | 每秒按键次数 | 1 Hz 聚合 | 低 | 开 | Input Monitoring |
| D-K2 | 键码分布 | 每秒各 keyCode 计数（QWERTY 热力图用） | 1 Hz 聚合 | **中** | **关**（可选开启，见 05-privacy.md） | Input Monitoring |
| D-K3 | 快捷键计数 | `cmd+c/v/z/…` 组合计数 | 事件触发 | 低 | 开 | Input Monitoring |
| D-K4 | 按键间隔分布 | 相邻按键间隔直方图（秒级聚合） | 1 Hz 聚合 | 低 | 开 | Input Monitoring |

### 应用与窗口 D-A

| ID | 字段 | 描述 | 频率 | 敏感 | 默认 | 权限 |
|---|---|---|---|---|---|---|
| D-A1 | 前台 App | `(bundleId, ts_start, ts_end)` | 切换触发 | 低 | 开 | 无 |
| D-A2 | 应用切换计数 | 每分钟前台切换次数 | 1 min 聚合 | 低 | 开 | 无 |
| D-A3 | 开启窗口集合 | 每分钟当前打开的 App 集合快照 | 1 min 采样 | 低 | 开 | 无 |
| D-A4 | 窗口标题（哈希） | 标题 SHA-256 哈希 + App bundleId；相同标题合并计数 | 切换触发 | **中** | 开 | Accessibility |
| D-A5 | 窗口标题（明文） | 标题原文 | 切换触发 | **高** | **关** | Accessibility |

### 空闲与系统 D-S / D-I

| ID | 字段 | 描述 | 频率 | 敏感 | 默认 | 权限 |
|---|---|---|---|---|---|---|
| D-I1 | 空闲检测 | 无事件 > 5 分钟 → 写入空闲段 `(ts_start, ts_end)` | 检测触发 | 低 | 开 | 无 |
| D-I2 | 剪贴板计数 | `NSPasteboard.changeCount` 的增量 | 1 Hz 轮询 | 低 | 开 | 无（**绝不读内容**） |
| D-S1 | 屏幕锁/解锁 | 触发事件 | 事件触发 | 低 | 开 | 无 |
| D-S2 | 睡眠/唤醒/合盖 | 触发事件 + 单次时长 | 事件触发 | 低 | 开 | 无 |
| D-S3 | 电源状态 | 电池/接电 + 电量百分比 | 事件触发 + 5min 轮询 | 低 | 开 | 无 |
| D-S4 | 相机/麦克风占用 | `isRunning` 状态变化 | 事件触发 | 中 | 开 | 无（观察状态，不接入媒体） |
| D-S5 | 输入法切换 | 当前输入法 ID + 切换时间 | 事件触发 | 低 | 开 | 无 |
| D-S6 | WiFi SSID | 当前 SSID 哈希（可选：明文） | 变化触发 | **中** | **关** | 位置权限 |
| D-S7 | Focus Mode | 系统专注模式切换 | 事件触发 | 低 | 开 | 无 |
| D-S8 | 通知计数 | 今日被通知打断次数（仅计数） | 事件触发 | 中 | 待评估 | 高风险（见 09-open-questions.md Q-03） |

### 硬件与环境 D-H / D-E

| ID | 字段 | 描述 | 频率 | 敏感 | 默认 | 权限 |
|---|---|---|---|---|---|---|
| D-H1 | CPU/GPU/内存 | 采样百分比 | 1 min 轮询 | 低 | 开 | 无 |
| D-E1 | 环境光 | 环境光 lux 值 | 1 min 轮询 | 低 | 开 | 无（但传感器不一定所有 Mac 都有） |

### 显示器元数据 D-D

| ID | 字段 | 描述 |
|---|---|---|
| D-D1 | `displayID` | 系统分配 ID |
| D-D2 | `dpi_physical` | 物理 DPI（毫米换算用） |
| D-D3 | `resolution` | 当前分辨率 |
| D-D4 | `is_primary` | 是否主屏 |

**这张表非常关键**：所有鼠标坐标都存归一化 [0,1] 值，渲染时再乘以当时的 `resolution × dpi`。这样多显示器切换、插拔外屏、改分辨率都不会让历史数据失真。

### 外部集成 D-X（用户授权才启用）

| ID | 字段 | 描述 | 默认 |
|---|---|---|---|
| D-X1 | 日历事件 | 标题（可选明文或只取 `is_meeting` 布尔）+ 时段 | 关 |

## 四、降采样作业（Aggregation Jobs）

由后台定时任务触发，**不阻塞**采集路径：

| 作业 | 频率 | 源 → 目标 |
|---|---|---|
| `roll_raw_to_sec` | 每 60 秒 | `raw_*` → `sec_*` |
| `roll_sec_to_min` | 每 5 分钟 | `sec_*` → `min_*` |
| `roll_min_to_hour` | 每小时 | `min_*` → `hour_*` |
| `purge_expired` | 每日 | 删除超过保留期的行 |
| `vacuum_db` | 每周 | `VACUUM` + `ANALYZE` |

## 五、SQLite Schema（示例，非最终）

```sql
-- L0 原始鼠标坐标（归一化，7 天后自动清理）
CREATE TABLE raw_mouse_moves (
  ts         INTEGER NOT NULL,      -- epoch ms
  display_id INTEGER NOT NULL,
  x_norm     REAL NOT NULL,         -- [0,1]
  y_norm     REAL NOT NULL
);
CREATE INDEX idx_raw_mouse_ts ON raw_mouse_moves(ts);

-- L2 分钟级应用使用
CREATE TABLE min_app (
  ts_minute    INTEGER NOT NULL,    -- epoch 对齐到整分钟
  bundle_id    TEXT NOT NULL,
  seconds_used INTEGER NOT NULL,
  PRIMARY KEY (ts_minute, bundle_id)
);

-- 系统事件表（永久）
CREATE TABLE system_events (
  ts       INTEGER NOT NULL,
  category TEXT NOT NULL,           -- sleep/wake/lock/lid/power/...
  payload  TEXT                     -- JSON
);

-- 显示器快照
CREATE TABLE display_snapshots (
  ts         INTEGER NOT NULL,
  display_id INTEGER NOT NULL,
  width_px   INTEGER,
  height_px  INTEGER,
  dpi        REAL,
  is_primary INTEGER
);
```

> 完整 schema 迁移脚本在实现阶段 B1 写在 `app/Resources/migrations/*.sql`。

## 六、"不采集"清单（红线）

- 键盘字符内容（按键 keyCode 明文也只在 D-K2 可选开启）
- 剪贴板内容（只读 `changeCount`）
- 屏幕截图 / 屏幕录像
- 文件内容 / 文件路径（除非来自 Accessibility 标题且用户开了明文）
- 网络流量 / 具体 URL
- 任何可识别地理位置的 GPS 坐标

详见 `05-privacy.md`。

---

## 相关文档

- 功能到数据采集的反向索引 → `02-features.md`
- 采集实现的架构与降采样机制 → `04-architecture.md`
- 敏感项的隐私审查 → `05-privacy.md`
- 获取采集所需的各项权限 → `06-onboarding-permissions.md`
