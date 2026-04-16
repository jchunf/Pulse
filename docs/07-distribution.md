# 07 — 分发与更新 Distribution

> Pulse 是一个非 App Store 的 macOS 应用，需要自建签名、公证与更新通道。本文档说明分发策略、必要的账号/密钥、打包流程，以及为什么我们不得不走这条路。

## 一、为什么不上 Mac App Store

**沙盒禁止 CGEventTap。**

App Store 应用强制使用 App Sandbox，而 CGEventTap（全局键鼠事件监听）在 sandbox 下被完全禁用。我们可以选择：

1. 放弃 CGEventTap → 等于放弃鼠标里程、键盘节奏、全部核心价值
2. 不上 App Store → 自建分发通道

我们选 2。这也是 RescueTime、Timing、Raycast 等同类 app 共同的选择。

### 代价

- 失去 App Store 的流量入口
- 失去系统级"自动下载/更新"的便利
- 用户首次打开需处理 Gatekeeper 警告
- 只能用 Developer ID 签名（而非 App Store 的"证书+App ID"组合）

### 收益

- 可以用系统级 API（CGEventTap、IOKit、AXUIElement 明文窗口标题等）
- 可以用 Sparkle 做快速自动更新（不用等 App Store 审核）
- 没有 30% 抽成，定价策略自由

## 二、必要的账号与密钥

| 项 | 用途 | 成本 |
|---|---|---|
| **Apple Developer Program** 账号 | 获取 Developer ID 证书 | $99/年 |
| **Developer ID Application 证书** | 签名 `.app` bundle | 免费（账号内） |
| **Developer ID Installer 证书** | 签名 `.pkg` 安装包（可选，若用 DMG 可不要） | 免费 |
| **App-Specific Password** | `notarytool` 登录用 | 免费（在 appleid.apple.com 生成） |
| **Sparkle EdDSA 密钥对** | 自动更新包签名 | 免费（本地 `generate_keys` 生成） |

## 三、分发格式

**首选 DMG**（业界惯例，比 `.app.zip` 仪式感更强）：

```
Pulse-0.1.0.dmg
├── Pulse.app                 (已签名 + 公证)
├── Applications 符号链接     (方便拖拽安装)
└── 背景图（可选）
```

**备选 ZIP**：若用户是 CLI 安装或 Homebrew Cask 分发。

**不考虑 PKG**：PKG 需要额外处理 `LaunchDaemon`，Pulse 用 `SMAppService` 注册更简单，无需 root。

## 四、打包流程（CI/CD）

### 本地开发版

```bash
xcodebuild -scheme Pulse -configuration Debug build
# 直接在 Xcode 里跑
```

### 发布版（手动或 GitHub Actions）

```bash
# 1. Archive
xcodebuild -scheme Pulse -configuration Release \
  -archivePath build/Pulse.xcarchive archive

# 2. Export (用 ExportOptions.plist 指定 Developer ID 签名)
xcodebuild -exportArchive \
  -archivePath build/Pulse.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist scripts/ExportOptions.plist

# 3. Notarize
xcrun notarytool submit build/export/Pulse.app \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait

# 4. Staple
xcrun stapler staple build/export/Pulse.app

# 5. Package to DMG
create-dmg --volname "Pulse" \
  --window-size 600 400 \
  --icon "Pulse.app" 150 180 \
  --app-drop-link 450 180 \
  build/Pulse-$VERSION.dmg \
  build/export/Pulse.app

# 6. Sign the update zip for Sparkle
cd build && zip -r Pulse-$VERSION.zip export/Pulse.app
sign_update Pulse-$VERSION.zip  # Sparkle 自带工具
```

### CI（GitHub Actions）

- Runner：`macos-14`（Xcode 15+，Apple Silicon）
- Secrets：`APPLE_ID`, `TEAM_ID`, `APP_SPECIFIC_PASSWORD`, `CERT_P12_BASE64`, `CERT_PASSWORD`, `SPARKLE_PRIVATE_KEY`
- 发布触发：push 到 tag `v*`

## 五、Sparkle 自动更新

### appcast.xml 架构

托管位置建议（选一）：

1. **GitHub Releases**（推荐）：每次 release 自动生成 `appcast.xml`，静态托管
2. **自建静态服务器**（如 Cloudflare Pages）：更可控，但要自己维护

### 客户端配置

- `Info.plist`：
  ```xml
  <key>SUFeedURL</key>
  <string>https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string><BASE64_PUBLIC_KEY></string>
  ```
- 默认更新策略：每次启动 + 每 24h 检查一次
- 用户偏好可关闭自动检查

### 零遥测要求

Sparkle 默认会收集"当前版本"等匿名数据上报。Pulse 要**关闭所有 Sparkle 遥测**：

```swift
let updater = SPUUpdater(...)
updater.sendsSystemProfile = false
```

## 六、定价策略（占位 · 待定）

目前暂定为**一次性买断制**，不走订阅：

| 方案 | 思路 | 优点 | 缺点 |
|---|---|---|---|
| **完全免费开源** | 吃流量，未来周边变现 | 获客最快 | 无直接收入，投入难持续 |
| **一次性买断** | $15–25 终身使用 | 用户认可度高、低压 | 长期收入难持续 |
| **免费 + 高级付费** | 基础功能免费，Wrapped 年报/导出 PDF/高级分析付费 | 漏斗式转化 | 免费/付费界限要想清楚 |
| **订阅** | $3/月或 $25/年 | 现金流稳定 | 用户对本地工具订阅阻力大 |

本文档先不拍板，实现到 v1.0 前再回来决策。可参考 Timing（订阅）、iStat Menus（买断）、Raycast（免费 + 订阅 Pro）。

## 七、SLSA / 签名审计占位

为对开源 / 企业用户建立信任：

- 发布产物（DMG、ZIP）同时发布 SHA-256 校验和
- 未来考虑加入 [SLSA Provenance](https://slsa.dev/) 和 Sigstore 签名（仅作为补充）
- 保持构建过程 reproducible

## 八、分发路线

| 阶段 | 渠道 |
|---|---|
| alpha（内部） | TestFlight 不可用（非 App Store），改用私链邀请 DMG |
| beta | GitHub Releases pre-release + 邀请码访问 |
| GA | 主站 `pulse.app`（或类似域名）+ GitHub Releases 双通道 |
| 长期 | Homebrew Cask 提交；考虑 Setapp（独立开发者常见选择） |

---

## 相关文档

- 为什么 CGEventTap 是必需的 → `03-data-collection.md` + `04-architecture.md#4.2`
- 更新检查不上报任何使用数据 → `05-privacy.md#一`
- 首次启动的 Gatekeeper 提示 → `06-onboarding-permissions.md`
