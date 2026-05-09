# VibeChard

[![Release](https://img.shields.io/github/v/release/Maples7/VibeChard?label=release&color=blue)](https://github.com/Maples7/VibeChard/releases) [![CI](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/Maples7/VibeChard?color=green)](LICENSE) ![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![Swift](https://img.shields.io/badge/swift-5.10%2B-orange)

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

<p align="center">
  <a href="docs/images/hero.zh-CN.png"><img src="docs/images/hero.zh-CN.png" alt="不用 vch：3 个并行的 xcodebuild 抢 build.db / 模块缓存 / 模拟器。用上 vch：每个 agent 都在自己的 worktree 里，独立 DerivedData + 独立模拟器克隆" width="960"></a>
</p>

> **为 AI 编程代理设计的 Apple 平台并行 worktree 隔离工具。**
> 在同一个 Xcode 项目里同时跑多个 Claude / Codex / Copilot / Cursor 会话，
> 不再触发 `build.db` 锁、`DerivedData` 抖动或者模拟器互相冲突。

```sh
brew install maples7/tap/vch
```

<p align="center">
  <img src="docs/images/demo.gif" alt="vch new → vch list → vch state → vch exec → vch remove，全部隔离，25 秒内走完" width="720">
</p>

随后在任意 Apple 项目里：

```sh
vch new add-paywall          # 创建隔离的 worktree + agent 分支
vch add-paywall              # 进入该 worktree 的 shell（隔离已生效）
                             # → 直接像平时一样用 xcodebuild / swift test
vch test add-paywall --device "iPhone 16"
vch remove add-paywall
```

就这些。每个 agent 拿到自己专属的 worktree、专属的 `DerivedData`、专属的模拟器克隆——你的 `~/Library/Developer/` 一字节都不会被动。

<p align="center">
  <img src="docs/images/vch-list.zh-CN.png" alt="vch list 输出：3 个 agent 任务并行，2 个 ok 1 个 fail，以及 vch state 详情" width="720">
</p>

> **状态：alpha。** CLI 接口已基本稳定但尚未冻结；
> `.vch/state.json` 的 schema 之后还可能加字段。需要稳定的话请固定 tag。

## 为什么单独做一个 CLI？

通用的 git-worktree 管理器（Rift、Emdash、Taskpods、Workie 之类）只解决「源码树隔离」一件事。但 Apple 的工具链里**至少还有 7 个**别的共享资源——并行跑 `xcodebuild` 时它们会互相踩，导致非确定性失败：

| 资源 | 不隔离时会怎样 | VibeChard 的做法 |
|---|---|---|
| `DerivedData` | 模块反复重建，缓存被污染 | `-derivedDataPath <wt>/.agent-build/DerivedData` |
| `ModuleCache.noindex` | 并发下 Clang 模块缓存损坏 | 每个 worktree 一个 `CLANG_MODULE_CACHE_PATH` |
| SwiftPM 全局缓存 | `Package.resolved` 写冲突 | 每个 worktree 一个 `-clonedSourcePackagesDirPath` |
| `xcresult` 报告包 | 后写者覆盖前写者 | 每个 worktree 一个 `-resultBundlePath` |
| 模拟器设备 | 两个任务同时往同一台 iPhone 16 装包 | 每个任务一个 `xcrun simctl clone` |
| Agent 走 PATH 找 `xcodebuild` | 直接绕过我们注入的 flag | **PATH shim** 自动注入 flag |
| 源码树 | 标准做法 | `git worktree` + `agent/<name>` 分支 |

工具是 **BYO Agent（自带代理）**——Claude、Codex、Copilot、Cursor，
任何能跑 shell 的东西都行。VibeChard *不是* AI 厂商的封装。无遥测、无网络请求、无 SDK 绑定。

<details>
<summary><strong>「直接用 <code>git worktree</code> + 写个 5 行的 shell 函数不就行了？」</strong></summary>

<br/>

合理的质疑——我一开始也是这么干的。代码树确实隔离了，但 agent 在
worktree 里跑的每一次 `xcodebuild` 仍然解析到这些**全局**位置：

- `~/Library/Developer/Xcode/DerivedData/MyApp-<hash>/`（全局默认）
- `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex/`（全局）
- `~/Library/Caches/org.swift.swiftpm/`（全局）
- `~/Library/Developer/CoreSimulator/Devices/<UDID>/`（全局）

只要其中任何一个被共享，并发下的 `xcodebuild` 就是 racy 的。要解决只有两条路：

1. **每次都手动传对 flag。** 每个 `xcodebuild`、每个 `swift test`
   都记得带上 `-derivedDataPath` / `-clonedSourcePackagesDirPath` /
   `-resultBundlePath`；然后还要教 Tuist、Fastlane、所有自定义测试脚本、任何会 shell out 的 `Package.swift` plugin 都这么做；然后还要叮嘱你的 *AI agent* 别忘——它一定会忘。
2. **在 `xcodebuild` 前面塞个 PATH shim**，保证不管谁、用什么方式调它，那些 flag 一定在。

VibeChard 选的是 (2)。这就是为什么它是个 CLI，而不是一段 `.zshrc`
片段。

</details>

## 安装

### Homebrew（推荐）

```sh
brew install maples7/tap/vch
```

formula 会安装：

- `vch` 到 Homebrew 的 `bin/`（在 `PATH` 上）
- `vch-xcodebuild-shim` 到 `libexec/`（**故意不**放在 `PATH` 上——它只应该被 `vch exec` 在每个任务的 `.vch/bin/` 里建的符号链接调到）
- Bash、Zsh、Fish 的命令补全脚本

### 从源码构建

环境要求：macOS 13+、Xcode 15.3+（Swift 5.10+）。

```sh
git clone https://github.com/maples7/VibeChard.git
cd VibeChard
swift build -c release
ln -s "$PWD/.build/release/vch" /usr/local/bin/vch    # 或者你存放 CLI 的任意位置
```

## 快速上手

在任意 git 仓库形态的 Apple 项目里：

```sh
# 1. 创建一个隔离的 worktree，分支为 agent/add-paywall
vch new add-paywall

# 2. 进到那个 worktree 的 shell（PATH shim 已激活）
vch add-paywall
# 在这个 shell 里：
#   xcodebuild build              ← 自动注入 -derivedDataPath
#   swift test                    ← 模块缓存 + SwiftPM 克隆目录已隔离
#   exit                          ← 回到原 shell

# 3. 也可以不进 shell，直接调 xcodebuild：
vch build add-paywall --scheme MyApp
vch test  add-paywall --scheme MyApp --device "iPhone 16"

# 4. 在 worktree 里直接驱动 agent：
vch new fix-toast --exec "claude"     # 在隔离的 worktree 里启动 claude
vch new triage --copy-untracked       # 顺便拷贝 .env / .vscode 等未跟踪文件
vch exec fix-toast -- npm run lint    # 在 worktree 里跑一次性命令

# 5. 查看与清理
vch list
vch path add-paywall                  # worktree 的绝对路径
vch remove add-paywall                # 删除 worktree + 分支 + 模拟器克隆
```

## 工作流：一连串任务

vch 的最佳使用姿势不是单个任务，而是**连续短任务**（或并行任务）：
每个任务都跑在自己的 worktree 里，落地完再起下一个。一个典型循环：

```sh
# 计划：A → B → C，每个任务都先合入再起下一个。

# 任务 A —— 实现、测试、Review。
vch new task-a
cd "$(vch path task-a)"
# ...编辑...
vch build task-a --scheme MyApp
vch test  task-a --scheme MyApp --device "iPhone 16"
git commit -am "perf: task A"
vch open task-a                       # 在 IDE 里 review

# 评审通过后，从主 worktree 合并：
cd /path/to/main-worktree
git merge --no-ff agent/task-a -m "Merge agent/task-a: <subject>"
vch remove task-a                     # worktree + 分支 + 模拟器克隆一起删干净

# 任务 B 从干净的 develop 重新开始，循环不变。
vch new task-b
# ...
```

每次 `vch new` 都会拿到独立的 SwiftPM 解析缓存、DerivedData 和模块
缓存（都在 `.vch/` 里），所以两个并行任务永远不会因为 SPM 锁竞争或
Xcode 构建缓存失效互相阻塞。从不同 shell 同时跑几个 `vch test` 也
不会撞 Core Data 数据库或抢同一个模拟器。

如果你给 vch 写脚本（比如驱动 agent），优先使用稳定的
`vch state <name> --field <dotted>` 接口，不要直接读
`.vch/state.json`：

```sh
udid=$(vch state task-a --field simulator.udid)
vch exec task-a -- xcodebuild test \
  -scheme MyApp \
  -destination "platform=iOS Simulator,id=$udid" \
  -only-testing:MyAppTests/Foo
```

## Cookbook

不够格做成命令、但又频繁出现的场景，记在这里。

### 从未提交的 WIP 上分叉新任务

`agent/foo` 做到一半，想再开一条 `agent/foo-experiment` 从 foo 的
**当前未提交状态**（不只是已提交历史）出发。`vch new --base agent/foo`
只能带上已提交的 commit；未提交的 diff 和未跟踪文件得靠 stash：

```sh
cd "$(vch path foo)"
git stash push --include-untracked -m "fork-checkpoint"

vch new foo-experiment --base agent/foo

cd "$(vch path foo-experiment)"
git stash apply              # 用 apply 不要用 pop —— stash 条目保留

cd "$(vch path foo)"
git stash pop                # foo 恢复到原状态
```

`apply` + `pop` 的组合让同一份 checkpoint 落到两个 worktree。如果不
需要把 WIP 还原回 foo，把最后一行换成 `git stash drop` 即可。

为什么不做成 `vch fork`：「原子地把 staged + unstaged + 未跟踪 +
按规则忽略的文件搬过去」在 git 里没有原生原语，详见
[#27](https://github.com/Maples7/VibeChard/issues/27)。上面这套手动
脚本足够稳，不值得加内置命令。

### 让长期任务保持最新

如果 `agent/<name>` 跑得够久，base 分支已经向前推进了，
`vch sync <name>` 会拉取记录中 base 分支的 upstream，并把任务分支
rebase 到上面 —— 全程不碰你的主 worktree：

```sh
vch sync foo                          # fetch + rebase
vch sync foo --dry-run                # 预览 ahead/behind 与计划
vch sync foo --merge                  # 改用 git merge --no-ff
                                      # （仅当 agent/foo 已被推到协作者会读的地方）
vch sync foo --onto origin/release-2  # 一次性换基准
vch sync foo --no-fetch               # 离线，仅靠已经 fetch 过的 ref 工作
```

默认策略是 「rebase、不强推、不 autostash」 —— vch 永远不会重写或
藏匿你的工作。如果 git 拒绝（未提交改动、冲突），操作会干净地中止，
你可以进入任务 worktree 手动收尾。成功的 `vch sync` 会在
`state.json` 写入 `lastSync` 块（`vch state <name>` 可见）。

### `vch land` 时保留生成的产物

`vch land` 只把**已 commit** 的内容带进目标分支。任务 worktree 里
git 不跟踪的内容 —— 未提交改动、untracked 文件、被 `.gitignore`
排除掉的内容（重新生成的图片、构建产物、缓存等等）—— **不会**
进入这次合并；而成功 land 之后默认的 `vch rm` 会把 worktree 连同
这些东西一起删掉。

这种坑会咬住一类特定的工作流：任务 worktree 里的某个脚本会重新
生成一批被 `.gitignore` 故意排除的产物，你确认了新产物没问题就
跑了 `vch land`，事后才发现这些重新生成的文件根本没跨过合并
—— 它们随 worktree 一起没了，主分支看到的还是旧版本。

如果你需要把这些产物搬到目标分支的 worktree 里，先告诉 vch
不要立刻删 worktree，等你拷贝完再删：

```sh
vch land foo --keep                              # 合并但保留 agent-foo/
rsync -a "$(vch path foo)/docs/images/" \
      docs/images/                               # 把你真正需要的部分拷过来
vch rm foo                                       # 然后再清理
```

至于用 `cp -R` / `tar -c | tar -x` / `git lfs migrate` 还是别的
工具搬，看你项目情况自己挑 —— vch 故意不去裁判 「哪些产物**应该**
被搬」「应该怎么搬」，因为答案完全取决于你的项目为什么 ignore
那些文件。

### 用 warm 模板省掉首次启动模拟器的等待

第一次对一个新克隆的模拟器跑 `vch test` 时，墙钟里大约 30 秒
是 `simctl create` + 首次启动的缓存预热，**不是**你的 build 本身。
如果你在同一台机器上对同一组 `(device, runtime)` 并行跑多个
agent，每个任务都会再付一次这笔钱。"warm 模板" 就是把这笔钱
预先付一次，让全机所有任务共享。

```sh
# 一次性准备（每对你实际用到的 device / runtime 跑一次）：
vch sim warm-template create "iPhone 16" --runtime "iOS 26.4"

# 之后每个 pin 了同一 runtime 的任务，第一次 `vch test` 都会少花
# 大约 21 秒 —— 单任务克隆会继承已经预热好的缓存。
vch test add-paywall  --device "iPhone 16" --runtime "iOS 26.4"
vch test fix-crash    --device "iPhone 16" --runtime "iOS 26.4"

# 看一下当前缓存了哪些：
vch sim warm-template list

# 不再需要的时候释放磁盘：
vch sim warm-template remove "iPhone 16" --runtime "iOS 26.4"
```

同样的写法在 **watchOS、tvOS、visionOS** 上也能用（#58），把
device 名字和 runtime label 换掉就行：

```sh
vch sim warm-template create "Apple Watch Series 10 (46mm)" --runtime "watchOS 11.5"
vch sim warm-template create "Apple TV 4K (3rd generation)" --runtime "tvOS 18.0"
vch sim warm-template create "Apple Vision Pro"             --runtime "visionOS 2.5"
```

warm 模板的生命周期**和任何任务都解耦**。`vch remove` 和
`vch doctor --clean` 永远不会动 warm 模板 —— 你创建，你删除。
`vch doctor` 会列出它们方便你发现 stale 或被启动的异常状态，
但绝不会自动清理（自动清理会悄悄抹掉 30 多秒的预热成果）。
`--runtime` 是必填的，因为同一个 device 不同 runtime 是不同的
warm 模板；不 pin 的话 vch 没办法精确查找。

各平台实测节省（中位数）：

| 平台 | cold path | warm path | 节省 |
|---|---|---|---|
| iOS（iPhone 16 + iOS 26.4，N=5） | 30.75 s | 9.41 s  | 21.35 s（69.4%）|
| watchOS（Apple Watch Series 10 (46mm) + watchOS 11.5，N=3） | 31.0 s | 23.3 s | 7.7 s（24.9%）|

watchOS 首次启动的缓存预热工作比 iOS 少，所以绝对收益小一些 ——
但仍然远高于 2 秒的噪声底线，不是白干。tvOS 和 visionOS 收益
量级估计也差不多（SPIKE 方法在 PR #58 里，你装了对应 runtime
就能自己跑一遍）。

## 命令一览

| 命令 | 作用 |
|---|---|
| `vch new <name>` | 在 `../<repo>-<name>` 创建 worktree，分支为 `agent/<name>`。`--exec "<cmd>"` 在 worktree 内直接跑命令（比如 AI agent）。`--copy-untracked` 会连同未跟踪、未被忽略的文件（如 `.env`、`.vscode/settings.json`）一起拷过来。`--seed-spm-from <task>` 用 APFS COW 把同 repo 下另一个 vch task 的 SwiftPM bare-mirror 缓存克隆过来，让这个 task 第一次 build 时跳过依赖网络拉取（仅 APFS；源 task 必须先 build 过一次）。`--cd` 启用机器可读契约：stdout 只输出 worktree 绝对路径，状态和提示一律走 stderr —— 给 fish / nushell 这类用不了 `vch shellenv` 的 shell 写 `cd "$(vch new --cd foo)"` 这种 wrapper。跟 `--exec` 互斥。 |
| `vch list` | 列出当前工作区下所有任务。`--json` 输出机器可读格式；`-v`/`--verbose` 增加 `BASE` 与 `PATH` 列；`--git-status` 增加 `AHEAD/BEHIND` + `DIRTY` + `LAST COMMIT` 列（每个 worktree 多跑一次 `git rev-list` + `git status`）。 |
| `vch state <name>` | 漂亮打印任务的 `.vch/state.json`。`--json` 输出原始文件内容。`--field <dotted>` 只输出单个字段值（如 `simulator.udid`），方便在脚本里 `$(vch state foo --field simulator.udid)` 这样取。 |
| `vch path <name>` | 打印任务 worktree 的绝对路径。 |
| `vch open [<name>] [--with <ide>]` | 在 IDE 中打开 worktree。自动识别 `*.xcworkspace` / `*.xcodeproj` / `Package.swift`（项目文件用 Xcode，否则用 VS Code）。`--with` 支持 `xcode`、`code`/`vscode`、`cursor`，或任意 app 名（透传给 `open -a`）。可用 `VCH_OPEN_DEFAULT` 覆盖默认值。不传 `<name>` 时使用 `$PWD` 所在的 worktree。 |
| `vch <name>` | `vch exec <name> -- $SHELL` 的语法糖——开一个 shell，隔离环境变量 + `.vch/bin` PATH shim 已就绪。 |
| `vch exec <name> -- <cmd...>` | 在任务 worktree 内跑任意命令，隔离已生效。 |
| `vch build <name> [flags] [-- xcodebuild-extras]` | 对任务的 worktree 跑 `xcodebuild build`，自动注入 `-derivedDataPath` / `-clonedSourcePackagesDirPath`。当项目只有一个共享 scheme 时，`--scheme` 可省（通过 `xcodebuild -list -json` 自动识别）；记录后会在后续调用里复用。`--runtime 'iOS 26.4'`（或 `'watchOS 11.5'`、`'tvOS 18.0'`、`'visionOS 2.5'`）用来在多个同名设备模板（不同 runtime）共存时锁定要用的 runtime。默认只输出精简摘要（`✓ build succeeded in 12.4s   (3 warnings)`）；`--verbose` 把 xcodebuild 完整输出直通到终端。完整 firehose 始终 tee 到 `<wt>/.vch/last-build.log`。 |
| `vch test  <name> [flags] [-- xcodebuild-extras]` | 跑 `xcodebuild test`，注入 `-resultBundlePath`；首次 `--device` 时懒克隆模拟器，后续复用。`--scheme` 自动识别与 `--runtime` 行为同 `vch build`。默认输出只显示精简摘要（每个 suite 一行，失败测试连同 file:line 与断言消息内联展开）；`--verbose` 把 xcodebuild 完整输出直通到终端。完整 firehose 始终 tee 到 `<wt>/.vch/last-test.log`。计数从 xcresult bundle 读取，因此 swift-testing（`@Suite`/`@Test`/`#expect`）目标也会被正确统计。`--rerun` 原样重放上一次调用；`--rerun-failed` 从记录的 xcresult 提取失败的测试 ID，用 `-only-testing:` 仅重跑那些失败用例。 |
| `vch run   <name> [flags] [-- launch-args]` | 在任务的模拟器克隆上构建、安装并启动 App。`--scheme` 自动识别与 `--runtime` 行为同 `vch build`，`PRODUCT_BUNDLE_IDENTIFIER` 通过 `xcodebuild -showBuildSettings -json` 自动解析。`--` 之后的参数原样转发给 `simctl launch`，例如 `vch run alpha -- -UsePreviewSampleData`。如有需要会自动启动模拟器并打开 `Simulator.app`。 |
| `vch logs <name> [--test\|--build]` | 打印任务最近一次 `vch test` 或 `vch build` 的完整 xcodebuild 日志。默认 `--test`；传 `--build` 看构建 firehose。日志每次运行时覆盖。 |
| `vch sim {clone,erase,shutdown,info} <name>` | 显式管理任务的模拟器克隆。 |
| `vch sim warm-template {create,list,remove}` | 管理共享的 *warm* 模拟器模板（#47、#58）。warm 模板是一个被「booted-once-then-shutdown」预热好的模拟器，后续 `vch test` 单任务克隆会继承它的缓存（iOS 实测：约 30 s → 约 9 s；watchOS：约 31 s → 约 23 s）。支持 iOS、watchOS、tvOS、visionOS。`create <device> --runtime "iOS 26.4"`（或 `"watchOS 11.5"`、`"tvOS 18.0"`、`"visionOS 2.5"`）创建；`list [--json]` 查看；`remove <device> --runtime "..."` 删除。**生命周期与任何任务都解耦** —— `vch remove` 和 `vch doctor --clean` 都不会动 warm 模板，需要你自己管。`vch test --device "<device>" --runtime "..."` 在匹配的 warm 模板存在时会自动选用。 |
| `vch land <name> [--into <branch>] [--no-ff\|--ff-only\|--squash] [--message MSG] [--keep] [--allow-dirty] [--dry-run] [--push\|--push-to <remote>]` | 将 `agent/<name>` 合回基准分支（在 `vch new` 时记录于 `state.json` 的主 worktree 分支）并删除 worktree。默认 `--no-ff`；默认提交消息 `Merge agent/<name>: <最近一个非合并提交的标题>`。下列情况下拒绝合并：空合并、主 worktree 不在目标分支上、主 worktree 中与任务分支 diff 重叠的路径未提交（可用 `--allow-dirty` 跳过）。`--keep` 跳过自动 rm；`--dry-run` 只打印计划不动任何东西。`--push` 把解析后的 `--into` 分支推到其追踪的 remote（`branch.<into>.remote`，没有时回落到 `origin`）；`--push-to <remote>` 显式覆盖 remote。两个标志都没传时 `vch land` 绝不联网。push 失败不会回滚 merge —— 失败信息以 stderr warning 输出。只有**已 commit** 的内容会被搬过去 —— 未提交改动、untracked 文件、被 `.gitignore` 排除的产物会随 worktree 一起被删（用 `--keep` + 手动拷贝；详见 cookbook 「`vch land` 时保留生成的产物」）。 |
| `vch sync <name> [--onto <ref>] [--rebase\|--merge] [--no-fetch] [--allow-dirty] [--dry-run] [-q]` | 拉取记录的基准分支的 upstream，并把 `agent/<name>` rebase 到其上。`--merge` 改用 `git merge --no-ff`（仅当任务分支已经被推到协作者会读的地方时再用）。`--onto <ref>` 覆盖基准；`--no-fetch` 跳过网络；`--allow-dirty` 把脏 worktree 检查交给 git 自己决定；`--dry-run` 只打印 ahead/behind 与计划策略，不写任何东西。所有 git 操作都在任务 worktree 内执行，绝不动主 worktree。成功后写入 `lastSync`。 |
| `vch remove <name> [--allow-dirty] [--allow-unmerged] [--keep-sim]` | 删除 worktree、分支以及（默认会删的）模拟器克隆。`--allow-dirty` 允许未提交改动；`--allow-unmerged` 强删未合并的分支。 |
| `vch repair` | 用 `git worktree list` 的实际状态重新对齐 `.vch/state.json`。 |
| `vch clean <name> [--swiftpm] [--logs] [--all] [--dry-run] [--json]` | 清理任务的 `DerivedData` + `ModuleCache`（默认）。`--swiftpm` 还会删 SwiftPM 克隆目录，`--logs` 删 `.vch/last-test.log`，`--all` 表示全删。如果有进程还在用 `.agent-build/` 或 `.vch/` 内的文件（比如 Xcode 正在索引）会拒绝；`--dry-run` 只列要删的内容不真删。 |
| `vch doctor [--clean] [--json]` | 检测孤儿模拟器克隆、失效绑定、损坏的 `state.json`。有发现就退出非零。 |
| `vch doctor --bug-report [--out <path>] [--json]` | 在本地打包一份脱敏诊断 tarball：每个任务的 `state.json` + `last-test.log`、porcelain worktree 列表、以及 `sw_vers` / `xcode-select -p` / `xcrun -f xcodebuild` / `swift --version` 的输出。`$HOME` 路径会被替换。不联网。默认输出 `./vch-bug-report-<UTC 时间戳>.tgz`。 |
| `vch shellenv` | 输出 `vch_cd` / `vch_new` / `vch_clean` shell 助手函数（bash/zsh）。 |
| `vch completions install [--shell <s>]` | 安装 `zsh` / `bash` / `fish` 的补全脚本（默认从 `$SHELL` 自动识别）。`--print` 预览；`--force` 覆盖已有文件。 |
| `vch version` | 打印版本与工具链信息（`--json` 为机器可读格式）。 |

所有接受 `<name>` 的命令都会从当前工作区拿任务名做补全——装好补全脚本，按 `<TAB>` 即可。

## 隔离的工作机制

<p align="center">
  <img src="docs/images/architecture.zh-CN.png" alt="架构图：agent → 主仓 → worktree → PATH shim → 独立 DerivedData + Sim 克隆" width="720">
</p>

任务 worktree 内的 `<wt>/.vch/bin/` 会被前置到 `PATH` 上，里面有三个符号链接 `xcodebuild`、`xcrun`、`swift` 都指向 `vch-xcodebuild-shim`。

shim 读三个环境变量（`VCH_DERIVED_DATA_PATH`、`VCH_SPM_CLONE_DIR`、
`VCH_RESULT_BUNDLE_PATH`），如果用户没显式传对应 flag 就把它们注入到
`xcodebuild` 的 argv 里，`mkdir -p` 创建目标目录，然后通过
`/usr/bin/xcrun -f xcodebuild` 解出真实的 `xcodebuild` 路径并 `execv`
（绕开 `PATH`，避免递归调用自己）。对 `xcrun` 和 `swift` 是透明转发。

效果：任何 agent 可能跑的工具——`xcodebuild`、`swift test`、Tuist、内部又会调到 `xcodebuild` 的脚本——都自动被隔离。无需手动传 flag。

`vch build`、`vch test` 与 `vch run` 跳过 PATH shim，直接调用 `xcodebuild`
传相同的 flag——因为它们在调用点就知道所有参数。

### `vch exec` / `vch <name>` 给子进程注入了什么

`vch <name>`（= `vch exec <name> -- $SHELL`）和 `vch exec <name> --
<cmd>` 都会在你已有环境之上叠一层确定性的 env，跟 `vch build` / `vch
test` / `vch run` 用的是同一套——所以你在 `vch <name>` 里手敲
`xcodebuild` 的行为跟 `vch build` 完全一致。基本不需要再来个「把我
扔进任务环境」的命令，`vch <name>` 已经是了：

| 变量 | 设置为 |
|---|---|
| `VCH_TASK_NAME` | 任务名（如 `add-paywall`），常用于 PS1 / 终端标题。 |
| `VCH_TASK_ROOT` | worktree 绝对路径。 |
| `VCH_DERIVED_DATA_PATH` | `<wt>/.agent-build/DerivedData`（shim 读取）。 |
| `VCH_SPM_CLONE_DIR` | `<wt>/.agent-build/SourcePackages`（shim 读取）。 |
| `VCH_RESULT_BUNDLE_PATH` | `<wt>/.agent-build/Result.xcresult`（shim 读取）。 |
| `VCH_RESULT_BUNDLE_DIR` | result bundle 的父目录。 |
| `CLANG_MODULE_CACHE_PATH` | `<wt>/.agent-build/ModuleCache`（clang 读取）。 |
| `SWIFTPM_CACHE_DIR` | `<wt>/.agent-build/SourcePackages`（SwiftPM 读取）。 |
| `DEVELOPER_DIR` | 宿主选定的 Xcode（`xcode-select -p`）—— 仅当用户没设置时注入。 |
| `SIMCTL_CHILD_SIMULATOR_UDID` | 任务绑定的模拟器克隆 —— 仅当已绑定时设置。 |
| `PATH` | 在头部追加 `<wt>/.vch/bin`，让 `xcodebuild` / `xcrun` / `swift` 走 shim。 |

`vch` 不会覆盖你已经导出的值——在 `vch exec` 之前手动 `export` 任意一个，
你的值优先。

## 配置

无。所有任务级状态都在 `<worktree>/.vch/state.json` 里。没有 `~/.vchrc`、没有 `.vch.toml`、没有任何全局配置文件。唯一的运行时旋钮是上面提到的那几个 `VCH_*` 环境变量
（一般由 `vch exec` 自己设置，你很少需要手动配）。`vch build`/`vch test`/`vch run` 还会把宿主选定的 `DEVELOPER_DIR`（通过 `xcode-select -p` 解出）传给子进程——手动设置该环境变量即可覆盖。

如果 `vch new` 提示了 `eval "$(vch shellenv)"`，可以用 `VCH_NEW_HINT=0`
关闭这条提示（或者直接安装好 shell helper）。

## VibeChard 不是什么

- **不是 AI 厂商封装。** 没有 SDK、没有 API key、没有模型抽象。用任何 agent 都行——VibeChard 只负责让并行会话安全。
- **不跨平台。** 只服务 Apple，是设计选择。整个项目的价值就在
  Xcode 工具链上的深度，不在广度。
- **不是 CI 编排器。** 它跑在你本地终端、对你磁盘上的 worktree 起作用。
  CI 矩阵是另一类问题。

## 常见问题

<details>
<summary><strong>能跟 Tuist / Fastlane / xcbeautify 一起用吗？</strong></summary>

<br/>

可以。PATH shim 会拦截所有的 `xcodebuild` 调用，不管是谁发起的。Tuist
生成的执行、Fastlane 的 `gym` / `scan`、xcbeautify 上游的管道、任何最终调到 `xcodebuild` 上的自定义脚本——都会被自动注入每任务的
`-derivedDataPath` / `-clonedSourcePackagesDirPath` /
`-resultBundlePath`。你不用自己传 flag。

</details>

<details>
<summary><strong>CocoaPods / Carthage 呢？</strong></summary>

<br/>

可以。它们的依赖拉取步骤不走 `xcodebuild`，本来就不需要隔离；构建步骤最终会调到 `xcodebuild`，被 shim 拦下来。`Pods/` 和 `Carthage/` 目录跟源码一起待在 worktree 里，由 `git worktree` 本身隔离。

</details>

<details>
<summary><strong>纯 SwiftPM 项目（没有 <code>.xcodeproj</code>）？</strong></summary>

<br/>

行。`swift build` / `swift test` 默认就把产物写进每个 worktree 自己的
`.build/`——天然隔离，shim 不用注入 flag。shim 仍然会包住 `swift` 但只做透明 passthrough。

</details>

<details>
<summary><strong><code>vch remove</code> 时未提交的改动会丢吗？</strong></summary>

<br/>

不会——它会拒绝执行。`vch remove` 在 worktree 脏的时候会带着明确提示中止。加 `--allow-dirty` 才会强删（连带丢掉未提交改动）；加 `--allow-unmerged`（或两个标志同时使用）还允许删除有未合并提交的分支。没有静默的破坏路径。

</details>

<details>
<summary><strong>不用 AI agent 也能用吗？</strong></summary>

<br/>

能。任何「我想要个并行沙盒」的场景都行：同时试两套互不相同的实现、跑长测试套件的同时在主 worktree 继续写代码，等等。CLI 跟 agent 解耦——所谓 agent 集成只是 `--exec "<your command>"`。

</details>

## 从源码构建与测试

```sh
swift build -c release
./.build/release/vch version
swift test --parallel
```

CI 在每次 push 上跑相同的命令，外加一个 shim 的烟雾测试：
[.github/workflows/ci.yml](.github/workflows/ci.yml)。

## 许可证

[Apache-2.0](LICENSE)。无 CLA，无遥测，无网络请求。
