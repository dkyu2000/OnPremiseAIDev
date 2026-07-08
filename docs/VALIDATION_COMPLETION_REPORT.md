# 폐쇄망 On-Premise AI Assistant 인프라 — 검증 완료보고서

| 항목 | 내용 |
|------|------|
| 문서명 | 폐쇄망 On-Premise AI Assistant 인프라 검증 완료보고서 |
| 작성일 | 2026-06-30 |
| 검증 대상 | LG CNS WISE 운영팀(50인) 폐쇄망 AI Assistant 인프라 |
| 검증 환경 | Dell Precision 5860T + RTX 5090 32GB (Blackwell, SM120) |
| 운영 목표 환경 | Dell Precision 7960 + RTX PRO 6000 Blackwell 96GB (동일 SM120) |
| 판정 | **운영 본 구축 Go** (조건부 항목은 §9 참조) |

> **★[2026-07-08 갱신]** 위 §1~10은 테스트 장비(RTX 5090) 검증 완료 시점(2026-06-30) 기록이다.
> 이후 **운영 장비(RTX PRO 6000 96GB)로 실제 Go-Live 전환을 수행**했으며, 그 실행 기록은 **§11 이하**에
> 추가했다. §11에서 서브 채팅 모델(Gemma) 트랙을 운영에서 완전히 폐지하기로 최종 결정했다 — §8의
> 선택지 B/C, §9.2의 NVFP4/Qwen 전환 검토는 이 결정으로 **미채택**되었다(사유는 §11.8 참조).

---

## 1. 검증 배경 및 목적

본 검증은 운영 인프라 **본 도입 전에**, 운영과 **동일한 GPU 아키텍처(Blackwell SM120)** 를 가진 테스트 장비(RTX 5090 32GB)에서 운영 스택 전체를 사전 검증하기 위해 수행되었다.

**핵심 전제 — SM120 동일성:** 테스트 GPU(RTX 5090)와 운영 GPU(RTX PRO 6000)는 동일한 SM120(compute capability 12.0)이다. 따라서 5090에서 해결한 드라이버/CUDA/vLLM/FP8/FP4 이슈는 운영 장비로 **거의 1:1로 이전**된다. 본 검증의 목적은 "70B 성능 측정"이 아니라 **운영 스택 전체(거버넌스·라우팅·클라이언트·운영 워크플로우)의 사전 검증**이다.

**VRAM 제약:** 테스트 장비는 32GB이므로 운영 메인 모델(Llama 3.3-70B, FP8 ~70GB)은 적재 불가하다. 따라서 메인 모델은 **프록시 모델(Llama 3.1-8B)** 로 거버넌스/라우팅 패턴을 검증하고, 운영 서브 모델(Gemma 2-27B)과 양자화(FP8/NVFP4)는 실제로 적재해 실측하였다.

---

## 2. 검증 환경

### 2.1 하드웨어 / 소프트웨어 베이스라인 (실측 확정)

| 계층 | 테스트(실측) | 운영 목표 | 비고 |
|------|------|------|------|
| GPU | RTX 5090 32GB (SM120) | RTX PRO 6000 96GB (SM120) | **동일 아키텍처** |
| OS | Ubuntu 26.04 LTS / 커널 7.0.0 | 동일 베이스라인 | 제안서 22.04 → 갱신 |
| 드라이버 | NVIDIA **595.71.05** (open 커널 모듈) | 동일(570+) | 제안서 v550 → 갱신. Blackwell open 모듈 필수 |
| CUDA | **12.9** (드라이버 13.2 지원) | 동일(12.8+) | 제안서 12.4 → 갱신 |
| 추론 엔진 | **vLLM 0.17.1** / torch 2.10.0+cu129 | 동일 | SM120 FP8/FP4 지원 |
| 컨테이너 | Docker 29.6 + nvidia-container-toolkit 1.19.1 | 동일 | — |
| 게이트웨이 | **LiteLLM v1.89.0 (OSS 무료)** + asyncpg 내장 커스텀 이미지 | 동일 | Enterprise 미사용 |
| PII | Presidio (analyzer/anonymizer 2.2.x) | 동일 | 자체 호스팅 |
| DB | PostgreSQL 16 | 동일 | 키/스펜드/Audit |
| 클라이언트 | OpenCode 1.17 + VS Code + Continue 2.x | 동일 | OpenAI 호환 |

> **제안서 대비 갱신 확정사항:** OS(22.04→26.04), 드라이버(550→595), CUDA(12.4→12.9). Blackwell SM120 은 **open 커널 모듈 필수**이며 proprietary 모듈 사용 시 `nvidia-smi`가 GPU를 인식하지 못한다.

### 2.2 검증 모델 (스테이징 7종)

