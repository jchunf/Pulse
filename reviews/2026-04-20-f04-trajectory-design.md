# F-04 鼠标轨迹可视化 — 设计稿

> 日期 2026-04-20 · 目的：在动 Metal 代码之前把范围、渲染模式、
> 内存预算、UI 位置定下，再拆成 2-3 个可审的 PR。作者评估后会把本
> 稿转成 `docs/A*-PROGRESS.md` 风格的落地清单。

## 1. 目标

`docs/02-features.md#F-04`：**鼠标轨迹可视化（Metal 渲染）**，v1.1
末尾项。roadmap §四 注明"工程量最大"。

用户价值：

1. **"我今天在屏幕上画了张怎样的图？"** — 每日一张抽象画，像
   `A3 鼠标里程卡`的放大版，提供"整天 on 屏幕"的情绪化证据。
2. **找死区** — 长时间没点的屏幕区域；这是 F-15 的前置原型。
3. **证明光标真的去过那么多地方** — 与 mileage 数字互相佐证
   （今天跑了 2.4km，但路径其实只占屏幕一半？）

**不是**目标（这一版）：

- F-04 不做人机工效学建议（"你的鼠标范围偏右，建议屏幕右移"）。
- 不做实时动画 —— 静态图就够。动画可以 v2.0 再谈。
- 不做光标速度分布（那是 F-18，v2.1）。

## 2. 数据来源 + 规模

表：`raw_mouse_moves(ts, display_id, x_norm, y_norm)`，每行 ~28B。

保留窗口：14 天（`AggregationRules.rawCutoff`）。

采样：`SamplingPolicy` 默认 active 30Hz / idle 1Hz。真实估算：

| 场景 | 点/天 | 占磁盘 |
|---|---|---|
| 重度（8h 活跃 + 16h 空闲） | ~1.0M | ~28 MB |
| 中度（4h 活跃 + 20h 空闲） | ~500k | ~14 MB |
| 轻度（1h 活跃 + 23h 空闲） | ~190k | ~5 MB |

**14 天全量上限 ~14M × 28B = 392 MB**（重度用户）。这超出一次性
VRAM 预算，必须分块。

> **行动项**：作者真机跑 `SELECT COUNT(*) FROM raw_mouse_moves`
> 给我一个量纲。如果日常 < 500k/天，第一版可以每天全量上传；
> 否则走 LOD 方案（见 §5）。

## 3. 关键决策 —— 需要作者拍板

### D1. 渲染模式

三选一 / 或允许切换：

| 模式 | 说明 | 复杂度 |
|---|---|---|
| **A. 轨迹线** | 相邻两点连直线，alpha 叠加；得到"轨迹图" | 低 |
| **B. 密度热力** | 每点 splat 到纹理，alpha 累加；得到"热区图" | 中 |
| **C. 两者可切换** | 单按钮切换 A/B | 中+ |
| **D. 两者叠加** | 热力做底，轨迹做线 | 高 |

**我的推荐**：**B 密度热力** 作为第一版。理由：

- 轨迹线在 1M 点下是一条密密麻麻的麻花，视觉信噪比低
- 热力直接回答"我的光标去过哪"，呼应"找死区"目标
- splat 实现（点 → 圆斑 → additive blend）只要一个
  vertex+fragment shader + MTLBlendFactor 设置

第二版再加 A/C。用户意见？

### D2. 时间窗口

| 选项 | 点数（重度） | 备注 |
|---|---|---|
| 今日 | ~1M | 最便宜、最直观 |
| 最近 7 天 | ~7M | 需要分块，~200MB 峰值 |
| 最近 14 天 | ~14M | 需要 LOD |

**我的推荐**：**今日 + 一个"切换日期"的按钮**（像 Heatmap 的
3/7/14/30 选择器，但选的是单日）。只渲染一天，避免 LOD。想看
更长尺度的话，A26 的 Vital Pulse + F-10 时间带已经提供"整周节
律"视角，F-04 做"今天这一天到底长啥样"。

### D3. 显示器处理

`raw_mouse_moves.display_id + x_norm + y_norm` 是归一化到**每块
屏幕**的坐标，不是虚拟桌面空间。选择：

1. **单显示器（主屏）** — 最简单，直接 `WHERE display_id = ?`
2. **Segmented 控件选显示器** — 用户手动切换
3. **自动合并** — 需要 `display_snapshots` 的 width/height/dpi
   重建虚拟桌面坐标；复杂但看起来"最对"

**我的推荐**：**2 Segmented 选显示器**。合并空间不是主场景
（多数人在主屏上鼠标最多），LOD 也不牵扯。给每块屏一份独立
image。

### D4. UI 位置

| 选项 | 空间 | 审美 |
|---|---|---|
| Dashboard 卡（Section 2 或 4） | ~820×180 pt | 受限但"一眼见" |
| 独立 Window | ~900×700 pt | 给 Metal canvas 呼吸空间 |
| 菜单项 → 独立 Window（懒加载） | 同上 | 进一步隔离启动成本 |

