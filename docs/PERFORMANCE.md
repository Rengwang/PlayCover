# 性能与兼容性核查及复测指南（2026-11-23）

本报告整合了 2026-11-23 同版本 App Store 对照测试结论与 `Tools/Performance/` 复测方法。

---

## 一、对比方法与测量边界

- **硬件与环境**：Apple M5，先按实际屏幕拓扑识别 Sidecar，再将新建测试窗口移动至副屏并验证坐标（不移动用户已有窗口）。
- **对比原则**：比较同一应用版本和构建；原生 macOS 与 iOS 产品仅作体验参考，不用于计算注入层开销。后台分别测量失焦可见、隐藏、恢复三种状态。
- **指标边界**：
  - 使用 `proc_pid_rusage(RUSAGE_INFO_V6)` 获取 CPU 时间、物理 footprint、唤醒和进程归因能量；`powermetrics` 获取整机 CPU/GPU 估算功率。
  - `attributed_mW` 为系统归因估算值，不等同于独立电源轨实测瓦数；`system_*_mW` 含 Sidecar 编码、WindowServer 及其他进程，缺失单进程 GPU 字段保留为空，不可解释为零 GPU 功耗。
  - 缓存后重复启动不视为重启机器后的冷启动。

### 复测命令

在 macOS + Xcode 环境（需已授辅助功能权限）下执行：

```sh
mkdir -p /tmp/playcover-perf-bin
xcrun swiftc -O Tools/Performance/window-runner.swift -o /tmp/playcover-perf-bin/window-runner
xcrun clang -O2 -Wall -Wextra Tools/Performance/process-usage.c -o /tmp/playcover-perf-bin/process-usage
python3 Tools/Performance/check-launch-inspection.py
python3 Tools/Performance/check-alias-reuse.py
python3 Tools/Performance/benchmark.py --manifest /path/to/cases.json \
  --bin /tmp/playcover-perf-bin --out /path/to/local-results --seconds 20 --rounds 2
```

清单格式示例（JSON 数组）：

```json
[
  {"label": "store", "path": "/Applications/Example.app", "states": ["active", "hidden", "restore"]},
  {"label": "playcover", "path": "/path/to/converted/Example.app", "states": ["active", "hidden", "restore"]}
]
```

PlayTools 输入生命周期与后台轮询回归在其仓库执行 `python3 Tests/check-input-lifecycle.py`。原始含本机路径/进程的报告仅保留在本地，可公开汇总数据见 [results-2026-11-23.json](../Tools/Performance/results-2026-11-23.json)。

---

## 二、后台 CPU、内存与归因能耗对照

正式对照包括 UpTimer 0.17.02（构建 230002450）和酷安 16.7.3（构建 2611121），均以 **810 × 720 pt** 窗口在 Sidecar 下测量（隐藏前等待 15 秒，隐藏采样 20 秒）：

| 应用与运行方式 | CPU（单核 100%） | 物理 footprint（MiB） | 进程归因功耗（mW） | 中断唤醒/秒 |
| --- | ---: | ---: | ---: | ---: |
| UpTimer / App Store iOS-on-Mac | 0.0030% | 125.3 | 0.300 | 2.4 |
| UpTimer / PlayCover | 0.0028% | 134.2 | 0.316 | 2.6 |
| UpTimer / Catalyst、移除 PlayTools 的隔离副本 | 0.0019% | 143.1 | 0.073 | 2.5 |
| 酷安 / App Store iOS-on-Mac | 0.0419% | 102.8 | 18.515 | 26.7 |
| 酷安 / PlayCover | 0.0393% | 153.3 | 8.911 | 29.1 |
| PlayCover 宿主 / 隐藏应用库 | 0.0001% | 48.7 | 0.007 | 0.1 |

> 内存差异受 Catalyst 与 iOS-on-Mac 运行机制、设备布局、应用内容和缓存释放时机共同影响（未注入 PlayTools 的 UpTimer Catalyst 对照仍占约 143 MiB），不把全部差值归因于 PlayTools 泄漏，也不宣称普遍降低了所有应用的常驻内存或整机功耗。

---

## 三、关键优化项与验证结果

### 3.1 后台输入与辅助线程清理
- 失焦或隐藏后释放映射触摸并销毁手柄队列显示回调，恢复前台按需重建；移除强制启用后台手柄事件的加载器。
- 摇杆持续轮询在失焦后停止并统一串行化到触摸队列（1,000 次并发回调压测仅单一轮询器，后台新增分发为 0）。
- 滑动动作计时器仅在有效触摸期间创建、回调弱引用、取消前确保激活；1,000 次对象释放测试由“保留 1,000 个泄漏对象”修复为全部释放。

### 3.2 启动检查与宿主峰值内存
将启动限制段检查由全文件 `Data(contentsOf:)` 改为只读 `mmap` 映射并缓存指纹；B 站 9.20.0（主程序约 311 MiB）独立检查 8 次调用对比：

| B 站主程序独立限制段检查 | 修复前 | 优化后 |
| --- | ---: | ---: |
| 检查耗时中位数 | 19.07 ms | 0.078 ms |
| 检查进程最大常驻内存 | 316.8 MiB | 5.8 MiB |

其他启动/扫描改进：安装不再阻塞等待 IPA 源网络刷新；串行元数据遍历（69 款应用 / 1,353 个镜像与原实现发现结果一致）；未变化别名与进程内 Security API 签名读取复用（69 款应用与 `codesign` 对照一致）。

### 3.3 兼容性冒烟与未完成验收项
- **69 款应用启动库图 & 14 项二进制边界检查 & 37 项 Catalyst 核心自检**：全部通过。
- **6 款实机应用 Sidecar 冒烟**（ChatGPT iOS 1.2026.315、Forest 5.35.0、系统电池分析 2.6.0、铁路 12306 5.9.6、海南航空 10.20.3、航旅纵横 8.6.8）：窗口创建、存活（8s / 125s 隐藏）与退出正常，无新增崩溃报告。
- **诚实记录的待验收边界**：长期持续播放、后台受控下载完整性、多应用长时内存趋势、实体手柄实机回归与完整登录业务流程未在本轮全部覆盖。

---

## 四、参考资料
- [PlayTools 上游仓库](https://github.com/PlayCover/PlayTools)
- [Apple: App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
- [Apple: Work When Visible](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/WorkWhenVisible.html)
- [Apple: iPad apps on Mac Lifecycle (WWDC 2019)](https://developer.apple.com/videos/play/wwdc2019/235/)