| 모델 | 양자화 | 용도 | throughput(단일,5090) |
|------|------|------|------|
| Llama 3.1-8B-Instruct | FP8 | 메인 프록시(채팅·에이전트) | 149 tok/s |
| Llama 3.1-8B-Instruct | NVFP4(W4A4) | FP4 디리스킹 | 158~163 tok/s |
| Gemma 2-9B-it | FP8 | 서브 채팅 | — |
| Gemma 2-27B-it | FP8 | **운영 서브 실측** | **49 tok/s** |
| StarCoder2-7B | FP8 | 자동완성(FIM) | 144 tok/s |
| Qwen2.5-Coder-7B | FP8 | 자동완성 대안(FIM) | ~155 tok/s |
| Mistral-Small-24B | NVFP4 | FP4 모델상향 PoC | 72 tok/s |

---

## 3. 시스템 아키텍처

```
 ┌─────────────────────── 개발자 클라이언트 (폐쇄망) ───────────────────────┐
 │   OpenCode (CLI 에이전트)            VS Code + Continue (IDE)            │
 │      └ 채팅·에이전트(tool)              └ 채팅 + tab 자동완성(FIM)        │
 └───────────────────────────────┬──────────────────────────────────────┘
                  OpenAI 호환 API + 가상 키(sk-...) │
                                  ▼
 ┌────────────────── LiteLLM 게이트웨이 (:4000, OSS 무료) ──────────────────┐
 │  · 가상 키 인증 / 3-Tier 권한·Rate Limit (rpm/tpm/모델 allowlist)        │
 │  · PII 가드레일(Presidio) : pre_call 마스킹 + output 마스킹              │
 │  · 라우팅 / Fallback (main→sub)                                         │
 │  · 커스텀 콜백: audit_logger(감사) / gemma_compat / autocomplete_compat │
 └───────┬──────────────────┬──────────────────┬───────────────┬──────────┘
         ▼                  ▼                  ▼               ▼
   vLLM main(:8000)   vLLM sub(:8001)   vLLM autocomplete   vLLM 27b(:8002)
   Llama(채팅·tool)   Gemma(채팅)       StarCoder2/Qwen     Gemma27B(C검증)
         │                  │             (:8003/:8004)
         └──────────────────┴── 단일 GPU 공유(--gpu-memory-utilization 분할) ──┘
                                  │
 ┌────────────────┬───────────────┴───────────────┬────────────────────────┐
 │ PostgreSQL     │ Presidio analyzer(:5002)       │ Presidio anonymizer    │
 │ (키/스펜드/    │  · KR_RRN / DB_SECRET 커스텀    │ (:5001)                │
 │  Audit 로그)   │    recognizer                  │                        │
 └────────────────┴────────────────────────────────┴────────────────────────┘
```

**핵심 설계 원칙**
- **단일 진입점**: 모든 클라이언트는 LiteLLM(:4000)만 접근. vLLM 직접 포트는 디버그용.
- **시크릿 분리**: 마스터 키는 서버 `.env`에만, 클라이언트는 가상 키(sk-...)만 사용.
- **폐쇄망**: 런타임 외부 통신 0. 모든 이미지·가중치 사전 스테이징. PostgreSQL 호스트 포트 미노출.
- **단일 GPU**: 멀티 GPU/텐서 병렬 없음. 한 카드에 여러 vLLM 인스턴스를 VRAM 분할로 동시 상주.
- **Compose 프로파일**: phase-a/b/ide/c/ide-qwen 으로 용도별 기동 분리(VRAM 제약 대응).

---

## 4. 검증 결과 종합

### 4.1 Phase 0 — 환경 베이스라인 ✅
- RTX 5090 인식, Driver 595(open 모듈), 컨테이너 GPU 패스스루(`nvidia/cuda:12.8` 컨테이너에서 GPU 인식) 확인.
- 컨테이너 내부 capability `(12,0)` = SM120, CUDA 12.9, torch 2.10 확인.
- OS/드라이버/CUDA 베이스라인 확정 및 문서 고정(재현성).

### 4.2 Phase A — 거버넌스 (A-1 ~ A-8) ✅
| 항목 | 검증 내용 | 결과 |
|------|------|------|
| A-1 서빙/추론 | Llama 3.1-8B FP8, `/health` 200, garbage 없는 정상 출력 | ✅ SM120 FP8 GEMM 정상 |
| A-2 3-Tier 키/Rate Limit | admin/senior/developer 차등 발급, 모델 allowlist | ✅ 미허용 모델 403, RPM 초과 429+Retry-After |
| A-3 Audit Trail | WHO/WHEN/MODEL/PROMPT/OUTPUT 5필드 + SHA-256 해시 비동기 적재 | ✅ + 취소요청 흔적(pending)까지 기록 |
| A-4 PII 마스킹 | 주민번호(KR_RRN) 마스킹, DB 시크릿(DB_SECRET) 차단 | ✅ KR_RRN→`<KR_RRN_1>`, DB_SECRET→HTTP 400 차단 |
| A-5 이상 탐지 | 토큰 5배 초과 / 시간당 300건 초과 룰 | ✅ 합성 트래픽으로 anomaly_alerts 생성 |
| A-6 클라이언트 연동 | OpenCode / VS Code(Continue) E2E | ✅ 에이전트(파일생성·실행) + 자동완성 동작 |
| A-7 백업/복구 | 설정 + 키/스펜드/Audit DB 백업·복원 | ✅ 키·정책·로그 보존 확인 |
| A-8 오프라인 스테이징 게이트 | SHA-256 무결성 + 라이선스 + 취약점 스캔 게이트 | ✅ 변조 시 배포 차단(비0 종료) |

