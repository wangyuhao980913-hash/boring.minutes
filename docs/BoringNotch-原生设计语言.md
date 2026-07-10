# Boring Notch 原生设计语言

> 本文档记录 **原生 Boring Notch** 的 UI 设计语言，供后续所有界面改造（含会议纪要功能）遵循参照。
> 说明：本文档只沉淀「原生」部分的设计规范，不记录后加的录音/会议功能自身的实现细节，但会议功能的 UI 应当向本规范靠拢。

---

## 1. 设计原则

- **黑色 Notch 画布优先**：刘海本体是纯黑画布，白/灰文字、高对比、不使用系统 Material，营造与硬件刘海融为一体的观感。
- **系统融合**：强调色默认跟随 macOS 系统强调色；外围窗口（设置、Onboarding）使用 macOS 原生控件与毛玻璃。
- **紧凑信息密度**：展开区固定 640×190，信息排布紧凑，多用胶囊、小圆角与语义字号。
- **克制的动效**：以 spring 与 `.smooth` 为主，快速、跟手、不喧宾夺主。

存在两大 UI 语境，规范略有差异：

| 语境 | 特征 |
| --- | --- |
| Notch 本体（关闭/展开态） | 纯黑背景、白/灰文字、胶囊与圆角矩形、无 Material |
| 外围窗口（设置、Onboarding、会议回看） | macOS 原生 Form / 分栏、`NSVisualEffectView` 毛玻璃、`effectiveAccent` 着色 |

---

## 2. 配色 Token

### 2.1 强调色 Accent

核心 token 定义在 `boringNotch/extensions/Color+AccentColor.swift`：

- `Color.effectiveAccent`：默认跟随 macOS `accentColor`，用户可自定义（8 种预设 + ColorPicker）。
- `Color.effectiveAccentBackground`：强调色的背景变体（约 25% 透明度），用于选中态底色。

**用法**：选中态、进度高亮、关键交互元素、说话人标签等，统一使用 `effectiveAccent`，不要引入其它无语义的彩色。

### 2.2 背景层级

| 层级 | 颜色 | 用途 |
| --- | --- | --- |
| Notch 主背景 | `.black` | 展开/关闭态主体 |
| 深灰控件底 | `Color(red: 20/255, green: 20/255, blue: 20/255)` | 按钮、占位块 |
| 半透明叠层 | `.black.opacity(0.3–0.7)` | 阴影、遮罩 |
| 中性控件底 | `Color(nsColor: .secondarySystemFill)` | Tab 胶囊、徽章 |
| 轻量卡片底 | `Color.primary.opacity(0.04)` | 列表卡片（外围窗口内） |
| 设置窗口 | `Color(NSColor.windowBackgroundColor)` | 设置根背景 |

### 2.3 文字层级

**Notch 内（深色背景上）**

| 层级 | 颜色 |
| --- | --- |
| 主 | `.white` |
| 次 | `.gray` |
| 三级 | `Color(white: 0.65)` |
| 弱化 | `.gray.opacity(0.7)` |

**外围窗口（含会议回看，`.dark` 配色）**：优先用语义色 `.primary` / `.secondary` / `.tertiary`，而非硬编码白灰，随系统更稳。

### 2.4 状态色

| 状态 | 颜色 |
| --- | --- |
| 激活 / 警告 / 录制 | `.red` |
| 成功 / 充电 | `.green` |
| 低电量模式 | `.yellow` |
| 禁用 / 不可用 | `.gray` / `opacity(0.35–0.6)` |

### 2.5 描边与分隔

- 微描边：`.white.opacity(0.04)`
- 胶囊描边：`.white.opacity(0.1)`，线宽 1
- 列表分隔：`.gray.opacity(0.2)`

---

## 3. 字体

