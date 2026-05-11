# VibeChard

[![Release](https://img.shields.io/github/v/release/Maples7/VibeChard?label=release&color=blue)](https://github.com/Maples7/VibeChard/releases) [![CI](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Maples7/VibeChard/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/Maples7/VibeChard?color=green)](LICENSE) ![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![Swift](https://img.shields.io/badge/swift-5.10%2B-orange)

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **日本語** · [한국어](README.ko.md)

<p align="center">
  <a href="docs/images/hero.ja.png"><img src="docs/images/hero.ja.png" alt="vch なし: 並列の xcodebuild 3 つが build.db / モジュールキャッシュ / シミュレータを取り合う。vch あり: 各エージェントが自分専用 worktree、専用 DerivedData + 専用シミュレータクローン" width="960"></a>
</p>

> **AI コーディングエージェント向け、Apple 開発のためのタスク単位で隔離された worktree。**
> 同じ Xcode プロジェクトに対して Claude / Codex / Copilot / Cursor を複数同時に走らせても、
> `build.db` のロック、`DerivedData` の取り合い、シミュレーターの衝突が起きません。

```sh
brew install maples7/tap/vch
```

<p align="center">
  <img src="docs/images/demo.gif" alt="vch new → vch list → vch state → vch exec → vch removeを 25 秒で、すべて隔離状態で" width="720">
</p>

あとはどの Apple プロジェクトでも：

```sh
vch new add-paywall          # 隔離された worktree + agent ブランチを作成
vch add-paywall              # その worktree のシェルに入る（隔離が有効な状態）
                             # → いつもどおり xcodebuild / swift test を実行
vch test add-paywall --device "iPhone 16"
vch remove add-paywall
```

それだけです。各エージェントは専用の worktree、専用の `DerivedData`、専用のシミュレータークローンを持ちます——あなたの `~/Library/Developer/`
は 1 バイトも変更されません。

<p align="center">
  <img src="docs/images/vch-list.ja.png" alt="vch list の出力: 3 つのエージェントタスクを並列実行、ok 2 つ ・ fail 1 つ、そして vch state の詳細" width="720">
</p>

> **ステータス: alpha。** CLI のインターフェースはほぼ落ち着いていますが
> まだ凍結されていません。`.vch/state.json` のスキーマには今後フィールドが
> 追加される可能性があります。安定が必要ならタグを固定してください。

## なぜ専用の CLI が必要なのか

汎用の git-worktree マネージャ（Rift、Emdash、Taskpods、Workie など）が解決するのは「ソースツリーの隔離」だけです。しかし Apple のツールチェインには
**他にも少なくとも 7 つ**の共有リソースがあり、`xcodebuild` を並列に走らせると互いに衝突して非決定的な失敗を引き起こします：

| リソース | 隔離しないとどうなるか | VibeChard の対応 |
|---|---|---|
| `DerivedData` | モジュール再ビルドの繰り返し、キャッシュ汚染 | `-derivedDataPath <wt>/.agent-build/DerivedData` |
| `ModuleCache.noindex` | 並行下で Clang モジュールキャッシュが破損 | worktree ごとに `CLANG_MODULE_CACHE_PATH` |
| SwiftPM グローバルキャッシュ | `Package.resolved` の書き込み競合 | worktree ごとに `-clonedSourcePackagesDirPath` |
| `xcresult` バンドル | 後勝ちで上書き | worktree ごとに `-resultBundlePath` |
| シミュレーターデバイス | 同じ iPhone 16 に 2 タスクが同時インストール | タスクごとに `xcrun simctl clone` |
| エージェントが PATH から `xcodebuild` を引く | 注入したフラグを素通り | **PATH シム**で自動的にフラグを注入 |
| ソースツリー | 標準的な対処 | `git worktree` + `agent/<name>` ブランチ |

**BYO Agent (Bring Your Own Agent)** です——Claude、Codex、Copilot、Cursor、シェルが叩けるものなら何でも。VibeChard は AI ベンダーのラッパーでは*ありません*。テレメトリなし、ネットワーク通信なし、SDK 依存なし。

<details>
<summary><strong>「<code>git worktree</code> と 5 行のシェル関数で十分じゃない？」</strong></summary>

<br/>

もっともな疑問です——最初は私もそうしました。ソースツリーは隠離できますが、エージェントが worktree 内で叩く `xcodebuild` は依然として以下の**グローバル**な場所を参照します：

- `~/Library/Developer/Xcode/DerivedData/MyApp-<hash>/`（グローバル既定値）
- `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex/`（グローバル）
- `~/Library/Caches/org.swift.swiftpm/`（グローバル）
- `~/Library/Developer/CoreSimulator/Devices/<UDID>/`（グローバル）

これらのいずれかが共有されている限り、並列の `xcodebuild` は競合します。解決策は二つ：

1. **毎回正しいフラグを渡す。** すべての `xcodebuild` と `swift test` で
   `-derivedDataPath` / `-clonedSourcePackagesDirPath` / `-resultBundlePath`
   を忘れずに。Tuist、Fastlane、各カスタムテストスクリプト、シェルアウトする `Package.swift` プラグインにも教え込む。そして *AI エージェント*にも忘れないよう念を押す——絶対に忘れます。
2. **`xcodebuild` の前に PATH シムを置く。** 誰がどんな方法で呼んでも、フラグが必ず効く状態にする。

VibeChard は (2) を採っています。これが「`.zshrc` のスニペット」ではなく CLI である唯一の理由です。

</details>

## インストール

### Homebrew（推奨）

```sh
brew install maples7/tap/vch
```

formula は以下をインストールします：

- `vch` を Homebrew の `bin/` に（`PATH` に載る）
- `vch-xcodebuild-shim` を `libexec/` に（**意図的に** `PATH` には載せない——タスクごとの `.vch/bin/` に `vch exec` が張るシンボリックリンク経由でのみ到達されるべきものです）
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
vch new triage --copy-untracked       # .env / .vscode など未追跡ファイルも一緒にコピー
vch exec fix-toast -- npm run lint    # worktree 内でワンショット実行

# 5. 確認とクリーンアップ
vch list
vch path add-paywall                  # worktree の絶対パス
vch remove add-paywall                # worktree + ブランチ + シミュレータークローンを削除
```

## ワークフロー：連続したタスク群

vch が本当に振るうのは、単発タスクではなく**互いに独立した短いタスクを連続**
（または並行）で回すケースです。各タスクはそれぞれの worktree で進め、取り込んで
から次に進みます。代表的なループ：

```sh
# 計画：A → B → C、それぞれをマージしてから次に進む。

# タスク A — 実装、テスト、レビュー。
vch new task-a
cd "$(vch path task-a)"
# ...編集...
vch build task-a --scheme MyApp
vch test  task-a --scheme MyApp --device "iPhone 16"
git commit -am "perf: task A"
vch open task-a                       # IDE でレビュー

# 承認されたらメイン worktree からマージ：
cd /path/to/main-worktree
git merge --no-ff agent/task-a -m "Merge agent/task-a: <subject>"
vch remove task-a                     # worktree + ブランチ + シミクローンをまとめて削除

# タスク B はクリーンな develop から同じサイクルを繰り返す。
vch new task-b
# ...
```

`vch new` のたびに SwiftPM 解決キャッシュ、DerivedData、モジュールキャッシュ
（いずれも `.vch/` 下）が独立で作られるため、並行中の 2 タスクが SPM ロック争いや
Xcode ビルドキャッシュの無効化で互いをブロックすることはありません。別のシェルで
複数の `vch test` を同時に走らせても Core Data ストアの衝突やシミュレーターの
上書きは起きません。

vch をスクリプトから驅動する場合（例：エージェントを回す）は、`.vch/state.json`
を手読みするより安定した `vch state <name> --field <dotted>` を使ってください：

```sh
udid=$(vch state task-a --field simulator.udid)
vch exec task-a -- xcodebuild test \
  -scheme MyApp \
  -destination "platform=iOS Simulator,id=$udid" \
  -only-testing:MyAppTests/Foo
```

## Cookbook

組み込みコマンドではないが、よく聞かれる使い方 —— WIP 中のタスクから
分岐する、テストの一部だけを実行する、長期タスクを最新に保つ、
`vch land` で生成物を残す、warm シミュレーターテンプレートで初回起動を
スキップする、タスクごとのシミュレーター状態をリセットする、テンプレート
が Booted で詰まったときの対処、マージ済みタスクの一括削除など。

→ 詳細は **[docs/cookbook.md](docs/cookbook.md)** を参照（英語単一ソース、
[AGENTS.md ルール #10](AGENTS.md) を参照）。

## コマンド一覧

| コマンド | 何をするか |
|---|---|
| `vch new <name>` | worktree と `agent/<name>` ブランチを作成（`--exec "<cmd>"`、`--copy-untracked`、`--seed-spm-from <task>`、`--cd`）。 |
| `vch list` | ワークスペース内の全タスクを一覧表示（`--json`、`-v`、`--git-status`）。 |
| `vch state <name>` | タスクの `.vch/state.json` を表示（`--json`、`--field <dotted>`）。 |
| `vch path <name>` | タスクの worktree の絶対パスを表示。 |
| `vch open [<name>]` | worktree を IDE で開く（`--with xcode`/`code`/`cursor`/…）。 |
| `vch <name>` | worktree のシェルに入る。分離環境と PATH shim が有効。 |
| `vch exec <name> -- <cmd...>` | タスクの worktree 内で任意コマンドを実行（分離有効）。 |
| `vch build <name>` | `xcodebuild build` を実行し `-derivedDataPath` / `-clonedSourcePackagesDirPath` を自動注入（`--scheme`、`--runtime`、`--erase-clone`、`--shutdown-template`、`--verbose`）。 |
| `vch test <name>` | `xcodebuild test` を実行し `-resultBundlePath` を注入。シミュレーターは遅延クローン（`--device`、`--runtime`、`--only-testing`、`--skip-testing`、`--rerun`、`--rerun-failed`、`--erase-clone`、`--shutdown-template`）。 |
| `vch run <name>` | タスクのシミュレータークローン上でビルド・インストール・起動（`--erase-clone`、`--shutdown-template`、`-- launch-args`）。 |
| `vch logs <name>` | タスク直近のビルド/テストの完全な xcodebuild ログを表示（`--test`/`--build`）。 |
| `vch sim {clone,erase,shutdown,info} <name>` | タスク用シミュレータークローンを明示的に管理。 |
| `vch sim warm-template {create,list,remove}` | 共有の *warm* シミュレーターテンプレートを管理（iOS / watchOS / tvOS / visionOS、[#47](https://github.com/Maples7/VibeChard/issues/47) / [#58](https://github.com/Maples7/VibeChard/issues/58)）。 |
| `vch land <name>` | `agent/<name>` を base にマージして後始末（`--into`、`--no-ff`/`--ff-only`/`--squash`、`--keep`、`--push`/`--push-to`、`--dry-run`）。 |
| `vch sync <name>` | base の upstream を fetch してタスクブランチを rebase（`--onto`、`--merge`、`--no-fetch`、`--dry-run`）。 |
| `vch remove <name>` | worktree、ブランチ、シミュレータークローンを削除（`--allow-dirty`、`--force`、`--allow-unmerged`、`--keep-sim`）。 |
| `vch prune` | base に完全マージ済みのタスクを一覧／削除（`--rm`、`--allow-dirty`、`--force`、`--keep-sim`、`--json`）。 |
| `vch repair` | `git worktree list` の実状に合わせて `.vch/state.json` を再同期。 |
| `vch clean <name>` | タスクの DerivedData / ModuleCache を削除（`--swiftpm`、`--logs`、`--all`、`--dry-run`）。 |
| `vch doctor` | 孤児シミュレータークローン、不正バインディング、壊れた `state.json` を検出（`--clean`、`--bug-report`、`--json`）。 |
| `vch shellenv` | `vch_cd` / `vch_new` / `vch_clean` の shell 補助関数を出力（bash/zsh）。 |
| `vch completions install` | `zsh` / `bash` / `fish` の補完スクリプトをインストール（`--shell`、`--print`、`--force`）。 |
| `vch version` | バージョンとツールチェーン情報を表示（`--json` で機械可読）。 |

`<name>` を受け取るコマンドは現在のワークスペースから補完されます ——
補完スクリプトをインストールして `<TAB>` を押すだけ。完全な flag リファレ
ンスは **[docs/commands.md](docs/commands.md)** を参照。

## 隔離の仕組み
<p align="center">
  <img src="docs/images/architecture.ja.png" alt="アーキテクチャ図: エージェント → メインリポ → worktree → PATH shim → 専用 DerivedData + Sim クローン" width="720">
</p>
タスクの worktree 内では `<wt>/.vch/bin/` が `PATH` の先頭に挿入され、そこに `xcodebuild`、`xcrun`、`swift` のシンボリックリンクがあり、すべて
`vch-xcodebuild-shim` を指しています。

シムは 3 つの環境変数（`VCH_DERIVED_DATA_PATH`、`VCH_SPM_CLONE_DIR`、
`VCH_RESULT_BUNDLE_PATH`）を読み、ユーザーが明示的に渡していない場合は対応するフラグを `xcodebuild` の argv に注入し、ターゲットディレクトリを
`mkdir -p` で作成、その後 `/usr/bin/xcrun -f xcodebuild` で本物の
`xcodebuild` のパスを解決して `execv`（`PATH` を経由しないので自分自身を再帰呼び出しすることはありません）。`xcrun` と `swift` に対しては透過的にパススルーします。

結果：エージェントが起動しうるあらゆるツール——`xcodebuild`、`swift test`、
Tuist、内部で `xcodebuild` を呼び出すスクリプト——が自動的に隔離されます。フラグを手で渡す必要はありません。

`vch build`、`vch test`、`vch run` は PATH シムをスキップして直接 `xcodebuild` を同じフラグで呼び出します。呼び出し地点で引数がすべて分かっているためです。

### `vch exec` / `vch <name>` が子プロセスに注入するもの

`vch <name>`（= `vch exec <name> -- $SHELL`）と `vch exec <name>
-- <cmd>` は、あなたの環境の上に決定的な env を一段重ねます。これは
`vch build` / `vch test` / `vch run` が使うものとまったく同じ集合
なので、`vch <name>` の中で手で `xcodebuild` を叩いても挙動は
`vch build` と一致します。「タスクの環境に入りたい」専用の別コマンドは
基本必要ありません — `vch <name>` がすでにそれです：

| 変数 | 設定値 |
|---|---|
| `VCH_TASK_NAME` | タスク名（例 `add-paywall`）。PS1 や端末タイトルに便利。 |
| `VCH_TASK_ROOT` | worktree の絶対パス。 |
| `VCH_DERIVED_DATA_PATH` | `<wt>/.agent-build/DerivedData`（シムが読む）。 |
| `VCH_SPM_CLONE_DIR` | `<wt>/.agent-build/SourcePackages`（シムが読む）。 |
| `VCH_RESULT_BUNDLE_PATH` | `<wt>/.agent-build/Result.xcresult`（シムが読む）。 |
| `VCH_RESULT_BUNDLE_DIR` | result bundle の親ディレクトリ。 |
| `CLANG_MODULE_CACHE_PATH` | `<wt>/.agent-build/ModuleCache`（clang が読む）。 |
| `SWIFTPM_CACHE_DIR` | `<wt>/.agent-build/SourcePackages`（SwiftPM が読む）。 |
| `DEVELOPER_DIR` | `xcode-select -p` で解決したホストの選択 Xcode — ユーザーが既に export していない場合のみ注入。 |
| `SIMCTL_CHILD_SIMULATOR_UDID` | タスクに紐づくシミュレータークローン — クローンが紐付いているときだけ設定。 |
| `PATH` | 先頭に `<wt>/.vch/bin` を付加して `xcodebuild` / `xcrun` / `swift` をシム経由に。 |

`vch` がユーザーの export 済みの値を上書きすることはありません — `vch exec`
の前に手動で `export` した値が常に優先されます。

## 設定

ありません。タスクごとの状態はすべて `<worktree>/.vch/state.json` に収まります。`~/.vchrc` も `.vch.toml` もグローバル設定ファイルもありません。唯一の実行時ノブは上記の `VCH_*` 環境変数です（通常は `vch exec` が自分でセットするので、手動で触る必要はほとんどありません）。`vch build`/`vch test`/`vch run` はホストで選ばれている `DEVELOPER_DIR`（`xcode-select -p` で解決）を子プロセスに伝播します。手動で環境変数を設定すれば上書きできます。

`vch new` が `eval "$(vch shellenv)"` のヒントを表示した場合、`VCH_NEW_HINT=0` で抑制できます（あるいはシェル helper をインストールすれば自動的に消えます）。

## VibeChard ではないもの

- **AI ベンダーのラッパーではありません。** SDK も API キーもモデル抽象もありません。好きなエージェントを使ってください——VibeChard は並列セッションを安全にすることだけを担当します。
- **クロスプラットフォームではありません。** 設計上 Apple 専用です。プロジェクトの価値は Xcode ツールチェインへの深さにあり、広さにはありません。
- **CI オーケストレータではありません。** ローカルのターミナルで、ディスク上の
  worktree に対して動作します。CI マトリクスは別の問題です。

## よくある質問

<details>
<summary><strong>Tuist / Fastlane / xcbeautify と組み合わせて使えますか？</strong></summary>

<br/>

使えます。PATH シムは誰が起動しても `xcodebuild` の呼び出しをすべてキャッチします。Tuist が生成する実行、Fastlane の `gym` / `scan`、
xcbeautify の上流パイプ、最終的に `xcodebuild` を叩くカスタムテストスクリプト — どれもタスクごとの `-derivedDataPath` /
`-clonedSourcePackagesDirPath` / `-resultBundlePath` が自動で注入されます。フラグの取り回しは不要です。

</details>

<details>
<summary><strong>CocoaPods / Carthage は？</strong></summary>

<br/>

問題ありません。依存解決のステップは `xcodebuild` を経由しないので隔離不要。ビルドステップは結局 `xcodebuild` を呼ぶのでシムがキャッチします。
`Pods/` と `Carthage/` ディレクトリはソースと同じ worktree 内にあるので、
`git worktree` 自体で隔離されます。

</details>

<details>
<summary><strong>SwiftPM のみのプロジェクト（<code>.xcodeproj</code> なし）？</strong></summary>

<br/>

動きます。`swift build` / `swift test` は既定で worktree ごとの `.build/`
ディレクトリに書き込むため、シムによるフラグ注入なしで初めから隔離されています。シムは透明な passthrough として `swift` をラップしますが argv は変更しません。

</details>

<details>
<summary><strong><code>vch remove</code> 時に未コミットの変更はどうなる？</strong></summary>

<br/>

失われません — `vch remove` は dirty な worktree では明確なメッセージとともに中断します。`--allow-dirty` を付けると上書きで削除（未コミット変更を失います）、`--allow-unmerged` を付ける（または両方併用）と未マージのコミットを持つブランチも削除できます。無言で破壊的に動くパスはありません。

</details>

<details>
<summary><strong>AI エージェントなしでも使えますか？</strong></summary>

<br/>

はい。「並列のサンドボックスが欲しい」シナリオすべてに使えます：同じ機能の別実装を 2 つ並走させる、長い test suite を走らせている裏でメイン worktree
でコーディングを続ける、など。CLI はエージェントに依存しません —いわゆる「エージェント連携」は `--exec "<your command>"` だけです。

</details>

## ソースからビルド・テスト

```sh
swift build -c release
./.build/release/vch version
swift test --parallel
```

CI は push のたびに同じコマンド + シムのスモークテストを実行します：
[.github/workflows/ci.yml](.github/workflows/ci.yml)。

## ライセンス

[Apache-2.0](LICENSE)。CLA なし、テレメトリなし、ネットワーク通信なし。
