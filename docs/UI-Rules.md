# UI Rules — 界面设计约束

本文件记录与 macOS 原生红绿灯/顶部区域、页面工具栏相关的设计约束，
供后续 UI 调整时遵循，避免破坏红绿灯定位与各页视觉一致性。

## 1. 布局配置（lib/core/constants/layout.dart）

- 结构：`PlatformLayoutConfig` 类（字段 `sidebarTopInset` / `sidebarWidth` /
  `pageToolbarHeight` / `pageToolbarTopInset` / `pageToolbarContentHeight`），通过全局 getter
  `layoutConfig` 按 `defaultTargetPlatform` 选择（macOS → `_macOS`，其余 → `_default`）。

| 字段 | macOS | 其他(Windows/Linux…) | 含义 |
|---|---|---|---|
| `sidebarTopInset` | 52 | 0 | 左侧边栏顶部预留（红绿灯区域；macOS 专属） |
| `sidebarWidth` | 92 | 80 | 左侧边栏（NavigationRail）宽度（macOS 让红绿灯组水平居中） |
| `pageToolbarHeight` | 112 | 112 | 页面标题工具栏总高 |
| `pageToolbarTopInset` | 32 | 32 | 工具栏顶部填充（替代被移除的全局顶栏高度） |
| `pageToolbarContentHeight` | 80 | 80 | 工具栏内容块高度（内容垂直居中） |
| `detailTopBarHeight` | 52 | 56 | 详情页顶栏总高（macOS 与 unified 工具栏红绿灯中心对齐） |
| `detailTopBarLeftInset` | 95 | 0 | 详情页左侧预留（macOS 让过红绿灯；Windows 不生效） |
| `playerTopBarTopReserve` | 40 | 0 | 播放页顶部红绿灯预留区（顶栏总高 = 56 控件区 + 本值） |

- 旧的**全局顶栏（TopBar）已于 2026-08-04 移除**，改为「页面避让」方案：
  - 左侧 NavigationRail 顶部预留 `layoutConfig.sidebarTopInset`（macOS=52）给红绿灯；
  - 右侧内容区各页使用统一高度的 `PageToolbar`（`lib/widgets/page_toolbar.dart`）。
- 传原生：Flutter 启动仍会通过 **MethodChannel `com.jerryc.txvziwm/window`**（方法 `setTopBarHeight`）
  发送 `layoutConfig.sidebarTopInset`（52），但**红绿灯已由 unified 工具栏原生定位，Swift 端为 no-op**。
  **仅 macOS 会调用**（其他平台无 handler，避免 MissingPluginException 噪音）。
- **数值微调**：Windows 版调试时改 `_default`（或新增 Windows 专属配置）即可，无需动 UI 代码。

## 2. 红绿灯定位规则（macOS 原生层）

- **方案（2026-08-10 起）：unified 工具栏（macOS 11+）。**
  文件：`macos/Runner/MainFlutterWindow.swift` → 空 `NSToolbar` + `.unifiedTitleAndToolbar`，
  `toolbarStyle = .unified`。
- **红绿灯由 AppKit 原生垂直居中于工具栏行**（中心 ≈26，顶栏高 ≈52）：
  - 从启动起位置即稳定，**不再用 `setFrameOrigin` 与 AppKit 布局争夺**；
  - 之前 `setFrameOrigin` 方案因 AppKit 会在启动各布局时点反复覆盖按钮位置而不可靠。
- Flutter 侧按此对齐：`sidebarTopInset = detailTopBarHeight = 52`（= 2×26）。
- 部署目标已升至 **11.0**（`toolbarStyle` 需 11+）。

### 2.1 红绿灯绿钮：最大化而非全屏（2026-08-10）

- **行为**：绿钮点击 = **最大化窗口（zoom）**，不再进入全屏。
- **实现**（`MainFlutterWindow.swift`）：`collectionBehavior` 显式移除
  `.fullScreenPrimary` / `.fullScreenAuxiliary` 并插入 `.fullScreenNone`（三者互斥）。
  窗口不支持全屏 → AppKit 自动把绿钮降级为缩放按钮（`performZoom:`/`_setNeedsZoom:`）。
- **验证**：诊断输出 `zoom.action=_setNeedsZoom:`、`collection=512`（= `.fullScreenNone`）。
- ⚠️ 副作用：窗口从此**无法通过任何入口进入全屏**（含菜单/手势），如需全屏需改回
  `.fullScreenPrimary` 或改用「绿钮菜单选全屏」。

## 3. 左侧边栏（NavigationRail）对齐参考

- NavigationRail 宽度：macOS = `layoutConfig.sidebarWidth`（92），顶部外包 `Padding(top: layoutConfig.sidebarTopInset)`。
- 红绿灯由 unified 工具栏原生定位（中心 ≈26）；侧栏预留 `sidebarTopInset = 52` 使红绿灯在其中垂直居中。

## 4. 页面工具栏（PageToolbar）

- 组件：`lib/widgets/page_toolbar.dart`，参数 `{title, subtitle?, actions?}`。
- 结构：总高 `layoutConfig.pageToolbarHeight`（112）= 顶部填充 `layoutConfig.pageToolbarTopInset`（32）
  + 内容块 `layoutConfig.pageToolbarContentHeight`（80，内容垂直居中）。
- 已覆盖：音乐库 / 专辑 / 歌手 / 播放列表 / 设置。
- **新页面接入规范**：顶部标题区一律用 `PageToolbar`，不要自行写 padding/Row，
  以保证各页工具栏高度与视觉完全一致。

### 4.3 页面内嵌搜索（PageToolbar actions）