- **Notch 内**：以 SF 语义字号为主 —— `.headline`（标题）、`.subheadline` / `.callout`（正文）、`.caption` / `.caption2`（辅助）。
- **等宽数字**：计时/时长用 `.caption.monospacedDigit()` 或 `.system(..., design: .monospaced)`。
- **Rounded 设计**：标题感组件（Header、空态大标题）用 `.system(..., design: .rounded)`。
- **字重**：标题 `.semibold` / `.medium`；正文默认；强调项 `.medium`。

常用对照：

| 场景 | 字体 |
| --- | --- |
| 主标题 | `.title3` / `.headline`，`.semibold` |
| 正文 | `.body` / `.callout` |
| 次要信息 | `.caption`，`.secondary` |
| 徽章 / 小标签 | `.caption2` |
| 计时 | `.caption.monospacedDigit()` |

---

## 4. 圆角与形状

- **NotchShape**：刘海本体专属非对称圆角（关闭 top 6 / bottom 14，展开 top 19 / bottom 24），由 `boringNotch/sizing/matters.swift` 定义。
- **Capsule**：Tab 选中、悬停按钮、HUD 背景、进度条轨道等。
- **常用圆角矩形**：

| 值 | 用途 |
| --- | --- |
| 4 | 小标签、关闭态封面 |
| 6 | 转录行等紧凑列表项 |
| 8 | 日历日期格、卡片 |
| 10 | 列表卡片 |
| 12（`.continuous`） | Shelf 项、Onboarding 选项、较大按钮 |
| 16 | 面板外框 |

新增卡片型元素优先使用 10~12 的圆角，风格统一。

---

## 5. 间距

以 **4pt 为基准**，常用 4 的倍数：`4 / 8 / 12 / 16 / 20 / 24`。

| 值 | 场景 |
| --- | --- |
| 2–4 | 行内紧凑元素 |
| 6–8 | 组件内部 |
| 10–12 | 展开区内边距、列表项间距 |
| 15–20 | 主分区间距 |
| 24+ | 大分段（Onboarding 步骤） |

---

## 6. 背景与效果

- **Notch 本体**：纯黑，无 SwiftUI Material；开合时用阴影（`.black.opacity(0.7)`，radius 4–6）与内容 `blur` + `opacity` 过渡。
- **外围窗口**：使用 `VisualEffectView`（封装于 `boringNotch/components/Settings/EditPanelView.swift`）；Material 常用 `.hudWindow`、`.underWindowBackground`，`blendingMode: .behindWindow`。
- **发光**：音乐封面用放大 `blur(radius: 40–50)` + `opacity(0.5)` 制造光晕。

---

## 7. 动画

| 场景 | 参数 |
| --- | --- |
| Notch 展开 | `spring(response: 0.42, dampingFraction: 0.8)` |
| Notch 关闭 | `spring(response: 0.45, dampingFraction: 1.0)` |
| 手势跟随 | `interactiveSpring(response: 0.38, dampingFraction: 0.8)` / `.smooth` |
| 内容/Tab 切换 | `.smooth`（或 `.smooth(duration: 0.35)` + scale 0.8 + opacity） |
| 悬停 | `.smooth(duration: 0.3)` |
| 按钮按下 | `spring(response: 0.3, dampingFraction: 0.3)`，scale 0.9–0.95 |

过渡优先 `.scale(0.8).combined(with: .opacity)` 或 `.opacity`。

---

## 8. 图标（SF Symbols）

- 统一使用 **SF Symbols**，少量自定义 Asset。
- HUD/状态类多用 `.fill` 变体；层次化用 `.symbolRenderingMode(.hierarchical)`。
- 动态图标随数值切换符号名（如音量 `speaker.wave.1` → `speaker.wave.3`）。
- 动效用 `.symbolEffect` 或 `.contentTransition(.interpolate)`；静音等状态叠加 `.slash` 变体。
- Notch 内图标默认 `.white`，激活 `.red`，不可用 `.gray`。
- 常见点击区：30×30（普通）/ 40×40（主操作）。

---

## 9. 组件范式

