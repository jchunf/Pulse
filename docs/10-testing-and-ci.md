# 10 — 测试驱动开发与 CI Testing & CI

> 对应需求 R-19 / R-20。本文档定义 Pulse 的测试策略（TDD 工作流、分层测试金字塔、覆盖率门槛）、CI 流水线、以及如何在采集类 app 的特殊约束（CGEventTap 需要权限 + GUI）下做自动化。

## 一、TDD 工作流

### 红 → 绿 → 重构

每个 PR 必须体现 TDD 循环：

1. **先写失败测试** —— 描述新行为的测试，确认运行是"红色"（失败）
2. **最小实现** —— 只写让测试变绿的代码
3. **重构** —— 测试保持绿色的前提下清理设计
4. **提交** —— commit 历史里至少能看到一次"先红后绿"

### PR 强制要求（CI 门槛）

- 新增业务逻辑 PR 必须附对应测试文件（lint 脚本检查）
- 修 bug 的 PR 必须附复现该 bug 的回归测试
- 覆盖率不能下降（`diff_cover` 检查变更行的覆盖率）
- 只改文档、构建脚本、CI 配置的 PR 可豁免（CI 检测 path 规则自动放行）

### 例外（不强制 TDD）

- UI 的视觉微调（颜色、间距）—— 快照测试兜底
- 实验性 spike（标 `spike/` 分支前缀）—— 不进主干
- 性能优化（以基准测试替代单测）

## 二、测试金字塔

| 层 | 比例目标 | 工具 | 说明 |
|---|---|---|---|
| **单元测试** | ~70% | Swift Testing（首选）/ XCTest | 聚合函数、里程换算、坐标归一化、schema 迁移 |
| **集成测试** | ~20% | XCTest | GRDB 真实 SQLite 读写、降采样作业链路、权限状态机 |
| **UI / 快照测试** | ~8% | `swift-snapshot-testing` | SwiftUI 视图回归，按像素/accessibility tree 比对 |
| **端到端（E2E）** | ~2% | XCUITest + 手动 | 完整引导流程、崩溃恢复、升级迁移 |

## 三、可测性设计（影响架构）

采集类 app 的最大测试挑战：**CGEventTap、AXUIElement、NSWorkspace 不能在 CI headless 环境里跑**。应对：

### 接口抽象

定义可注入的协议层，生产实现 + 测试假实现并存：

```swift
protocol EventSource {
    func start(handler: @escaping (Event) -> Void)
    func stop()
}

struct CGEventTapSource: EventSource { /* 真实实现 */ }
struct FakeEventSource: EventSource { /* 测试用，手动 pump 事件 */ }
```

所有 Collector/Aggregator 依赖 `EventSource`，而不是直接调 `CGEventTap`。

### 时间冻结

降采样逻辑严重依赖时间，必须能冻结：

```swift
protocol Clock { var now: Date { get } }
struct FakeClock: Clock { var now: Date }  // 测试时手动推进
```

### 权限状态机

`PermissionService` 抽象为协议，测试里可返回任意状态组合，覆盖 4 种掉权限场景。

### 显示器配置

`DisplayRegistry` 抽象，测试里可模拟单屏/双屏/DPI 变化。

## 四、覆盖率目标

| 模块 | 目标行覆盖 | 目标分支覆盖 | 理由 |
|---|---|---|---|
| `CollectorCore` | ≥ 90% | ≥ 85% | 采集正确性是整个 app 的基础 |
| `Aggregator` | ≥ 95% | ≥ 90% | 降采样 bug 会污染长期数据，不可逆 |
| `Storage / Migration` | ≥ 95% | ≥ 90% | 迁移失败 = 用户数据损坏 |
| `PermissionService` | ≥ 90% | ≥ 85% | 掉权限的状态机是 UX 核心 |
| `UI (ViewModel)` | ≥ 80% | ≥ 70% | View 本身用快照覆盖 |
| `UI (View)` | — | — | 由快照测试覆盖 |
| **整体** | **≥ 85%** | — | 汇总下限 |

`xccov` 生成 LCOV，`codecov.io`（本地托管 Codecov OSS）或 `coverage.py`-like 工具渲染。

## 五、性能与资源基准测试

每次 CI 跑一组**性能门槛测试**（XCTest metrics），数值超过阈值就 fail：

| 测试 | 阈值 |
|---|---|
| 24h 事件流模拟（1000 万条）入库耗时 | < 60s |
| 24h 数据做一次 `rollRawToSec` | < 10s |
| 打开仪表盘（冷启动 → 首帧） | < 500ms（M 系列） |
| 空闲内存（1 小时无操作） | < 150MB |
| 采集空转 CPU | < 1% |

