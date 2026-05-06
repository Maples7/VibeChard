# VibeChard

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

> **为 AI 编程代理设计的 Apple 平台并行 worktree 隔离工具。**
> 在同一个 Xcode 项目里同时跑多个 Claude / Codex / Copilot / Cursor 会话，
> 不再触发 `build.db` 锁、`DerivedData` 抖动或者模拟器互相冲突。

```sh
brew install maples7/tap/vch
```

随后在任意 Apple 项目里：

```sh
vch new add-paywall          # 创建隔离的 worktree + agent 分支
vch add-paywall              # 进入该 worktree 的 shell（隔离已生效）
                             # → 直接像平时一样用 xcodebuild / swift test
vch test add-paywall --device "iPhone 16"
vch remove add-paywall
```

就这些。每个 agent 拿到自己专属的 worktree、专属的 `DerivedData`、
专属的模拟器克隆——你的 `~/Library/Developer/` 一字节都不会被动。

> **状态：alpha (v0.1.0)。** CLI 接口已基本稳定但尚未冻结；
> `.vch/state.json` 的 schema 之后还可能加字段。需要稳定的话请固定 tag。

## 为什么单独做一个 CLI？

通用的 git-worktree 管理器（Rift、Emdash、Taskpods、Workie 之类）只解决
「源码树隔离」一件事。但 Apple 的工具链里**至少还有 7 个**别的共享资源
——并行跑 `xcodebuild` 时它们会互相踩，导致非确定性失败：

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
任何能跑 shell 的东西都行。VibeChard *不是* AI 厂商的封装。无遥测、
无网络请求、无 SDK 绑定。

## 安装

### Homebrew（推荐）

```sh
brew install maples7/tap/vch
```

formula 会安装：

- `vch` 到 Homebrew 的 `bin/`（在 `PATH` 上）
- `vch-xcodebuild-shim` 到 `libexec/`（**故意不**放在 `PATH` 上——
  它只应该被 `vch exec` 在每个任务的 `.vch/bin/` 里建的符号链接调到）
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

## 命令一览

| 命令 | 作用 |
|---|---|
| `vch new <name>` | 在 `../<repo>-<name>` 创建 worktree，分支为 `agent/<name>`。`--exec "<cmd>"` 在 worktree 内直接跑命令（比如 AI agent）。`--copy-untracked` 会连同未跟踪、未被忽略的文件（如 `.env`、`.vscode/settings.json`）一起拷过来。 |
| `vch list` | 列出当前工作区下所有任务。`--json` 输出机器可读格式；`-v`/`--verbose` 增加 `BASE` 与 `PATH` 列。 |
| `vch path <name>` | 打印任务 worktree 的绝对路径。 |
| `vch state <name>` | 漂亮打印任务的 `.vch/state.json`。`--json` 输出原始文件内容。 |
| `vch open [<name>] [--with <ide>]` | 在 IDE 中打开 worktree。自动识别 `*.xcworkspace` / `*.xcodeproj` / `Package.swift`（项目文件用 Xcode，否则用 VS Code）。`--with` 支持 `xcode`、`code`/`vscode`、`cursor`，或任意 app 名（透传给 `open -a`）。可用 `VCH_OPEN_DEFAULT` 覆盖默认值。不传 `<name>` 时使用 `$PWD` 所在的 worktree。 |
| `vch <name>` | `vch exec <name> -- $SHELL` 的语法糖——开一个 shell，隔离环境变量 + `.vch/bin` PATH shim 已就绪。 |
| `vch exec <name> -- <cmd...>` | 在任务 worktree 内跑任意命令，隔离已生效。 |
| `vch build <name> [flags] [-- xcodebuild-extras]` | 对任务的 worktree 跑 `xcodebuild build`，自动注入 `-derivedDataPath` / `-clonedSourcePackagesDirPath`。 |
| `vch test  <name> [flags] [-- xcodebuild-extras]` | 跑 `xcodebuild test`，注入 `-resultBundlePath`；首次 `--device` 时懒克隆模拟器，后续复用。 |
| `vch sim {clone,erase,shutdown,info} <name>` | 显式管理任务的模拟器克隆。 |
| `vch remove <name> [--force [--force]] [--keep-sim]` | 删除 worktree、分支以及（默认会删的）模拟器克隆。两次 `--force` 才允许脏树 + 未合并分支。 |
| `vch repair` | 用 `git worktree list` 的实际状态重新对齐 `.vch/state.json`。 |
| `vch doctor [--clean] [--json]` | 检测孤儿模拟器克隆、失效绑定、损坏的 `state.json`。有发现就退出非零。 |
| `vch shellenv` | 输出 `vch_cd` / `vch_new` / `vch_clean` shell 助手函数（bash/zsh）。 |
| `vch completions install [--shell <s>]` | 安装 `zsh` / `bash` / `fish` 的补全脚本（默认从 `$SHELL` 自动识别）。`--print` 预览；`--force` 覆盖已有文件。 |
| `vch version` | 打印版本与工具链信息（`--json` 为机器可读格式）。 |

所有接受 `<name>` 的命令都会从当前工作区拿任务名做补全——
装好补全脚本，按 `<TAB>` 即可。

## 隔离的工作机制

任务 worktree 内的 `<wt>/.vch/bin/` 会被前置到 `PATH` 上，里面有
三个符号链接 `xcodebuild`、`xcrun`、`swift` 都指向 `vch-xcodebuild-shim`。

shim 读三个环境变量（`VCH_DERIVED_DATA_PATH`、`VCH_SPM_CLONE_DIR`、
`VCH_RESULT_BUNDLE_PATH`），如果用户没显式传对应 flag 就把它们注入到
`xcodebuild` 的 argv 里，`mkdir -p` 创建目标目录，然后通过
`/usr/bin/xcrun -f xcodebuild` 解出真实的 `xcodebuild` 路径并 `execv`
（绕开 `PATH`，避免递归调用自己）。对 `xcrun` 和 `swift` 是透明转发。

效果：任何 agent 可能跑的工具——`xcodebuild`、`swift test`、Tuist、
内部又会调到 `xcodebuild` 的脚本——都自动被隔离。无需手动传 flag。

`vch build` 和 `vch test` 跳过 PATH shim，直接调用 `xcodebuild`
传相同的 flag——因为它们在调用点就知道所有参数。

## 配置

无。所有任务级状态都在 `<worktree>/.vch/state.json` 里。
没有 `~/.vchrc`、没有 `.vch.toml`、没有任何全局配置文件。
唯一的运行时旋钮是上面提到的那几个 `VCH_*` 环境变量
（一般由 `vch exec` 自己设置，你很少需要手动配）。

## VibeChard 不是什么

- **不是 AI 厂商封装。** 没有 SDK、没有 API key、没有模型抽象。
  用任何 agent 都行——VibeChard 只负责让并行会话安全。
- **不跨平台。** 只服务 Apple，是设计选择。整个项目的价值就在
  Xcode 工具链上的深度，不在广度。
- **不是 CI 编排器。** 它跑在你本地终端、对你磁盘上的 worktree 起作用。
  CI 矩阵是另一类问题。

## 从源码构建与测试

```sh
swift build -c release
./.build/release/vch version
swift test --parallel             # 116 个测试，M 系芯片上约 9 秒
```

CI 在每次 push 上跑相同的命令，外加一个 shim 的烟雾测试：
[.github/workflows/ci.yml](.github/workflows/ci.yml)。

## 许可证

[Apache-2.0](LICENSE)。无 CLA，无遥测，无网络请求。