- **入口**：各功能页（音乐库/专辑/歌手/播放列表）标题栏 `PageToolbar.actions` 最前放搜索图标按钮（`Icons.search`，tooltip「搜索」）。设置页不做搜索。
- **进入**：点击后其余 actions 清空，仅保留 `ToolbarSearchField`（`lib/widgets/toolbar_search_field.dart`）——内部放大镜 + 有输入时清空按钮 + 外部关闭按钮；搜索框宽度弹性：最小 `minWidth`（默认 240），最大 = 窗口宽 × `maxWidthFactor`（默认 0.4，最大化窗口时变宽）。
- **过滤**：内存过滤，统一用 `lib/core/utils/search_util.dart` 的 `normalizeQuery`/`containsIgnoreCase`（纯函数，可单测）；查询为空显示全部内容。
- **匹配数**：搜索中 `PageToolbar.subtitle` 显示「匹配 N 首/张/位/个」。
- **无结果**：`Expanded(child: SearchEmptyState(query: …))`（`lib/widgets/search_empty_state.dart`）。
- **关闭**：清空输入回到全部内容（仍在搜索模式）；点关闭按钮退出搜索模式并恢复原 actions。
- **特例**：音乐库搜索时隐藏文件夹/扫描/沙箱横幅，仅显示歌曲结果；播放列表搜索时隐藏「我的收藏」卡片。
- **播放**：音乐库搜索结果的播放走 `LibraryViewModel.playSongsFromList(filtered, index)`，保证"下一首"限定在搜索结果内。

### 4.1 详情页顶部栏（DetailTopBar）

- 组件：`lib/widgets/detail_top_bar.dart`，实现 `PreferredSizeWidget`，走 Scaffold `appBar:` 槽位（body 无需改动）。
- 结构：总高 `layoutConfig.detailTopBarHeight`（macOS=52 与红绿灯中心对齐，其余=56）；左侧 `layoutConfig.detailTopBarLeftInset`（macOS=95 让过红绿灯，其余=0）；返回键与右侧功能按钮用 `IconButtonTheme` 统一（icon 22 / 命中区 36）；标题 `titleMedium` 左对齐，距左侧按钮约一个按钮宽度（32）。
- 已覆盖：专辑/歌手/播放列表详情、我的收藏。
- **规范**：二级详情页一律用 `DetailTopBar`；「播放全部」等大操作不放此栏（由页面内容区放置）。

### 4.2 详情页「播放全部」按钮（PlayAllButton）

- 组件：`lib/widgets/play_all_button.dart` —— 统一的**椭圆形文本按钮**（`FilledButton.icon` + `StadiumBorder`，▶ 播放全部）。
- 位置：放在**详情块信息文本下方**（封面右侧那一列，文本之下）；详情块（`DetailHeader`）底部用**底边线**（`Border(bottom: outlineVariant)`，`elevation: 0`）分隔列表区（2026-08-25 起弃用 elevation 阴影，见 4.3）。
- 已用：专辑详情、播放列表详情、我的收藏（爱心占位详情块）、歌手「歌曲」区块标题右侧（同一组件）。
- 空态禁用：播放列表详情 / 我的收藏在歌曲为空时传 `enabled: false`（`FilledButton` 原生禁用态），专辑/歌手因列表恒非空保持默认启用（2026-09-08）。

### 4.3 卡片表面（CardSurface）— 弃用 Card elevation 阴影

- 组件：`lib/widgets/card_surface.dart` —— `Container`（`surfaceContainerLow` 底色 + 圆角 12 + `boxShadow`）+ `Material(transparency)` + `InkWell`（水波保留）。
- **阴影**：`bottomDropShadow()` 3 条 `blurRadius: 0` 实线（偏移 (0,1)/(0,2)/(0,3)、alpha .10/.07/.04、颜色 `scheme.shadow`）。`blurRadius: 0` = 纯色填充，**不触发 Impeller 的 SDF blur** —— 弱 GPU / Intel 上近零 raster 开销（perf 验证：关 elevation 阴影从 ~20ms 尖峰回到 60fps）。
- **规范**：卡片一律用 `CardSurface`；**勿用 `Card(elevation:)`**（Material elevation 阴影在 Impeller macOS SDF 路径上开销高）。
- 已覆盖：专辑/播放列表网格（`CoverCard`）、播放列表「我的收藏」卡、音乐库文件夹行；`DetailHeader` 用 `elevation: 0` + 底边线分隔。
- 调参：改 `card_surface.dart` 一处即可（alpha / 偏移 / 底色）。

## 5. 二级页面待办

- 已用 `DetailTopBar` 完成避让（2026-08-04）：专辑/歌手/播放列表详情、我的收藏、播放列表（队列）全屏页。
- 播放页：保留其 `AppBar`，结构改为「顶部红绿灯预留 `playerTopBarTopReserve`（macOS 45）+ 下方 56 控件区」，控件固定在下方；标题字号与 `DetailTopBar` 一致（2026-08-05）。
- 仍待处理：歌词全屏页（`LyricsPage`，M3 `AppBar`≈56 会与红绿灯重叠）；其窄窗歌词展示方案后续另行讨论。(页面已完全重做，没有这个问题了)
- 详情页按钮回归（2026-08-05）：专辑/播放列表/我的收藏 详情的「播放全部」统一用 `PlayAllButton` 椭圆形文本按钮（▶ 播放全部），置于**详情块信息文本下方**；详情块底部**底边线**分隔列表（2026-08-25 起，弃用 Material 阴影，见 4.3）；播放列表详情的「添加歌曲/更多」放回 `DetailTopBar` actions；歌手详情用「歌曲」区块标题右侧的同一 `PlayAllButton`。收藏页 `_playAll` unused 告警已清零。
