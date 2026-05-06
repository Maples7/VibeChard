# VibeChard

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · **한국어**

> **AI 코딩 에이전트와 함께하는 Apple 병렬 개발을 위한, 작업 단위로 격리된 worktree.**
> 동일한 Xcode 프로젝트에서 Claude / Codex / Copilot / Cursor 세션을 동시에 여러 개
> 실행해도 `build.db` 잠금, `DerivedData` 충돌, 시뮬레이터 충돌이 발생하지 않습니다.

```sh
brew install maples7/tap/vch
```

그다음 어떤 Apple 프로젝트에서든:

```sh
vch new add-paywall          # 격리된 worktree + agent 브랜치 생성
vch add-paywall              # 격리가 적용된 셸로 진입
                             # → 평소처럼 xcodebuild / swift test 실행
vch test add-paywall --device "iPhone 16"
vch remove add-paywall
```

이게 전부입니다. 각 에이전트는 자신만의 worktree, 자신만의 `DerivedData`,
자신만의 시뮬레이터 클론을 가지며 — 사용자의 `~/Library/Developer/`는
1 바이트도 건드리지 않습니다.

> **상태: alpha (v0.1.0).** CLI 표면은 거의 안정화되었지만 아직 동결되지
> 않았습니다. `.vch/state.json` 스키마에는 이후 필드가 추가될 수 있습니다.
> 안정성이 필요하면 태그를 고정하세요.

## 왜 별도의 CLI 가 필요한가

범용 git-worktree 매니저(Rift, Emdash, Taskpods, Workie 등)는 "소스 트리 격리"
하나만 해결합니다. 그러나 Apple 툴체인에는 병렬 `xcodebuild` 실행 시 서로
충돌하여 비결정적 실패를 일으키는 공유 자원이 **최소 7 개 더** 있습니다:

| 자원 | 격리하지 않을 때의 문제 | VibeChard 의 해법 |
|---|---|---|
| `DerivedData` | 모듈 재빌드 반복, 캐시 오염 | `-derivedDataPath <wt>/.agent-build/DerivedData` |
| `ModuleCache.noindex` | 동시성 하에서 Clang 모듈 캐시 손상 | worktree 별 `CLANG_MODULE_CACHE_PATH` |
| SwiftPM 전역 캐시 | `Package.resolved` 쓰기 충돌 | worktree 별 `-clonedSourcePackagesDirPath` |
| `xcresult` 번들 | 나중에 쓴 쪽이 덮어씀 | worktree 별 `-resultBundlePath` |
| 시뮬레이터 디바이스 | 같은 iPhone 16 에 두 작업이 동시에 설치 | 작업별 `xcrun simctl clone` |
| 에이전트가 PATH 로 `xcodebuild` 검색 | 주입한 플래그를 우회 | **PATH shim** 으로 자동 주입 |
| 소스 트리 | 표준 처리 | `git worktree` + `agent/<name>` 브랜치 |

**BYO Agent (Bring Your Own Agent)** 입니다 — Claude, Codex, Copilot, Cursor 등
셸을 호출할 수 있는 무엇이든 됩니다. VibeChard 는 AI 벤더 래퍼가 *아닙니다*.
텔레메트리 없음, 네트워크 호출 없음, SDK 종속 없음.

## 설치

### Homebrew (권장)

```sh
brew install maples7/tap/vch
```

formula 가 설치하는 항목:

- `vch` 를 Homebrew 의 `bin/` 에 (`PATH` 에 포함)
- `vch-xcodebuild-shim` 을 `libexec/` 에 (**의도적으로** `PATH` 에 두지 않음
  — 작업별 `.vch/bin/` 안에 `vch exec` 가 만든 심볼릭 링크를 통해서만
  도달해야 합니다)
- Bash, Zsh, Fish 자동완성 스크립트

### 소스로부터 빌드

요구 사항: macOS 13+, Xcode 15.3+ (Swift 5.10+).

```sh
git clone https://github.com/maples7/VibeChard.git
cd VibeChard
swift build -c release
ln -s "$PWD/.build/release/vch" /usr/local/bin/vch    # CLI 보관 경로에 맞춰
```

## 빠른 시작

git 으로 관리되는 임의의 Apple 프로젝트 안에서:

```sh
# 1. agent/add-paywall 위에 격리된 worktree 생성
vch new add-paywall

# 2. 그 안의 셸로 진입 (PATH shim 활성)
vch add-paywall
# 이 셸 안에서:
#   xcodebuild build              ← -derivedDataPath 가 자동 주입됨
#   swift test                    ← 모듈 캐시 + SwiftPM 클론 디렉터리 격리됨
#   exit                          ← 원래 셸로 복귀

# 3. 셸에 들어가지 않고 바로 xcodebuild 호출도 가능:
vch build add-paywall --scheme MyApp
vch test  add-paywall --scheme MyApp --device "iPhone 16"

# 4. worktree 안에서 직접 에이전트 구동:
vch new fix-toast --exec "claude"     # 격리된 worktree 에서 claude 실행
vch exec fix-toast -- npm run lint    # worktree 안에서 일회성 명령 실행

# 5. 점검과 정리
vch list
vch path add-paywall                  # worktree 의 절대 경로
vch remove add-paywall                # worktree + 브랜치 + 시뮬레이터 클론 삭제
```

## 명령어