基线（baseline）由 `main` 分支的最近 10 次 CI 运行中位数生成；PR 超过基线 20% 触发警告，超过 50% fail。

## 六、CI 流水线

### 触发事件与对应作业

| 事件 | 作业 |
|---|---|
| Pull Request | lint + unit + integration + coverage + snapshot |
| push to `main` | 上面全部 + E2E + 性能基准 |
| push tag `v*` | 上面全部 + archive + sign + notarize + DMG + Sparkle appcast 生成 + GitHub Release |
| 每夜 cron | 跑完整测试 + 最新 macOS beta（提前发现 API 变更） |

### GitHub Actions 结构

```
.github/workflows/
├── ci.yml              # PR/push 的基础 CI
├── release.yml         # tag 触发，签名+公证+发布
├── nightly.yml         # cron，跑 macOS beta
└── dependabot.yml      # 依赖更新
```

### 关键 job 模板（摘要）

```yaml
jobs:
  test:
    runs-on: macos-14   # 含 Xcode 15+
    strategy:
      matrix:
        macos: [macos-14, macos-15]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/cache@v4
        with: { path: ~/Library/Developer/Xcode/DerivedData, ... }
      - run: xcodebuild test -scheme Pulse -destination "platform=macOS" \
             -enableCodeCoverage YES -resultBundlePath test.xcresult
      - run: xcrun xccov view --report test.xcresult
      - uses: codecov/codecov-action@v4
```

### 签名与公证（仅在 tag / release 上）

Secrets 配置：

| Secret | 内容 |
|---|---|
| `APPLE_ID` | Apple ID 邮箱 |
| `APPLE_TEAM_ID` | Team ID |
| `APP_SPECIFIC_PASSWORD` | notarytool 用 |
| `CERT_P12_BASE64` | Developer ID 证书（base64） |
| `CERT_PASSWORD` | p12 密码 |
| `SPARKLE_PRIVATE_KEY` | Sparkle 更新签名私钥（EdDSA） |

```yaml
- name: Import certificate
  run: |
    echo "$CERT_P12_BASE64" | base64 -d > cert.p12
    security create-keychain -p "$KC_PW" build.keychain
    security import cert.p12 -P "$CERT_PASSWORD" -k build.keychain -T /usr/bin/codesign
- name: Archive + Sign + Notarize
  run: bash scripts/release.sh
```

### CI 要求

- 所有 secrets 走 GitHub Environments，`release` environment 要求 PR 评审后才能用
- Build 产物保留 30 天（archive+dSYM+ipa）
- 每个 PR 自动注释 coverage diff

### macOS runner 成本

- GitHub Actions 免费层：macOS runner 10× multiplier，个人开发者账号可能不够
- 替代：**self-hosted Mac mini**（M1/M2） + `actions-runner` daemon
- 建议：**初期用 GitHub 公共 runner**，发布后视成本切 self-hosted

## 七、Swift Testing vs XCTest（Q-11 已关闭）

**已决定：新代码用 Swift Testing，XCUITest / 不支持场景保留 XCTest。**

- 业务逻辑（单元/集成测试）一律走 **Swift Testing**：宏驱动的 `@Test`、参数化语法天然、并发友好
- UI 测试（XCUITest）目前仅支持 **XCTest**，保持
- 两种框架在同一工程共存，按目录划分：
  - `PulseTests/Unit/*` → Swift Testing
  - `PulseTests/Integration/*` → Swift Testing
  - `PulseUITests/*` → XCTest（XCUITest）

最低系统版本 macOS 14（Q-13 决策），Swift Testing 完全可用。

## 八、用户手动参与的测试

TDD + CI 覆盖不了的部分：**真实用户感知**。

- **alpha 内测**（10 人）：MVP 冻结期，7 天真实使用反馈
- **可用性测试**：邀请 5 位目标用户录屏第一次使用，观察卡点
- **Dogfooding**：开发者自己每天用自己的 build，遇到 bug 立刻写测试修

## 九、已知测试盲区（留给人工）

- **macOS 权限系统真实弹窗**：自动化只能检测 "IOHIDCheckAccess" 状态，不能自动点击系统授权框 → 引导流程只能靠手工
- **公证结果延迟**：notarytool 可能几分钟到几小时 → CI 拿到最终结果需要 wait + poll
- **Sparkle 升级**：真实升级流要跨两个 build，CI 只能做烟雾测试
- **Apple Silicon vs Intel 行为差异**：性能测试需要分别跑；目前策略仅跑 Apple Silicon，Intel 由社区反馈

---

## 相关文档

- 模块边界（决定测试边界）→ `04-architecture.md#三`
- 签名/公证/发布通道 → `07-distribution.md`
- 具体 CI 工具与测试框架拍板 → `09-open-questions.md` Q-11 ~ Q-14
