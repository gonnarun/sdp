# SDP 명령어 매뉴얼

> 영문 원본 [`COMMAND_MANUAL.md`](COMMAND_MANUAL.md)의 확인용 한국어 번역본. 내용이 어긋나면 영문본이 기준이다.

명령은 네 개다. 앞의 세 개는 동일한 SDP 코어(Stage 1~8, 게이트 2개)를 실행하며, 작업을 어떻게 쪼개고 어디서 돌리는지만 다르다.

> **호출 방식.** Claude Code는 슬래시 형식 `/sdp …`, Codex는 스킬 형식 `$sdp:sdp …`를 쓴다. 아래에 둘 다 표기했다.

| 명령어 | 용도 |
|---|---|
| [`sdp`](#sdp) | 단일 작업을 Stage 1~8로 순차 실행 |
| [`batch-sdp`](#batch-sdp) | 큰 범위를 세그먼트로 분할해 차례대로 실행 |
| [`worktree-dispatch`](#worktree-dispatch) | 서로 독립적인 작업을 worktree별로 병렬 실행 |
| [`precompact`](#precompact) | 컨텍스트 압축 전에 작업 상태와 재개 프롬프트 저장 |

---

## `sdp`

단일 작업을 인터뷰 → 설계 → 구현 → 테스트 → 검증 순으로 실행한다. 계획에 Gate A, 테스트 결과에 Gate B를 적용한다.

```text
/sdp 로그인 실패 횟수 제한 기능 구현
```
```text
$sdp:sdp 로그인 실패 횟수 제한 기능 구현
```

작고 위험도 낮은 작업은 인터뷰를 축약하고 별도 설계 문서를 생략하는 fast-path를 탄다. 게이트는 그대로 실행된다.

**사용 시점** — 이번 세션에서 끝까지 처리할 하나의 일관된 변경일 때.

---

## `batch-sdp`

큰 범위를 독립 세그먼트로 나눈 뒤 각 세그먼트에 전체 SDP 워크플로를 차례로 실행한다. 조각 사이에 선후 의존이 있을 때 적합하다.

```text
/batch-sdp 사용자 관리 기능 전체 구현
```
```text
$sdp:batch-sdp 사용자 관리 기능 전체 구현
```

엔진은 **앵커가 선택한** `defaults.yaml`의 `dispatch.batch_engine`으로 고른다. 탐색 순서는 프로젝트 `.sdp/` → 프로젝트 `scripts/sdp/` → `XDG_CONFIG_HOME`가 **명시적으로 설정된 경우에만** `$XDG_CONFIG_HOME/sdp/`, 아니면 passwd-home `~/.config/sdp/` → passwd-home `~/.sdp/`. 처음 발견된 **안전하고 존재하는** 후보가 이긴다. 후보가 있으나 안전하지 않거나 읽을 수 없으면 다음으로 넘어가지 않고 중단한다. 사용자 전역 파일도 유효하다. 프로젝트 로컬 `.sdp/defaults.yaml`이 없다고 해서 키가 미설정인 것은 **아니며**, `XDG_CONFIG_HOME`이 미설정이면 실제로 읽히는 파일은 보통 `~/.config/sdp/defaults.yaml`이다. no-weakening·fail-closed 규칙은 [Configuration](README.md#configuration) 참조.

| 값 | 동작 |
|---|---|
| `agent_tool` (기본) | 각 세그먼트를 이 세션의 서브에이전트로 실행. 추가 도구 불필요. |
| `tmux_long_lived` | 배치당 `tmux` 안에 장기 실행 **Codex** 워커 세션 1개를 띄우고 세그먼트 프롬프트를 밀어 넣음. `tmux`·`codex`·`git`이 `PATH`에 있고 cwd가 git 체크아웃이어야 하며, 없으면 `agent_tool`로 폴백. Claude Code는 리뷰 게이트에만 쓰인다. |

세그먼트 완료 신호는 `STATUS.md` 파일이다. 터미널 화면을 긁지 않는다.

**사용 시점** — 한 번에 처리하기엔 크지만 조각들이 순서대로 들어가야 할 때.

---

## `worktree-dispatch`

인터뷰 한 번으로 **서로 독립적인** 작업 목록을 확정한 뒤, 각 작업을 개별 git worktree에 넘겨 전체 SDP 워크플로를 병렬 실행한다.

```text
/worktree-dispatch
1. 로그인 API 구현
2. 사용자 관리 화면 구현
3. 배포 설정 추가
```

목록이 길면 Markdown 파일에 저장하고 경로를 넘긴다.

```text
/worktree-dispatch TASKS.md의 작업목록을 병렬 실행
```
```text
$sdp:worktree-dispatch TASKS.md의 작업목록을 병렬 실행
```

**전제 조건** — 작업 간에 의존성, 수정 파일, DB 상태, 포트가 겹치면 안 된다. 겹치면 `batch-sdp`를 쓴다.

모드는 앵커가 선택한 `defaults.yaml`의 `dispatch.worktree_mode`로 고른다 — 탐색 순서와 fail-closed 규칙은 위 `dispatch.batch_engine`과 같다. 즉 `manual`은 *선택된 파일이 모드를 지정하지 않았다*는 뜻이지, *프로젝트 로컬 파일이 없다*는 뜻이 아니다.

| 값 | 동작 |
|---|---|
| `manual` (기본) | 작업별 핸드오버 문서를 만들고, 실행은 사용자가 직접 띄운다. |
| `auto` | worktree마다 headless **Codex** 세션을 자동 생성. `tmux`·`codex`·`git` 필요, 없으면 `manual`로 폴백. |

worktree 세션은 검증 체크리스트까지만 만든다. 런타임·화면 테스트는 머지 후 main에서 직렬로 돈다(`worktree.runtime_isolation: serial_main`). 프로젝트가 worktree별 임시 런타임을 선택하면 달라진다.

**사용 시점** — 서로 무관한 변경 여러 건을 동시에 진행하고 싶을 때.

---

## `precompact`

유틸리티 명령. SDP 코어를 실행하지 **않는다**. 현재 작업 상태를 `.private/precompact/{날짜}/`에 저장하고, 다음 컨텍스트에 붙여넣을 재개 프롬프트를 출력한다.

```text
/precompact login-limit
```
```text
$sdp:precompact login-limit
```

**사용 시점** — 컨텍스트가 차올라서 다음 세션이 깔끔하게 이어받아야 할 때.

### 자동 모드 (Claude 호스트)

플러그인은 compact와 다음 프롬프트를 이어붙이는 훅 3개를 함께 배포한다. 손으로 칠 것이 없다.

1. **`Stop`** — 세션 트랜스크립트에서 실제 컨텍스트 사용량을 읽는다. 임계치를 넘으면 `decision: block`을 돌려줌으로써 모델에게 도구 사용이 가능한 턴을 한 번 더 주고 스냅샷 작성을 지시한다.
2. **`PreCompact`** — 방금 작성된 스냅샷을 해당 `session_id`에 묶는다. 같은 디렉토리의 다른 세션이 엉뚱한 스냅샷으로 재개하는 사고를 막는다.
3. **`SessionStart`** (matcher `compact`) — compact 직후 스냅샷 경로와 재개 지시를 `additionalContext`로 주입하고, 마커를 지워 다음 사이클을 다시 무장한다.

자동 compact 직후에는 호스트가 턴을 스스로 이어가므로 사용자 입력 없이 작업이 재개된다. 수동 `/compact`의 경우에는 주입된 컨텍스트가 다음 메시지에서 사용된다.

사용자가 켜기 전까지는 꺼져 있고, 미설정은 결코 켜진 것으로 간주하지 않는다.

```bash
PLUGIN="$(ls -d ~/.claude/plugins/cache/sdp-marketplace/sdp/*/ | sort -V | tail -1)"
python3 "${PLUGIN}scripts/precompact_hook.py" config set auto   # 또는 manual
python3 "${PLUGIN}scripts/precompact_hook.py" doctor            # 상태 진단
```

`doctor`는 미충족 조건을 전부 출력하고 non-zero로 종료한다. 반만 설치된 자동화가 성공을 보고하는 상황을 만들지 않는다. `SDP_PRECOMPACT_TRANSCRIPT=<세션 .jsonl>`을 주면 실제 세션을 측정해 차단 여부까지 알려준다.

임계치 기본값은 컨텍스트 창의 78%로, 호스트 자체 auto-compact 지점보다 낮게 잡아 스냅샷이 경주에서 이기도록 했다. `SDP_PRECOMPACT_THRESHOLD` 또는 `~/.sdp/precompact.json`의 `threshold`로 바꾼다.

컨텍스트 창 크기 자체는 추론해야 한다. 훅에는 사용량 필드가 오지 않고, 트랜스크립트에 기록되는 모델 id는 200k 세션이든 1M 세션이든 동일하다. 그래서 그 세션이 실제로 도달한 최대 점유량(기록된 compact 포함)을 먼저 보고, 다음으로 설정된 `[1m]` 모델을 보며, 한 세션 안에서 다시 좁아지지 않는다. 아직 한 번도 compact하지 않았고 어디에도 wide 모델이 적히지 않은 세션은 필요보다 이르게 스냅샷을 요청할 수 있다. `SDP_PRECOMPACT_CONTEXT_TOKENS`(또는 호스트의 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`)로 못박으면 된다.

두 호스트 모두 이 세 이벤트를 지원하고, 플러그인의 `hooks/hooks.json`을 자동으로 읽는다. 매니페스트 하나로 Claude Code와 Codex를 함께 굴린다. 호스트 차이는 두 가지다. Codex는 **신뢰(trust) 전까지 플러그인 훅을 건너뛴다** — 해당 호스트에서 `/hooks`를 한 번 실행해 승인해야 하며, 그전까지는 등록만 되고 발동하지 않는다. 그리고 트랜스크립트 형식이 다르다. Claude는 assistant 메시지마다 `message.usage`를 남기고, Codex는 `token_count` 이벤트를 남긴다. 점유량은 `last_token_usage.input_tokens`를, 창 크기는 Codex가 명시하는 `model_context_window`를 쓴다. `total_token_usage`는 세션 누적 청구량이라 쓰지 않는다. 두 값은 **같은, 가장 최근** 이벤트에서 함께 가져온다. 세션 도중 모델이 바뀔 수 있는데, 최신 점유량을 그 세션이 한때 가졌던 가장 큰 창으로 나누면 258400 창의 210k가 81%가 아니라 21%로 읽힌다. 임계치를 못 넘고 스냅샷도 못 남긴다.

호스트가 이렇게 명시한 창은 그대로 쓴다. 넓어지기만 하는 기억값과 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`는 창을 추론해야 하는 경우를 위한 장치라 이 값을 덮지 않는다. Claude 전용 환경변수가 Codex 세션의 창을 정해서는 안 된다. `SDP_PRECOMPACT_CONTEXT_TOKENS`만 두 호스트 모두에서 모든 것보다 우선한다.

두 트랜스크립트 형식 모두 공식 인터페이스가 아니므로, 바뀌면 측정값을 내지 않고 조용히 멈춘다. 틀린 값을 내지는 않는다.

`doctor`는 호스트가 실제로 훅을 등록했는지까지는 확인할 수 없다. 설정 상태만 보고하고, 무엇을 직접 확인해야 하는지 알려준다.

---

## 산출물 위치

모든 명령은 설정된 `base_dir`(기본 `.private/sdp-artifacts`) 아래에 쓴다.

```
.private/sdp-artifacts/{YYYY-MM-DD}/{주제}/{문서유형}
```

`.private/`는 최초 실행 시 자동 생성되고 `.gitignore`에 등록된다. 산출물 언어는 앵커가 선택한 `defaults.yaml`의 `output_locale`을 따른다(탐색 순서는 위와 동일, `auto` = 실행 환경 언어).
