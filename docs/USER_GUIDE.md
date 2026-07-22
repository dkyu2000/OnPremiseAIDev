# 사용자 매뉴얼 (User Guide)

> 폐쇄망 On-Premise AI Assistant — 개발자/PM용 사용 가이드.
> IDE(OpenCode, VS Code)에서 사내 AI 모델로 **코드 채팅·자동완성**을 사용하는 방법.
> 인터넷 연결 없이 사내망에서만 동작하며, 모든 요청은 사내 게이트웨이를 거칩니다.

---

## 1. 시작하기 전에

### 무엇을 할 수 있나
- **코드 채팅**: 코드 설명, 리뷰, 리팩터링 제안, 알고리즘 질문, 문서 작성 등
- **tab 자동완성**: 타이핑하면 회색으로 다음 코드를 제안 (VS Code)
- **에이전트 작업**: OpenCode로 파일 편집·명령 실행 등 자동화 (도구 사용)

### 필요한 것
1. **가상 키(`sk-...`)** — 운영팀에서 1인 1개 발급받습니다. (이메일/메신저 등 안전 채널)
   - 키는 **본인만** 사용하고 공유하지 마세요. 분실/유출 시 운영팀에 즉시 알려 폐기합니다.
2. **게이트웨이 주소** — 보통 `http://<사내서버>:4000/v1` (운영팀 안내값)
3. 클라이언트: **OpenCode**(CLI 에이전트) 또는 **VS Code + Continue 확장**

> ⚠️ 이 환경은 **폐쇄망**입니다. 외부 인터넷 AI(ChatGPT 등)는 동작하지 않으며, 사내 모델만 사용합니다.

---

## 2. 사용할 모델 — 무엇을 언제 쓰나

| 모델 | 용도 | IDE에서 |
|------|------|---------|
| **main-gptoss** (gpt-oss-120b) | 채팅·코드설명·리팩터링·**에이전트(도구 사용)** | 채팅·편집의 기본(유일한 채팅 모델) |
| **autocomplete-starcoder2** (StarCoder2-7B) | **tab 자동완성** | 코드 편집기에서 자동 동작 |

**핵심 가이드**
- **코드 작성 중 자동완성(회색 제안)** → StarCoder2가 **자동으로** 담당. 모델을 고를 필요 없습니다.
- **채팅으로 질문/리팩터링/에이전트 작업** → **main-gptoss**를 사용합니다(채팅 모델은 이거 하나뿐입니다).
- ★가벼운 서브 채팅 모델(Gemma)은 운영에서 사용하지 않습니다 — 짧은 질문도 main-gptoss가 처리합니다.
- ★**어려운/복잡한 질문일수록 응답이 길어질 수 있습니다**(내부적으로 사고과정을 거친 뒤 답하는 모델이라).
  자체 스크립트로 직접 API를 호출하는 경우 `max_tokens`를 최소 600~900 이상으로 주세요(너무 작으면 답이
  중간에 끊겨 빈 응답이 올 수 있습니다). OpenCode/Continue는 기본 설정으로 이미 충분히 동작합니다.

---

## 3. OpenCode (CLI 에이전트) 사용법

OpenCode는 터미널/IDE에서 동작하는 AI 코딩 에이전트입니다.

