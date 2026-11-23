# 双仓库构建入口

此入口从同级的 PlayTools 源码构建 iOS / Catalyst 两个切片，再构建和签署 PlayCover。它保存了本轮实际使用的工作区脚本，增加了从仓库内定位同级目录的支持。

准备两个 Fork：

```sh
mkdir playcover-workspace
cd playcover-workspace
git clone -b develop https://github.com/Rengwang/PlayCover.git PlayCover
git clone -b master https://github.com/Rengwang/PlayTools.git PlayTools
git -C PlayCover remote add upstream https://github.com/PlayCover/PlayCover.git
git -C PlayTools remote add upstream https://github.com/PlayCover/PlayTools.git
./PlayCover/Tools/Workspace/sync_upstream.sh build
./PlayCover/Tools/Workspace/sync_upstream.sh install
```

需要 Xcode、命令行工具和 Carthage。脚本在构建宿主时使用 `FASTLANE=1` 及刚生成的运行时；项目原始 Carthage 配置仍指向上游，直接打开 Xcode 自动更新依赖时应注意其来源。

`check` 拉取上游并显示补丁差异；`sync` 要求干净工作树，先备份分支再 rebase；`export-patches` 导出补丁。`push` 沿用工作区脚本的 `--force-with-lease`，用于已审阅的 rebase 后发布。本轮维护分支没有 rebase，使用普通 `git push` 发布。

`install` 会安装到本机 `/Applications/PlayCover.app` 和用户的 `~/Library/Frameworks/PlayTools.framework`，执行前可保留旧版回滚副本。固定的本地签名身份配置见[维护手册](../../SESSION_MODIFICATIONS.md)。
