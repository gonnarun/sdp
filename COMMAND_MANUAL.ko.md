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

엔진은 `.sdp/defaults.yaml`의 `dispatch.batch_engine`으로 고른다.

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

모드는 `dispatch.worktree_mode`로 고른다.

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

---

## 산출물 위치

모든 명령은 설정된 `base_dir`(기본 `.private/sdp-artifacts`) 아래에 쓴다.

```
.private/sdp-artifacts/{YYYY-MM-DD}/{주제}/{문서유형}
```

`.private/`는 최초 실행 시 자동 생성되고 `.gitignore`에 등록된다. 산출물 언어는 `.sdp/defaults.yaml`의 `output_locale`을 따른다(`auto` = 실행 환경 언어).