### 설정
저장소의 **`opencode.json.example`**을 프로젝트 루트에 `opencode.json`으로 복사한 뒤,
`baseURL`의 `<사내-LiteLLM-서버-주소>`만 실제 서버 주소로 바꾸면 됩니다(운영팀에 문의). 참고용 내용:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "litellm-onprem/main-gptoss",
  "provider": {
    "litellm-onprem": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "On-Prem AI",
      "options": {
        "baseURL": "http://<사내서버>:4000/v1",
        "apiKey": "{env:OPENCODE_LITELLM_KEY}"
      },
      "models": {
        "main-gptoss": { "name": "gpt-oss-120b (채팅·에이전트)" }
      }
    }
  }
}
```

가상 키는 환경변수로 주입(파일에 평문 저장 금지):
```bash
export OPENCODE_LITELLM_KEY=sk-...본인키...
```

**항상 한국어로 응답받기 (한 번만 설정하면 이후 모든 프로젝트에 자동 적용):**
매번 "한국어로 답해줘"라고 요청하지 않아도 되도록, PC 계정 전체에 적용되는 전역 지침 파일을 만들 수
있습니다.

```bash
mkdir -p ~/.config/opencode
cp AGENTS.md.example ~/.config/opencode/AGENTS.md   # 저장소의 AGENTS.md.example 사용
```

그리고 `~/.config/opencode/opencode.jsonc`(전역 설정, 없으면 새로 생성)에 아래 내용을 추가:
```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "instructions": ["/home/<사용자계정>/.config/opencode/AGENTS.md"],
  "permission": {
    "bash": {
      "*": "allow",
      "nohup *": "deny",
      "* &": "deny"
    }
  }
}
```
경로는 반드시 **절대경로**로 쓰세요(`~`는 인식되지 않습니다). 이후로는 어떤 프로젝트에서 OpenCode를
켜든 모든 응답과 산출물(OpenSpec 문서 포함)이 한국어로 작성됩니다. `permission.bash`는 §3의
개발 서버 백그라운드 기동 문제에 대한 **기술적 강제 장치**입니다 — 아래 §3에서 이어서 설명합니다.

### 사용
```bash
opencode                                   # 대화형 TUI 실행
opencode run "이 함수의 시간복잡도는?"       # 비대화형 한 번 실행
```
- TUI 안에서 `/models` 로 모델 전환, 일반 대화처럼 질문/지시.
- main-gptoss는 도구(bash/파일편집)를 사용해 실제 작업을 수행합니다.

### ⚠ 주의사항: 개발 서버(Flask/Node 등) 백그라운드 기동 시 멈추는 문제

OpenCode에게 "백엔드 서버 켜줘" 식으로 시키면 `nohup python app.py > log 2>&1 &`,
`nohup node index.js > backend.log 2>&1 &` 같은 명령을 직접 실행하는데, **`&`로 제대로 백그라운드
처리하고 로그로 리다이렉트까지 해도 OpenCode의 bash 도구가 명령이 끝난 뒤에도 계속 응답을 기다리며
멈추는 경우가 실측 확인됐습니다**(2026-07-21~22, Flask/Node 백엔드 둘 다 재현). 터미널에서 똑같은
명령을 직접 치면 0.001초 만에 끝나고 서버도 정상 기동되므로 명령어 자체는 문제가 없습니다 — OpenCode
쪽 bash 도구(대화형 PTY 기반)가 장시간 실행되는 프로세스를 백그라운드로 보낸 뒤 완전히 분리(detach)
됐다고 판단하는 데 문제가 있는 것으로 보이는, **현재까지 근본 해결책이 없는 클라이언트 쪽 한계**입니다.
증상: 몇 분씩 응답이 없다가 결국 타임아웃되거나, 직접 `esc`로 중단해야 함.

**★[2026-07-22 1차] 전역 지침(AGENTS.md)으로 시도했으나 프롬프트만으로는 불완전함이 실측 확인됨.**
전역 설정 파일(`~/.config/opencode/AGENTS.md`, 배포용 원본은 `AGENTS.md.example`)에 "서버를 bash로
직접 백그라운드 기동하지 말 것" 지침을 추가하고, 신규 세션이 이 지침을 **복창(인지)**하는 것까지는
확인했었습니다. 하지만 실제 사용 세션(2026-07-22 오전)에서 `nohup npm run dev`/`nohup node index.js`
시도가 2시간 넘게 20회 가까이 반복 재현됨 — **지침 인지와 실행 시 준수는 별개**였습니다(LLM 지침
순응은 확률적이라 프롬프트만으로는 100% 보장되지 않음). `permission` 설정이 아예 없어 모든 bash
명령이 기술적으로 무조건 자동 allow였던 것이 근본 원인.

**★[2026-07-22 2차, 확정] `permission.bash`로 기술적 강제 추가.** 위 "설정" 절의 `opencode.jsonc`
예시처럼 `nohup *`, `* &` 패턴을 `"deny"`로 지정하면 OpenCode가 지침을 "따르길 바라는" 수준이 아니라
**명령 자체가 실행되지 않고 즉시 차단**됩니다. 이제는 사용자가 매번 요청할 필요 없이, 이 두 패턴을
치려는 시도 자체가 막히므로 OpenCode가 pytest fixture나 Jest `beforeAll`/`afterAll` 같은 대안으로
전환할 수밖에 없습니다.

혹시 그래도 이 증상이 재현되면(예: 전역 설정 반영 전 세션이거나 `permission` 블록을 아직 추가하지
않은 경우), 아래처럼 직접 지시해서 우회할 수 있습니다:
```
서버를 매번 nohup으로 수동 기동하지 말고, 테스트의 beforeAll/afterAll(또는 pytest fixture)에서
프로세스를 직접 띄우고 포트 응답을 폴링한 뒤 진행하도록 만들어줘. 이후로는 서버를 bash 명령으로
직접 켜지 말고 항상 이 테스트를 통해서만 실행해줘.
```
가장 확실한 건 **새 세션을 시작하는 것**입니다 — 낡은 대화 맥락 없이 전역 지침이 바로 적용됩니다.

### 확장 기능 (플러그인 / MCP 서버)

OpenCode 자체는 node/npm이 없는 단일 바이너리이므로, npm 기반 확장(OpenSpec 등)을 쓰려면 Node.js를
**먼저 별도 설치**해야 합니다. sudo 없이 사용자 홈 디렉터리에 설치할 수 있습니다:

```bash
mkdir -p ~/.local/nodejs
curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz"
tar -xJf /tmp/node.tar.xz -C ~/.local/nodejs --strip-components=1
echo 'export PATH="$HOME/.local/nodejs/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

