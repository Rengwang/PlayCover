# PlayCover 与 PlayTools 维护手册

本手册适用于个人 Fork 的双仓库工作区。PlayCover 宿主负责 IPA 安装、Mach-O 转换、签名和应用配置。PlayTools 运行在已注入的应用进程内，负责窗口、输入和 iOS API 兼容。Git 历史保存历次实现和完整变更，本文记录当前维护流程及已验证的边界。

| 仓库 | 分支 | Fork | 上游 |
| --- | --- | --- | --- |
| PlayCover | `develop` | [Rengwang/PlayCover](https://github.com/Rengwang/PlayCover) | [PlayCover/PlayCover](https://github.com/PlayCover/PlayCover) |
| PlayTools | `master` | [Rengwang/PlayTools](https://github.com/Rengwang/PlayTools) | [PlayCover/PlayTools](https://github.com/PlayCover/PlayTools) |

## 构建、安装与同步

从同时包含 `PlayCover/`、`PlayTools/` 和 `sync_upstream.sh` 的工作区根目录执行。

```sh
./sync_upstream.sh build
```

脚本构建原生 iOS 和 Mac Catalyst 两个 arm64 PlayTools 切片，并把 macOS 布局的 `AKInterface.bundle` 装入各切片。PlayCover 使用 Catalyst 切片，真机 IPA 导出使用随应用资源携带的 `PlayTools-iOS.framework`。本地构建采用 Ad-Hoc 签名。最终应用在 `build/PlayCover/Release/PlayCover.app`，双切片在 `PlayCover/Carthage/Build/PlayTools.xcframework`。

维护命令如下。

| 命令 | 行为 |
| --- | --- |
| `./sync_upstream.sh check` | 拉取上游引用，列出上游新提交和本地补丁栈。 |
| `./sync_upstream.sh export-patches` | 重新导出两个仓库相对上游的提交到 `patches/PlayCover/` 和 `patches/PlayTools/`。 |
| `./sync_upstream.sh sync` | 要求工作树干净，创建备份分支、导出补丁，再将本地提交 rebase 到上游。 |
| `./sync_upstream.sh build` | 构建并签署本机调试用 Release 应用。 |
| `./sync_upstream.sh push` | 对两个 Fork 的对应分支执行 `--force-with-lease`。 |

上游更新后按 `check`、`sync`、`build` 的顺序处理，验证完成后再决定是否发布分支。遇到 rebase 冲突时可在对应仓库使用 `git rebase --continue` 或 `git rebase --abort`。

批量或自动化安装可以调用构建产物的 `Contents/MacOS/PlayCover --install-ipa <path>`。成功时输出 `INSTALLED|<bundleId>|<appPath>|<supportsAdaptive>|<ratio>`，并安装本机 PlayTools 运行时。框架安装先暂存并校验签名，再原子替换。面向 GitHub 的签名和公证仍由 [fastlane 配置](fastlane/Fastfile) 及[发布工作流](.github/workflows/1.build_release.yml)负责。

## 运行时行为

- **窗口布局**　默认 `resolution = 7` 为 Smart Auto-Adapt。根据设备族、窗口能力、方向和场景声明选择自由重排或等比画布。稳定后出现明显横向溢出时可自动切到等比模式。缩放同步同场景可见应用窗口，输入命中使用 UIKit 坐标转换。
- **设备和界面**　`layoutIdiom = 3` 为 iPhone Duo，标识为 `iPhone19,4`。显式 iPhone、iPad 和 Duo 协调设备与界面的 idiom。Auto 由 UIKit 决定布局，设备型号按配置读取。`uiScale`、原生平台身份和 SDK Shift 可按应用选择。
- **低功耗应用模式**　默认关闭按键映射、Discord 动态与电池及温控伪装。手柄输入按需启停。窗口热路径与 PlayChain SQLite 连接复用。游戏模式可在应用设置页启用相应功能。
- **PlayChain**　完整属性参与查询。支持查询上限、重复项返回码和永久密钥标签。数据库版本 2 为既有记录补充不透明标识。持久引用在属性更新后保持稳定，并可用于读取、更新与删除。无法约束的写操作返回错误。
- **Mach-O 和沙盒**　宿主镜像转换为 arm64 Catalyst。Swift overlay 按实际依赖和系统共享缓存解析，应用随附库优先。系统加载的 `.appex` 和原生组件 `.bundle` 保留各自平台。扫描指纹覆盖镜像相对路径、大小、时间与系统版本。沙盒兼容规则维护系统 locale、时区别名和字体别名的读取。旧版 `ProxyShield.dylib` 的安装残留由迁移代码清理。
- **插件、资源和系统框架**　`AKInterface` 提供桌面窗口、鼠标和键盘桥接。`PlayTools.strings` 随 IPA 安装和应用启动复制，以独立名称提供运行时本地化。

## 自动化与自检

| 设置 | 用途 |
| --- | --- |
| `PLAYCOVER_TARGET_SCREEN=sidecar` | 已连接随航时优先将新测试窗口放到副屏。 |
| `PLAYTOOLS_AUTOMATION=1` | 启用进程内 JSON IPC。目录为 `~/Library/Containers/io.playcover.PlayCover/Automation/<bundleId>/`。 |
| `PLAYTOOLS_SELFTEST=1` | 生成 `Automation/selftest_<bundleId>.json`，包含 PID、时间、逐项结果与观测值。 |
| `PLAYTOOLS_SELFTEST_GROUP` | 可指定 `keychain`、`platform` 或 `geometry`。探针构建还支持 `entitlements`、`media`、`webkit`、`urls`、`presentations`。 |

IPC 通过 `cmd.json` 接收 `dump`、`dumpTree`、`tap`、`swipe` 或 `setMode`，通过 `state.json` 返回结果。`selftestGeometry` 可在缩放后重新校验坐标往返和画布适配。标记过的独立夹具可在探针构建中调用 `selftestPresentations`，验证当前窗口的系统面板。窗口测试应核对实际落点，触控测试使用进程内事件。

构建系统框架探针时，在单独的 xcconfig 中加入以下设置。

```xcconfig
SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) PLAYTOOLS_FRAMEWORK_PROBES
```

通过 `XCODE_XCCONFIG_FILE` 传给 `./sync_upstream.sh build`。用独立测试应用验证会申请权限或改动音频会话的入口。普通应用上的探针只运行适用项。本机测试辅助脚本和原始报告位于工作区 `build/diagnostics/`，其中 `semantic-contracts/fixture-probes.md` 记录夹具用法。

## 验证与已知边界

| 范围 | 已验证结果 |
| --- | --- |
| Keychain | B 站和独立 Catalyst 应用各通过 20 项。系统 Security 入口返回重复项 `-25299`，持久引用可回查和删除。迁移后的测试库通过 SQLite 检查，临时记录已清理。 |
| 平台 | 独立应用测试了四种布局与原生平台开关的八种组合。主程序 `+load` 的身份观测与运行后相符，更早加载的依赖库不在此结论内。重复调用 `ProcessInfo.isMacCatalystApp` 的单调用点基准中位数由约 50.4 µs 降至 8.6 ns。 |
| Mach-O | QuickLook overlay 夹具修复后可启动，弱链接类型和随附库优先级得到保留。冷启动和热启动的指纹测试通过。B 站、高德地图和小红书共检查 25 个 Catalyst 宿主镜像及 18 个独立 iOS 扩展。 |
| 几何 | 第二轮在内建屏用最终 Release 对 B 站、高德地图、小红书和酷安完成 16 项宽窄窗口、缩放与恢复检查。四款应用正常退出，本轮几何回归期间无新增崩溃报告。小红书可打开笔记和分享入口的应用内登录提示。高德地图的底部面板保留越界候选。独立夹具验证了第二窗口按钮命中。 |
| 权限和媒体 | 第二轮全量探针通过 70 项。新夹具另行验证临时通知授权并完成清理。常用音频类别、混音播放激活和状态恢复通过。Apple 登录与 GameKit 认证使用可单独触发的测试入口，待随航实测。 |
| WebKit、跳转和系统面板 | iPhone 和 Duo 的窄窗 WebView 返回移动 UA，显式桌面模式与自定义 UA 得到保留。未知 Scheme 和相对 URL 在约 8–12 ms 返回 `false`。15 项系统面板检查覆盖宽窗、窄窗和等比缩放。 |
| 沙盒 | 工行签名规则的本机重放确认修复时区、UTF-8 和系统字体别名读取，无关系统文件仍受原规则限制。签名或完整性自检需单独定位。 |
| 功耗 | UpTimer 在相同 810 × 720 窗口下，两组 15 秒空闲样本的平均进程归因功耗为 2.93 → 3.88 mW。延长稳定时间后，30 秒对照为 2.55 → 2.51 mW，未复现短样本升幅。长期运行和整机功耗待测。 |

详细报告保存在本机诊断目录。发布或表述某个应用已兼容时，应以对应版本和具体场景的复测为准。
