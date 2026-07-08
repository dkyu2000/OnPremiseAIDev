# REQUIREMENTS.md — 검증 환경 요구사항

본 문서는 폐쇄망 On-Premise AI 인프라 **검증 환경**의 기능/비기능 요구사항을 정의한다.
운영 제안서(`On-Premise_AI_개발_환경_구축`)의 거버넌스 요구를 테스트 장비(RTX 5090 32GB, SM120)에서
**구현 가능한 형태**로 옮긴 것이다. 각 항목은 **수용 기준(AC)** 으로 검증한다.

---

## 0. 검증 범위

### 0.1 In Scope (이 장비에서 검증)
- 추론 엔진(vLLM) SM120 기동·FP8 정합성, 멀티 모델 동시 서빙 패턴
- 게이트웨이(LiteLLM): 3-Tier 키 정책, Rate Limit, Audit, PII 마스킹, 라우팅
- 클라이언트(OpenCode/IDE) End-to-End 연동
- 오프라인 모델 업데이트 워크플로우, 백업/복구

### 0.2 Out of Scope (운영 장비/추후 단계)
- Llama 3.3-70B 풀스케일 서빙 및 성능 측정 → **운영 장비(96GB)**
- 50인 동시 접속 부하 테스트 → 운영 장비 (단, 소규모 동시성 스모크는 본 환경에서 수행)
- RAG / Vector DB 연동 → 운영 Phase 4

### 0.3 라이선스 정책 (확정: LiteLLM 무료 OSS 전용)
**LiteLLM은 무료(OSS) 버전만 사용한다. Enterprise 라이선스는 채택하지 않으며 `LITELLM_LICENSE` 키를 설정하지 않는다.**
- **OSS로 충분(사용):** 가상 키, 예산/Rate Limit(rpm/tpm/budget), 모델 allowlist, 콜백 기반 로깅, **Presidio PII 마스킹**, 커스텀 가드레일.
- **Enterprise 기능(미사용):** 관리형 Audit Log 보존정책, SSO/SAML, 자동 키 로테이션, 호스티드 가드레일(Lakera/Aporia 등 — 폐쇄망에서도 불가).
- → 따라서 Audit(FR-5)·키 로테이션(FR-3)·이상탐지(FR-7)는 **OSS 콜백/스크립트로 자체 구현**한다(설계 기본값, 선택 아님).

---

## 1. 기능 요구사항 (FR)

### FR-1. 추론 서빙 (vLLM)
- vLLM v0.17.0+로 OpenAI 호환 API(`/v1/...`) 제공. `VLLM_FLASH_ATTN_VERSION=2`.
- 모델 구성은 `CLAUDE.md §5`를 따른다. **운영 채택(2026-07-08 갱신): Llama 3.3-70B NVFP4(main) + StarCoder2-15B FP8(autocomplete) 2-트랙만.**
  구 채택(FP8 70B+FIM 7B, 2026-07-07)은 VRAM 여유가 30MiB로 타이트했고 NVFP4 전환으로 대체됨(품질도 FIM 15B가 개선).
  Gemma 서브 트랙(2-27B 단일 / Llama 8B+Gemma 9B 듀얼)은 Phase B/C에서 검증 통과했으나 운영 미채택(역사적 기록).
- **AC:** `curl /v1/chat/completions`가 정상 응답하며, 출력에 garbage character가 없다. `/health` 200.

### FR-2. 게이트웨이 (LiteLLM)
- OpenAI 호환 엔드포인트를 포트 **4000**으로 제공, 백엔드 vLLM(8000 main / 8003 autocomplete)을 프록시.
  (8001 sub은 Phase B 역사적 검증 전용, 운영 미사용)
- 마스터 키는 서버 측에만, 클라이언트는 가상 키 사용. PostgreSQL 백엔드.
- **AC:** 가상 키로 `/v1/chat/completions` 호출 성공, 마스터 키 미노출.

### FR-3. 3-Tier API Key 정책
역할별 가상 키를 발급하고 한도·모델 권한을 차등 적용한다(제안서 기준).

★[2026-07-07 갱신] 서브 채팅 모델을 운영에서 사용하지 않기로 확정 → 전 역할이 **main + autocomplete**만 사용하며,
역할 차등은 RPM/토큰 한도로만 구분한다(모델 allowlist 차등 없음).

