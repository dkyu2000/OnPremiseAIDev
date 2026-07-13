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
프로젝트 루트에 `opencode.json` 이 있거나, 아래처럼 구성합니다(운영팀이 배포한 템플릿 사용 권장):

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

### 사용
```bash
opencode                                   # 대화형 TUI 실행
opencode run "이 함수의 시간복잡도는?"       # 비대화형 한 번 실행
```
- TUI 안에서 `/models` 로 모델 전환, 일반 대화처럼 질문/지시.
- main-gptoss는 도구(bash/파일편집)를 사용해 실제 작업을 수행합니다.

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
2. 사용자 설정 `~/.continue/config.yaml` 작성:

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

---

## 7. 도움 요청
- 키 발급/권한/한도 → **운영팀**
- 모델 응답 품질·기능 문의 → 운영팀 경유 (모델 구성은 `OPERATOR_GUIDE.md` 참조)
- 키 유출 의심 시 → **즉시 운영팀에 알려 폐기** 요청