### 4.3 Phase B — 듀얼 모델 라우팅 (B-1 ~ B-3) ✅
- **B-1 듀얼 동시 상주**: Llama 8B(util 0.45) + Gemma 9B(util 0.40)를 단일 카드에 동시 적재(VRAM 30.5GB, OOM 없음).
- **Gemma2 attention 백엔드 실측**: `VLLM_ATTENTION_BACKEND=FLASHINFER` 지정에도 vLLM 0.17.1 이 **FLASH_ATTN 자동 선택**, logit soft-capping 정상 처리, garbage 없음. CLAUDE.md 가 우려한 SM120 FlashInfer head_size 이슈 미발생.
- **B-2 라우팅/Fallback**: `model=` 명시 라우팅(main/sub), main 중지 시 sub로 자동 fallback 확인.
- **B-3 동시성 스모크**: 동시 8×3 + 10×2 = **44/44 성공(100%)**, main/sub 균등 분배, KV 캐시 안정(VRAM 피크 30.5GB). 콜드스타트 후 동시 10건 ~1.2초(p50 0.47s).

### 4.4 Phase C — 운영 모델 실측 + FP4 디리스킹 (C-1, C-2) ✅
- **C-1 Gemma 2-27B FP8 단독 실측**: VRAM 31.5GB(단독 필수)로 OOM 없이 기동, garbage 없는 정상 추론(한국어/영어/코드), **디코드 throughput ~49 tok/s**(운영 용량산정 입력값). FLASH_ATTN 자동선택(9B와 일관).
- **C-2 NVFP4 디리스킹 → 조건부 Go**: NVFP4(W4A4) Llama 3.1-8B 기동·추론 성공. 로그 `NvFp4LinearBackend.FLASHINFER_CUTLASS for NVFP4 GEMM` — **SM120 FP4 GEMM 경로 실동작 확인**(Marlin 음수스케일 버그 회피). garbage 없음, VRAM ~19GB(FP8의 절반), throughput 163 tok/s.

### 4.5 IDE 클라이언트 연동 (FR-9 심화) ✅
- **OpenCode 에이전트**: 가상 키 인증 → main-llama → **도구 호출(파일 write + bash 실행)** → FizzBuzz/TodoList/구구단 생성·실행 완수. 전체 에이전트 워크플로우 검증.
- **VS Code 자동완성(FIM)**: StarCoder2/Qwen2.5-Coder 로 tab 자동완성 실동작. prefix+suffix 기반 inline 제안 + 게이트웨이 Audit 기록.

---

## 5. 성능 실측 요약 (단일 요청, 5090 SM120)

| 모델 | 양자화 | 디코드 throughput | VRAM(weights) | 비고 |
|------|------|------|------|------|
| Llama 3.1-8B | FP8 | 149 tok/s | ~8GB | 메인 프록시 |
| Llama 3.1-8B | NVFP4 | 158~163 tok/s | ~5GB | FP4가 약간 빠름(대역폭↓) |
| Gemma 2-27B | FP8 | **49 tok/s** | ~27GB | 운영 서브 실측 |
| Mistral-Small-24B | NVFP4 | 72 tok/s | ~15GB | FP4 모델상향 |
| StarCoder2-7B | FP8 | 144 tok/s | ~7GB | 자동완성 |
| Qwen2.5-Coder-7B | FP8 | ~155 tok/s | ~8GB | 자동완성(품질 우위) |

> 운영 RTX PRO 6000(96GB)은 더 큰 KV 캐시·배치로 **동시성과 총 처리량이 크게 증가**한다. 단일요청 디코드 속도는 동일 SM120이라 유사하다.

---

## 6. PoC 결과 (운영 의사결정 근거)

### 6.1 FP4 양자화 vs 모델 크기 (`docs/POC_FP4_QUANT_COMPARISON.md`)
**3-way 비교: Llama-8B-FP8 / Llama-8B-NVFP4 / Mistral-24B-NVFP4**
- **FP8→FP4 손실은 미미**(8B 일반작업 품질 동등, 속도는 FP4가 약간 빠름).
- **까다로운 추론에선 모델 크기 ≫ 양자화**: 24B-NVFP4(정답 ~5/7)가 8B-FP8/NVFP4(~2.5/7)를 함정추론·논리·한국어함정에서 압도.
- **★FP4 degeneration(반복 붕괴) 리스크는 작은 모델 한정**: 8B-NVFP4 는 긴 한국어 추론에서 토큰 반복 붕괴, 24B-NVFP4 는 안정.
- **결론**: **대형 모델은 NVFP4 안전·유리 / 소형(자동완성·서브)은 FP8 권장.**

