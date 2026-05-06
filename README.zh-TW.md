# VibeChard

[![Release](https://img.shields.io/github/v/release/Maples7/VibeChard?label=release&color=blue)](https://github.com/Maples7/VibeChard/releases) [![CI](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/Maples7/VibeChard?color=green)](LICENSE) ![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![Swift](https://img.shields.io/badge/swift-5.10%2B-orange)

[English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

> **為 AI 編程代理設計的 Apple 平台並行 worktree 隔離工具。**
> 在同一個 Xcode 專案裡同時跑多個 Claude / Codex / Copilot / Cursor 工作階段，
> 不再觸發 `build.db` 鎖、`DerivedData` 抖動或者模擬器互相衝突。

```sh
brew install maples7/tap/vch
```

接著在任何 Apple 專案裡：

```sh
vch new add-paywall          # 建立隔離的 worktree + agent 分支
vch add-paywall              # 進入該 worktree 的 shell（隔離已生效）
                             # → 直接像平常一樣用 xcodebuild / swift test
vch test add-paywall --device "iPhone 16"
vch remove add-paywall
```

就這樣。每個 agent 都拿到自己專屬的 worktree、專屬的 `DerivedData`、
專屬的模擬器副本——你的 `~/Library/Developer/` 一個位元組都不會被動。

> **狀態：alpha (v0.1.0)。** CLI 介面已大致穩定但尚未凍結；
> `.vch/state.json` 的 schema 之後還可能新增欄位。需要穩定請固定 tag。

## 為什麼要單獨做一個 CLI？

通用的 git-worktree 管理器（Rift、Emdash、Taskpods、Workie 之類）只解決
「原始碼樹隔離」一件事。但 Apple 的工具鏈裡**至少還有 7 個**別的共享資源
——並行跑 `xcodebuild` 時它們會互相干擾，導致非確定性失敗：

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
任何能跑 shell 的東西都行。VibeChard *不是* AI 廠商的封裝。沒有遙測、
沒有網路請求、沒有 SDK 綁定。

## 安裝

### Homebrew（推薦）

```sh
brew install maples7/tap/vch
```

formula 會安裝：

- `vch` 到 Homebrew 的 `bin/`（在 `PATH` 上）
- `vch-xcodebuild-shim` 到 `libexec/`（**故意不**放在 `PATH` 上——
  它只應該被 `vch exec` 在每個任務的 `.vch/bin/` 裡建立的符號連結呼叫到）
- Bash、Zsh、Fish 的命令補全指令稿

### 從原始碼建置

環境需求：macOS 13+、Xcode 15.3+（Swift 5.10+）。

```sh
git clone https://github.com/maples7/VibeChard.git
cd VibeChard
swift build -c release
ln -s "$PWD/.build/release/vch" /usr/local/bin/vch    # 或者你存放 CLI 的任意位置
```

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
vch exec fix-toast -- npm run lint    # 在 worktree 裡跑一次性指令

# 5. 檢視與清理
vch list
vch path add-paywall                  # worktree 的絕對路徑
vch remove add-paywall                # 刪除 worktree + 分支 + 模擬器副本
```

## 指令一覽

| 指令 | 作用 |
|---|---|
| `vch new <name>` | 在 `../<repo>-<name>` 建立 worktree，分支為 `agent/<name>`。`--exec "<cmd>"` 在 worktree 內直接執行指令（例如 AI agent）。`--copy-untracked` 會連同未追蹤、未被忽略的檔案（如 `.env`、`.vscode/settings.json`）一起複製過來。 |
| `vch list` | 列出目前工作區下所有任務。`--json` 為機器可讀格式；`-v`/`--verbose` 增加 `BASE` 與 `PATH` 欄位。 |
| `vch path <name>` | 印出任務 worktree 的絕對路徑。 |
| `vch state <name>` | 漂亮印出任務的 `.vch/state.json`。`--json` 輸出原始檔案內容。 |
| `vch open [<name>] [--with <ide>]` | 在 IDE 中開啟 worktree。自動偵測 `*.xcworkspace` / `*.xcodeproj` / `Package.swift`（專案檔走 Xcode，其他走 VS Code）。`--with` 支援 `xcode`、`code`/`vscode`、`cursor`，或任意 app 名稱（透傳給 `open -a`）。可用 `VCH_OPEN_DEFAULT` 覆寫預設值。未指定 `<name>` 時使用 `$PWD` 所在的 worktree。 |
| `vch <name>` | `vch exec <name> -- $SHELL` 的語法糖——開一個 shell，隔離環境變數 + `.vch/bin` PATH shim 已就緒。 |
| `vch exec <name> -- <cmd...>` | 在任務 worktree 內執行任意指令，隔離已生效。 |
| `vch build <name> [flags] [-- xcodebuild-extras]` | 對任務的 worktree 執行 `xcodebuild build`，自動注入 `-derivedDataPath` / `-clonedSourcePackagesDirPath`。 |
| `vch test  <name> [flags] [-- xcodebuild-extras]` | 執行 `xcodebuild test`，注入 `-resultBundlePath`；首次 `--device` 時延遲複製模擬器，後續重複使用。 |
| `vch sim {clone,erase,shutdown,info} <name>` | 顯式管理任務的模擬器副本。 |
| `vch remove <name> [--force [--force]] [--keep-sim]` | 刪除 worktree、分支以及（預設會刪的）模擬器副本。兩次 `--force` 才允許髒樹 + 未合併分支。 |
| `vch repair` | 用 `git worktree list` 的實際狀態重新對齊 `.vch/state.json`。 |
| `vch doctor [--clean] [--json]` | 偵測孤兒模擬器副本、失效綁定、毀損的 `state.json`。有發現就以非零退出。 |
| `vch shellenv` | 輸出 `vch_cd` / `vch_new` / `vch_clean` shell 輔助函式（bash/zsh）。 |
| `vch completions install [--shell <s>]` | 安裝 `zsh` / `bash` / `fish` 的補全腳本（預設從 `$SHELL` 自動識別）。`--print` 預覽；`--force` 覆寫已有檔案。 |
| `vch version` | 印出版本與工具鏈資訊（`--json` 為機器可讀格式）。 |

所有接受 `<name>` 的指令都會從目前工作區的任務名做補全——
裝好補全指令稿，按 `<TAB>` 即可。

## 隔離的運作方式

任務 worktree 內的 `<wt>/.vch/bin/` 會被前置到 `PATH` 上，裡面有
三個符號連結 `xcodebuild`、`xcrun`、`swift` 都指向 `vch-xcodebuild-shim`。

shim 讀取三個環境變數（`VCH_DERIVED_DATA_PATH`、`VCH_SPM_CLONE_DIR`、
`VCH_RESULT_BUNDLE_PATH`），如果使用者沒明確傳對應 flag 就將它們注入到
`xcodebuild` 的 argv 裡，`mkdir -p` 建立目標目錄，然後透過
`/usr/bin/xcrun -f xcodebuild` 解析出真正的 `xcodebuild` 路徑並 `execv`
（繞過 `PATH`，避免遞迴呼叫自己）。對 `xcrun` 與 `swift` 則是透明轉發。

效果：任何 agent 可能執行的工具——`xcodebuild`、`swift test`、Tuist、
內部又會呼叫 `xcodebuild` 的指令稿——都會自動被隔離。無需手動傳 flag。

`vch build` 與 `vch test` 跳過 PATH shim，直接呼叫 `xcodebuild`
傳遞相同的 flag——因為它們在呼叫點就知道所有參數。

## 設定

無。所有任務級狀態都在 `<worktree>/.vch/state.json` 裡。
沒有 `~/.vchrc`、沒有 `.vch.toml`、沒有任何全域設定檔。
唯一的執行期旋鈕是上面提到的那幾個 `VCH_*` 環境變數
（一般由 `vch exec` 自己設定，你很少需要手動配置）。

## VibeChard 不是什麼

- **不是 AI 廠商封裝。** 沒有 SDK、沒有 API key、沒有模型抽象。
  用任何 agent 都行——VibeChard 只負責讓並行工作階段安全。
- **不跨平台。** 只服務 Apple，是設計選擇。整個專案的價值就在
  Xcode 工具鏈上的深度，不在廣度。
- **不是 CI 編排器。** 它跑在你本地終端機、對你磁碟上的 worktree 起作用。
  CI 矩陣是另一類問題。

## 從原始碼建置與測試

```sh
swift build -c release
./.build/release/vch version
swift test --parallel             # 116 個測試，M 系列晶片上約 9 秒
```

CI 在每次 push 時跑相同的指令，外加一個 shim 的煙霧測試：
[.github/workflows/ci.yml](.github/workflows/ci.yml)。

## 授權

[Apache-2.0](LICENSE)。無 CLA，無遙測，無網路請求。