| 역할 | RPM | 일 토큰 | 사용 가능 모델 |
|------|-----|---------|----------------|
| 관리자 | 무제한 | 무제한 | main + autocomplete + 관리 콘솔 |
| 시니어 개발자 | 120 | 200K | main + autocomplete |
| 일반 개발자·PM | 60 | 100K | main + autocomplete |

- 발급은 `/key/generate`에 `rpm_limit`, `tpm_limit`(또는 `max_budget`/`budget_duration`), `models`(allowlist) 포함.
- 키 라이프사이클: 1인 1키, 90일 강제 로테이션(스크립트), 퇴사/이동 시 즉시 비활성화.
- **AC:** 일반 키로 한도 초과 시 자동 거부(명확한 오류). 일반 키로 허용되지 않은 모델 요청 시 거부.
  90일 로테이션 스크립트가 신규 키 발급 + 구 키 폐기를 수행.

### FR-4. Rate Limiting
- 키별 RPM/TPM 및 예산 한도. 초과 시 **429 + Retry-After**.
- **AC:** RPM 초과 부하 시 429 반환 및 Retry-After 헤더 존재. 한도 리셋 후 정상화.

### FR-5. Audit Trail (5종 필드)
모든 요청/응답을 아래 5필드로 비동기 적재(Audit DB).

| # | 필드 | 내용 |
|---|------|------|
| 1 | WHO | `user_id` / `api_key_id` (익명 요청 불가) |
| 2 | WHEN | `timestamp` (KST, ms) + latency |
| 3 | MODEL | 라우팅 결과 모델 + token 수 |
| 4 | PROMPT | 프롬프트 + 해시(위변조 검증), PII는 마스킹 후 적재 |
| 5 | OUTPUT | 응답 본문 + `finish_reason` |

- LiteLLM 로깅 콜백(커스텀)으로 DB 적재. 동기 응답 경로를 막지 않는다(async).
- **AC:** 임의 요청 1건이 5필드 모두 채워져 DB에 적재됨. PROMPT 필드의 PII가 마스킹 상태로 저장됨.

### FR-6. Prompt Inspection / PII 마스킹
- **Presidio**(자체 호스팅) 가드레일로 민감정보(주민번호, DB 비밀번호, 이메일, 전화 등) 탐지.
- 모드: 요청 전 마스킹(`pre_call`/`during_call`), 응답 마스킹(`output_parse_pii: true`), 로그 마스킹.
- **AC:** 주민번호/DB 비밀번호 패턴 포함 요청 시 모델 입력·로그에서 해당 값이 마스킹/차단됨. 위반 시 **차단 + 사유** 반환(개발자 학습 효과).
  - **[검증 실측]** LiteLLM presidio 가드레일의 BLOCK 응답 코드는 **HTTP 400**(예: `Blocked entity detected: DB_SECRET by Guardrail: presidio-pii`)이다. 제안서의 "422"는 LiteLLM OSS 기본 동작과 다름 → 실측 400으로 확정. 차단+학습용 사유 반환이라는 취지는 충족.

### FR-7. 이상 탐지 (Anomaly Detection)
- 룰 예시: ① 토큰량이 사용자 평균 대비 **5배** 초과, ② 동일 사용자 **시간당 300건** 초과.
- Audit DB 기반 배치/스트림 룰로 구현(폐쇄망 내 자체). 위반 시 경보/플래그.
- **AC:** 합성 트래픽으로 두 룰이 각각 트리거되어 경보 레코드가 생성됨.

### FR-8. 모델 라우팅
★[2026-07-07 갱신] 서브 채팅 모델 운영 미채택 확정 → **작업 유형과 무관하게 채팅/에이전트는 전부 main, IDE tab
자동완성만 autocomplete로 분기**하는 2-분기 구조로 단순화. 아래는 그 갱신된 매트릭스다:

| 작업 유형 | 토큰 | 결과 |
|-----------|------|------|
| **IDE tab 자동완성(라인/블록)** | <4K | **autocomplete (StarCoder2-7B FIM)** |
| 짧은 Q&A·채팅 | any | main (Llama) |
| CLI Agent 단순 명령 | any | main |
| JIRA 티켓 분석 | any | main |
| 로그 분석/원인 추적 | any | main |
| 기술 문서 작성 | any | main |
| 복잡 알고리즘 설계 | any | main |
| CLI Agent 복합 워크플로우 | any | main |