### 6.2 자동완성 모델 비교 (StarCoder2 vs Qwen2.5-Coder)
**동일 FIM 케이스 6종 채점:**
- **Qwen2.5-Coder-7B (6/6)** > StarCoder2-7B (~3.5/6). Qwen 이 컴프리헨션·예외처리·간결성에서 우위, garbage/hallucination 없음.
- **속도 동등**(워밍 후 ~155 vs 144 tok/s).
- **정책 주의**: Qwen 은 중국계(Alibaba) → 자동완성 예외 적용은 **보안팀 공식 승인 필요**(코드 컨텍스트 한정·폐쇄망·외부통신0 근거).

---

## 7. 해결한 기술 이슈 (운영 이전성)

검증 중 발견·해결한 이슈는 모두 코드/설정/문서에 반영되었으며, 운영 장비에서도 동일하게 적용된다.

| # | 이슈 | 해결 |
|---|------|------|
| 1 | LiteLLM 이미지에 asyncpg 부재 → Audit 콜백 무력화 | `litellm/Dockerfile`로 asyncpg 내장 커스텀 이미지 빌드 |
| 2 | Prisma 가 DATABASE_URL 에 `connection_limit` 추가 → asyncpg 오류 | `audit_logger.py` DSN 쿼리스트링 제거 |
| 3 | PII 가드레일 미적용 | `config.yaml` guardrail 에 `default_on: true` |
| 4 | PERSON 마스킹 한국어 오탐(`<PERSON>` 남발) | PERSON 엔티티 제거(주민번호·DB시크릿은 유지) |
| 5 | PII 차단 코드 422 아닌 HTTP 400 | 문서 실측 정정(차단+사유 취지 충족) |
| 6 | IDE 에이전트 `"auto" tool choice requires...` | vLLM main 에 `--enable-auto-tool-choice --tool-call-parser llama3_json` |
| 7 | Gemma2 가 에이전트(system/tools)에서 실패 | `gemma_compat.py` 콜백(system 병합 + tools 제거) |
| 8 | 신규 모델 호출 403(키 allowlist 누락) | `rotate_keys.sh` 모델 목록 갱신 + `/key/update` |
| 9 | Audit 가 completion/취소요청 미기록 | `audit_logger.py` completion 추출 + pre_call pending 기록 |
| 10 | 에이전트 코드실행 `python not found` | `python-is-python3` 설치 |
| 11 | 에이전트 컨텍스트 초과(400) | `MAIN_MAX_LEN` 32768 확대(Llama 128K 지원) |
| 12 | 자동완성 모델 교체 시 FIM 토큰 불일치(빈 제안) | `autocomplete_compat.py` 콜백(FIM 토큰 정규화) |

---

## 8. 운영 모델 구성 권고

운영 장비(96GB 단일 카드) 기준 3개 선택지를 도출하였다(상세: `docs/OPERATOR_GUIDE.md` §10).

| 선택지 | 메인 채팅·에이전트 | 서브 | 자동완성 | 합 VRAM | 성격 |
|--------|------|------|------|------|------|
| **A** | Llama 3.3-70B **FP8** | — | StarCoder2-7B FP8 | ~77GB | **검증된 안정·출시 권장** |
| **B** | Llama 3.3-70B **NVFP4** | Gemma 2-27B FP8 | StarCoder2-7B FP8 | ~72GB | 서브 다양성·부하분산 |
| **C** | **Mistral Large 123B NVFP4** | — | StarCoder2-7B FP8 | ~77GB | 최고 품질(같은 VRAM에 더 큰 모델) |

- 모든 선택지 공통: **거버넌스 스택(LiteLLM OSS + Presidio + Audit + 3-Tier 키)은 검증된 그대로 이전.**
- 자동완성은 **FIM 전용 코드 모델 필수**(Llama/Gemma instruct 는 FIM 미지원). 품질 우선 시 Qwen2.5-Coder(중국계 예외 승인 전제).

---

## 9. 운영 전환 제안 및 변경사항

### 9.1 제안서 반영 권고 (확정 사항)
1. **OS/드라이버/CUDA 갱신**: `Ubuntu 26.04 / Driver 595(open 모듈) / CUDA 12.9`. 제안서의 `22.04/550/12.4`는 Blackwell 부적합.
2. **운영 OS 확정**: Windows 11 표기 → **Ubuntu 26.04 네이티브 Linux**(WSL2 Blackwell hang 회피).
3. **LiteLLM 무료(OSS) 채택**: Enterprise 미사용. Audit/키 로테이션/이상탐지는 자체 콜백·스크립트로 충족함을 실증.
4. **자동완성 모델 추가**: 제안서의 "자동완성 → Gemma"는 오류. **FIM 전용 코드 모델**(StarCoder2/Qwen2.5-Coder)을 별도 배포해야 tab 자동완성이 가능.

