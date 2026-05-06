# VibeChard

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **日本語** · [한국어](README.ko.md)

> **AI コーディングエージェント向け、Apple 開発のためのタスク単位で隔離された worktree。**
> 同じ Xcode プロジェクトに対して Claude / Codex / Copilot / Cursor を複数同時に走らせても、
> `build.db` のロック、`DerivedData` の取り合い、シミュレーターの衝突が起きません。

```sh
brew install maples7/tap/vch
```

あとはどの Apple プロジェクトでも：

```sh
vch new add-paywall          # 隔離された worktree + agent ブランチを作成
vch add-paywall              # その worktree のシェルに入る（隔離が有効な状態）
                             # → いつもどおり xcodebuild / swift test を実行
vch test add-paywall --device "iPhone 16"
vch remove add-paywall
```

それだけです。各エージェントは専用の worktree、専用の `DerivedData`、
専用のシミュレータークローンを持ちます——あなたの `~/Library/Developer/`
は 1 バイトも変更されません。

> **ステータス: alpha (v0.1.0)。** CLI のインターフェースはほぼ落ち着いていますが
> まだ凍結されていません。`.vch/state.json` のスキーマには今後フィールドが
> 追加される可能性があります。安定が必要ならタグを固定してください。

## なぜ専用の CLI が必要なのか

汎用の git-worktree マネージャ（Rift、Emdash、Taskpods、Workie など）が
解決するのは「ソースツリーの隔離」だけです。しかし Apple のツールチェインには
**他にも少なくとも 7 つ**の共有リソースがあり、`xcodebuild` を並列に走らせると
互いに衝突して非決定的な失敗を引き起こします：

| リソース | 隔離しないとどうなるか | VibeChard の対応 |
|---|---|---|
| `DerivedData` | モジュール再ビルドの繰り返し、キャッシュ汚染 | `-derivedDataPath <wt>/.agent-build/DerivedData` |
| `ModuleCache.noindex` | 並行下で Clang モジュールキャッシュが破損 | worktree ごとに `CLANG_MODULE_CACHE_PATH` |
| SwiftPM グローバルキャッシュ | `Package.resolved` の書き込み競合 | worktree ごとに `-clonedSourcePackagesDirPath` |
| `xcresult` バンドル | 後勝ちで上書き | worktree ごとに `-resultBundlePath` |
| シミュレーターデバイス | 同じ iPhone 16 に 2 タスクが同時インストール | タスクごとに `xcrun simctl clone` |
| エージェントが PATH から `xcodebuild` を引く | 注入したフラグを素通り | **PATH シム**で自動的にフラグを注入 |
| ソースツリー | 標準的な対処 | `git worktree` + `agent/<name>` ブランチ |

**BYO Agent (Bring Your Own Agent)** です——Claude、Codex、Copilot、Cursor、
シェルが叩けるものなら何でも。VibeChard は AI ベンダーのラッパーでは
*ありません*。テレメトリなし、ネットワーク通信なし、SDK 依存なし。

## インストール

### Homebrew（推奨）

```sh
brew install maples7/tap/vch
```

formula は以下をインストールします：

- `vch` を Homebrew の `bin/` に（`PATH` に載る）
- `vch-xcodebuild-shim` を `libexec/` に（**意図的に** `PATH` には載せない
  ——タスクごとの `.vch/bin/` に `vch exec` が張るシンボリックリンク経由でのみ
  到達されるべきものです）
- Bash、Zsh、Fish の補完スクリプト

### ソースからビルド

要件: macOS 13+、Xcode 15.3+（Swift 5.10+）。

```sh
git clone https://github.com/maples7/VibeChard.git
cd VibeChard
swift build -c release
ln -s "$PWD/.build/release/vch" /usr/local/bin/vch    # CLI を置いている場所に合わせて
```

## クイックスタート

git 管理下の任意の Apple プロジェクト内で：

```sh
# 1. agent/add-paywall 上に隔離された worktree を起こす
vch new add-paywall

# 2. その中のシェルに入る（PATH シムが有効）
vch add-paywall
# このシェル内で：
#   xcodebuild build              ← -derivedDataPath が自動注入される
#   swift test                    ← モジュールキャッシュと SwiftPM の clone 先が隔離済み
#   exit                          ← 元のシェルに戻る

# 3. シェルに入らず直接 xcodebuild を呼ぶことも可能：
vch build add-paywall --scheme MyApp
vch test  add-paywall --scheme MyApp --device "iPhone 16"

# 4. worktree 内で直接エージェントを走らせる：
vch new fix-toast --exec "claude"     # 隔離された worktree 内で claude を起動
vch exec fix-toast -- npm run lint    # worktree 内でワンショット実行

# 5. 確認とクリーンアップ
vch list
vch path add-paywall                  # worktree の絶対パス
vch remove add-paywall                # worktree + ブランチ + シミュレータークローンを削除
```

## コマンド一覧

