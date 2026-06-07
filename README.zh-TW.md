# VibeChard

[![Release](https://img.shields.io/github/v/release/Maples7/VibeChard?label=release&color=blue)](https://github.com/Maples7/VibeChard/releases) [![CI](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/Maples7/VibeChard?color=green)](LICENSE) [![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FMaples7%2FVibeChard%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Maples7/VibeChard) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FMaples7%2FVibeChard%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Maples7/VibeChard)

[English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

<p align="center">
  <a href="docs/images/hero.zh-TW.png"><img src="docs/images/hero.zh-TW.png" alt="不用 vch：3 個並行的 xcodebuild 互搶 build.db / 模組快取 / 模擬器。用上 vch：每個 agent 都在自己的 worktree 裡，獨立 DerivedData + 獨立模擬器副本" width="960"></a>
</p>

> **為 AI 編程代理設計的 Apple 平台並行 worktree 隔離工具。**
> 在同一個 Xcode 專案裡同時跑多個 Claude / Codex / Copilot / Cursor 工作階段，
> 不再觸發 `build.db` 鎖、`DerivedData` 抖動或者模擬器互相衝突。

```sh
brew install maples7/tap/vch
```

<p align="center">
  <img src="docs/images/demo.gif" alt="vch new → vch list → vch state → vch exec → vch remove，全部隔離，25 秒內走完" width="720">
</p>

接著在任何 Apple 專案裡：

```sh
vch new add-paywall          # 建立隔離的 worktree + agent 分支
vch add-paywall              # 進入該 worktree 的 shell（隔離已生效）
                             # → 直接像平常一樣用 xcodebuild / swift test
vch test add-paywall --device "iPhone 16"
vch remove add-paywall
```

就這樣。每個 agent 都拿到自己專屬的 worktree、專屬的 `DerivedData`、專屬的模擬器副本——你的 `~/Library/Developer/` 一個位元組都不會被動。

<p align="center">
  <img src="docs/images/vch-list.zh-TW.png" alt="vch list 輸出：3 個 agent 任務並行，2 個 ok 1 個 fail，以及 vch state 詳情" width="720">
</p>

> **狀態：穩定（1.0）。** CLI 介面與磁碟上的 `.vch/state.json` schema（v1）
> 已凍結；變更遵循[語意化版本](https://semver.org/)——破壞性變更要等到 2.0。

## 為什麼要單獨做一個 CLI？

通用的 git-worktree 管理器（Rift、Emdash、Taskpods、Workie 之類）只解決「原始碼樹隔離」一件事。但 Apple 的工具鏈裡**至少還有 7 個**別的共享資源——並行跑 `xcodebuild` 時它們會互相干擾，導致非確定性失敗：

| 資源 | 不隔離時會怎樣 | VibeChard 的做法 |
|---|---|---|
| `DerivedData` | 模組反覆重建、快取被汙染 | `-derivedDataPath <wt>/.agent-build/DerivedData` |
| `ModuleCache.noindex` | 並行下 Clang 模組快取損毀 | 每個 worktree 一個 `CLANG_MODULE_CACHE_PATH` |
| SwiftPM 全域快取 | `Package.resolved` 寫入衝突 | 每個 worktree 一個 `-clonedSourcePackagesDirPath` |
| `xcresult` 報告包 | 後寫者覆蓋前寫者 | 每個 worktree 一個 `-resultBundlePath` |
| 模擬器裝置 | 兩個任務同時往同一台 iPhone 16 安裝 | 每個任務一個 `xcrun simctl clone` |
| Agent 走 PATH 找 `xcodebuild` | 直接繞過我們注入的 flag | **PATH shim** 自動注入 flag |
| 原始碼樹 | 標準做法 | `git worktree` + `agent/<name>` 分支 |

工具是 **BYO Agent（自帶代理）**——Claude、Codex、Copilot、Cursor，
任何能跑 shell 的東西都行。VibeChard *不是* AI 廠商的封裝。沒有遙測、沒有網路請求、沒有 SDK 綁定。
<details>
<summary><strong>「直接用 <code>git worktree</code> + 寫個 5 行 shell function 不就好了？」</strong></summary>

<br/>

合理的懷疑——我一開始也是這麼做的。原始碼樹確實被隔離了，但 agent
在 worktree 裡跑的每一次 `xcodebuild` 仍然解析到這些**全域**位置：

- `~/Library/Developer/Xcode/DerivedData/MyApp-<hash>/`（全域預設）
- `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex/`（全域）
- `~/Library/Caches/org.swift.swiftpm/`（全域）
- `~/Library/Developer/CoreSimulator/Devices/<UDID>/`（全域）

只要任何一個被共用，並發下的 `xcodebuild` 就是 racy。能解決的方式只有兩條：

1. **每次都手動傳對 flag。** 每個 `xcodebuild`、每個 `swift test`
   都記得加上 `-derivedDataPath` / `-clonedSourcePackagesDirPath` /
   `-resultBundlePath`；然後還要教 Tuist、Fastlane、所有自訂測試腳本、任何會 shell out 的 `Package.swift` plugin 都這麼做；然後還要叮寧你的 *AI agent* 別忘——它一定會忘。
2. **在 `xcodebuild` 前面塞一個 PATH shim**，保證不管誰、用什麼方式叫它，那些 flag 一定都在。

VibeChard 選的是 (2)。這就是為什麼它是 CLI，而不是一段 `.zshrc`
片段。

</details>
## 安裝

### Homebrew（推薦）

```sh
brew install maples7/tap/vch
```

formula 會安裝：

- `vch` 到 Homebrew 的 `bin/`（在 `PATH` 上）
- `vch-xcodebuild-shim` 到 `libexec/`（**故意不**放在 `PATH` 上——它只應該被 `vch exec` 在每個任務的 `.vch/bin/` 裡建立的符號連結呼叫到）
- Bash、Zsh、Fish 的命令補全指令稿

### 從原始碼建置

建置環境：macOS 13+，搭配 Xcode 15.3+（Swift 5.10+）。建置產物 `vch`
二進位執行於 macOS 13+。

```sh
git clone https://github.com/maples7/VibeChard.git
cd VibeChard
swift build -c release
ln -s "$PWD/.build/release/vch" /usr/local/bin/vch    # 或者你存放 CLI 的任意位置
```

### Apple 平台支援

隔離機制——worktree、PATH shim、`DerivedData` / `ModuleCache` / SwiftPM /
`xcresult` 重新導向——與平台無關，對任何 `xcodebuild` 呼叫都生效。模擬器
複製與預熱範本已針對 **iOS、watchOS、tvOS、visionOS** 參數化。日常驗證集中
在 **iOS**，它是 `vch run`（安裝 + 啟動）最常走的路徑；另外三個平台走的是
相同程式碼路徑，但真機 dogfooding 較少。macOS（真機目標）專案的建置與測試
同樣正常——只是不使用模擬器複製。

## 快速上手

在任何 git 控管下的 Apple 專案內：

```sh
# 1. 建立隔離的 worktree，分支為 agent/add-paywall
vch new add-paywall

# 2. 進到那個 worktree 的 shell（PATH shim 已啟用）
vch add-paywall
# 在這個 shell 裡：
#   xcodebuild build              ← 自動注入 -derivedDataPath
#   swift test                    ← 模組快取 + SwiftPM 複製目錄已隔離
#   exit                          ← 回到原本的 shell

# 3. 也可以不進 shell，直接呼叫 xcodebuild：
vch build add-paywall --scheme MyApp
vch test  add-paywall --scheme MyApp --device "iPhone 16"

# 4. 在 worktree 裡直接驅動 agent：
vch new fix-toast --exec "claude"     # 在隔離的 worktree 裡啟動 claude
vch new triage --copy-untracked       # 順便將 .env / .vscode 等未追蹤檔案一起帶過來
vch new --adopt-current               # 接管目前 linked worktree，並使用它的目錄名
vch exec fix-toast -- npm run lint    # 在 worktree 裡跑一次性指令

# 5. 檢視與清理
vch list
vch path add-paywall                  # worktree 的絕對路徑
vch remove add-paywall                # 刪除 worktree + 分支 + 模擬器副本
```

### Agent runbook

如果是 AI agent 在驅動任務，把它指向與目前版本相符的 runbook：

```sh
vch runbook
```

在 `vch <name>` / `vch exec` 裡，子行程還會拿到
`VCH_AGENT_RUNBOOK_URL`，指向同一個按 tag 固定的連結。原始碼副本在
**[docs/agent-runbook.md](docs/agent-runbook.md)**。

## 工作流：一連串任務

vch 的最佳使用姿態不是單一任務，而是**連續短任務**（或平行任務）：
每個任務都跑在自己的 worktree 裡，落地完再起下一個。一個典型循環：

```sh
# 規劃：A → B → C，每個任務都先合入再起下一個。

# 任務 A —— 實作、測試、Review。
vch new task-a
cd "$(vch path task-a)"
# ...編輯...
vch build task-a --scheme MyApp
vch test  task-a --scheme MyApp --device "iPhone 16"
git commit -am "perf: task A"
vch open task-a                       # 在 IDE 裡 review

# 評審通過後，從主 worktree 合併：
cd /path/to/main-worktree
git merge --no-ff agent/task-a -m "Merge agent/task-a: <subject>"
vch remove task-a                     # worktree + 分支 + 模擬器副本一起刪乾淨

# 任務 B 從乾淨的 develop 重新開始，循環不變。
vch new task-b
# ...
```

每次 `vch new` 都拿到獨立的 SwiftPM 解析快取、DerivedData 與模組
快取（都在 `.vch/` 裡），所以兩個平行任務永遠不會因 SPM 鎖競爭或
Xcode 建置快取失效互相阻塞。從不同 shell 同時跑幾個 `vch test` 也
不會撞 Core Data 資料庫或抶同一個模擬器。

如果你要把 build/test 迴圈寫進腳本，請優先使用 `vch build` /
`vch test`，而不是裸跑 `vch exec ... xcodebuild ...`；高階命令會
保留簡潔摘要、日誌和 result bundle 路徑：

```sh
vch test task-a --scheme MyApp --device 'iPhone 16' \
  --only-testing MyAppTests/Foo
```

如果確實需要呼叫底層工具，請優先使用穩定的
`vch state <name> --field <dotted>` 介面，不要直接讀
`.vch/state.json`。

## Cookbook

不屬於內建指令，但經常被問到的一些用法 —— 比如基於一個 WIP 中的任務再開
分支、只跑一部分測試、給長跑任務做基線同步、`vch land` 時保留生成的產物、
warm 模擬器模板的快速路徑、重置每任務的模擬器狀態、模板被 Booted 卡住時
的處理、清理已合併任務等等。

→ 完整內容見 **[docs/cookbook.md](docs/cookbook.md)**（英文單一來源，
詳見 [AGENTS.md 規則 #10](AGENTS.md)）。

## 指令一覽

| 指令 | 作用 |
|---|---|
| `vch new [<name>]` | 建立 worktree + `agent/<name>` 分支，或接管目前 linked worktree（搭配 `--adopt-current` 時可省略 `<name>`；`--exec "<cmd>"`、`--copy-untracked`、`--seed-spm-from <task>`、`--cd`）。 |
| `vch list` | 列出工作區下所有任務（`--json`、`-v`、`--git-status`）。 |
| `vch state <name>` | 印出任務的 `.vch/state.json`（`--json`、`--field <dotted>`）。 |
| `vch path <name>` | 印出任務 worktree 的絕對路徑。 |
| `vch open [<name>]` | 在 IDE 中開啟 worktree（`--with xcode`/`code`/`cursor`/…）。 |
| `vch <name>` | 進入 worktree shell，隔離環境與 PATH shim 已就緒。 |
| `vch exec <name> -- <cmd...>` | 在任務 worktree 內跑任意指令，隔離已生效。 |
| `vch build [<name>]` | 跑 `xcodebuild build`，自動注入 `-derivedDataPath` / `-clonedSourcePackagesDirPath`；在任務 worktree 內可省略 `<name>`（`--scheme`、`--project`、`--workspace`、`--runtime`、`--erase-clone`、`--shutdown-template`、`--existing-sim`、`--verbose`）。 |
| `vch test [<name>]` | 跑 `xcodebuild test`，注入 `-resultBundlePath`；在任務 worktree 內可省略 `<name>`，懶克隆模擬器（`--device`、`--project`、`--workspace`、`--runtime`、`--only-testing`、`--skip-testing`、`--rerun`、`--rerun-failed`、`--erase-clone`、`--shutdown-template`、`--test-execution-idle-timeout`）。 |
| `vch run [<name>]` | 在任務的模擬器克隆上建置、安裝並啟動 App；在任務 worktree 內可省略 `<name>`（`--project`、`--workspace`、`--erase-clone`、`--shutdown-template`、`--existing-sim`、`-- launch-args`）。 |
| `vch logs <name>` | 印出任務最近一次建置/測試的完整 xcodebuild 紀錄（`--test`/`--build`）。 |
| `vch sim {clone,erase,shutdown,info} <name>` | 明確管理任務的模擬器克隆；透過重複執行 `vch sim clone --device <name>`，一個任務可以同時持有多個克隆（每個平台一個，例如 iOS + watchOS）（[#99](https://github.com/Maples7/VibeChard/issues/99)）。 |
| `vch sim warm-template {create,list,remove}` | 管理共享的 *warm* 模擬器模板（iOS / watchOS / tvOS / visionOS，[#47](https://github.com/Maples7/VibeChard/issues/47) / [#58](https://github.com/Maples7/VibeChard/issues/58)）。 |
| `vch land <name>` | 把 `agent/<name>` 合併回 base 並清理（`--into`、`--no-ff`/`--ff-only`/`--squash`、`--keep`、`--push`/`--push-to`、`--dry-run`）。 |
| `vch sync <name>` | 拉取 base 的 upstream 並把任務分支 rebase 上去（`--onto`、`--merge`、`--no-fetch`、`--dry-run`）。 |
| `vch remove <name>` | 刪除 vch 建立的 worktree、分支與模擬器克隆；接管的任務只註銷 vch 狀態（`--allow-dirty`、`--force`、`--allow-unmerged`、`--keep-sim`）。 |
| `vch prune` | 列出或刪除已完全合併進 base 的任務（`--rm`、`--allow-dirty`、`--force`、`--keep-sim`、`--json`）。 |
| `vch repair` | 用 `git worktree list` 的實際狀態重新對齊 `.vch/state.json`。 |
| `vch clean <name>` | 刪除任務的 DerivedData / ModuleCache（`--swiftpm`、`--logs`、`--all`、`--dry-run`、`--kill-stuck-tests`）。 |
| `vch doctor` | 檢測孤兒模擬器克隆、失效綁定、損壞的 `state.json`（`--clean`、`--bug-report`、`--json`）。 |
| `vch shellenv` | 輸出 `vch_cd` / `vch_new` / `vch_clean` shell 輔助函式（bash/zsh）。 |
| `vch completions install` | 安裝 shell 補全腳本（`--shell`、`--print`、`--force`）。 |
| `vch runbook` | 印出按版本固定的 Agent runbook URL 與 Homebrew 安裝文件路徑提示（`--json`）。 |
| `vch version` | 印出版本與工具鏈資訊（`--json` 為機器可讀格式）。 |

所有接受 `<name>` 的指令都會從目前工作區拿任務名做補全——裝好補全腳本按
 `<TAB>` 即可。完整 flag 參考見
**[docs/commands.md](docs/commands.md)**。

## 隔離的運作方式

<p align="center">
  <img src="docs/images/architecture.zh-TW.png" alt="架構圖：agent → 主倉 → worktree → PATH shim → 獨立 DerivedData + Sim 副本" width="720">
</p>

任務 worktree 內的 `<wt>/.vch/bin/` 會被前置到 `PATH` 上，裡面有三個符號連結 `xcodebuild`、`xcrun`、`swift` 都指向 `vch-xcodebuild-shim`。

shim 讀取三個環境變數（`VCH_DERIVED_DATA_PATH`、`VCH_SPM_CLONE_DIR`、
`VCH_RESULT_BUNDLE_PATH`），如果使用者沒明確傳對應 flag 就將它們注入到
`xcodebuild` 的 argv 裡，`mkdir -p` 建立目標目錄，然後透過
`/usr/bin/xcrun -f xcodebuild` 解析出真正的 `xcodebuild` 路徑並 `execv`
（繞過 `PATH`，避免遞迴呼叫自己）。對 `xcrun` 與 `swift` 則是透明轉發。

效果：任何 agent 可能執行的工具——`xcodebuild`、`swift test`、Tuist、內部又會呼叫 `xcodebuild` 的指令稿——都會自動被隔離。無需手動傳 flag。

`vch build`、`vch test` 與 `vch run` 跳過 PATH shim，直接呼叫 `xcodebuild`
傳遞相同的 flag——因為它們在呼叫點就知道所有參數。

### `vch exec` / `vch <name>` 為子行程注入了什麼

`vch <name>`（= `vch exec <name> -- $SHELL`）和 `vch exec <name> --
<cmd>` 都會在你既有的環境之上疊一層確定性的 env，跟 `vch build` /
`vch test` / `vch run` 用的是同一套——所以你在 `vch <name>` 裡手敲
`xcodebuild` 的行為與 `vch build` 完全一致。基本上不再需要另一個
「把我丟進任務環境」的指令，`vch <name>` 已經是了：

| 變數 | 設成 |
|---|---|
| `VCH_TASK_NAME` | 任務名稱（如 `add-paywall`），常用於 PS1 / 終端標題。 |
| `VCH_TASK_ROOT` | worktree 絕對路徑。 |
| `VCH_AGENT_RUNBOOK_URL` | 目前 `vch` 二進位對應的按版本固定 Agent runbook URL。 |
| `VCH_DERIVED_DATA_PATH` | `<wt>/.agent-build/DerivedData`（shim 讀取）。 |
| `VCH_SPM_CLONE_DIR` | `<wt>/.agent-build/SourcePackages`（shim 讀取）。 |
| `VCH_RESULT_BUNDLE_PATH` | `<wt>/.agent-build/Result.xcresult`（shim 讀取）。 |
| `VCH_RESULT_BUNDLE_DIR` | result bundle 的父目錄。 |
| `CLANG_MODULE_CACHE_PATH` | `<wt>/.agent-build/ModuleCache`（clang 讀取）。 |
| `SWIFTPM_CACHE_DIR` | `<wt>/.agent-build/SourcePackages`（SwiftPM 讀取）。 |
| `DEVELOPER_DIR` | 宿主選定的 Xcode（`xcode-select -p`）—— 僅當使用者尚未設定時注入。 |
| `SIMCTL_CHILD_SIMULATOR_UDID` | 任務綁定的模擬器副本 —— 僅當已綁定時設定。 |
| `PATH` | 在最前面附加 `<wt>/.vch/bin`，讓 `xcodebuild` / `xcrun` / `swift` 走 shim。 |

`vch` 不會覆寫你已 export 的值——在 `vch exec` 之前手動 `export`
任意一個，你的值優先。

## 設定

無。所有任務級狀態都在 `<worktree>/.vch/state.json` 裡。沒有 `~/.vchrc`、沒有 `.vch.toml`、沒有任何全域設定檔。唯一的執行期旋鈕是上面提到的那幾個 `VCH_*` 環境變數
（一般由 `vch exec` 自己設定，你很少需要手動配置）。`vch build`/`vch test`/`vch run` 也會把宿主選定的 `DEVELOPER_DIR`（透過 `xcode-select -p` 解出）傳給子行程——手動設定該環境變數即可覆寫。

如果 `vch new` 提示了 `eval "$(vch shellenv)"`，可以用 `VCH_NEW_HINT=0`
關掉這條提示（或者直接安裝好 shell helper）。

## VibeChard 不是什麼

- **不是 AI 廠商封裝。** 沒有 SDK、沒有 API key、沒有模型抽象。用任何 agent 都行——VibeChard 只負責讓並行工作階段安全。
- **不跨平台。** 只服務 Apple，是設計選擇。整個專案的價值就在
  Xcode 工具鏈上的深度，不在廣度。
- **不是 CI 編排器。** 它跑在你本地終端機、對你磁碟上的 worktree 起作用。
  CI 矩陣是另一類問題。

## 常見問題

<details>
<summary><strong>能跟 Tuist / Fastlane / xcbeautify 一起用嗎？</strong></summary>

<br/>

可以。PATH shim 會拦截所有的 `xcodebuild` 呼叫，不管是誰發起的。Tuist
產生的執行、Fastlane 的 `gym` / `scan`、xcbeautify 上游的管道、任何最終貓到 `xcodebuild` 上的自訂腳本——都會被自動注入每任務的
`-derivedDataPath` / `-clonedSourcePackagesDirPath` /
`-resultBundlePath`。你不用自己傳 flag。

</details>

<details>
<summary><strong>CocoaPods / Carthage 呢？</strong></summary>

<br/>

可以。它們的相依拉取步驟不走 `xcodebuild`，本來就不需要隔離；建構步驟最終會貓到 `xcodebuild`，被 shim 攝下來。`Pods/` 和 `Carthage/` 目錄跟原始碼一起待在 worktree 裡，由 `git worktree` 本身隔離。

</details>

<details>
<summary><strong>純 SwiftPM 專案（沒有 <code>.xcodeproj</code>）？</strong></summary>

<br/>

行。`swift build` / `swift test` 預設就把產物寫進每個 worktree 自己的
`.build/`——天然隔離，shim 不用注入 flag。shim 仍然會包住 `swift` 但只做透明 passthrough。

</details>

<details>
<summary><strong><code>vch remove</code> 時未提交的改動會丟嗎？</strong></summary>

<br/>

不會——它會拒絕執行。`vch remove` 在 worktree 騷的時候會帶著明確提示中止。加 `--allow-dirty` 才會強刪（連帶丟掉未提交改動）；加 `--allow-unmerged`（或兩個旗標同時使用）還允許刪除有未合併提交的分支。沒有靜默的破壞路徑。

</details>

<details>
<summary><strong>不用 AI agent 也能用嗎？</strong></summary>

<br/>

能。任何「我想要個並行沙盒」的場景都行：同時試兩套互不相同的實作、跑長測試套件的同時在主 worktree 繼續寫程式，等等。CLI 跟 agent 解耦——所謂 agent 整合只是 `--exec "<your command>"`。

</details>

## 從原始碼建置與測試

```sh
swift build -c release
./.build/release/vch version
swift test --parallel
```

CI 在每次 push 時跑相同的指令，外加一個 shim 的煙霧測試：
[.github/workflows/ci.yml](.github/workflows/ci.yml)。

## 授權

[Apache-2.0](LICENSE)。無 CLA，無遙測，無網路請求。
