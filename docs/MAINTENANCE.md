# PlayCover 与 PlayTools 维护手册

本手册整合了原维护记录与双仓库构建脚本说明，作为个人 Fork 双仓库工作区的统一维护参考。[PlayCover 宿主](https://github.com/Rengwang/PlayCover) 维护在 `develop`，[PlayTools 运行时](https://github.com/Rengwang/PlayTools) 维护在 `master`。

| 仓库 | 分支 | Fork | 上游 |
| --- | --- | --- | --- |
| PlayCover | `develop` | [Rengwang/PlayCover](https://github.com/Rengwang/PlayCover) | [PlayCover/PlayCover](https://github.com/PlayCover/PlayCover) |
| PlayTools | `master` | [Rengwang/PlayTools](https://github.com/Rengwang/PlayTools) | [PlayCover/PlayTools](https://github.com/PlayCover/PlayTools) |

---

## 一、双仓库构建、安装与上游同步

### 1.1 工作区初始化

新环境可按同级双仓库布局拉取代码并构建（需要 Xcode、命令行工具与 Carthage；项目原始 Carthage 配置指向上游，直接打开 Xcode 更新依赖时需注意来源）：

```sh
mkdir playcover-workspace && cd playcover-workspace
git clone -b develop https://github.com/Rengwang/PlayCover.git PlayCover
git clone -b master https://github.com/Rengwang/PlayTools.git PlayTools
git -C PlayCover remote add upstream https://github.com/PlayCover/PlayCover.git
git -C PlayTools remote add upstream https://github.com/PlayCover/PlayTools.git
./PlayCover/Tools/Workspace/sync_upstream.sh build
./PlayCover/Tools/Workspace/sync_upstream.sh install
```

在已有工作区根目录（同时包含 `PlayCover/`、`PlayTools/` 与 `sync_upstream.sh`）可直接执行 `./sync_upstream.sh <command>`：

| 命令 | 说明 |
| --- | --- |
| `./sync_upstream.sh check` | 拉取 `upstream` 引用，对比上游新提交与本地补丁栈。 |
| `./sync_upstream.sh export-patches` | 导出相对 `upstream` 的提交到 `./patches/`。 |
| `./sync_upstream.sh sync` | 创建备份分支并将本地提交 rebase 到最新上游（要求工作树干净）。 |
| `./sync_upstream.sh build` | 依次构建 `PlayTools`（`iphoneos`）、`AKInterface.bundle`（`macosx`，移除根目录残留 `Info.plist`）、`PlayTools`（`Mac Catalyst`），打包双切片 `PlayTools.xcframework` 并使用 `FASTLANE=1` 构建签署 `PlayCover.app`。 |
| `./sync_upstream.sh install` | 校验严格签名、`matchingUUID` 及运行 `PlayTools/Tests/check-compat-invariants.py`，原子安装到 `/Applications/PlayCover.app` 与 `~/Library/Frameworks/PlayTools.framework`。 |
| `./sync_upstream.sh build-install` | 依次执行 `build` 与 `install`。 |
| `./sync_upstream.sh push` | 使用 `--force-with-lease` 将本地分支推送至 `origin`（常规迭代可直接使用 `git push`）。 |

### 1.2 签名、命令行安装与外挂补丁

- **固定本地签名身份**：可在 `${XDG_CONFIG_HOME:-$HOME/.config}/playcover/local-signing-identity` 写入签名指纹，或设置环境变量 `PLAYCOVER_SIGNING_IDENTITY`，以便重建后延续 KeyCover 钥匙串授权；未配置时自动采用 Ad-Hoc 签名。
- **无界面批量安装 CLI**：`PlayCover.app/Contents/MacOS/PlayCover --install-ipa <path>` 支持无界面安装 IPA，成功输出 `INSTALLED|<bundleId>|<appPath>|<supportsAdaptive>|<ratio>`。
- **独立插件与发布**：本地独立外挂脚本保留在工作区 `patches/marginnote5/`；正式签名与公证仍由 [fastlane 配置](../fastlane/Fastfile) 及 [发布工作流](../.github/workflows/1.build_release.yml) 负责。

---

## 二、运行时增强与兼容性架构

### 2.1 窗口几何、输入与设备界面
- **Smart Auto-Adapt（`resolution = 7`）**：结合设备族、方向、场景声明自动选择自由重排或等比画布；窗口稳定后出现明显横向溢出可自动切回等比缩放，并在多窗口间同步缩放。
- **实时拖拽节流与窗口持久化**：记录并恢复应用窗口位置/尺寸，防止 iPad 兼容应用窄屏拖拽误落 9:16 比例；通过 `CFRunLoopObserver` 测量帧提交耗时动态节流 live-resize 频率（`nextAdaptiveResizePacingInterval`）并在拖拽期间抑制无效布局与唤醒抖动。
- **设备模型与 iPhone Duo（`layoutIdiom = 3`）**：支持显式 iPhone / iPad / Duo（`iPhone19,4`）/ Auto 切换，提供 **iPhone Duo 右侧垂直栏（`duoVerticalBar`，默认 52pt）** 与多子视图自定义 TabBar 浮胶囊自动隐藏守卫。
- **全局返回与桌面输入**：支持跨应用的标题栏返回/首页按钮、侧键/键盘快捷键触发通用返回（`GlobalBackSettings`）；支持 **Option + 滚轮缩放（`optionScrollZoom`）**、可调滚轮速度（`scrollWheelSpeed`）与无 MouseArea 滚轮拖动。

### 2.2 能效控制、iOS 语义自适应帧率与开关管理
- **Switch Manager 开关总控（`FeatureManagerView`）**：仿 macOS“隐私与安全性”风格的分栏开关面板，集中管理所有应用的能效、外观、输入与兼容选项。
- **能效模式（`EfficiencySettingsView`）**：
  - **省电模式（`powerSavingMode`）**：开启系统降透/减动态语义、窗口被完全遮挡时挂起 `WKWebView` 媒体并在 10 秒无播放时切入 `5 FPS` 低刷新、合并限制视频预缓冲。
  - **省内存模式（`memorySavingMode`）**：收敛 `NSCache` / `NSURLCache`（`8 MiB`）上限，宿主机端对 `Cacher.appIconCache` 设置 `16 MiB` 解码预算，并在遮挡时释放 `MTKView` Drawable。
  - **Metal 省显存（`metalMemorySaver`）与视频节流（`avMediaSaver`）**：关闭 `CAMetalLayer` EDR 并限制 `maximumDrawableCount <= 2`，限制位图与渲染器格式为标准 8-bit；限制 `AVPlayerItem` 分辨率、码率上限（`3 Mbps`）与前向缓冲（`8s`）。
  - **外观模式（`appearanceStyle`）**：按应用切换“跟随系统 / 浅色 / 深色”，配合 `_updateFromSystemAppearance:` 重入保护与深色环境 `UIVisualEffectView` 不透明回退。
- **多档限帧与 iOS 语义自适应（`frameRateCap`）**：
  - 手动档位：`60 / 45 / 40 / 30 / 20 / 10 FPS` 及不限制（`0`）。
  - **自适应模式（`-1`）**：交互窗口（`3s`）及连续 `CALayer` 大位移/画布重绘、空间 `CAAnimation`、高帧率 `CAMetalLayer` / `AVPlayer`（`>= 35 FPS`）保持 **`60 FPS · 动效`**（含约 `1.8s` 防抖弛豫）；纯播放 24/30fps 媒体流平滑降至 **`30 FPS · 媒体`**；纯静态页面无操作 `3s` 后降至 **`10 FPS · 静止`**，`12s` 后降至 **`1 FPS · 静止`**（自动过滤光标闪烁与微小进度条抖动，输入瞬间唤醒）。
- **应用内实时帧率悬浮窗（`fpsOverlay`）**：轻量非交互左上角胶囊，展示实时 `FPS`、状态标签与 Metal 帧率，窗口遮挡时暂停计数。

### 2.3 媒体、定位与系统兼容层
- **相机兼容（`CameraCompatibility.m`）**：Catalyst 无后摄时自动回退可用前摄并保持硬件位置属性；支持水平角度校准（`cameraRotation`）与前后摄预览独立镜像（`cameraFrontMirror` / `cameraBackMirror`）。
- **虚拟定位（`LocationCompatibility.m` + `LocationPickerView`）**：提供按应用的 MapKit 可视化选点与线程安全的 `CLLocationManager` 定位注入。
- **开屏广告通用拦截（`blockSplashAds`）与 SDK 风控中性化**：按主流广告 SDK 协议拦截开屏并回调失败代理；通过磁盘镜像 GOT 敏感符号扫描中性化部分 SDK 风险弹框（支持 `PT_RISK_*` 诊断开关）。**边界声明：服务端校验与重签名校验不在客户端可控范围内**。
- **底层安全与系统兼容**：
  - 安装期反自毁陷阱清理（`Macho.neutralizeAntiTamperTraps`）、`mmap` 只读启动限制段检查、Swift overlay 路径解析、FAT32/FAT64 通用二进制切片选择；
  - 沙盒 `/usr/share/locale`、`/Library/Fonts`、`/etc`、`/var` 读取保留，宿主机直读应用包图标（避免同步 `lsd` 卡顿）；
  - App Group 无空格规范化及幂等迁移、`MarketplaceKit`（`AppDistributor.other`）/ `WirelessInsights` 兼容存根、iOS-only 弱框架防崩、OneNote 启动开屏场景衔接、`CTPocketOutputCompatibility` 退出 C++ 流缓冲保护、`PlayChain` 全属性精确匹配与连接池化、`CloudKit` 缺失权限存根、UE `getlogin_r` 与退出超时保护；
  - 同步集成社区 PR 改进（如 `AppsVM` 库刷新防抖、iTunes 请求去重、滚轮速度调节、`WKWebView` 触控特性对齐、`fishhook` 防递归原始系统调用与 Metal HUD 菜单保留等）。

---

## 三、自检体系与最新验收结论

- **自动化不变式与模块回归**：位于 `PlayTools/Tests/` 的 `check-compat-invariants.py` 与 7 个专项测试脚本（`check-input-lifecycle.py`、`check-option-scroll-zoom.py`、`check-msc-mouse-bridge.py`、`check-duo-vertical-bar.py`、`check-global-back.py`、`check-launch-crash-guards.py`、`check-wireless-insights-compat.py`），在 `./sync_upstream.sh install` 时自动运行，最近一轮 **154 passed / 0 failed**。
- **可控与实机功能验证（2026-11-27）**：
  - `AdaptiveMotionProbe`（Mac Catalyst）12/12 场景全通过。
  - **63 款已安装应用 Sidecar 并发全量回归（6 并发，耗时 `90.0s`）**：**61/63** 正常挂载副屏、完成 `ready.json` 与 UI 层级采样并退出，被测应用 **0 崩溃（0 新增 `.ips`）**；仅 `com.burbn.instagram` 与 `com.facebook.Facebook` 呈现既有白屏及 `ready.json` 超时，关闭全部限帧/能效开关后对照组表现完全一致。
- **性能基线对照（2026-11-23）**：详见 [性能与兼容性核查报告](PERFORMANCE.md)。

> 如需运行框架级底层探针测试，可通过 `XCODE_XCCONFIG_FILE` 传入 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) PLAYTOOLS_FRAMEWORK_PROBES` 并开启 `PLAYTOOLS_AUTOMATION=1` / `PLAYTOOLS_SELFTEST=1`。