| 명령어 | 동작 |
|---|---|
| `vch new <name>` | `../<repo>-<name>` 에 worktree 생성, 브랜치는 `agent/<name>`. `--exec "<cmd>"` 로 worktree 내부에서 명령 실행 (예: AI 에이전트). |
| `vch list` | 현재 워크스페이스의 모든 작업 나열. `--json` 으로 기계 판독 가능 형식. |
| `vch path <name>` | 작업 worktree 의 절대 경로 출력. |
| `vch <name>` | `vch exec <name> -- $SHELL` 의 단축형 — 격리 환경 변수 + `.vch/bin` PATH shim 이 활성화된 셸 진입. |
| `vch exec <name> -- <cmd...>` | 작업 worktree 내에서 임의의 명령 실행 (격리 활성). |
| `vch build <name> [flags] [-- xcodebuild-extras]` | 작업 worktree 에 대해 `xcodebuild build` 실행. `-derivedDataPath` / `-clonedSourcePackagesDirPath` 자동 주입. |
| `vch test  <name> [flags] [-- xcodebuild-extras]` | `xcodebuild test` 실행, `-resultBundlePath` 주입. 첫 `--device` 시 시뮬레이터를 지연 클론하고 이후 재사용. |
| `vch sim {clone,erase,shutdown,info} <name>` | 작업의 시뮬레이터 클론을 명시적으로 관리. |
| `vch remove <name> [--force [--force]] [--keep-sim]` | worktree, 브랜치, (기본으로) 시뮬레이터 클론 삭제. `--force` 두 번이면 더티 트리 + 머지되지 않은 브랜치도 허용. |
| `vch repair` | `git worktree list` 의 실제 상태에 맞춰 `.vch/state.json` 재동기화. |
| `vch doctor [--clean] [--json]` | 고아 시뮬레이터 클론, 오래된 상태 바인딩, 손상된 `state.json` 탐지. 발견 시 비정상 종료. |
| `vch shellenv` | `vch_cd` / `vch_clean` 셸 헬퍼 출력 (bash/zsh). |
| `vch version` | 버전과 툴체인 정보 출력 (`--json` 으로 기계 판독). |

`<name>` 을 받는 모든 명령은 현재 워크스페이스의 작업 이름으로 자동완성됩니다 —
자동완성 스크립트를 설치하고 `<TAB>` 을 누르세요.

## 격리 동작 원리

작업 worktree 안에서 `<wt>/.vch/bin/` 이 `PATH` 의 맨 앞에 추가되며,
이 디렉터리에는 `xcodebuild`, `xcrun`, `swift` 세 개의 심볼릭 링크가
모두 `vch-xcodebuild-shim` 을 가리킵니다.

shim 은 세 개의 환경 변수(`VCH_DERIVED_DATA_PATH`, `VCH_SPM_CLONE_DIR`,
`VCH_RESULT_BUNDLE_PATH`)를 읽고, 사용자가 해당 플래그를 명시적으로 전달하지
않은 경우 `xcodebuild` 의 argv 에 주입한 뒤, 대상 디렉터리를 `mkdir -p` 로
만들고, `/usr/bin/xcrun -f xcodebuild` 로 실제 `xcodebuild` 경로를 해결하여
`execv` 로 실행합니다(자기 자신을 재귀 호출하지 않도록 `PATH` 를 우회).
`xcrun` 과 `swift` 에 대해서는 투명한 패스스루입니다.

결과: 에이전트가 실행할 수 있는 모든 도구 — `xcodebuild`, `swift test`,
Tuist, 내부에서 `xcodebuild` 를 호출하는 스크립트 — 가 자동으로 격리됩니다.
플래그를 손으로 전달할 필요가 없습니다.

`vch build` 와 `vch test` 는 호출 시점에 인자를 모두 알고 있으므로 PATH shim 을
거치지 않고 같은 플래그로 `xcodebuild` 를 직접 호출합니다.

## 설정

없습니다. 작업별 상태는 모두 `<worktree>/.vch/state.json` 에 저장됩니다.
`~/.vchrc` 도, `.vch.toml` 도, 어떤 전역 설정 파일도 없습니다. 유일한
런타임 노브는 위에서 언급한 `VCH_*` 환경 변수뿐입니다(보통 `vch exec` 가
직접 설정하므로 손으로 만질 일은 거의 없습니다).

## VibeChard 가 아닌 것

- **AI 벤더 래퍼가 아닙니다.** SDK 도, API 키도, 모델 추상화도 없습니다.
  원하는 어떤 에이전트든 사용하세요 — VibeChard 는 병렬 세션을 안전하게
  만드는 일만 합니다.
- **크로스 플랫폼이 아닙니다.** 설계상 Apple 전용입니다. 프로젝트의 가치는
  Xcode 툴체인에 대한 깊이에 있지 폭에 있지 않습니다.
- **CI 오케스트레이터가 아닙니다.** 로컬 터미널에서 디스크상의 worktree 에
  대해 동작합니다. CI 매트릭스는 다른 문제입니다.

## 소스로 빌드 및 테스트

```sh
swift build -c release
./.build/release/vch version
swift test --parallel             # 116 개 테스트, M 시리즈에서 약 9 초
```

CI 는 push 마다 같은 명령과 shim 스모크 프로브를 실행합니다:
[.github/workflows/ci.yml](.github/workflows/ci.yml).

## 라이선스

[Apache-2.0](LICENSE). CLA 없음, 텔레메트리 없음, 네트워크 호출 없음.
