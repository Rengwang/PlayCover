# PlayCover 与 PlayTools 维护手册

本手册为个人 Fork 双仓库工作区的统一维护与能力总览。[PlayCover 宿主](README.md) 维护在 `develop`，[PlayTools 运行时](https://github.com/Rengwang/PlayTools/tree/master) 维护在 `master`。

| 仓库 | 分支 | Fork | 上游 |
| --- | --- | --- | --- |
| PlayCover | `develop` | [Rengwang/PlayCover](https://github.com/Rengwang/PlayCover) | [PlayCover/PlayCover](https://github.com/PlayCover/PlayCover) |
| PlayTools | `master` | [Rengwang/PlayTools](https://github.com/Rengwang/PlayTools) | [PlayCover/PlayTools](https://github.com/PlayCover/PlayTools) |

---

## 一、构建、安装与上游同步

从同时包含 `PlayCover/`、`PlayTools/` 与 `sync_upstream.sh` 的工作区根目录执行（新克隆可直接调用 [双仓库构建入口](Tools/Workspace/README.md)：`./PlayCover/Tools/Workspace/sync_upstream.sh`）：

| 命令 | 说明 |
| --- | --- |
| `./sync_upstream.sh check` | 拉取 `upstream` 引用，对比上游新提交与本地补丁栈。 |
| `./sync_upstream.sh export-patches` | 导出相对 `upstream` 的提交到 `./patches/`。 |
| `./sync_upstream.sh sync` | 创建备份分支并将本地提交 rebase 到最新上游。 |
| `./sync_upstream.sh build` | 构建双切片 `PlayTools.xcframework`（含 macOS 布局 `AKInterface.bundle`）与 `PlayCover.app`。 |
| `./sync_upstream.sh install` | 校验签名、`matchingUUID` 及兼容不变式，并原子安装到 `/Applications/PlayCover.app` 与 `~/Library/Frameworks/PlayTools.framework`。 |
| `./sync_upstream.sh build-install` | 依次执行 `build` 与 `install`。 |
| `./sync_upstream.sh push` | 将 `develop` / `master` 推送至个人 Fork（`origin`）。 |

- **固定签名身份**：可通过 `${XDG_CONFIG_HOME:-$HOME/.config}/playcover/local-signing-identity` 或 `PLAYCOVER_SIGNING_IDENTITY` 指定本地签名指纹，以便重建后延续 KeyCover 钥匙串授权；未配置时自动采用 Ad-Hoc 签名。
- **命令行安装**：`PlayCover.app/Contents/MacOS/PlayCover --install-ipa <path>` 支持无界面批量安装，成功输出 `INSTALLED|<bundleId>|<appPath>|<supportsAdaptive>|<ratio>`。
- **独立插件与发布**：独立本地化实验脚本保留在工作区 `patches/marginnote5/`；正式签名与公证仍由 [fastlane 配置](fastlane/Fastfile) 及[发布工作流](.github/workflows/1.build_release.yml)负责。

---

## 二、运行时增强与桌面体验汇总

### 1. 窗口几何、输入与设备界面
- **Smart Auto-Adapt（`resolution = 7`）**：结合设备族、方向、场景声明自动选择自由重排或等比画布；窗口稳定后出现明显横向溢出可自动切回等比缩放，并在多窗口间同步缩放。
- **窗口持久化与全局返回**：记录并恢复应用窗口位置/尺寸，防止 iPad 兼容应用窄屏拖拽误落 9:16 比例；支持侧键/手势触发通用返回（`check-global-back.py`）。
- **设备模型与 iPhone Duo（`layoutIdiom = 3`）**：支持显式 iPhone / iPad / Duo (`iPhone19,4`) / Auto 切换，并提供 **iPhone Duo 垂直栏（`duoVerticalBar`）** 与合成右侧导航栏开关。
- **Option + 滚轮缩放（`optionScrollZoom`）**：支持以光标为中心触发双指捏合缩放手势，可在应用设置与开关管理中单独开启或关闭（`hideTitleBar` 默认开启）。

### 2. 能效控制、iOS 语义自适应帧率与开关管理
- **Switch Manager 开关总控（`FeatureManagerView`）**：仿 macOS“隐私与安全性”风格的统一分栏开关面板，集中管理并批量切换所有应用的能效、外观、输入与兼容选项。
- **能效模式（`EfficiencySettingsView`）**：
  - **省电模式（`powerSavingMode`）**：强开系统无障碍降透/减动态语义、窗口被完全遮挡时挂起 `WKWebView` 媒体并在 10 秒无播放时切入 `5 FPS` 低刷新、合并限制视频预缓冲。
  - **省内存模式（`memorySavingMode`）**：收敛 `NSCache` / `NSURLCache`（`8 MiB`）上限，宿主机端对 `Cacher.appIconCache` 设置 `16 MiB` 解码预算，并在遮挡时释放 `MTKView` Drawable。
  - **Metal 省显存（`metalMemorySaver`）与视频节流（`avMediaSaver`）**：关闭 `CAMetalLayer` EDR 并限制 `maximumDrawableCount <= 2`，统一将 `CALayer` 位图格式及 `UIGraphicsImageRendererFormat` 限制为标准 8-bit；限制 `AVPlayerItem` 分辨率、码率上限（`3 Mbps`）与前向缓冲（`8s`）。
  - **外观模式（`appearanceStyle`）**：支持按应用切换“跟随系统 / 浅色 / 深色”；并在深色播放等环境下对受影响 `UIVisualEffectView` 提供不透明深色回退（避免白色磨砂块遮挡）。
- **多档限帧与 iOS 语义自适应（`frameRateCap`）**：
  - 手动档位支持 `60 / 45 / 40 / 30 / 20 / 10 FPS` 及不限制（`0`）。
  - **自适应模式（`-1`）**：还原 iOS Core Animation / ProMotion 按实际渲染需求调度的语义，而非单纯按无键鼠操作强行一刀切：
    - 交互窗口（`3s`）及检测到连续 `CALayer` 大位移/画布重绘（`setPosition:` / `setBounds:` / `setTransform:` / `setNeedsDisplay` / 大画布 `setContents:`）、在飞空间 `CAAnimation`、高帧率 `CAMetalLayer`（`>= 35 FPS`）或高帧率 `AVPlayer` 视频（`> 35 FPS`）时，保持 **`60 FPS · 动效`**（含约 `1.8s` 防抖弛豫，如开启弹幕看视频不动鼠标也能流畅跑满）；
    - 纯播放 24/30fps 媒体流（含 `AVPlayer` 与 `AVSampleBufferDisplayLayer`）且无弹幕/动效时，平滑降至 **`30 FPS · 媒体`**；
    - 纯静态页面（如阅读/帖子页）在无操作 `3s` 后降至 **`10 FPS · 静止`**，`12s` 后降至 **`1 FPS · 静止`**（自动过滤光标闪烁与微小进度条抖动，键鼠/触控操作瞬间唤醒）。
- **应用内实时帧率悬浮窗（`fpsOverlay`）**：轻量非交互左上角胶囊（不拦截点击、不污染自适应动效判定、窗口遮挡时暂停计数），直观展示实时 `FPS`、状态标签（`静止` / `媒体` / `动效` / `省电`）与 Metal 帧率。

### 3. 媒体、定位与开屏/风控兼容（Fork 独有与系统兼容层）
- **相机兼容（`CameraCompatibility.m`）**：Catalyst 无后摄时自动回退可用前摄并保持硬件位置属性；支持水平角度校准（`cameraRotation`）与前后摄预览独立镜像（`cameraFrontMirror` / `cameraBackMirror`）。
- **虚拟定位（`LocationCompatibility.m` + `LocationPickerView`）**：提供按应用的 MapKit 可视化选点与线程安全的 `CLLocationManager` 定位注入。
- **开屏广告通用拦截（`blockSplashAds`）**：在 `PlayLoader.m` 按主流广告 SDK 类名协议拦截开屏加载/展示并回调失败代理，避免白屏卡死；同时梳理了聚合加载器、自研开屏等后续扩展分层（`PLAYTOOLS_DISABLE_SPLASH_AD_BLOCK=1` 可临时关闭）。
- **SDK 风险横幅中性化与结构拦截（`PlayLoader.m`）**：定位“检测到 hook 框架 / 篡改 / 官方渠道”风控提示来源（基于磁盘镜像 GOT 敏感符号扫描与 `PrinterPlatformizationManger` 通道），采用结构签名中性化与无词表依赖的通道静音替代易漏报关键词黑名单；提供 `PT_RISK_BANNER=0` / `PT_RISK_NEUTRALIZE=0` / `PT_RISK_HOOKS=0` / `PT_RISK_PROBE=1` 诊断开关。注意：**重签名与服务端校验不在客户端可控范围**，本地手段只确保风险弹框不上屏、主流程可用。
- **底层安全与系统兼容**：
  - 安装期反自毁陷阱清理（`Macho.neutralizeAntiTamperTraps`）与按需只读映射检查；
  - Swift overlay 路径解析、ARM64 FAT32/FAT64 通用二进制切片选择、沙盒 locale/timezone/字体别名兼容；
  - App Group 无空格规范化及幂等迁移、`MarketplaceKit`（`AppDistributor.other`）/ `WirelessInsights` 弱连接与兼容存根、iOS-only 弱框架防崩、OneNote 启动开屏场景衔接、中国电信退出 C++ 流缓冲保护、`PlayChain` 属性精确匹配与连接池化、`CloudKit` 缺失权限存根、UE `getlogin_r` 与退出超时保护。

---

## 三、自检体系与最新验收结论

- **自动化不变式与模块回归**：位于 `PlayTools/Tests/` 的 `check-compat-invariants.py` 与 7 个专项测试脚本（`check-input-lifecycle.py`、`check-option-scroll-zoom.py`、`check-msc-mouse-bridge.py`、`check-duo-vertical-bar.py`、`check-global-back.py`、`check-launch-crash-guards.py`、`check-wireless-insights-compat.py`），在最终 `./sync_upstream.sh install` 时自动运行，最近一轮 **147 passed / 0 failed**。
- **可控与实机功能验证（2026-11-27）**：
  - `AdaptiveMotionProbe`（Mac Catalyst）12/12 场景全通过：静态 `60 -> 10 -> 1 FPS · 静止`、24fps 视频 `30 FPS · 媒体`、无鼠标触发下启动 `setPosition:` / `CAAnimation` / 大画布 `setContents:` 均自动唤醒至 `60 FPS · 动效` 并可回落、微幅光标/进度条不误唤醒。
  - **63 款已安装应用 Sidecar 并发全量回归（6 并发，耗时 `90.0s`）**：**61/63** 正常挂载副屏、完成 `ready.json` 与 UI 层级采样并退出，被测应用 **0 崩溃（0 新增应用 `.ips`）**；仅 `com.burbn.instagram` 与 `com.facebook.Facebook` 呈现既有白屏及 `ready.json` 超时，关闭全部限帧/能效开关后对照组表现完全一致，确认与本轮改动无关。
- **性能基线对照（2026-11-23）**：UpTimer / 酷安同版本 App Store 对照、启动分段优化及硬件归因边界详见 [PERFORMANCE_REVIEW.md](PERFORMANCE_REVIEW.md) 与 [Tools/Performance/README.md](Tools/Performance/README.md)。

> 如需运行框架级底层探针测试，可通过 `XCODE_XCCONFIG_FILE` 传入 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) PLAYTOOLS_FRAMEWORK_PROBES` 并开启 `PLAYTOOLS_AUTOMATION=1` / `PLAYTOOLS_SELFTEST=1`。