- **HoverButton**（`boringNotch/components/HoverButton.swift`）：悬停时 `Color.gray.opacity(0.2)` 胶囊底 + SF Symbol，`contentTransition: .symbolEffect`。
- **Tab 选中**：胶囊 + `matchedGeometryEffect` 滑动。
- **卡片列表项**：圆角 10–12 + `Color.primary.opacity(0.04)` 底，整块可点。
- **空状态**：居中大号 SF Symbol（`.secondary`）+ 主标题（`.subheadline .secondary`）+ 副标题（`.caption .tertiary`）。
- **设置页**：`NavigationSplitView` + Form Section，全局 `.tint(.effectiveAccent)`，footer 用 `.caption .secondary`。

---

## 10. 设计关键词

> **Dark Notch Canvas · System Accent · Capsule & Asymmetric Radius · SF Typography · Spring Motion · SF Symbols**

---

## 11. 会议 / 回看界面适配要点

后续会议相关界面在遵循上述规范时，重点：

1. 强调色统一走 `effectiveAccent`，不引入随机彩色。说话人标签这类「多实例区分」场景，改用**低饱和中性灰调色板**（`saturation ≤ 0.10`，靠亮度/极弱色相区分），保证既能区分又克制、不喧宾夺主。
2. 文字用 `.primary` / `.secondary` / `.tertiary` 语义层级。
3. 卡片型内容用圆角 10–12 + `Color.primary.opacity(0.04)` 底。
4. 空态统一用第 9 节的三段式范式。
5. 计时/时间戳用 `monospacedDigit`。
6. 交互动效用 `.smooth` 与标准 spring 参数。

---

## 12. 刘海内交互与列表规范（会议面板经验沉淀）

刘海会在鼠标移出时自动收回，任何「需要用户持续操作」的场景都必须显式抑制收回，否则交互会被打断。

1. **抑制自动收回（pin 刘海）**：`BoringViewModel.suppressAutoClose` 为全局开关，`ContentView` 的 hover-out 分支与上滑手势都会检查它。以下场景期间必须置位：
   - 悬停 / 滚动刘海内的可滚动列表（`.onHover` 跟随开关）；
   - 打开 `popover` / `confirmationDialog`（会把指针带到子窗口，触发刘海 hover-out）；
   - 打开 `NSOpenPanel` 等模态窗口。
   推荐用**交互计数器**（进入 +1、退出 -1，`>0` 即视为交互中）叠加「列表悬停」状态统一驱动，避免多来源竞态导致提前复位。
2. **滚动不误收**：可滚动区域的 `.onHover` 置位 `suppressAutoClose`，可同时挡住「上滑手势被误判为关闭」。
3. **列表项 hover 反馈**：`scaleEffect(1.03)` + `Color.gray.opacity(0.16)` 圆角底，`.easeInOut(0.15)`，轻量不夸张。
4. **滚动条留白**：`ScrollView` 内容加 `.padding(.trailing, 4)`，行内尾部图标（删除/更多）不与系统滚动条重叠。
5. **录制指示呼吸感**：关闭态 REC 红点用 `opacity` 在 `1.0 ↔ 0.35` 间 `easeInOut(1.1s).repeatForever(autoreverses:)` 循环，营造「正在进行」的呼吸。
6. **控件的「低调 / 明显」二态**：非活动态用灰（按钮 `gray.opacity(0.6)`、波形 `gray.opacity(0.22)`）；活动态才转为明确色（录制红 / `gray.opacity(0.85)`），用 `.easeInOut(0.2)` 过渡。
7. **权限申请用系统原生弹窗**：麦克风走 `AVCaptureDevice.requestAccess`、屏幕录制走 `CGRequestScreenCaptureAccess`（均为苹果标准弹窗）；被拒时用 `NSAlert`（「打开系统设置」+「取消」，直达 `x-apple.systempreferences:` 隐私页）引导，**不要在界面上堆红色错误文字**。