> 폐쇄망 배포 시에는 이 tar.xz를 빌드 단계에서 미리 받아 반입 매체에 포함하세요(모델 스테이징과 동일한 패턴).

**OpenSpec (스펙 기반 개발 워크플로우, `/opsx:*` 명령):**
```bash
npm install -g @fission-ai/openspec@latest
echo 'export OPENSPEC_TELEMETRY=0' >> ~/.bashrc   # ★필수: 기본값이 외부 익명 사용통계 전송(ON) — 폐쇄망 정책상 반드시 끌 것
source ~/.bashrc
cd <프로젝트 디렉터리>
openspec init --tools opencode        # .opencode/skills, .opencode/commands, openspec/ 생성
```
설치 후 OpenCode를 재시작하면 `/opsx:propose "아이디어"` 등 슬래시 명령을 쓸 수 있습니다.

**OpenSpec 사용법 — 기능 하나를 이렇게 진행합니다:**

작업 전에 먼저 "무엇을 왜 만드는지" 스펙(계획서)을 글로 정리하고, 그걸 팀(또는 나중의 나 자신)이
리뷰한 뒤에 실제 코드를 구현하는 방식입니다. "일단 코드부터 짜고 보자"로 시작하면 놓치기 쉬운 요구사항
누락·설계 재작업을 줄여줍니다.

| 단계 | 명령 | 하는 일 |
|---|---|---|
| 0 (선택) | `/opsx:explore` | 아직 뭘 만들지 명확하지 않을 때 — 아이디어를 자유롭게 탐색하고 요구사항을 정리 |
| 1 | `/opsx:propose "기능 설명"` | 변경 제안 생성 — `openspec/changes/<이름>/`에 스펙·설계·작업목록 자동 생성 |
| 2 | (사람이 리뷰) | 생성된 스펙 파일을 직접 읽고 방향이 맞는지 확인/수정 요청 |
| 3 | `/opsx:apply` | 승인된 스펙대로 실제 코드 구현 |
| 4 | `/opsx:sync` | 구현이 끝난 변경분(delta)을 프로젝트의 메인 스펙 문서에 반영 |
| 5 | `/opsx:archive` | 완료된 변경 건을 보관(정리) |

- 진행 중 스펙 내용을 다시 고쳐야 하면 `/opsx:update`로 기존 계획서만 수정(코드는 안 건드림).
- 지금까지 만들어진 스펙/변경 목록은 터미널에서 `openspec list`(목록) 또는 `openspec view`(대화형
  대시보드)로 확인 가능합니다.
- 간단한 버그 수정처럼 스펙까지 쓸 필요 없는 작업엔 이 워크플로우를 안 써도 됩니다 — 규모 있는 기능
  추가/설계 변경에 적합합니다.
- **★단계마다 새 세션(채팅)으로 시작하는 것을 권장합니다.** 진행 상태는 대화 기억이 아니라
  `openspec/changes/` 폴더의 파일에 저장되므로, 세션을 새로 시작해도 이어서 작업할 수 있습니다.
  반대로 `/opsx:explore`를 같은 세션에서 여러 번 이어 붙이거나 큰 PDF를 반복해서 읽으면 컨텍스트가
  쌓여 `max_tokens must be at least 1, got -N` 오류가 나기 쉽고, 한 번 이 상태가 되면 그 세션은
  복구되지 않습니다(§6 FAQ 참조) — 새 세션에서 다시 시작하세요.

**★★"공유 메모 파일" 패턴 — 1~2페이지짜리 요구사항 문서를 단계적으로 다듬을 때 (실사용 검증됨,
2026-07-14):** "개선사항을 찾아줘"처럼 **채팅으로만 답을 받으면** 그 내용은 대화 기억에만 남아서,
다음 단계를 새 세션에서 시작하는 순간 "그게 뭐였지?"가 되어버립니다(위 원칙과 충돌하는 것처럼
보이지만, 핵심은 "새 세션 자체"가 아니라 "채팅에만 남은 내용"이 문제입니다). 해결책은 **채팅 대신
항상 파일에 결과를 먼저 저장**하는 것 — 그러면 세션이 몇 개로 나뉘든 다음 세션은 파일만 읽으면
이어집니다.