| コマンド | 役割 |
|---|---|
| `vch new <name>` | `../<repo>-<name>` に worktree を作成、ブランチは `agent/<name>`。`--exec "<cmd>"` で worktree 内で直接コマンド実行（例: AI エージェント）。 |
| `vch list` | 現在のワークスペース下のすべてのタスクを一覧。`--json` で機械可読出力。 |
| `vch path <name>` | タスク worktree の絶対パスを出力。 |
| `vch open [<name>] [--with <ide>]` | worktree を IDE で開く。`*.xcworkspace` / `*.xcodeproj` / `Package.swift` を自動検出（プロジェクトファイルは Xcode、それ以外は VS Code）。`--with` は `xcode`、`code`/`vscode`、`cursor`、または任意のアプリ名（`open -a` に渡す）に対応。`VCH_OPEN_DEFAULT` でデフォルトを上書き可能。`<name>` 省略時は `$PWD` のある worktree を使う。 |
| `vch <name>` | `vch exec <name> -- $SHELL` のシュガー。隔離環境変数 + `.vch/bin` PATH シムが有効なシェルが立ち上がる。 |
| `vch exec <name> -- <cmd...>` | タスク worktree 内で任意のコマンドを実行（隔離有効）。 |
| `vch build <name> [flags] [-- xcodebuild-extras]` | タスクの worktree に対して `xcodebuild build` を実行。`-derivedDataPath` / `-clonedSourcePackagesDirPath` を自動注入。 |
| `vch test  <name> [flags] [-- xcodebuild-extras]` | `xcodebuild test` を実行し `-resultBundlePath` を注入。初回 `--device` 時にシミュレーターを遅延クローンし以降は再利用。 |
| `vch sim {clone,erase,shutdown,info} <name>` | タスクのシミュレータークローンを明示的に管理。 |
| `vch remove <name> [--force [--force]] [--keep-sim]` | worktree、ブランチ、（デフォルトで）シミュレータークローンを削除。`--force` 2 回でダーティツリー＋未マージブランチも許容。 |
| `vch repair` | `git worktree list` の実状態に合わせて `.vch/state.json` を再同期。 |
| `vch doctor [--clean] [--json]` | 孤児シミュレータークローン、古いステートバインディング、破損 `state.json` を検出。検出時は非ゼロ終了。 |
| `vch shellenv` | `vch_cd` / `vch_clean` のシェルヘルパーを出力（bash/zsh）。 |
| `vch version` | バージョンとツールチェイン情報を出力（`--json` で機械可読）。 |

`<name>` を取るすべてのコマンドはワークスペース内のタスクから補完されます——
補完スクリプトを入れて `<TAB>` を押してください。

## 隔離の仕組み

タスクの worktree 内では `<wt>/.vch/bin/` が `PATH` の先頭に挿入され、
そこに `xcodebuild`、`xcrun`、`swift` のシンボリックリンクがあり、すべて
`vch-xcodebuild-shim` を指しています。

シムは 3 つの環境変数（`VCH_DERIVED_DATA_PATH`、`VCH_SPM_CLONE_DIR`、
`VCH_RESULT_BUNDLE_PATH`）を読み、ユーザーが明示的に渡していない場合は
対応するフラグを `xcodebuild` の argv に注入し、ターゲットディレクトリを
`mkdir -p` で作成、その後 `/usr/bin/xcrun -f xcodebuild` で本物の
`xcodebuild` のパスを解決して `execv`（`PATH` を経由しないので自分自身を
再帰呼び出しすることはありません）。`xcrun` と `swift` に対しては透過的に
パススルーします。

結果：エージェントが起動しうるあらゆるツール——`xcodebuild`、`swift test`、
Tuist、内部で `xcodebuild` を呼び出すスクリプト——が自動的に隔離されます。
フラグを手で渡す必要はありません。

`vch build` と `vch test` は PATH シムをスキップして直接 `xcodebuild` を
同じフラグで呼び出します。呼び出し地点で引数がすべて分かっているためです。

## 設定

ありません。タスクごとの状態はすべて `<worktree>/.vch/state.json` に
収まります。`~/.vchrc` も `.vch.toml` もグローバル設定ファイルもありません。
唯一の実行時ノブは上記の `VCH_*` 環境変数です（通常は `vch exec` が
自分でセットするので、手動で触る必要はほとんどありません）。

## VibeChard ではないもの

- **AI ベンダーのラッパーではありません。** SDK も API キーもモデル抽象も
  ありません。好きなエージェントを使ってください——VibeChard は並列セッションを
  安全にすることだけを担当します。
- **クロスプラットフォームではありません。** 設計上 Apple 専用です。
  プロジェクトの価値は Xcode ツールチェインへの深さにあり、広さにはありません。
- **CI オーケストレータではありません。** ローカルのターミナルで、ディスク上の
  worktree に対して動作します。CI マトリクスは別の問題です。

## ソースからビルド・テスト

```sh
swift build -c release
./.build/release/vch version
swift test --parallel             # 116 テスト、M シリーズで約 9 秒
```

CI は push のたびに同じコマンド + シムのスモークテストを実行します：
[.github/workflows/ci.yml](.github/workflows/ci.yml)。

## ライセンス

[Apache-2.0](LICENSE)。CLA なし、テレメトリなし、ネットワーク通信なし。