> ★**[검증 정정 2026-06] tab 자동완성은 sub(Gemma)가 아니라 FIM 전용 코드 모델로 분기한다.**
> Llama/Gemma 등 instruct 모델은 FIM(Fill-in-the-Middle) 토큰이 없어 prefix+suffix 기반 inline 자동완성이
> 불가하다(실측: 두 모델 tokenizer에 FIM 토큰 없음). StarCoder2-7B(FP8, BigCode, 비중국계)는 FIM 토큰 보유 →
> SM120에서 inline 자동완성 정상 동작 확인. 자동완성은 `/v1/completions`(prompt+suffix), 채팅/에이전트는
> `/v1/chat/completions` 로 경로 자체가 다르다.

> ★**[2026-07-07 운영 결정] 서브 채팅 모델(Gemma 트랙) 미채택.** Phase B(2-트랙 라우팅)·Phase C(27B 서브 실검증) 모두
> 기술적으로는 검증 통과했으나, 단일 채팅 모델로 라우팅을 단순화하는 편이 운영 복잡도·장애 지점 관리에 유리하다고
> 판단해 서브 트랙은 채택하지 않는다(2026-07-07 시점 구성은 VRAM 여유도 ~1.4GB로 타이트했으나, 2026-07-08 main
> NVFP4 전환 후에는 여유 ~4.5GB로 개선됨 — 단, 서브 미채택 결정 자체는 VRAM 문제와 무관하게 유지). main 실패
> 시 sub로 넘길 대상 자체가 없으므로 **fallback 라우팅도 사용하지 않는다**(연결 안 된 백엔드로 fallback 시도
> 시 원인이 가려지는 이중 오류가 발생함이 실측 확인됨 → `litellm/config.yaml` fallback 제거).

- 예외: ① `model=` 명시 시 권한 범위 내 직접 사용, ② Rate Limit 초과 429, ③ 보안 위반 400(PII BLOCK, 실측), 권한 위반 403.
- **AC:** 매트릭스 대표 케이스가 의도한 모델로 라우팅됨(채팅/에이전트→main, tab 자동완성→autocomplete).

### FR-9. 클라이언트 연동 (OpenCode + IDE)
- OpenCode(및 VS Code/IntelliJ 플러그인)를 LiteLLM(4000) + 가상 키로 연결.
- **AC:** IDE에서 발생한 자동완성/채팅 요청이 게이트웨이를 거쳐 응답되고, 해당 요청이 Audit에 기록됨.

### FR-10. 오프라인 모델 업데이트 워크플로우
4단계: ① 인터넷 분리망에서 모델/이미지 다운로드 → ② **SHA-256 + 라이선스 + 취약점 스캔(Trivy 등)** →
③ 승인 매체(보안 USB/Data Diode)로 사내망 이송, 사설 레지스트리 적재 → ④ **Blue/Green** 무중단 배포 + 롤백.
- **AC:** 사전 스테이징된 가중치/이미지의 체크섬 검증 통과 후, 신규 인스턴스 카나리 → 트래픽 전환 → 롤백이 동작.

### FR-11. 백업/복구
- 대상: OS 설정, Docker Compose, LiteLLM 설정, 키/스펜드 DB(Postgres), (추후 Vector DB).
- **AC:** 백업본으로 스택을 **24시간 이내** 재기동하여 키·정책·로그가 복원됨.

---

## 2. 비기능 요구사항 (NFR)

- **NFR-1 폐쇄망:** 런타임 외부 통신 0. 모든 의존성 사전 반입. 외부 IP/도메인 Outbound Drop 전제로 동작.
- **NFR-2 재현성:** OS/드라이버/CUDA/이미지/모델 버전 전부 고정 기록. `latest` 금지. 동일 절차로 재구축 가능.
- **NFR-3 SM120 패리티:** 모든 설정은 운영 RTX PRO 6000(동일 SM120)으로 이전 가능해야 함. GPU별 하드코딩 금지(VRAM 분할값 등은 파라미터화).
- **NFR-4 단일 노드:** 단일 GPU·단일 호스트 구성. 멀티 GPU 가정 금지.
- **NFR-5 보안:** 시크릿 분리(.env/secrets), 최소 권한, 마스터 키 비노출, 키 90일 로테이션.
- **NFR-6 관측성:** vLLM/LiteLLM 로그 수집, 기본 메트릭(요청 수/지연/토큰) 확인 가능.

---

## 3. 운영 제안서로의 피드백 항목

**[확정]** 표시는 결정 완료, **[검증]** 은 검증 결과로 판정.