```
1단계(새 세션): /opsx:explore docs/REQ.md 를 읽고 개선사항을 핵심/중간/보완으로 분류해서
              docs/IMPROVEMENTS.md 라는 새 파일에 정리해줘(원본 REQ.md는 아직 건드리지 마)
2단계(새 세션): docs/IMPROVEMENTS.md 의 "핵심" 항목만 docs/REQ.md 에 반영해줘
3단계(새 세션): docs/IMPROVEMENTS.md 의 "중간" 항목만 docs/REQ.md 에 반영해줘
4단계(새 세션): docs/IMPROVEMENTS.md 의 "보완" 항목만 docs/REQ.md 에 반영해줘
```

- **2~4단계는 `/opsx:explore`를 붙이지 말고 그냥 직접 지시하세요.** `/opsx:explore`는 "탐색/생각"
  모드라 파일 편집을 바로 하지 않고 되묻거나(가이드에 "Don't auto-capture" 원칙 명시), 탐색용
  서브에이전트를 추가로 호출해 토큰을 더 씁니다. "이미 정리된 내용을 파일에 옮기는" 기계적 작업은
  접두어 없이 기본(Build) 에이전트에게 바로 시키는 게 더 빠르고 안전합니다. `/opsx:explore`는
  1단계처럼 실제로 "찾아서 분류"하는 열린 작업에만 쓰세요.
- 문서가 1~2페이지로 짧다면 아예 1단계 하나로 끝내는 것도 방법입니다: `/opsx:explore docs/REQ.md
  를 읽고 개선사항을 핵심/중간/보완으로 분류해서 채팅 말고 바로 파일 끝에 "## 개선사항 검토"
  섹션으로 추가해줘`처럼 **조사+파일반영을 한 턴에** 요청하면 세션이 몇 번을 재시작되든 잃어버릴
  내용이 없습니다.

> ⚠ **`npx`로 MCP 서버를 띄우지 마세요 — 연결 경쟁(race condition) 실측 확인.** `opencode run`(비대화형
> 1회 실행)이 MCP 서버 초기화를 충분히 기다리지 않고 진행하는 버그가 있어(`timeout` 설정을 늘려도 안 고쳐짐,
> OpenCode 1.17.18 기준 알려진 이슈), `npx -y <패키지>`처럼 매번 패키지 해석 과정을 거치면 지연이 커져
> "server unavailable"로 실패하는 사례가 실측됨. **`npm install -g`로 전역 설치 후 생성된 바이너리를
> 직접 command에 지정**하면 스핀업이 즉시 끝나 이 경쟁을 사실상 피할 수 있다(아래 예시 전부 이 방식).
> 그래도 가끔 실패하면 §"OpenCode 사용법" 하단의 `opencode serve` 우회법 참조.

**Playwright MCP (브라우저 자동화):**
```bash
npm install -g @playwright/mcp
npx --yes playwright install chromium   # 브라우저 바이너리(~180MB) 최초 1회 다운로드
which playwright-mcp                    # 설치된 바이너리 경로 확인
```
`~/.config/opencode/opencode.jsonc` (전역 설정, 모든 프로젝트에 공통 적용)에 추가:
```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "playwright": {
      "type": "local",
      "command": ["playwright-mcp", "--headless"],
      "enabled": true
    }
  }
}
```
`opencode mcp list`로 `connected` 상태 확인.

**Context7 MCP (최신 라이브러리 문서 조회) — ⚠ 클라이언트에 인터넷이 있을 때만:**

Context7은 자체 호스팅이 불가능해 요청마다 Context7의 외부 클라우드 API(context7.com)를 직접
호출합니다. **AI 추론 스택(vLLM/LiteLLM, RTX PRO 6000 서버)은 폐쇄망이라 여기서는 절대 쓸 수
없지만**, OpenCode를 실행하는 클라이언트 PC가 사내망 프록시 등으로 별도 인터넷 접근이 가능한
경우에는 그 PC에서 로컬 프로세스로 기동해 사용할 수 있습니다(LLM 추론 자체는 여전히 사내
LiteLLM 경유, Context7 조회만 외부로 나감). **본인 PC가 인터넷이 안 되는 완전 폐쇄망이면 이 MCP는
연결에 실패하니 설치하지 마세요.**

