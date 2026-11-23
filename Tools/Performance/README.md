# macOS 性能复测

在 macOS 和已配置 Xcode 的环境运行。`window-runner` 需要现有的辅助功能权限。测试先读取实际屏幕名称和坐标，有 Sidecar 时优先放到副屏；启动后同时保存实际窗口坐标。脚本拒绝复用已打开的同标识应用，不会自动关闭用户已有会话。

```sh
mkdir -p /tmp/playcover-perf-bin
xcrun swiftc -O Tools/Performance/window-runner.swift -o /tmp/playcover-perf-bin/window-runner
xcrun clang -O2 -Wall -Wextra Tools/Performance/process-usage.c -o /tmp/playcover-perf-bin/process-usage
python3 Tools/Performance/check-launch-inspection.py
python3 Tools/Performance/check-alias-reuse.py
python3 Tools/Performance/benchmark.py --manifest /path/to/cases.json \
  --bin /tmp/playcover-perf-bin --out /path/to/local-results --seconds 20 --rounds 2
```

清单使用 JSON 数组，逐项指定 `label`、完整应用路径 `path`，以及可选的 `states`：

```json
[
  {"label": "store", "path": "/Applications/Example.app", "states": ["active", "hidden", "restore"]},
  {"label": "playcover", "path": "/path/to/converted/Example.app", "states": ["active", "hidden", "restore"]}
]
```

请先核对版本、构建、签名和实际窗口大小。`firstWindowSeconds` 测量出现窗口的时间，`firstAXWindowSeconds` 仅在窗口由辅助功能识别时提供。辅助功能缺失时使用 WindowServer 的窗口边界复核，不能改变尺寸则拒绝同尺寸测量。这些指标不代表网络内容加载完成，也不包含 PlayCover 的启动前准备。测试工具会唤醒应用的辅助功能支持；启动指标按同一方法比较。应用在机器重启后首次启动与缓存后的重复启动应另行标注。

进程计量包括物理 footprint、CPU 时间、唤醒和系统归因能量。`attributed_mW` 是归因估算值，不能当作独立电源轨的实测瓦数。`powermetrics` 通过非交互式 `sudo -n` 尝试采样，权限不足会记录错误并继续保存进程计量。`system_*_mW` 是整机 CPU/GPU 估算功率，含 Sidecar、WindowServer 和其他进程。缺失的进程 GPU 字段保留为空，不能解释为零 GPU 功耗。

测量期间不要编译、播放其他视频或手动切换应用。检查每个状态的 `before` / `after`，前台状态发生变化或尺寸不一致的样本不能进入同状态对比。程序通过普通退出请求清理自身启动的 PID；若请求未能结束，会核对实际可执行文件后尝试 SIGTERM，并记录此事。原始报告可能包含本机路径与进程信息，只保存在本地，发布时仅提交整理后的核查报告。

本轮结果见 [PERFORMANCE_REVIEW.md](../../PERFORMANCE_REVIEW.md)。PlayTools 的输入对象释放与后台轮询回归在其独立仓库运行 `python3 Tests/check-input-lifecycle.py`。