### 9.2 운영 모델 변경 제안 (신규)
1. **메인 모델 NVFP4 검토**: SM120 에서 NVFP4 FP4 GEMM 이 실동작함을 검증. 70B 를 NVFP4 로 하면 VRAM 절반(~38GB) → 동시성↑ 또는 **123B 급으로 모델 상향** 가능(선택지 C). 단 **96GB 단일 카드 상한은 123B 급**(405B/675B 는 멀티 GPU 필요 → 정책상 불가).
2. **양자화 전략**: **대형 메인=NVFP4 / 소형(자동완성·서브)=FP8**. FP4 degeneration 리스크가 소형 모델에 국한됨을 PoC로 확인.
3. **자동완성 품질 향상**: Qwen2.5-Coder 가 StarCoder2 대비 정확도 우위(6/6 vs 3.5/6). 보안팀 승인 시 채택 권고. 정책 유지 시 StarCoder2-15B/Codestral-22B 대안.
4. **운영 96GB 장비 최종 검증 과제**: `70B-FP8 vs 70B-NVFP4 vs 123B-NVFP4` 품질 직접 비교(본 검증의 5090 으로는 70B 미적재).

### 9.3 운영 전환(Go-Live) 체크리스트 (`OPERATOR_GUIDE.md` 부록 A)
- 검증 데이터 초기화: `TRUNCATE audit_log, anomaly_alerts`
- 테스트 키 전량 폐기 후 운영 사용자별 1인 1키 재발급
- 시크릿(마스터 키/DB 비번) 운영용 강난수 재생성
- 모델 교체(8B/9B → 70B/27B) + 사전 스테이징 게이트
- VRAM 분할값 96GB 기준 재산정, 확정 버전 점검, 초기 백업

---

## 10. 결론

테스트 장비(RTX 5090, SM120)에서 **운영 스택 전체(인프라·거버넌스·라우팅·클라이언트·운영 워크플로우·모델·양자화)를 검증 완료**하였다.

- **TEST_PLAN 종료 기준 충족**: Phase 0/A/B/C 전 항목 통과, FP8 용량/성능 실측, FP4 Go/No-Go 판정 완료, 확정 버전 고정 기록.
- **SM120 동일성**에 의해 본 검증 결과는 운영 장비(RTX PRO 6000 96GB)에 **모델 교체와 VRAM 분할값 조정만으로 이전** 가능.
- **거버넌스 전 계층(키·Audit·PII·이상탐지·백업·스테이징·라우팅)이 LiteLLM OSS + Presidio + PostgreSQL 로 폐쇄망에서 동작**함을 실증.
- **운영 모델 의사결정 근거**(FP4 양자화 전략, 모델 상향 가능성, 자동완성 모델 선택)를 데이터로 확보.

→ **운영 장비(RTX PRO 6000 Blackwell 96GB) 본 구축 Go 판정.** 잔여 과제는 운영 96GB 장비에서의 70B/123B 최종 품질 비교와 자동완성 모델의 보안 정책 결정뿐이다.

---

## 11. 운영 장비(RTX PRO 6000) Go-Live 실행 기록 (2026-07-07 ~ 07-08)

### 11.1 개요
검증장비(RTX 5090)에서의 §1~10 검증 완료 후, 실제 운영 장비(Dell Precision 7960 + RTX PRO 6000 Blackwell
96GB, hostname `LGCNS-AI-DEV-Precision7960`)로 **실제 Go-Live 전환**을 수행했다. 목적은 §11.8에서 서술할
운영 정책(서브 채팅 모델 미채택) 확정을 포함, "이론상 이전 가능"이 아니라 **실기동으로 증명**하는 것이었다.

### 11.2 환경 확인 및 사전 조치
- GPU 인식: `NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition`, 97887 MiB, Driver 595.71.05 — **5090과 완전 동일 버전 조합**(재현성 확인, NFR-2).
- **docker 그룹 권한 이슈**: `wiseop` 계정이 `docker` 그룹에 새로 추가됐으나, 이미 시작된 OS 로그인 세션(`loginctl` 세션이 그룹 추가 이전에 시작)이라 반영 안 됨 → **OS 재로그인/재부팅**으로 해결(앱 재시작만으로는 불충분했음).
- **nvidia-container-toolkit 미설치 발견**: CLAUDE.md §4가 요구하는 필수 컴포넌트가 이 신규 장비에 없었음(`docker run --gpus all` → "no known GPU vendor found from CDI"). NVIDIA 공식 apt 레포로 설치 + `nvidia-ctk runtime configure` + CDI 스펙 생성(`/etc/cdi/nvidia.yaml`)으로 해결, `docker run --gpus all ... nvidia-smi`로 검증 완료.
- 버전 재확인(컨테이너 내부): CUDA 12.9 / torch 2.10.0+cu129 / vLLM 0.17.1 / capability (12,0) — 5090 실측치와 **완전 일치**.

### 11.3 이관 상태 확인
`scripts/migrate_export.sh`/`migrate_import.sh`로 이관된 번들(git repo·docker 이미지·`.env`·검증용 모델·Claude 메모리)이
이미 반입되어 있었다. Postgres 볼륨이 이 세션에서 **신규 생성**된 것을 확인 → 검증장비의 키/Audit 데이터는
애초에 이 장비에 존재하지 않음(별도 DB) → 부록A "테스트 키 전량 삭제"는 별도 조치 없이 이미 충족.