```bash
npm install -g @upstash/context7-mcp
which context7-mcp
```
```jsonc
// ~/.config/opencode/opencode.jsonc 의 "mcp" 안에 추가
"context7": {
  "type": "local",
  "command": ["context7-mcp"],
  "enabled": true
}
```
도구 이름은 `context7_resolve-library-id`, `context7_query-docs` 처럼 **언더스코어(`_`)** 형식입니다
(점(`.`) 표기로 호출하면 `Invalid Tool` 오류 발생). 사용 예: "context7 도구로 React 최신 문서 찾아줘".

**PDF Reader MCP (PDF 텍스트 추출 + 스캔 이미지 OCR):**

`@modelcontextprotocol/server-pdf`(공식 패키지)는 **Claude Desktop류의 UI-호스팅 클라이언트 전용**
(인터랙티브 뷰어를 여는 방식)이라 **OpenCode(터미널 전용)에는 도구 자체가 노출되지 않음을 실측
확인**— 이 패키지는 쓰지 말 것. 대신 순수 텍스트/OCR 추출 전용인 `@sylphx/pdf-reader-mcp`를 쓴다
(로컬 우선, `pdfjs-dist` 기반, 외부 API 호출 없음 — 폐쇄망 가능).

스캔 문서 OCR을 쓰려면 tesseract를 먼저 설치(sudo 필요):
```bash
sudo apt-get install -y tesseract-ocr tesseract-ocr-kor tesseract-ocr-eng
```
```bash
npm install -g @sylphx/pdf-reader-mcp
which pdf-reader-mcp
```
```jsonc
// ~/.config/opencode/opencode.jsonc 의 "mcp" 안에 추가
"pdf-reader": {
  "type": "local",
  "command": ["pdf-reader-mcp"],
  "environment": {
    "MCP_PDF_OCR_COMMAND": "tesseract",
    "MCP_PDF_OCR_ARGS_JSON": "[\"{input}\", \"stdout\", \"-l\", \"kor+eng\", \"tsv\"]"
  },
  "enabled": true
}
```
도구 이름은 `pdf-reader_read_pdf`(선택적 텍스트+OCR 자동 판별), `pdf-reader_search_pdf`,
`pdf-reader_pdf_evidence`(페이지 렌더링/영역 크롭/OCR 개별 실행). 사용 예: "pdf-reader 도구로
`/절대/경로/파일.pdf` 읽어줘". **⚠ 이미지 안의 도표·차트·사진 같은 시각 내용 자체를 모델이 "이해"하는
건 별개 문제다** — 현재 운영 메인 모델(`gpt-oss-120b`)은 텍스트 전용(비전 미지원)이라, OCR로 뽑아낸
**텍스트**는 읽을 수 있어도 이미지 자체의 시각적 의미는 해석할 수 없다(비전 지원 모델 도입 시 별도 검토 필요).

**VS Code(Continue)에서 쓰려면** `~/.continue/config.yaml`에 별도 형식으로 추가(OpenCode와 설정 파일
형식이 다름 — Continue는 `mcpServers` 최상위 키 사용). GUI 프로세스는 셸 PATH(`.bashrc`)를 상속하지
않을 수 있어 **절대경로**로 지정할 것(`which pdf-reader-mcp`로 확인한 경로):
```yaml
mcpServers:
  - name: pdf-reader
    type: stdio
    command: /home/<사용자>/.local/nodejs/bin/pdf-reader-mcp   # which pdf-reader-mcp 결과로 교체
    env:
      MCP_PDF_OCR_COMMAND: tesseract
      MCP_PDF_OCR_ARGS_JSON: '["{input}", "stdout", "-l", "kor+eng", "tsv"]'
```
설정 후 VS Code 재시작 필요. 실사용 검증 완료(2026-07-13, Continue 채팅에서 "pdf-reader 도구로 ~ 읽어줘"
요청 시 정상 동작).

> ⚠ **`neon` MCP는 사용하지 마세요.** Neon사의 클라우드 Postgres 전용 관리 도구로, 우리는 자체
> 호스팅 PostgreSQL을 쓰므로 애초에 해당 사항이 없습니다(CLAUDE.md §2-5 외부 클라우드 컴포넌트 금지).

### MCP 서버 사용법 요약

설치가 끝났다면, 채팅창에 아래처럼 **"어떤 도구를 쓸지"를 자연어로 직접 언급**하면 모델이 알아서 정확한
도구를 찾아 호출합니다(도구 이름을 정확히 몰라도 됨 — "context7 도구로", "pdf-reader 도구로" 처럼
서버 이름만 언급하면 충분).

