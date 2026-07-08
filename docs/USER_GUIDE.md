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
| **main-llama** (Llama 3.3-70B) | 채팅·코드설명·리팩터링·**에이전트(도구 사용)** | 채팅·편집의 기본(유일한 채팅 모델) |
| **autocomplete-starcoder2** (StarCoder2) | **tab 자동완성** | 코드 편집기에서 자동 동작 |

**핵심 가이드**
- **코드 작성 중 자동완성(회색 제안)** → StarCoder2가 **자동으로** 담당. 모델을 고를 필요 없습니다.
- **채팅으로 질문/리팩터링/에이전트 작업** → **main-llama**를 사용합니다(채팅 모델은 이거 하나뿐입니다).
- ★가벼운 서브 채팅 모델(Gemma)은 운영에서 사용하지 않습니다 — 짧은 질문도 main-llama가 처리합니다.

---

## 3. OpenCode (CLI 에이전트) 사용법

OpenCode는 터미널/IDE에서 동작하는 AI 코딩 에이전트입니다.

### 설정
프로젝트 루트에 `opencode.json` 이 있거나, 아래처럼 구성합니다(운영팀이 배포한 템플릿 사용 권장):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "litellm-onprem/main-llama",
  "provider": {
    "litellm-onprem": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "On-Prem AI",
      "options": {
        "baseURL": "http://<사내서버>:4000/v1",
        "apiKey": "{env:OPENCODE_LITELLM_KEY}"
      },
      "models": {
        "main-llama": { "name": "Llama (채팅·에이전트)" }
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
- main-llama는 도구(bash/파일편집)를 사용해 실제 작업을 수행합니다.

---

## 4. VS Code (Continue 확장) 사용법

### 설치 (운영팀이 사전 배포했을 수 있음)
1. VS Code 확장에서 **Continue** 설치
2. 사용자 설정 `~/.continue/config.yaml` 작성:

```yaml
name: On-Prem AI
version: 0.0.1
schema: v1
model: litellm-onprem/main-llama
models:
  - name: Llama (채팅·편집)
    provider: openai
    model: main-llama
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