### 11.4 운영 전환(Go-Live) 체크리스트 수행 (`OPERATOR_GUIDE.md` 부록A)
| 항목 | 수행 내용 |
|---|---|
| 검증 데이터 초기화 | `TRUNCATE audit_log, anomaly_alerts` 수행(헬스체크로 생긴 더미 레코드 1건 포함 정리) |
| 운영 키 발급 | admin 가상 키 1개 발급(`admin-ops-admin-20260706`, 90일 만료) — 사용자별 대량 발급은 명단 확보 후 별도 |
| 시크릿 재생성 | `LITELLM_MASTER_KEY`/`POSTGRES_PASSWORD` 신규 강난수로 교체, `ALTER ROLE`로 실DB 반영, 재기동 후 **기존 가상 키는 마스터 키와 독립이라 그대로 유효함**을 확인 |
| 모델 교체 | 8B(검증) → **Llama 3.3-70B FP8**(운영, 아래 §11.5) |
| VRAM 재산정 | §11.6 참조 |
| 확정 버전 점검 | §11.2에서 5090과 완전 일치 확인 |
| 백업 | `scripts/backup.sh` 수행(db.sql.gz + config.tar.gz), 재확인 실행 |
| 최종 헬스체크 + E2E | 전 서비스 200, admin 키로 실제 요청 1건 + audit_log 적재 확인 |

### 11.5 70B 메인 모델 스테이징
- 소스: `RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic`(HuggingFace, ungated 확인) — vLLM 이미지 내장 `huggingface-cli`로 다운로드(68GB, 약 1시간 48분).
- **LICENSE 누락 발견**: 양자화 리포에 LICENSE 파일이 동봉되지 않음(선행 스테이징한 8B/9B/27B 모델과 차이) → 동일 계열의 미양자화 ungated 리포(`RedHatAI/Llama-3.3-70B-Instruct`)에서 LICENSE/NOTICE/USE_POLICY.md 확보해 동봉.
- `scripts/stage_model.sh manifest` 로 SHA256SUMS 생성 → `gate`로 무결성·라이선스 검증 통과(FR-10 ②③).

### 11.6 VRAM 파라미터 튜닝 (실측 시행착오 3회)
운영 96GB 카드에서 이론치(70B~70GB+FIM~7GB=합~77GB, KV 여유~19GB)만으로 파라미터를 잡았으나 실측과 크게 어긋남을 확인:

| 시도 | 설정 | 결과 |
|---|---|---|
| 1차 | `MAIN_GPU_UTIL=0.83`, `MAIN_MAX_LEN=32768` | ❌ KV 10.0GiB 필요 / 9.04GiB만 가용 → EngineCore 기동 실패, **32회 재시작 크래시 루프** |
| 2차 | `MAIN_GPU_UTIL=0.85`(util 상향)로 재시도 | ❌ "Free memory... less than desired util" — autocomplete(nominal 9.5GiB)가 CUDA 컨텍스트/cudagraph 오버헤드로 **실사용 13.6GiB**라 free 공간 자체가 부족(정책상 gpu_memory_utilization은 프로세스 오버헤드를 반영 못함을 실증) |
| 3차 | `MAIN_GPU_UTIL=0.83` 유지, `MAIN_MAX_LEN=28672` | ❌ KV 8.75GiB 필요 / 8.74GiB 가용 — **0.01GiB 차이로 재실패** |
| **최종** | `MAIN_GPU_UTIL=0.83`, `MAIN_MAX_LEN=27648`, `AUTOCOMPLETE_GPU_UTIL=0.10` | ✅ **healthy, 재시작 없음.** 실측 GPU 사용량 96,462~97,212 / 97,887 MiB (**여유 30~1,400 MiB, 매우 타이트**) |

**교훈(문서 반영, `.env`/`OPERATOR_GUIDE.md` §10):** `gpu_memory_utilization`은 vLLM 자체 텐서(가중치+KV) 예산일
뿐, 프로세스별 CUDA 컨텍스트·cudagraph 캡처 오버헤드는 포함하지 않는다. 동시상주 구성에서는 이론치보다
**실측 마진을 반드시 확보**해야 한다.

### 11.7 클라이언트 연동 검증
- **OpenCode 1.17.14**: 신규 설치(공식 install 스크립트) → admin 키로 `opencode run` 실행, `read_file` 도구 호출로 `REQUIREMENTS.md`를 읽어 FR-5(Audit Trail)를 정확히 요약 — tool calling 전체 왕복 정상, audit_log 정상 적재.
- **VS Code 1.127.0(snap) + Continue 2.0.0**: 신규 설치 → `~/.continue/config.yaml` 작성(main-llama: chat/edit/apply, autocomplete-starcoder2: autocomplete). 채팅(REQUIREMENTS.md FR-5 질의, 도구 호출 포함) 정상. tab 자동완성은 Continue 자체 텔레메트리(`~/.continue/dev_data/0.2.0/autocomplete.jsonl`)로 **37건 중 24건(65%) 수락**, 테스트 파일의 모든 함수(add/is_even/factorial/reverse_string/distance_to/fetch_user)가 정확히 채워짐을 확인(에디터 미저장 버퍼로 인해 처음엔 디스크 반영이 안 보였던 것으로, 저장 후 확인됨).