| MCP 서버 | 언제 쓰나 | 예시 프롬프트 |
|---|---|---|
| **playwright** | 웹페이지 내용 확인, 사내 웹 UI 테스트, 스크린샷 | "playwright 도구로 http://localhost:4000/health 열어서 응답 보여줘" |
| **context7** (인터넷 되는 PC만) | 최신 라이브러리/프레임워크 공식 문서 조회(모델이 알고 있는 옛날 API가 아니라 최신 버전 기준) | "context7 도구로 React 19의 useEffect 최신 사용법 찾아줘" |
| **pdf-reader** | PDF 문서 텍스트 추출, 스캔 이미지 OCR, PDF 안에서 특정 단어 검색 | "pdf-reader 도구로 /home/kim/spec.pdf 읽어서 요약해줘" · "pdf-reader 도구로 이 PDF에서 '계약금액' 부분 찾아줘" |

- 도구 호출이 실제로 됐는지는 채팅 응답 위에 `⚙ 도구이름 {...}` 같은 표시가 뜨는지로 확인할 수 있습니다
  (안 뜨고 바로 답만 나오면 모델이 자기 지식으로만 답한 것 — 원하는 결과가 아니면 "실제로 `pdf-reader`
  도구를 호출해서"처럼 더 명확히 요청해보세요).
- pdf-reader는 **텍스트만** 다룹니다. PDF 안의 그래프·사진·도표를 모델이 "보고 설명"하는 건 안 됩니다
  (§위 pdf-reader 안내 참조 — 현재 메인 모델이 텍스트 전용이라 비전 입력 자체가 불가능합니다).
- **⚠ 큰 PDF(수십 페이지 이상, 특히 요구사항서·설계서 등 텍스트 많은 문서)는 처음부터 나눠서
  읽어달라고 요청하세요.** 통째로 읽게 두면 문서 내용이 모델의 컨텍스트 한도(32768토큰)를 넘겨
  `max_tokens must be at least 1, got -N` 오류로 요청이 아예 실패할 수 있습니다(실측 확인, 초과분이
  수백~수천 토큰까지도 발생). 처음 요청할 때부터 이렇게 범위를 지정하면 예방됩니다:
  ```
  pdf-reader 도구로 [파일] 을 auto_detail: "fast", pages: "1-5" 옵션으로 읽어줘
  ```
  - `auto_detail: "fast"` — 표/신뢰도 증거 같은 부가 데이터를 빼고 핵심 텍스트만 가져와 훨씬 가벼움
    (기본값 `"balanced"`보다 크게 작음)
  - `pages: "1-5"` — 문서 전체가 아니라 지정한 페이지만. 문서가 길면 `"6-10"`, `"11-15"`처럼 나눠서
    여러 번 요청 → 이전 요청에서 파악한 내용을 참고해 다음 구간을 이어서 확인하는 방식으로 진행
  - 문서 전체를 매번 나누지 않고 한 번에 다루는 일이 잦다면 운영팀에 문의하세요(서버 컨텍스트 한도
    자체를 늘리려면 VRAM 재튜닝이 필요한 별도 작업입니다).

**`opencode run`이 MCP 도구를 못 찾을 때(가끔 발생):**

`npx` 제거로 크게 줄었지만 완전히 없어지진 않는다. 재현되면 지속 서버로 우회:
```bash
opencode serve --port 4097 &                              # 백그라운드로 서버 기동, MCP 연결 완료까지 대기
opencode run --attach http://127.0.0.1:4097 "..."          # 매번 새로 붙지 않고 이미 연결된 서버 재사용
```
대화형 TUI(`opencode` 단독 실행)나 VS Code(Continue)는 세션이 오래 유지돼 이 경쟁이 사실상 발생하지
않는다 — 위 우회는 `opencode run` 스크립트/자동화 용도에만 필요하다.

---

## 4. VS Code (Continue 확장) 사용법

### 설치 (운영팀이 사전 배포했을 수 있음)
1. VS Code 확장에서 **Continue** 설치
2. 저장소의 **`continue-config.yaml.example`**을 `~/.continue/config.yaml`로 복사(경로 정확해야 인식됨),
   `apiBase`의 서버 주소와 `apiKey`의 본인 가상 키만 교체. 참고용 내용:

```yaml
name: On-Prem AI
version: 0.0.1
schema: v1
model: litellm-onprem/main-gptoss
models:
  - name: gpt-oss-120b (채팅·편집)
    provider: openai
    model: main-gptoss
    apiBase: http://<사내서버>:4000/v1
    apiKey: sk-...본인키...
    roles: [chat, edit, apply]
  - name: StarCoder2 (자동완성)
    provider: openai
    model: autocomplete-starcoder2
    apiBase: http://<사내서버>:4000/v1
    apiKey: sk-...본인키...
    roles: [autocomplete]
```

### 채팅 사용
1. 왼쪽 사이드바 **Continue 아이콘(∞)** 클릭 (안 보이면 `Ctrl+Shift+P` → `Continue: Focus on Continue View`)
2. 채팅창 아래 **모델 드롭다운**에서 **Llama** 선택(채팅 모델은 이거 하나뿐입니다)
3. 질문 입력. 코드를 선택하고 `Ctrl+L` → "이 함수 설명해줘" 처럼 사용.

### tab 자동완성 사용
1. **코드 편집기**에서 타이핑하거나 잠시 멈추면 → **회색 inline 제안**이 뜸
2. **`Tab`** 으로 수락, `Esc` 로 무시
3. StarCoder2가 자동 담당하므로 모델 선택은 필요 없습니다.

> 💡 자동완성 모델(StarCoder2)은 **채팅 모델 드롭다운에 안 보입니다 — 정상입니다.** 채팅용이 아니라 자동완성 전용이기 때문입니다.

---

## 5. 보안 정책 (사용 시 알아둘 것)

### 민감정보는 자동 처리됩니다
- **주민등록번호**를 입력하면 `<KR_RRN_1>` 로 **자동 마스킹**되어 모델에 전달됩니다.
- **DB 비밀번호/시크릿**(예: `password=...`, `postgres://user:pw@...`)이 포함되면 요청이 **차단(HTTP 400)** 됩니다 — 보안 학습을 위한 의도된 동작입니다.
- 이메일·전화번호·카드번호도 마스킹됩니다.

→ **시크릿/개인정보를 프롬프트에 넣지 마세요.** 차단되거나 마스킹되어 의도한 답을 못 받을 수 있고, 모든 요청은 감사 로그에 남습니다.

### 사용량 한도 (Rate Limit)
- 키 등급별 분당 요청수(RPM)·토큰 한도가 있습니다. 초과 시 **HTTP 429**(잠시 후 재시도) 가 반환됩니다.
- 일반 개발자: 60 RPM. 과도한 자동화/반복 호출은 한도에 걸릴 수 있습니다.

### 감사(Audit)
- 모든 요청(누가·언제·어떤 모델·프롬프트·응답)이 사내 DB에 기록됩니다(프롬프트는 PII 마스킹 후 저장).
- 정상적인 개발 용도 사용에는 영향 없습니다.

---

## 6. 자주 묻는 질문 (FAQ)

**Q. 자동완성(회색 제안)이 안 떠요.**
- 코드 **편집기**에서 타이핑하셨나요? (채팅 패널이 아니라 코드 파일)
- Continue가 활성화됐는지: 사이드바 Continue 아이콘을 한 번 클릭하거나 `Ctrl+Shift+P` → `Continue: Focus on Continue View`.
- 그래도 안 되면 `Ctrl+Shift+P` → `Continue: Toggle Autocomplete Enabled` 로 켜기.

**Q. "403 / key not allowed to access model" 오류가 나요.**
- 키에 해당 모델 권한이 없습니다. 운영팀에 사용하려는 모델(예: autocomplete)을 알리고 키 권한 추가를 요청하세요.

**Q. "429" 오류가 나요.**
- 사용량 한도 초과입니다. 잠시 후 재시도하거나, 지속적으로 필요하면 운영팀에 등급 상향을 요청하세요.

**Q. 요청이 차단(400)됐어요.**
- 프롬프트에 DB 비밀번호/시크릿 패턴이 포함됐을 수 있습니다. 민감정보를 빼고 다시 시도하세요.

**Q. 외부 인터넷 AI처럼 최신 정보를 물어봐도 되나요?**
- 이 모델들은 사내 폐쇄망에서 동작하며 외부 검색을 하지 않습니다. 코드/기술 작업에 활용하세요.

**Q. OpenCode 화면 오른쪽 "Context" 패널이 계속 `0 tokens / 0% used / $0.00 spent`로 고정돼 있어요.**
- **실제 대화/컨텍스트 사용량이나 요금과는 무관한 표시 버그**입니다(2026-07-21 확인) — 서버는 토큰을
  정상적으로 세고 있고, 응답 품질이나 잘림 현상과도 관계없습니다. 원인은 LiteLLM 게이트웨이가
  스트리밍 응답 끝에 붙는 토큰 사용량(usage) 정보를 클라이언트로 전달하지 못하는 LiteLLM 자체의
  알려진 버그 2건이 겹친 것입니다(상세: 완료보고서 §19.12). 임시 조치(몽키패치)를 적용해 대부분의
  경우 정상적으로 숫자가 표시되도록 했습니다 — 그래도 계속 0으로 보이면:
  - LiteLLM 컨테이너가 최근 재시작됐는지 확인(`docker compose ps litellm`), 재시작 직후라면 몇 번
    더 요청해보세요.
  - 그래도 반복되면 운영팀에 알려주세요 — 근본 해결책(중계 프록시로 전환)이 이미 설계돼 있어 필요시
    적용할 수 있습니다.
  - 이 표시가 0이어도 실제 대화 진행·응답 품질에는 영향이 없으니, 급한 작업 중이라면 무시하고
    계속 사용하셔도 됩니다.

**Q. `max_tokens must be at least 1, got -N` 오류가 나요(주로 `/opsx:explore` 등 스킬/긴 대화 중 발생).**
- **초과분이 작을 때(수십 토큰 이내):** `opencode.json`의 `context` 값이 서버 실제 한도(`32768`,
  2026-07-14 재튜닝 이전엔 `27648`)와 정확히 같으면, 스킬 프롬프트+대화 이력이 조금만 늘어나도 남은
  토큰 계산이 음수가 되어 발생합니다(2026-07-13 실측 확인·수정됨). `opencode.json`의
  `models.main-gptoss.limit.context`를 `32768`보다 여유 있게(예: `30000`) 낮추면 해결됩니다 —
  배포용 `opencode.json.example`에는 이미 반영되어 있습니다.
- **초과분이 클 때(수백~수천 토큰, 주로 `pdf-reader`로 큰 PDF를 읽을 때):** 설정 여유 문제가 아니라
  **문서 자체가 커서** 스킬 프롬프트+문서 내용을 합치면 컨텍스트 한도(32768토큰)를 실제로 넘어서는
  경우입니다. `output`(답변 예산)을 줄이는 건 gpt-oss가 harmony 포맷상 답변 완결에 많은 토큰이
  필요해서(§확장 기능 절 참조) 답이 다시 잘리는 문제를 일으키므로 권장하지 않습니다. 대신 **PDF를
  나눠서 읽도록 명시적으로 요청**하세요:
  ```
  pdf-reader 도구로 [파일] 을 auto_detail: "fast", pages: "1-5" 옵션으로 읽어줘
  ```
  `auto_detail: "fast"`는 표/신뢰도 증거 같은 부가 데이터를 빼고 핵심 텍스트만 가져와 훨씬 가볍고,
  `pages`로 필요한 구간만 나눠 여러 번 요청하면 큰 문서도 처리할 수 있습니다. 큰 문서를 자주 다뤄야
  한다면 운영팀에 문의하세요(서버 컨텍스트 한도 자체를 늘리려면 VRAM 재튜닝이 필요한 더 큰 작업입니다).
- **같은 세션에서 계속 반복될 때(한 세션 안에서 `/opsx:explore` 등을 여러 번 이어서 실행 → 매번 초과분이
  점점 커지며 -N 값도 커짐):** 이건 설정이나 문서 크기 문제가 아니라 **그 세션 자체가 한도를 넘어선
  상태로 굳어진 것**입니다. OpenCode의 자동 컨텍스트 압축이 우리 모델의 좁은 컨텍스트(30000)에서는
  제때 발동하지 않는 경우가 있어(2026-07-13 실측: 세션이 한도를 넘긴 뒤 이후 모든 메시지가 예외 없이
  같은 오류로 실패, 초과분이 -2036→-2053→-2070으로 계속 증가), 한 번 이 상태가 되면 그 세션에서는
  더 이상 정상 응답을 받을 수 없습니다. **해결: 그 세션을 계속 쓰지 말고 새 세션을 시작**하세요(작업
  상태는 대화 기억이 아니라 `openspec/changes/` 폴더의 파일에 저장되므로, 새 세션에서 이어서
  진행해도 지금까지의 진행 상황은 그대로 유지됩니다). 특히 `/opsx:explore`를 같은 세션에서 여러 번
  이어 붙이거나 큰 PDF를 여러 번 읽으면 이 상태에 빠지기 쉬우니, **OpenSpec 단계(explore→propose→
  apply)마다 새 세션으로 시작하는 것을 권장**합니다.

---

## 7. 도움 요청
- 키 발급/권한/한도 → **운영팀**
- 모델 응답 품질·기능 문의 → 운영팀 경유 (모델 구성은 `OPERATOR_GUIDE.md` 참조)
- 키 유출 의심 시 → **즉시 운영팀에 알려 폐기** 요청
