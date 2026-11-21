# PlayCover 智能窗口适配与后台静默验证改动整理

本仓库为 [`PlayCover/PlayCover`](https://github.com/PlayCover/PlayCover)（基线 `develop@24bbed7`）的个人 Fork，配合同步修改的 [`Rengwang/PlayTools`](https://github.com/Rengwang/PlayTools)（基线 `master@fbc8880`），汇总了多轮会话中针对 **IPA 窗口自适应重排、等比画布缩放、本地无证书构建以及 Sidecar 副屏零打扰自动化测试** 的全部源码改动与实机验证记录。

---

## 一、核心目标与背景痛点

原版 PlayCover / PlayTools 在日常运行 iOS 应用时存在以下问题：
1. **默认分辨率锁死**：原版默认 `resolution = 1`（基于显示器固定尺寸）或固定分辨率，只在 `resolution == 6` 时开放窗口调整，且普通应用拖动窗口时只改外部裁剪框、内部 UIKit 不触发重排。
2. **`Resizable (6)` 机制不完整**：仅缓存首个 `UIWindow`，多窗口或开屏切换后易失效；未 Hook `UIScreen.nativeBounds`，缺少 `UICollectionView`/`UITableView` 递归布局刷新。
3. **固定比例竖屏/横屏应用容易被裁切**：对于未声明 iPad 自适应布局（如 `UIRequiresFullScreen = true` 或仅支持单一方向）的应用，自由缩窄窗口会导致界面被截断。
4. **部分第三方自定义 `UICollectionViewLayout` 懒计算导致空白**：如小红书等瀑布流/详情页自定义布局在初次 `prepareLayout` 后或二次进入时 `collectionViewContentSize` 仍返回 `{0, 0}`，导致页面空白或错位。
5. **需要无打扰、不抢鼠标的真机 UI 验证方案**：macOS 全局只有一个实体光标，传统 GUI 自动化会抢占用户主屏与鼠标；通过 `PLAYCOVER_TARGET_SCREEN=sidecar` + `PLAYTOOLS_AUTOMATION=1` + `sidecar_runner` 实现副屏静默启动、进程内触控注入与按窗口 ID 静默截图。

---

## 二、总体架构：双模式智能自适应引擎（`resolution = 7`）

将默认分辨率模式升级为 **`7 - 智能自适应（Smart Auto-Adapt）`**，在安装及启动阶段依据 `Info.plist` 自动分流：

1. **模式 A：自由拖动自适应布局（`Adaptive`）**
   - **判定条件**：`UIDeviceFamily` 包含 `2`（支持 iPad）、`UIRequiresFullScreen != true`，且同时支持横竖屏或声明了 `UIApplicationSceneManifest`。
   - **行为**：放开自由缩放（最小内容区 `360x540`），动态同步 `UIScreen.bounds`、`applicationFrame`、`nativeBounds` 到当前活跃主 `UIWindow` 尺寸，并在尺寸变化时递归刷新 `UIViewController`、`UICollectionViewLayout` 与 `UITableView`。
   - **运行时溢出兜底**：稳定后若检测到非横向滚动主体视图发生横向溢出（`> 24pt`，排除 `TabScroll`/`QueuingScrollView`/`PageView`/`Carousel`/`Banner` 与动画图层），自动无缝降级为模式 B。
2. **模式 B：推荐比例等比画布缩放（`Scaled`）**
   - **判定条件**：强制全屏或单一方向应用（如仅竖屏 `9:16 -> 414x736`、仅横屏 `16:9 -> 1280x720`、纯 iPad 竖屏 `3:4 -> 768x1024`）。
   - **行为**：AppKit 锁定 `NSWindow.contentAspectRatio`；UIKit 将主 `UIWindow.bounds` 保持在逻辑画布尺寸，通过 `UIWindow.transform` 等比居中缩放并钳制直接子视图（如 `UITransitionView` / `TopmostView`）边界，同时修正 `contentLayoutRect` 下的鼠标/触控坐标映射。

---

## 三、`PlayCover` 宿主端修改明细（9 个文件）

### 1. 应用能力识别与智能默认配置
- [`PlayCover/Model/AppInfo.swift`](PlayCover/Model/AppInfo.swift)
  - 新增 `deviceFamilies`、`supportsIPad`、`requiresFullScreen`、`supportedOrientations`。
  - 新增 `supportsAdaptiveWindowLayout`、`recommendedAspectRatio`（`16:9` / `3:4` / `9:16`）与 `recommendedLogicalResolution`（`1280x720` / `768x1024` / `414x736`）。
- [`PlayCover/Model/AppSettings.swift`](PlayCover/Model/AppSettings.swift)
  - 将 `AppSettingsData.resolution` 默认值与缺省解码值由 `1` 改为 `7`（智能自适应）。
  - 新增 `applySmartAdaptDefaults(to:info:)`：自适应应用默认自由比例、初始窗口 `900x760`；固定布局应用自动写入推荐长宽比与逻辑尺寸；同步接入 `init`、`sync()` 与 `reset()`。

### 2. 设置界面与本地化文案
- [`PlayCover/Views/AppSettingsView.swift`](PlayCover/Views/AppSettingsView.swift)
  - 分辨率选择器新增选项 `7`（`settings.picker.adaptiveRes.7`）。
  - 选中智能自适应时展示当前识别结果（「自适应窗口」或「推荐比例 (W:H)」）。
  - 重构 `setResolution()` 以统一更新 `updatedSettings` 并在切换到 `7` 时重新应用智能默认参数。
- [`PlayCover/en.lproj/Localizable.strings`](PlayCover/en.lproj/Localizable.strings) & [`PlayCover/zh-Hans.lproj/Localizable.strings`](PlayCover/zh-Hans.lproj/Localizable.strings)
  - 补充 `Smart Auto-Adapt` / `智能自适应`、`Adaptive Window` / `自适应窗口`、`Recommended Aspect (%@)` / `推荐比例 (%@)` 等文案（同时补全了缺失的中文 `settings.picker.adaptiveRes.6` 及比例文案）。

### 3. 安装链路、无头 CLI 入口与本地签名构建
- [`PlayCover/Utils/PlayTools.swift`](PlayCover/Utils/PlayTools.swift)
  - 拆分同步安装方法 `installOnSystemSync()`，并在复制前兼容清理遗留的符号链接目标。
  - 将 `installInIPA(_:)` 改造为 `withCheckedThrowingContinuation` 异步等待 `Inject.injectMachO`、插件复制、用户 dylib 同步及重签名真正完成，修复连续安装/启动竞态。
- [`PlayCover/AppInstaller/Installer.swift`](PlayCover/AppInstaller/Installer.swift)
  - 新增 `Installer.installCLI(ipaUrl:)`：支持无头 CLI 安装（跳过交互式 Mac App Store 弹窗、自动创建 `PlayChain` 目录、同步设置、签名、生成 LaunchServices alias 与去 quarantine）。
- [`PlayCover/Views/PlayCoverApp.swift`](PlayCover/Views/PlayCoverApp.swift)
  - 新增 `@main enum PlayCoverLauncher`，支持 `--install-ipa <path>` / `--install-ipa=<path>` 命令行无界安装模式（`.prohibited` 激活策略，不抢占桌面焦点），输出结构化结果 `INSTALLED|<bundleId>|<appPath>|<supportsAdaptive>|<ratio>`。
- [`PlayCover.xcodeproj/project.pbxproj`](PlayCover.xcodeproj/project.pbxproj)
  - 调整 `Sign PlayTools & Sparkle` 构建脚本，支持无签名证书时自动回退 Ad-Hoc（`-`）并仅在非 `-` 时附加 `-o runtime`。
  - 将 Debug / Release 的 `ENABLE_HARDENED_RUNTIME` 设为 `NO`，以便本地无开发者证书调试运行。

---

## 四、`PlayTools` 注入框架修改明细（7 个文件，详见 [`Rengwang/PlayTools`](https://github.com/Rengwang/PlayTools)）

1. **[`AKPlugin.swift`](https://github.com/Rengwang/PlayTools/blob/master/AKPlugin.swift) & [`Plugin.swift`](https://github.com/Rengwang/PlayTools/blob/master/Plugin.swift)**
   - 新增 `AKAppLayoutInfo` 解析 `Info.plist` 布局能力；基于 `resolutionSetting == 7` 初始化自适应最小尺寸 (`360x540`) 或推荐比例锁定（`contentAspectRatio`）。
   - 多窗口跟踪（`configuredWindows` / `verifiedTargetWindows`），监听 `didFinishLaunching` 与 `NSWindow` 激活/曝光通知。
   - 新增 `applyWindowAspectLock`、`clearWindowAspectLock`、`placeWindowOnTargetScreenIfNeeded` 与 `contentLayoutRect`。
   - 支持 `PLAYCOVER_TARGET_SCREEN=sidecar|secondary`，在窗口初始化时直接居中并钳制到 Sidecar 副屏可见区域。
2. **[`PlayTools/PlaySettings.swift`](https://github.com/Rengwang/PlayTools/blob/master/PlayTools/PlaySettings.swift)**
   - 默认 `resolution = 7`，新增 `smartAdaptive`、`dynamicWindowMode`，扩展 `resizableWindow`（`6 || 7`），并为 `AppSettingsData` 实现全字段安全缺省解码。
3. **[`PlayTools/PlayScreen.swift`](https://github.com/Rengwang/PlayTools/blob/master/PlayTools/PlayScreen.swift)**
   - 实现 `PlayDisplayMode`（`.adaptive` / `.scaled`）、`activePrimaryWindow` 评分筛选与 `resolveBoundsResizable`。
   - 实现 `.scaled` 模式下 `UIWindow` `bounds`/`center`/`transform` 等比缩放与直接子视图/根视图尺寸边界钳制（解决 `TopmostView` 等残留全屏尺寸导致的画面裁切）。
   - 实现 `.adaptive` 模式下宿主窗口 resize 节流与视图树递归刷新（`UICollectionViewLayout.invalidateLayout()`、`UITableView` cell 刷新）。
   - 实现防误触的运行时横向溢出自动降级检测（`evaluateRuntimeNonAdaptiveFallback`）。
   - 内置 `PLAYTOOLS_AUTOMATION=1` 文件 IPC 服务（`~/Library/Containers/io.playcover.PlayCover/Automation/<bundleId>/{ready.json,cmd.json,state.json}`），支持 `dump`、`dumpTree`、`tap`、`swipe`（经 `PTFakeMetaTouch` 进程内派发）与 `setMode`，同时返回 `clippedViews` 与 `interactiveElements`。
4. **[`PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.m`](https://github.com/Rengwang/PlayTools/blob/master/PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.m)**
   - 增加空类/空方法 swizzle 保护；在 `dynamicWindowMode` 下 Hook `UIScreen`（`bounds`/`applicationFrame`/`nativeBounds`/`nativeScale`/`scale`）、`UIWindow`（`layoutSubviews`/`setFrame:`/`setBounds:`/`setRootViewController:`/`didAddSubview:`）与 `UIViewController`（`viewWillLayoutSubviews`/`viewDidAppear:`）。
   - **通用自定义 `UICollectionViewLayout` 懒计算修复**：通过 `dladdr` 识别非系统且非 PlayTools 本身的自定义 `UICollectionViewLayout` 子类，Hook `prepareLayout`、`collectionViewContentSize`、`invalidateLayoutWithContext:` 及 `UICollectionView` 的初始化/切换布局/`layoutSubviews`，在 `collectionViewContentSize` 首次返回 `{0, 0}` 时自动触发一次 `layoutAttributesForElementsInRect:` 预热并维护重入保护与尺寸缓存，修复部分自定义瀑布流/详情页布局在 Catalyst 下内容尺寸未即时计算的问题。
5. **[`PlayTools/Controls/Frontend/EventAdapter/Mouse/Instances/TouchscreenMouseEventAdapter.swift`](https://github.com/Rengwang/PlayTools/blob/master/PlayTools/Controls/Frontend/EventAdapter/Mouse/Instances/TouchscreenMouseEventAdapter.swift)**
   - 在 `dynamicWindowMode` 与常规模式下统一改用 `contentLayoutRect` 计算归一化坐标，修复标题栏高度偏移与等比缩放后的点击偏移。
6. **[`PlayTools/MysticRunes/PlayedAppleDB.swift`](https://github.com/Rengwang/PlayTools/blob/master/PlayTools/MysticRunes/PlayedAppleDB.swift)**
   - 打开 SQLite 数据库前自动确保 `PlayChain` 目录存在。

---

## 五、配套工具与 Sidecar 实机验证记录

### 1. 全局后台静默 Computer Use 技能沉淀
- 已将零抢鼠标、副屏隔离自动化方案总结并安装为全局 Antigravity Skill：`~/.gemini/config/skills/silent-computer-use/`（包含 `SKILL.md`、`references/architecture.md`、`scripts/sidecar_runner.swift` 与编译后的 `sidecar_runner`）。

### 2. 多应用实机验证结果（Sidecar 副屏，`clippedViewCount = 0`）
- **小红书（`com.xingin.discover`）**：
  - 验证了宽屏 4 列瀑布流（`911x770` / `980x780`）、窄屏 3 列自适应重排（`420x760`）、`scaled 9:16`（`479x880` @ `1.504x`、`321x599` @ `1.007x`）以及从缩放恢复自适应宽屏，`clippedViewCount` 均为 `0`。（注：后期未登录访客点击首页卡片会触发应用自身的 `XYAuthWelcomeEntranceViewController` 登录墙拦截。）
- **酷安（`com.coolapk.app`）**：
  - 验证了宽屏（`980x780`）、窄屏（`420x760`）、回宽屏、`scaled 9:16`（`479x880`、`321x599`）、帖子详情页宽/窄屏切换以及“数码” Tab 多列网格布局，`clippedViewCount` 均为 `0`（注：刚跨模式大幅缩放窗口瞬间，顶部轮播图会保留旧水平滚动偏移直到下次分页吸附）。
- **哔哩哔哩（`tv.danmaku.bilianime`）**：
  - 在前期构建中验证了首页推荐窄屏 2 列 ↔ 宽屏 3 列自适应、“分区”网格重排，以及修复 `Scaled` 模式下 `TopmostView` 尺寸残留与 `BFCTabScrollView` 误触发降级。
- **公考雷达（`com.midas.gkld`）**：
  - 验证了推荐比例 `9:16` 等比缩放居中渲染（`clippedViewCount = 0`）。

---

## 六、后续增强（iPhone Duo、UI Scale、SDK Shift 与稳定性护栏）

1. **iPhone Duo（折叠屏宽窗）布局与系统状态反映**
   - 默认设备标识与布局选项新增 `iPhone Duo`（`iPhone19,4` / `layoutIdiom = 3`，与 iPhone / iPad / 自动并列）。
   - `AppInfo.swift`、`AKPlugin.swift`、`PlayScreen.swift` 识别 `DTSDKName >= 27.1`（`supportsDuoAdaptive`）与 `UIRequiresFullScreenIgnoredStartingWithVersion`。
   - 在 `iPhone Duo` 展开横屏宽窗下通过 `UIWindow.safeAreaInsets`、`UIWindowScene.interfaceOrientation`、`UIApplication.statusBarOrientation`、`UIWindowSceneGeometry.interfaceOrientation` 与 `_UIScreenFixedCoordinateSpace.bounds` 动态反映折叠/展开与独占模拟内屏占比（实测高德地图 `17.03.1` 首页与路线规划页在 `1050×780` 宽窗下正确激活左栏右图分栏，哔哩哔哩 `9.20.0` `1100×820` 4 列 ↔ `420×770` 2 列自由重排）。
2. **Catalyst 界面缩放比例（`uiScale` / `iOSMacScaleFactor`）**
   - 在单应用图形设置中支持 `100%`（默认 1:1）、`77%`（macOS Catalyst 原版默认）、`115%`、`125%`、`150%`、`200%` 切换。
3. **SDK Shift（强制解锁自由自适应缩放）单应用开关 + 模式 6 修复**
   - 参考 `SDKShift-for-Duo` 思路，新增单应用开关 `sdkShift`：开启后在宿主与 `PlayTools` 中解除全屏与单向比例锁定，并在内存中为 `[NSBundle mainBundle]` 声明 `DTSDKName = iphoneos27.2` 与 `UIRequiresFullScreen = NO`（实测百度网盘 `13.37.5` 从 `9:16` 锁定解锁至 `900×760` 内容重排）。
   - 修复模式 `6`（`Resizable`）下 `AKPlugin.aspectRatioSetting` 未优先判断 `resizableAspectRatioType == 0` 导致残留宽高仍锁死窗口比例的问题。
4. **运行时兼容性与稳定性护栏**
   - `Toucher.swift` 增加空 `keyWindow` 判空保护；`PlayedApple.swift` / `PlayedAppleDB.swift` 补齐默认 `kSecAttrAccessGroup` 与 `PRAGMA user_version` 建表检查。
   - `PlayLoader.m` 增加 libc interpose 原函数快照防互调递归、`CloudKit` 缺失权限安全降级桩、`UINSUIKitTerminationController` 退出超时上限收敛与远程通知重复注册限流；`ProxyShield.m` 在签名前注入以向应用呈现 iOS 标准网络代理/网卡视图。

---

## 七、低功耗「应用模式（App Mode）」默认策略与宿主功耗修复

面向日常非游戏 iOS 应用（B 站、小红书、酷安等）与笔记本续航场景，将默认运行策略升级为低功耗 **App Mode**，同时保留一键切回 **Game Mode** 的能力（配套 `PlayTools` 侧同步停用空载 60–120Hz `CADisplayLink`、消除 `SwordRPC`/SwiftNIO 10 线程泄漏并优化热路径 Hook）：

1. **共享配置默认收敛为低功耗 App Mode**
   - [`PlayCover/Model/AppSettings.swift`](PlayCover/Model/AppSettings.swift)、[`PlayCover/Model/DiscordActivity.swift`](PlayCover/Model/DiscordActivity.swift)、[`PlayCover/Utils/LegacySettings.swift`](PlayCover/Utils/LegacySettings.swift)
   - 与 `PlayTools` 对齐默认配置：`keymapping = false`、`discordActivity.enable = false`，新增单应用开关 `spoofPowerState = false`（仅在开启时伪装 100% 满电、正常温控与非低电量模式；关闭时遵循 macOS 低电量模式、系统温控与 App Nap）。
   - 保留 `layoutIdiom = 3`、`iosDeviceModel = "iPhone19,4"`、`resolution = 7`、`uiScale = 1.0`、`playChain = true`、`rootWorkDir = true` 不变。
2. **宿主 `PlayApp.runAppExec()` 1 Hz 轮询与无条件防息屏缺陷修复**
   - [`PlayCover/Model/PlayApp.swift`](PlayCover/Model/PlayApp.swift)
   - 修复此前忽略 `disableTimeout == false` 而无条件创建 `kIOPMAssertionTypeNoDisplaySleep` 阻止显示器休眠的 Bug（`disableTimeOut()` 增加 `guard settings.settings.disableTimeout`）。
   - 移除 `while !runningApp.isTerminated { ... sleep(1) }` 1 Hz 阻塞轮询循环，改为事件驱动的 `NSWorkspace.shared.notificationCenter` 监听（`didActivateApplicationNotification` / `didDeactivateApplicationNotification` / `didTerminateApplicationNotification`）：默认关闭防息屏且未启用 KeyCover 时零监听、零唤醒、零电源断言，应用退出与对象销毁时自动清理。
3. **设置页「运行模式」一键预设与电池/温控伪装开关**
   - [`PlayCover/Views/AppSettingsView.swift`](PlayCover/Views/AppSettingsView.swift)、[`PlayCover/en.lproj/Localizable.strings`](PlayCover/en.lproj/Localizable.strings)、[`PlayCover/zh-Hans.lproj/Localizable.strings`](PlayCover/zh-Hans.lproj/Localizable.strings)
   - 在 `MiscView` 顶部新增「运行模式（Usage Mode）」一键切换按钮：**低功耗应用模式**（关闭 `keymapping`、`discordActivity.enable`、`spoofPowerState`、`disableTimeout`）与 **游戏模式**（开启 `keymapping`、`spoofPowerState`）。
   - 新增独立开关「伪装满电与无温控（游戏模式）」（`spoofPowerState`）及说明提示，并清理 `KeymappingView`/`MiscView` 中未使用的 `@AppStorage` 冗余声明。