- **[확정] OS/드라이버/CUDA:** 제안서의 `22.04 / 550 / 12.4`는 Blackwell 부적합 → **`Ubuntu 26.04 LTS / Driver 570+ / CUDA 12.8+`로 갱신**(테스트=운영 동일). 검증장비 실측: Ubuntu 26.04 LTS / 커널 7.0.0-22-generic / Driver 595.71.05(open 커널 모듈). 제안서 본문을 이 사양으로 수정한다.
- **[확정] 운영 OS:** 제안서 HW표의 "Windows 11 Pro" 표기를 **Ubuntu 26.04 LTS(네이티브 Linux)**로 확정(WSL2 Blackwell hang 이슈 회피). 운영 RTX PRO 6000 장비도 동일 26.04 베이스라인으로 정렬(NFR-2 재현성).
- **[확정] LiteLLM 라이선스:** **무료(OSS) 버전만 사용**. Enterprise 미채택(§0.3). Audit/키 로테이션/이상탐지는 OSS 콜백·스크립트로 자체 구현.
- **[판정완료] FP4 듀얼 모델 → 조건부 Go (2026-06-29 실측):** 검증장비(5090, SM120)에서 **NVFP4(W4A4) Llama 3.1-8B 기동 성공**.
  vLLM 0.17.1 이 `NvFp4LinearBackend.FLASHINFER_CUTLASS` FP4 GEMM 경로를 사용(Marlin 음수스케일 버그 회피) — garbage 없는 정상
  추론(영/한), VRAM ~19GB(FP8의 절반), throughput 163.8 tok/s(8B 단일요청). **SM120 FP4 경로가 실동작**하므로 운영
  RTX PRO 6000(동일 SM120)에 이전 가능. → 운영 "70B-NVFP4(~38GB) + 27B-FP8(~27GB) + FIM(~7GB)" 3-트랙이 96GB에서 성립.
  **잔여 조건(운영 검증 과제):** ① 70B/27B NVFP4 체크포인트 가용성·출처 확정, ② 96GB 장비에서 `70B-FP8 vs 70B-NVFP4` 최종 품질 비교.
  **PoC 품질 비교(`docs/POC_FP4_QUANT_COMPARISON.md`, 2026-06-30):** 8B-FP8 / 8B-NVFP4 / 24B-NVFP4 3-way 측정 결과 —
  까다로운 추론에선 **모델 크기 ≫ 양자화**(24B-NVFP4 가 8B-FP8 압도) → 70B-NVFP4 전략 지지. 단 **FP4 반복붕괴(degeneration)
  리스크는 작은 모델 한정**(8B-NVFP4 긴 한국어 추론에서 붕괴, 24B-NVFP4 안정) → **대형=NVFP4 / 소형(자동완성·서브)=FP8** 권장.
  ★[2026-07-07 운영 결정] 27B-FP8 **서브**를 포함한 3-트랙 구성은 서브 채팅 모델 미채택 결정에 따라 운영에
  적용하지 않는다. ★[2026-07-08 운영 결정 갱신] 다만 **main의 NVFP4 자체는 채택**한다 — main만 NVFP4(가중치
  ~40GB)로 바꾸면 서브 없이도 VRAM이 크게 절감되어(구 FP8 2-트랙 대비 여유 30MiB→~4.5GB) **FIM 모델을
  StarCoder2-7B→15B로 상향**할 수 있고, 실측상 15B가 7B보다 FIM 완성 품질이 개선됨을 확인(garbage 텍스트
  발생 빈도 감소, 자연스러운 stop 비율 개선). 이 2-트랙(NVFP4 main + FIM 15B)이 현재 최종 채택 구성이다.
- **[확정] IDE tab 자동완성 = FIM 전용 코드 모델 추가:** Llama 3.3-70B/Gemma 2(instruct)는 FIM 미지원이라 제대로 된
  tab 자동완성 불가(실측 확인). → **자동완성 전용 FIM 코드 모델**(StarCoder2/CodeLlama 등, 비중국계)을
  별도 배포해야 한다. 검증장비(5090)에서 StarCoder2-7B FP8 FIM inline 자동완성 SM120 동작 확인.
  **운영 최종 채택 구성(96GB 단일 카드, 2026-07-08 갱신): Llama 3.3-70B NVFP4(채팅·에이전트) + StarCoder2-15B FP8(자동완성) 2-트랙**
  (가중치 합 ~55GB, GPU 총사용 ~90.5GB/여유 ~4.5GB — 상세 실측치는 완료보고서 §13).
  제안서의 "자동완성 → Gemma" 표기를 "자동완성 → FIM 코드 모델"로 수정한다.