### 11.8 운영 정책 확정: 서브 채팅 모델(Gemma) 트랙 폐지
**결정: 앞으로 모든 검증·운영 단계에서 서브 채팅 모델을 사용하지 않는다. main(70B FP8)+FIM(StarCoder2) 2-트랙만 채택.**

**사유:**
1. §11.6 실측 결과, main+FIM 2-트랙만으로 이미 GPU 여유가 30~1,400MiB로 사실상 0에 가까움 — 서브 모델(9B든 27B든)을 얹을 물리적 여유가 없음.
2. 단일 채팅 모델 구조가 운영 복잡도·장애 지점 관리에 유리함(§11.9의 fallback 이중오류 사례 참조).

**영향받은 파일(전면 갱신, 커밋 `83e3b42`):** `CLAUDE.md`(§5), `REQUIREMENTS.md`(FR-3/FR-8), `TEST_PLAN.md`(Phase B/C에 미채택 콜아웃 추가, 결과 자체는 역사적 기록으로 보존), `docs/OPERATOR_GUIDE.md`(§10 선택지 A 확정 채택 명시, B/C 미채택 처리 — 즉 §8/§9.2의 NVFP4·123B·Qwen 전환 검토는 폐기), `docs/USER_GUIDE.md`, `litellm/config.yaml`(sub-gemma/prod-gemma27b model_list 삭제, fallback 삭제, gemma_compat 콜백 해제), `docker-compose.yml`(gemma_compat 마운트 제거), `litellm/gemma_compat.py`(비활성 명시, 파일은 보존), `scripts/rotate_keys.sh`(전 역할 main+autocomplete만), `scripts/poc_concurrency_smoke.py`, `scripts/audit.sh`. 라이브 반영도 확인(`/v1/models`에 main-llama+autocomplete-starcoder2만 노출, 기존 발급 키의 allowlist도 `/key/update`로 동기화).

### 11.9 실사용 중 발견·해결한 이슈
| # | 증상 | 원인 | 조치 |
|---|------|------|------|
| 13 | OpenCode로 `docker-compose.yml` 읽기 시 `Blocked entity detected: DB_SECRET` 로 요청 자체가 BLOCK | Presidio `DB_SECRET` 정규식이 bash 변수치환 문법(`${VAR:?required}`)을 실제 자격증명으로 오탐(false positive) | `presidio/recognizers/kr_custom.yaml`의 두 패턴에 부정선행탐색(`(?![?=$-])`, `(?!\$)`) 추가. `/analyze` API 직접 호출로 오탐 제거 + 진짜 비밀번호는 계속 탐지되는 회귀 테스트 통과 확인 |
| 14 | 긴 문서(`OPERATOR_GUIDE.md` 전체)를 컨텍스트에 넣은 요청이 컨텍스트 초과(400) 실패 시, 원인이 가려지는 **이중 오류**(sub-gemma 연결 실패까지 겹침) | `litellm/config.yaml`의 `main-llama→sub-gemma` fallback이 **미기동 백엔드**를 가리키고 있었음 | fallback 설정 제거(§11.8 정책과 함께 영구 조치). 재현 테스트로 이후엔 단일 오류(`Fallbacks=None`)만 발생함을 확인 |
| 15 | `autocomplete-starcoder2`가 정답 뒤에 관련없는 텍스트를 계속 생성(예: `"a * b + outputId\ndf['age_..."`) — EOS(`<|endoftext|>`)를 안정적으로 못 냄 | StarCoder2-7B 체크포인트 자체의 FIM 종료 토큰 불안정성(특히 컨텍스트 없는 짧은 프롬프트에서 심함) | `litellm/config.yaml`에 서버측 `stop` 목록(FIM 특수토큰 + `\n\n\n`) 추가로 완화(완전 해결은 아님 — 근본 원인은 체크포인트 한계). 단, Continue의 실제 전체 파일 컨텍스트 요청에서는 이 문제가 거의 나타나지 않음을 §11.7에서 확인(짧은 인위적 프롬프트에서만 두드러짐) |
| 16 | audit_log에서 `sub-gemma` 요청이 반복 실패로 기록됨 | Continue/OpenCode에서 sub-gemma로 모델을 전환해 직접 호출(fallback 아님, `Received Model Group=sub-gemma`로 확인) — 애초에 미기동 모델을 호출한 것 | `opencode.json`에서 sub-gemma 항목 제거(§11.8 정책과 일치) |
| 17 | `/v1/models`가 config.yaml에서 이미 제거한 `sub-gemma`/`prod-gemma27b`를 계속 노출 | 이 엔드포인트는 라이브 설정이 아니라 **호출 키에 저장된 허용 모델 메타데이터**를 반환함(실제 라우팅은 이미 정상 차단) | `/key/update`로 기존 admin 키의 `models` 필드를 `main-llama, autocomplete-starcoder2`로 동기화 |

