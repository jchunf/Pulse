# 06 — 首次启动与权限引导 Onboarding & Permissions

> macOS 对采集类 app 的权限管控是用户流失的最大入口之一。本文档定义首次启动的引导流程、每项权限的解释话术、跳转系统设置的 deep link、以及权限掉失的自检与恢复。

## 一、权限清单

### 必需权限（MVP 不可跳过）

| 权限 | 用途 | 系统设置路径 | API |
|---|---|---|---|
| **Input Monitoring**（输入监控） | 拿到鼠标移动/点击、滚轮、键盘按键的系统级事件（CGEventTap） | 系统设置 → 隐私与安全 → 输入监控 | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` |
| **Accessibility**（辅助功能） | 读当前前台窗口的标题（AXUIElement） | 系统设置 → 隐私与安全 → 辅助功能 | `AXIsProcessTrustedWithOptions` |

### 可选权限（按功能分级请求）

| 权限 | 功能 | 默认 | 系统设置路径 |
|---|---|---|---|
| **Location Services** | F-35 WiFi SSID 画像 | 关 | 隐私 → 定位服务 |
| **Calendars** | F-36 日历联动 | 关 | 隐私 → 日历 |
| **Notifications** | F-45 阈值警报推送给用户 | 首次用到时请求 | 通知 |
| **Full Disk Access** | 未使用 | 永不请求 | — |

**原则**：除非功能启用，否则**绝不**请求该功能对应的权限。这避免让用户误以为 Pulse "想要一切"。

## 二、首次启动流程（Onboarding Flow）

### Step 0：欢迎屏

- 一句话产品介绍（来自 `00-vision.md`）
- 一张仪表盘效果图（成品吸引力）
- "继续" 按钮

### Step 1：隐私承诺（关键一步）

- 展示 `05-privacy.md#七` 的"隐私承诺语"
- 勾选框：「我理解 Pulse 不会采集我的打字内容、剪贴板或屏幕。」
- 必须勾选才能继续
- 底部链接："完整隐私政策"（跳到 `05-privacy.md` 的 app 内渲染版本）

### Step 2：Input Monitoring 权限

- 解释：「Pulse 需要监听您的键盘和鼠标事件，以统计活动时长与鼠标里程。**我们只记录按键次数和坐标，绝不记录您打的字。**」
- "打开系统设置" 按钮 → 用 deep link 直接定位到对应页

  ```swift
  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
  ```

- 提供动画教程（GIF 或 Lottie）演示如何勾选 Pulse
- 授权后 Pulse 会被系统杀掉重启 —— 引导文案提前告知："点完勾后 Pulse 会重启，这是 macOS 的正常行为"
- 自动轮询 `IOHIDCheckAccess` 返回值，检测到授权立即前进

### Step 3：Accessibility 权限

- 解释：「Pulse 需要辅助功能权限来识别您当前使用的应用和窗口标题。**窗口标题默认会被哈希处理**，不以明文存储。」
- "打开系统设置" deep link：

  ```swift
  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  ```

- 同样提供动画教程
- 用 `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])` 同时触发系统弹框

### Step 4：可选开关

逐个展示可选功能 + 对应权限，用户可勾选：

- [ ] 窗口标题明文记录（否则仅存哈希）
- [ ] 键码分布（否则仅记总次数）
- [ ] 登录时自动启动（默认勾选，调 `SMAppService.mainApp.register()`）
- [ ] WiFi 地点画像（启用后会请求位置权限）
- [ ] 日历联动（启用后会请求日历权限）

### Step 5：完成

- "Pulse 正在倾听您的脉搏..." 动效
- 按钮："打开仪表盘" / "最小化到菜单栏"
- 菜单栏图标开始跳动（用 `NSStatusItem` 做心跳动效）

## 三、权限掉失自检

macOS 每次大版本升级（甚至某些次版本）会让 Input Monitoring 掉权限。Pulse 必须能优雅处理：

### 启动时自检

```swift
enum PermissionStatus { case granted, denied, unknown }

func checkAll() -> [Permission: PermissionStatus] {
    return [
        .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == .granted ? .granted : .denied,
        .accessibility:   AXIsProcessTrusted() ? .granted : .denied,
        // ...
    ]
}
```

### 掉权限的表现

| 情况 | UI 行为 |
|---|---|
| 所有必需权限在 | 菜单栏图标正常，心跳动效 |
| 丢 Input Monitoring | 菜单栏图标变**红色感叹号**；点击显示"采集已暂停，请重新授权"；一键跳转系统设置 |
| 丢 Accessibility | 菜单栏图标变**黄色感叹号**；采集鼠标键盘仍正常，但窗口标题为空 |
| 用户主动关闭采集 | 菜单栏图标变**灰色**；心跳动效停止 |

### 后台定期复查

- 每 5 分钟 poll 一次 `checkAll()`
- 状态变化 → 发本地通知（前提：用户允许通知）："Pulse 检测到 Input Monitoring 权限被撤销，采集已暂停。"
- 允许用户点通知直达系统设置

## 四、文案原则

- **直白**：不堆营销词，"我们需要 X 权限来做 Y" 一句话说明白
- **对称**：有"为什么需要" 就配"不需要什么"（对应红线清单）
- **可验证**：配动画演示，让用户知道授权后会发生什么
- **没有暗模式**：不用恐吓式文案（"不授权就无法享受完整体验"），用事实描述

## 五、Info.plist 的 Usage Description

macOS 要求所有权限申请配 usage description。Pulse 的文案：

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Pulse 使用此权限识别当前前台应用，统计使用时长。</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>Pulse 可以识别当前 WiFi 以画出"在不同场所的工作分布"。位置信息不会离开你的 Mac，SSID 会被哈希处理。</string>

<key>NSCalendarsUsageDescription</key>
<string>Pulse 可选读取日历，区分"深度工作"和"会议时段"。事件标题默认不存储。</string>

<key>NSUserNotificationsUsageDescription</key>
<string>Pulse 用通知提醒"超时工作"或"权限失效"。</string>
```

注意：Accessibility 和 Input Monitoring 没有 usage description key —— 由系统统一弹对话框，文案无法自定义。所以必须在引导页里用我们自己的话把用途说透。

## 六、卸载体验

用户在偏好里点"卸载并清除所有本地数据"：

1. 二次确认对话框 + 输入"DELETE"确认
2. 停止所有 collector
3. 删除 `~/Library/Application Support/Pulse/`
4. 注销 `SMAppService.mainApp.unregister()`
5. 提示用户把 Pulse.app 拖到废纸篓
6. 提示用户去系统设置 → 隐私 → 输入监控 / 辅助功能 把 Pulse 从列表里删掉（deep link 直达）

## 七、Telemetry 的诱惑（不要）

很多开发者在首次启动会偷偷上报"匿名安装"事件。**Pulse 不做**。

- 不上报安装、不上报首次权限授权、不上报功能使用
- 唯一的出站调用：检查更新（Sparkle 的 appcast XML），用户可在偏好里关闭

---

## 相关文档

- 每个权限对应的采集项 → `03-data-collection.md`
- 隐私承诺原文 → `05-privacy.md#七`
- 为什么这些权限必须存在（不能绕过） → `07-distribution.md`