**我的推荐**：**3 菜单项 → 独立 Window**。理由：

- Metal 初始化有成本；不该每次打开 Dashboard 都启动一次 GPU pipeline
- 独立窗口有空间放 Segmented 控件、日期选择、导出按钮
- 存量 Dashboard 已经相当满，新加 200pt 高的卡会把"首屏"挤掉

菜单入口文案："Show today's trajectory…" / "查看今日轨迹…"。

## 4. 渲染 pipeline（建议 B 密度热力模式）

```
raw_mouse_moves → Metal buffer (xy in [0,1]²)
                      ↓ vertex shader:
                      位置 = NDC(x, y)
                      点大小 = 8-12 px（随显示器缩放）
                      ↓ fragment shader:
                      圆形 splat, alpha = Gaussian(d), additive blend
                      ↓ blend to offscreen texture
                      ↓ post process:
                      查表（viridis / inferno 色带）
                      ↓ 呈现给 MTKView
```

着色器伪代码：

```metal
// vertex
struct VertexIn { float2 pos [[attribute(0)]]; };
vertex float4 traj_vertex(VertexIn in [[stage_in]],
                           uint vid [[vertex_id]]) {
    return float4(in.pos * 2.0 - 1.0, 0, 1); // [0,1] → NDC
}

// fragment
constexpr float SIGMA = 0.4;
fragment float4 traj_fragment(float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    float a = exp(-d * d / (2 * SIGMA * SIGMA));
    return float4(1, 1, 1, a) * ALPHA_DENSITY;
}
```

Blend state: `add, srcAlpha * one`（累加 alpha），结果纹理 alpha
是"密度"。最后在呈现 pass 里用色带查表。

## 5. 内存 & 分块

第一版（D2 建议：今日单日）只看"今天"，点数估计 1M 以内。

- 每点 8 字节（2 × Float16）→ 8 MB buffer，一次性上传
- 不需要 LOD，不需要流式

如果作者真机日均点数 > 2M，fallback 方案：

- 按小时分块 upload + accumulate 到 offscreen texture
- 结束时只保留累加后的 texture，buffer 可以释放
- LOD 不需要 —— 密度 splat 本身对点密度不敏感（100 个点叠在
  一起和 10 个都是饱和的）

## 6. 颜色 & 视觉

- **底色**：Dashboard surface（`PulseDesign.surface`），不加额
  外 stroke
- **热力色带**：sage → coral → amber 的连续渐变，alpha 0→1
- **死区**：留白（surface 色），不画轮廓
- **显示器分隔**：按 D3 推荐，一屏一图，不需要分隔线

## 7. 隐私

- `raw_mouse_moves` 已经是本地 SQLite，不离端
- 归一化坐标（[0,1]²）本身不暴露屏幕分辨率
- 与 A21 export 一致：不把 raw_moves 导出到任何 PDF / 图片

**不需要**新的权限文案 / `docs/05-privacy.md` 更新。F-04 不引
入任何新采集源。

## 8. PR 拆分计划

| PR | 内容 | 预估行数 |
|---|---|---|
| **A35** | 数据层 —— `rawMouseMoves(on:displayID:)` 流式读取 + 测试 | ~300 |
| **A35b** | Metal pipeline + `TrajectoryView` (SwiftUI wrapper over MTKView) + shader + 独立 Window scene + 菜单入口 | ~600 |
| **A35c**（可选） | 日期切换 + 显示器 segmented 控件 + 导出 PNG | ~200 |

A35 / A35b 必须，A35c 看回归反馈。

总量估 ~1100 行新增（含着色器 + Swift）。

## 9. 待定 / 问作者

1. **D1 渲染模式**：确认 B 密度热力优先，或倾向于 A 轨迹线？
2. **D2 时间窗口**：确认今日 + 切换日期按钮，或你更想一次看整周？
3. **D3 显示器**：同意 Segmented 选择，还是坚持自动合并多屏？
4. **D4 UI 位置**：确认独立 Window + 菜单入口？
5. **性能 baseline**：真机跑一下 `SELECT COUNT(*) FROM raw_mouse_moves WHERE ts > <今天起点 ms>`，贴一下数字，我好决定要不要 LOD。
6. **导出 PNG**：A35c 要不要做？（跟 F-06 PDF 对齐，"每日艺术
   画"可以保存分享）

## 10. 不做 / 延后

- **轨迹线模式（A）** — v1.2 再加
- **实时动画** — v2.0
- **轨迹叠加 heatmap** — v2.0
- **多屏合并** — v2.0，要解决虚拟桌面坐标系
- **点击热力** — 这是 F-16，v2.0 独立项，与 F-04 解耦
- **光标速度分布** — F-18，v2.1

---

## 相关

- `docs/02-features.md#F-04`
- `docs/08-roadmap.md#v11`
- `docs/03-data-collection.md#鼠标`（`raw_mouse_moves` 定义）
- `A3-PROGRESS.md`（mileage 卡，F-04 的数字基础）
- A26 Vital Pulse（色彩基调来源）