### 11.10 동시성 부하 테스트 (main+FIM 2-트랙, RTX PRO 6000)
| 시나리오 | 요청 수 | 성공률 | 평균 지연 | GPU 메모리 |
|---|---|---|---|---|
| main-llama 단독, 동시 8×3라운드 | 24 | 100% | 1.74s | 97,173MiB 사용 / 69MiB 여유, **무변동** |
| main-llama 단독, 동시 16×3라운드 | 48 | 100% | 1.75s | 동일, 무변동 |
| 채팅(12)+FIM(12) 혼합 동시 | 24 | 100% | chat 1.74s / FIM 0.68s | 동일, 무변동 |

**발견:** vLLM은 기동 시 KV 캐시 풀을 고정 예약하므로, 동시 요청이 늘어도 **추가 VRAM을 요구하지 않고** 예약된 풀 안에서 처리한다(풀이 차면 큐잉, OOM 아님). 현재 여유(30~1,400MiB)는 부하와 무관하게 이미 고정된 상태였음 — 즉 이 구성의 실질적 동시성 상한에 가깝다. 스크립트: `scripts/poc_concurrency_smoke.py`(§11.8 정책 반영, main-llama 전용으로 갱신됨).

**검토했으나 보류:** FIM 모델을 CodeLlama-13B로 상향하는 안을 검토했으나, VRAM 계산상 main 컨텍스트를 27648→약 9,953 토큰(64% 축소)까지 줄여야 해 에이전트 워크플로우(이미 최대 23K+ 토큰 요구 사례 확인됨)에 심각한 영향이 예상되어 보류. 원인이 모델 크기 문제인지 프롬프트/파라미터 문제인지(§11.9 #15 참조) 먼저 진단 후 재검토 예정.

### 11.11 커밋 이력 (이번 전환 세션)
```
d3e2496 운영 전환(phase-prod): 70B 메인 모델 반영
3c5c1e1 운영 실측 발견사항 반영: PII 오탐 수정 + fallback 설정 정리
d9f271d opencode.json에서 sub-gemma 제거(운영 선택지 A는 vllm-sub 미기동)
83e3b42 운영 정책 확정: 서브 채팅 모델(Gemma) 트랙 폐지, main+FIM 2-트랙만 사용
```

### 11.12 Go-Live 최종 상태 (2026-07-08 기준)
- **로드된 모델**: `main-llama`(Llama 3.3-70B-Instruct FP8, 컨텍스트 27648) / `autocomplete-starcoder2`(StarCoder2-7B FP8, 컨텍스트 8192) — 이 둘만 상시 기동.
- **GPU**: 97,173~97,212 / 97,887 MiB 사용(여유 매우 타이트, §11.10 참조).
- **클라이언트**: OpenCode·VS Code(Continue) 모두 실사용 검증 완료.
- **거버넌스**: 시크릿 재생성·백업·E2E·audit_log 전부 실측 확인 완료.
- **판정**: 운영 장비 Go-Live **실행 완료**(§1~10의 "권고"가 아니라 §11에서 실제로 수행·검증됨). 잔여 과제는 §12 참조.

## 12. 잔여 과제 (2026-07-08 기준)
- 운영 사용자 50인 명단·역할 확보 후 `rotate_keys.sh`로 1인 1키 일괄 발급(현재 admin 키 1개만 발급됨).
- FIM 자동완성 품질 이슈(§11.9 #15)의 근본 원인 진단 — 모델 교체보다 프롬프트/디코딩 파라미터 튜닝 우선 검토.
- 더 큰 동시 사용자 규모(예: 50인 근접 부하)의 별도 검증 — 현재는 최대 동시 24건까지만 확인됨.
- VRAM 여유가 매우 타이트(30~1,400MiB)하므로 운영 중 주기적 재확인 필요(모니터링 권장).

---

## 부록. 산출물 목록

| 구분 | 산출물 |
|------|------|
| IaC | `docker-compose.yml`, `.env(.example)` |
| 게이트웨이 | `litellm/config.yaml`, `litellm/Dockerfile`, `audit_logger.py`, `gemma_compat.py`, `autocomplete_compat.py` |
| PII | `presidio/recognizers/kr_custom.yaml`, `presidio/README.md` |
| 운영 스크립트 | `scripts/`: phase0_bootstrap, rotate_keys, backup, restore, stage_model, deploy_model, audit, anomaly_check, poc_quant_compare, poc_fim_compare, poc_concurrency_smoke |
| 문서 | `REQUIREMENTS.md`, `TEST_PLAN.md`, `CLAUDE.md`, `docs/OPERATOR_GUIDE.md`, `docs/USER_GUIDE.md`, `docs/POC_FP4_QUANT_COMPARISON.md`, 본 보고서 |
| 클라이언트 | `opencode.json`, `~/.continue/config.yaml` |
| 스테이징 모델 | Llama 8B(FP8/NVFP4), Gemma 9B/27B(FP8), StarCoder2-7B(FP8), Qwen2.5-Coder-7B(FP8), Mistral-24B(NVFP4) — 검증장비(5090) |
| **운영 스테이징 모델** | **Llama 3.3-70B-Instruct(FP8, ~68GB)** — 운영장비(RTX PRO 6000), §11.5 |
