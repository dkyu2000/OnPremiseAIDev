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
> **§13에서 모델 구성이 한 차례 더 갱신**됐다 — main을 FP8→**NVFP4**로, FIM을 7B→**15B**로 전환(서브는
> 계속 미사용). 현재 운영 최종 구성은 §13을 따른다(§11의 FP8 70B+FIM 7B는 역사적 기록).

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

**1차(소규모, `scripts/poc_concurrency_smoke.py`):**
| 시나리오 | 요청 수 | 성공률 | 평균 지연 | GPU 메모리 |
|---|---|---|---|---|
| main-llama 단독, 동시 8×3라운드 | 24 | 100% | 1.74s | 97,173MiB 사용 / 69MiB 여유, **무변동** |
| main-llama 단독, 동시 16×3라운드 | 48 | 100% | 1.75s | 동일, 무변동 |
| 채팅(12)+FIM(12) 혼합 동시 | 24 | 100% | chat 1.74s / FIM 0.68s | 동일, 무변동 |

**2차(50인 풀로드 규모, 2026-07-08):**
| 시나리오 | 동시 요청 | 성공률 | 채팅 평균/p95 | FIM 평균/p95 |
|---|---|---|---|---|
| 채팅35+FIM15 혼합 × 2라운드 | 50 | **100%**(100/100) | 2.64s / 4.45s | 1.07s / 1.33s |
| 순수 채팅 50명 × 2라운드 | 50 | **100%**(100/100) | 2.39s / 4.01s | — |
| 초과부하 확인용: 순수 채팅 80명 × 1라운드 | 80 | **100%**(80/80) | 2.99s / 4.96s | — |

전체 280건(1차 96건 + 2차 280건 중 실측치, 표는 2차만 집계) 중 **실패 0건**. 전 시나리오에서 GPU 메모리는
97,130MiB 사용/112MiB 여유로 완전히 고정, 전 컨테이너 healthy 유지, 서비스 중단 없음. 80명(운영 목표 50인을
초과하는 부하)까지도 100% 성공해 **50인 풀로드 규모의 동시성은 문제없이 소화됨**을 확인했다. p95 지연이
4~5초 수준으로 커지는 것은 동시 요청 증가에 따른 정상적인 배치 대기 증가이며 OOM/오류는 아니다. 단, 이는
순간 동시 부하(burst) 테스트이며 **하루 종일 지속되는 워크로드에서의 지연 누적은 별도 모니터링 필요**(§12).

**발견:** vLLM은 기동 시 KV 캐시 풀을 고정 예약하므로, 동시 요청이 늘어도 **추가 VRAM을 요구하지 않고** 예약된 풀 안에서 처리한다(풀이 차면 큐잉, OOM 아님). GPU 여유(30~1,400MiB)는 부하와 무관하게 이미 고정된 상태였음 — 즉 남은 여유는 "메모리 상한"이 아니라 이미 컴퓨트 스케줄링만으로 50~80명 동시 부하를 소화한다는 뜻. 스크립트: `scripts/poc_concurrency_smoke.py`(소규모, main-llama 전용), 50인 풀로드용 스크립트는 잡 임시 디렉터리에서 실행(리포 미포함 — 필요 시 재작성 가능).

**검토했으나 보류:** FIM 모델을 CodeLlama-13B로 상향하는 안을 검토했으나, VRAM 계산상 main 컨텍스트를 27648→약 9,953 토큰(64% 축소)까지 줄여야 해 에이전트 워크플로우(이미 최대 23K+ 토큰 요구 사례 확인됨)에 심각한 영향이 예상되어 보류. 원인이 모델 크기 문제인지 프롬프트/파라미터 문제인지(§11.9 #15 참조) 먼저 진단 후 재검토 예정. → 이후 §13에서 **main NVFP4 전환으로 이 제약 자체를 해소**하는 선택지 B 전환을 진행.

**3차(30분 지속 부하/soak test, 2026-07-08):** 앞선 1·2차는 순간 버스트 테스트라 "하루 종일 지속되는 워크로드에서 지연이 누적될 수 있다"는 우려에 답하기 위해, 50명이 각자 다른 타이밍(think-time 5~20초, 채팅 35%/FIM 65%)으로 30분간 계속 요청하는 지속 부하를 재현했다.

| 구간 | 요청 수 | 평균 지연 | GPU 온도 | 비고 |
|---|---|---|---|---|
| 전반부(0~15분) | 3,310 | 1.01s | 74→87°C로 초반 3~4분 내 정착 | — |
| 후반부(15~30분) | 3,366 | 0.98s | 83~87°C 유지 | **전반부 대비 지연 증가 없음(오히려 소폭 감소)** |
| 전체 | **6,676** | — | — | **성공 6,676/6,676 (100%), 실패 0건** |

- GPU 메모리: 30분 내내 97,083~97,192MiB 범위(±100MiB 자연 변동) — **누수/드리프트 없음**.
- 전력: 거의 항상 300W 상한에 붙어있음(정상적인 전력 제한 동작). 클럭은 1700~1940MHz에서 진동하며 **지속적으로 떨어지는 추세는 없음**(초기 스로틀링 후 안정화, 폭주성 열화 아님).
- **결론: 지속 부하 조건에서도 큐 적체·열 스로틀링에 의한 점진적 성능 저하가 관찰되지 않았다.** §12의 "지속 워크로드 모니터링 필요" 우려는 이 30분 창 안에서는 근거 없음으로 확인(단, 실제 8시간 연속 가동에 대한 완전한 대체 검증은 아니므로 운영 중 모니터링은 계속 권장).

### 11.11 커밋 이력 (이번 전환 세션)
```
d3e2496 운영 전환(phase-prod): 70B 메인 모델 반영
3c5c1e1 운영 실측 발견사항 반영: PII 오탐 수정 + fallback 설정 정리
d9f271d opencode.json에서 sub-gemma 제거(운영 선택지 A는 vllm-sub 미기동)
83e3b42 운영 정책 확정: 서브 채팅 모델(Gemma) 트랙 폐지, main+FIM 2-트랙만 사용
```

### 11.12 Go-Live 최종 상태 (2026-07-08 기준)
- **로드된 모델**: `main-llama`(Llama 3.3-70B-Instruct FP8, 컨텍스트 27648) / `autocomplete-starcoder2`(StarCoder2-7B FP8, 컨텍스트 8192) — 이 둘만 상시 기동. ★2026-07-08 §13에서 NVFP4/15B로 대체됨(아래).
- **GPU**: 97,173~97,212 / 97,887 MiB 사용(여유 매우 타이트, §11.10 참조). ★§13 전환 후 ~4.5GB로 개선.
- **클라이언트**: OpenCode·VS Code(Continue) 모두 실사용 검증 완료.
- **거버넌스**: 시크릿 재생성·백업·E2E·audit_log 전부 실측 확인 완료.
- **판정**: 운영 장비 Go-Live **실행 완료**(§1~10의 "권고"가 아니라 §11에서 실제로 수행·검증됨). 잔여 과제는 §12 참조, 이후 §13에서 모델 구성이 한 차례 더 갱신됨.

## 12. 잔여 과제 (2026-07-08 기준)
- 운영 사용자 50인 명단·역할 확보 후 `rotate_keys.sh`로 1인 1키 일괄 발급(현재 admin 키 1개만 발급됨).
- ~~FIM 자동완성 품질 이슈(§11.9 #15)의 근본 원인 진단~~ → **완료(§13)**: 프롬프트 튜닝이 아니라 **FIM 모델을 7B→15B로 상향**하는 방식으로 해결(더 근본적 개선).
- ~~더 큰 동시 사용자 규모(50인 근접 부하) 검증~~ → **완료(§11.10 2차)**: 채팅 50~80명 동시 부하까지 100% 성공 확인(2026-07-08).
- ~~지속 워크로드에서의 지연 누적 확인~~ → **완료(§11.10 3차, 30분 소크 테스트)**: 6,676건 100% 성공, 지연/온도 드리프트 없음 확인(2026-07-08). 8시간 전체 대체 검증은 아니므로 운영 중 가벼운 모니터링은 계속 권장.
- ~~VRAM 여유가 매우 타이트(30~1,400MiB)~~ → **§13에서 개선(~4.5GB)**. 여전히 운영 중 주기적 재확인 권장.

---

## 13. 선택지 D 전환: main NVFP4 + FIM StarCoder2-15B (2026-07-08)

### 13.1 배경
§11에서 채택한 선택지 A(70B FP8 + FIM 7B)는 GPU 여유가 30MiB까지 타이트했고, FIM 자동완성 품질(§11.9 #15,
정답 뒤 garbage 생성)도 완전히 해결되지 않은 상태였다. 사용자가 FIM 모델을 "한 단계 상향"하고 싶다고
요청했으나, 단순히 FIM만 키우면(예: CodeLlama-13B) main의 컨텍스트를 27648→~9,953(64% 축소)까지 줄여야
해 보류했었다(§11.10). 이를 근본적으로 풀기 위해 **main 자체를 NVFP4로 전환**해 VRAM을 절감하고, 그
여유로 FIM을 15B로 키우는 방향(사용자가 "운영 구성 B"로 지칭)으로 재검토했다.

### 13.2 모델 소싱
- **main**: `RedHatAI/Llama-3.3-70B-Instruct-NVFP4`(ungated). HF safetensors 메타데이터 실측: 가중치
  39.89GiB(FP8의 67.72GiB 대비 -27.9GiB). LICENSE는 동일 계열 미양자화 리포(`RedHatAI/Llama-3.3-70B-Instruct`)에서
  확보(양자화 리포 자체엔 미동봉 — §11.5와 동일 패턴).
- **FIM**: `RedHatAI/starcoder2-15b-FP8`(ungated, **사전 양자화 체크포인트 존재** — 이전에 검토했던 CodeLlama-13B는
  이런 기성 FP8 체크포인트가 없어 즉석양자화가 필요했던 것과 대조적으로, StarCoder2 계열이라 검증된 소스를
  그대로 사용할 수 있었음). 가중치 15.43GiB(7B의 7.3GiB 대비 +8.1GiB). LICENSE는 7B와 동일 계열(BigCode
  OpenRAIL-M v1)로 자체 `MODEL_LICENSE_NOTICE.txt` 작성.
- 둘 다 `scripts/stage_model.sh gate`로 무결성(SHA256SUMS)·라이선스 검증 통과.

### 13.3 VRAM 튜닝 (2차 시행착오)
| 시도 | 방식 | 결과 |
|---|---|---|
| 1차 | main(util 0.58)+autocomplete(util 0.25) **동시** 기동 | ❌ 둘 다 실패 — main "Available KV cache: -2.73GiB", autocomplete "-33.84GiB". 두 vLLM이 동시에 기동하면 서로의 메모리 프로파일링 시점에 상대가 아직 자리잡지 못한 상태를 잘못 참조해 실제보다 훨씬 부족하게 계산됨(§11.6에서도 유사 패턴 존재했으나 이번엔 동시기동 자체가 원인) |
| 2차 | **순차** 기동: main(util 0.72) 단독 → 확인 → autocomplete(util 0.20) 추가 | ✅ **둘 다 healthy.** main: weights 39.89GiB + KV 여유 **26.2GiB**(오버헤드 실측 ~2.3GiB로 FP8 때와 비슷 — 1차 실패는 순수 오버헤드 문제가 아니라 동시기동 간섭이 원인이었음을 확인). autocomplete: weights 15.43GiB + KV 여유 **2.14GiB** |

**최종 GPU 사용량: 92,628MiB/97,887MiB(여유 4,614MiB ≈ 4.5GiB)** — 선택지 A(여유 30MiB) 대비 훨씬 안전.

**교훈(운영 절차 반영):** 동시상주 vLLM 인스턴스를 재구성할 때는 **반드시 하나씩 순차로 기동**하고 각각의
`Available KV cache memory` 로그를 확인한 뒤 다음 인스턴스를 올릴 것. `docker compose up -d`로 여러 서비스를
한 번에 올리면 프로파일링 간섭으로 실제로는 문제없는 설정도 실패할 수 있다.

### 13.4 품질 검증
NVFP4 main으로 정상적인 한국어 응답(quicksort 설명) 확인, garbage 없음. FIM은 §11.9 #15에서 재현했던 동일
테스트(`multiply` 함수, max_tokens 30)로 비교:

| 모델 | 결과 |
|---|---|
| StarCoder2-7B (구) | `"a*bimport substitution\n#Left shift\n#Code alphabets..."` — 관련없는 텍스트로 계속 이어짐 |
| StarCoder2-15B (신) | 4회 중 3회 `finish_reason: stop`으로 자연스럽게 종료. 예: `'a * b\n'`, `'a * b\n\nt = Triangle(3, 4)\nt.area()\n'`, `'a * b\n\nd = multiply(3,5)\n\nprint(d)'` — 모두 맥락상 타당한 코드 |

**모델 크기 상향이 FIM 완성 품질(특히 EOS 안정성)을 실질적으로 개선함을 확인.** 이전 서버측 stop 토큰
완화책(§11.9 #15)은 그대로 유지(추가 안전장치).

### 13.5 최종 설정 (`.env`)
```
MAIN_MODEL_PATH=/models/llama-3.3-70b-instruct-nvfp4
AUTOCOMPLETE_MODEL_PATH=/models/starcoder2-15b-fp8
MAIN_GPU_UTIL=0.72
MAIN_MAX_LEN=27648
AUTOCOMPLETE_GPU_UTIL=0.20
AUTOCOMPLETE_MAX_LEN=8192
```
LiteLLM `model_list`는 `served-model-name`(main-llama/autocomplete-starcoder2)이 그대로라 **변경 불필요**
(§11.6에서 확립한 패턴 재확인 — 모델 실체가 바뀌어도 served-model-name만 유지하면 게이트웨이·클라이언트
설정이 전부 그대로 재사용됨).

### 13.6 갱신된 최종 상태 (2026-07-08)
- **로드된 모델**: `main-llama`(Llama 3.3-70B-Instruct **NVFP4**, `NvFp4LinearBackend.FLASHINFER_CUTLASS` 실동작, 컨텍스트 27648) / `autocomplete-starcoder2`(StarCoder2-**15B** FP8, 컨텍스트 8192).
- **GPU**: 92,628 / 97,887 MiB 사용(여유 ~4.5GiB).
- E2E(헬스체크·채팅·FIM·audit_log) 전부 재검증 완료.
- 이 구성이 §10(OPERATOR_GUIDE) "선택지 D"로 문서화됨. 선택지 A는 역사적 기록으로 보존, 서브 채팅 모델
  미채택 결정(§11.8)은 그대로 유지.

### 13.7 IDE(VS Code+Continue) 재검증 및 발견사항: FIM "완료 지점 이후 반복 수락" 함정 (2026-07-09)

VS Code+Continue로 선택지 D(NVFP4 main + FIM 15B)를 재검증하는 과정에서 신규 테스트 파일
(`ide_test_nvfp4_15b.py`)을 사용해 자동완성·채팅을 실사용 테스트했다.

**정상 동작 확인:** Continue 자체 텔레메트리(`~/.continue/dev_data/0.2.0/autocomplete.jsonl`) 기준
15건 중 12건(80%) 수락. `binary_search` 함수를 `left=0`→`right=len(arr)-1`→`mid=(left+right)//2`→
`if arr[mid]==target:`→`return mid` 5단계로 정확히 완성했고, §11.9 #15에서 문제됐던 `multiply` 재현
케이스도 `a * b`로 깔끔히 수락됨 — §13.4의 품질 개선이 실사용에서도 재확인됨.

**신규 발견(버그 아님, 사용 패턴 이슈):** 동일 파일에서 `binary_search`를 두 번째로(변수명 `low/high`로)
테스트할 때, `return mid`로 함수가 이미 완성된 지점(telemetry 24번 이벤트) 이후에도 `Tab`을 계속 눌러
추가 완성을 계속 수락하자, 모델이 **도달 불가능한 코드(return 이후)를 계속 생성**했다:
```python
        if arr[mid] == target:
            return mid
            mid = (low + high) // 2      # ← 도달 불가능, 이후 반복
            if arr[mid] == target:
                return mid
                mid = (low + high) // 2   # ← 들여쓰기가 계속 깊어짐
                ...
                    if arr[mid]           # ← 결국 "== target:" 누락, 문법 오류
                       return mid
```
telemetry로 정확한 시퀀스를 추적한 결과, **모델이 아니라 반복 수락이 원인**임을 확인했다: 각 개별
completion은 그 자체로는 "그럴듯한" 다음 줄이었으나(FIM 모델은 "이 함수가 이미 끝났다"는 걸 모름),
사용자가 자연스러운 종료 지점(`return`) 이후에도 계속 수락을 이어가자 모델의 최근 컨텍스트가 점점
자기 자신이 방금 생성한 반복 패턴으로 채워지면서 들여쓰기가 누적적으로 깊어지다 결국 무너졌다.

- **결론:** 서버/모델 설정 문제가 아니라 **FIM 자동완성의 구조적 한계 + 사용 습관**의 조합이다. FIM
  모델은 "논리적으로 함수가 끝났다"를 인식하지 못하므로, **`return`(또는 명백한 함수 종료) 직후에는
  추가 제안 수락을 멈추고 다음 작업으로 넘어가는 습관**이 필요하다.
- **조치:** 인프라/설정 변경 없음(재현·근본원인만 문서화). IDE 사용 가이드에 반영 검토 권고(`docs/USER_GUIDE.md`
  또는 팀 온보딩 자료에 "자동완성은 함수가 끝난 것처럼 보이면 추가 Tab을 누르지 말 것" 안내 추가).
- 이슈가 발생한 테스트 파일(`ide_test_nvfp4_15b.py`)은 커밋 대상이 아니며 그대로 두거나 삭제해도 무방.

### 13.8 선택지 D 부하 재검증 (2026-07-09)

선택지 A에서 수행했던 것과 동일한 3단계 부하 테스트(§11.10)를 선택지 D(NVFP4 main + FIM 15B) 구성으로
재실행해 결과가 유지되는지 확인했다.

**소규모 + 50인 풀로드(순간 버스트):**
| 시나리오 | 요청 수 | 성공률 | 지연(평균/p95) | GPU 메모리 |
|---|---|---|---|---|
| main-llama 단독, 동시 16×3 | 48 | 100% | 1.74s / — | 93,740MiB 사용 / 3.5GiB 여유, **무변동** |
| 채팅35+FIM15 혼합 × 2라운드 | 100 | 100% | chat 2.36s/3.64s, fim 1.11s/1.33s | 동일, 무변동 |
| 초과부하 확인용: 순수 채팅 80명 | 80 | 100% | 2.61s / 4.28s | 동일, 무변동 |

총 228건 전부 성공, GPU 메모리는 시작부터 끝까지 93,740MiB로 완전히 고정 — §11.10의 결론(vLLM 고정 KV 풀
구조)이 선택지 D에서도 동일하게 재확인됨. 지연 수치도 선택지 A 때와 비슷하거나 소폭 낮음.

**30분 지속 부하(soak test):**
| 구간 | 요청 수 | 평균 지연 | GPU 온도 |
|---|---|---|---|
| 전반부(0~15분) | 3,265 | 1.21s | 76→88°C로 정착 |
| 후반부(15~30분) | 3,287 | 1.21s | 84~87°C 유지 |
| 전체 | **6,552** | — | **성공 6,552/6,552(100%), 실패 0건** |

- 전반부·후반부 평균 지연이 **완전히 동일(1.21s)** — 드리프트/열화 없음(§11.10 3차와 동일한 결론).
- GPU 메모리 30분 내내 93,727~93,738MiB(변동폭 11MiB 이하) — 누수 없음, 여유 3.5GiB 그대로 유지.
- 11분째 GPU 활용률이 일시적으로 8%로 떨어진 순간이 있었으나(부하 공백 우연), 성공률·안정성에 영향 없음.

**결론:** 선택지 D는 §11.10에서 검증한 선택지 A의 부하 특성(동시성·지속부하 안정성)을 그대로 유지하며,
GPU 여유는 30MiB→3.5GiB로 개선되어 오히려 더 여유 있는 상태로 운영 가능함을 재확인했다.

### 13.9 메모리 상세 구성 비교 (선택지 A vs D, 2026-07-09)

두 구성 모두에서 vLLM 로그(`Model loading took`, `Available KV cache memory`)와 `nvidia-smi --query-compute-apps`
프로세스별 실측치를 대조해 가중치·KV 캐시·기타 오버헤드(CUDA 컨텍스트/cudagraph)를 분해했다.

**선택지 D(현재 운영, 실측 2026-07-09):**

| 서비스 | 모델 | 가중치 | KV 캐시 | CUDA 컨텍스트/기타 오버헤드 | 프로세스 총합 |
|---|---|---|---|---|---|
| vllm-main | Llama 3.3-70B NVFP4 | 39.89 GiB | 26.2 GiB | ~4.84 GiB | **70.93 GiB (72,632 MiB)** |
| vllm-autocomplete | StarCoder2-15B FP8 | 15.43 GiB | 2.14 GiB | ~2.31 GiB | **19.88 GiB (20,352 MiB)** |
| **합계** | | **55.32 GiB** | **28.34 GiB** | **~7.15 GiB** | **90.81 GiB** |

GPU 전체: 93,659 MiB 사용(위 합계+기타 프로세스 655MiB) / 97,887 MiB / **여유 3,583 MiB(3.5 GiB)**.

**선택지 A(구, 2026-07-07~08 운영, 역사적 기록):**

| 서비스 | 모델 | 가중치 | KV+오버헤드(합산) | 프로세스 총합(실측) |
|---|---|---|---|---|
| vllm-main | Llama 3.3-70B **FP8** | 67.72 GiB | ~13.34 GiB | **81.06 GiB (83,008 MiB)** |
| vllm-autocomplete | StarCoder2-**7B** FP8 | 7.32 GiB | ~5.96 GiB | **13.28 GiB (13,600 MiB)** |
| **합계** | | **75.04 GiB** | **~19.30 GiB** | **94.34 GiB** |

GPU 전체(당시): 96,462 MiB 사용 / 97,887 MiB / **여유 1,425 MiB(1.4 GiB)**.
★선택지 A는 KV 캐시와 CUDA 컨텍스트/cudagraph 오버헤드를 분리 측정하지 않고 `nvidia-smi` 프로세스 총량으로만
검증했다(당시 튜닝 시행착오 로그상 main의 KV 예산은 대략 8.7~9.0GiB 선으로 추정되나 근사치). 선택지 D부터
`Available KV cache memory` 로그값을 직접 확인해 더 정밀하게 측정한다.

**비교 요약:**

| | 선택지 A(구) | 선택지 D(현재) |
|---|---|---|
| main 가중치 | 67.72 GiB (FP8) | 39.89 GiB (**NVFP4**, -27.83GiB) |
| FIM 가중치 | 7.32 GiB (7B) | 15.43 GiB (**15B**, +8.11GiB) |
| GPU 여유 | 1.4 GiB | 3.5 GiB |

가중치(main)를 FP8→NVFP4로 줄여 확보한 여유를, FIM 모델 크기 상향(7B→15B, §13.4 품질 개선 참조)과 전체
안전마진 확대(1.4GB→3.5GB)에 나눠 투입한 구조임을 수치로 재확인.

### 13.10 "선택지 C" 재검토 시도: 메인 모델 대안 3종 조사 (2026-07-09~11)

사용자가 "선택지 C"(더 큰/고성능 메인 모델)를 다시 검토하고 싶어해, 후보 3종을 실측·조사했다. 결론적으로
모두 채택 불가로 판정되어 **선택지 D(§13) 구성이 그대로 유지**된다.

**① Mistral Large 3 (675B) — 즉시 기각(용량):**
- `mistralai/Mistral-Large-3-675B-Instruct-2512`: 675B 파라미터, Apache 2.0(라이선스는 양호).
- 공식 NVFP4 양자화본(`mistralai/Mistral-Large-3-675B-Instruct-2512-NVFP4`)도 실재하나 **403.2GB** —
  96GB 단일 카드의 4배 초과. 어떤 양자화로도 단일 카드 배치 불가(`CLAUDE.md`/`OPERATOR_GUIDE.md` §10의
  "675B(~403GB)는 멀티 GPU 필요 → 정책상 금지" 케이스와 정확히 일치). **다운로드 시도 없이 조사만으로 기각.**

**② NVIDIA Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4 — 아키텍처 리스크로 보류:**
- 75B 총/9.3B 활성(MoE+Mamba 하이브리드), NVFP4 53.5GB, 라이선스 OpenMDW-1.1(MIT급, 상업적 사용 자유),
  벤치마크 우수(MMLU-Pro 82.2 등, Llama 3.3-70B 대비 높음).
- `NemotronHPuzzleForCausalLM`이 vLLM 0.17.1 레지스트리에 등록되어 있으나, NVIDIA 공식 배포 예시가
  **`tensor-parallel-size 2~4` 권장**(단일 GPU 정책과 충돌), **검증 vLLM 버전이 0.20.0**(우리 고정판 0.17.1보다
  신규), Mamba 전용 캐시 설정(`mamba_ssm_cache_dtype` 등) 필요, 일부 배포 예시는 `--trust-remote-code` 요구.
  **다운로드 전 리스크가 명확해 사용자와 협의 후 보류(다운로드 시도 없음).**

**③ Mistral-Small-4-119B-2603-NVFP4 — 다운로드·실기동까지 시도했으나 로드 실패:**
- 119B 총/6.5B 활성(MoE), NVFP4 실측 66GB, 라이선스 **Apache 2.0**(완전 자유), 아키텍처는 표준
  `Mistral3ForConditionalGeneration`(Mamba 없음, vLLM 0.17.1에 등록됨), 양자화 주체가 **vLLM팀·Red Hat 직접
  협업 제작**(신뢰도 최상), 벤치마크상 GPT-OSS 120B 상회. 세 후보 중 가장 유망해 실제 다운로드·기동까지 진행.
- **다운로드**: 66GB, 약 1시간 45분. `stage_model.sh gate` 통과(무결성·라이선스, `MODEL_LICENSE_NOTICE.txt` 자체 작성).
- **실기동 시도**: 기존 서비스(main+autocomplete) 일시 중지 후 GPU 전체 반납, `--gpu-memory-utilization 0.85 --max-model-len 16384 --tool-call-parser mistral --enable-auto-tool-choice`로 단독 기동 시도.
- **실패 원인(확정):**
  ```
  ValueError: Unknown version: v15 in tekken.json.
  Make sure to use a valid version string: ['v1', 'v2', 'v3', 'v7', 'v11', 'v13']
  ```
  이 모델은 표준 HF `config.json`이 아니라 Mistral 고유 포맷(`params.json`+`tekken.json`, Tekken 토크나이저
  **v15**)을 쓰는데, 우리 vLLM 이미지(v0.17.1)에 내장된 `mistral_common`이 **1.9.1**(v13까지만 지원)이라
  파싱 자체가 실패한다. 모델 카드가 명시한 요구사항(`mistral_common >= 1.11.0`)을 사전에 확인했었고, 실제
  로드 시도로 그 우려가 정확히 재현됨.
- **조치**: 실패 즉시 컨테이너 제거, 기존 main→autocomplete 순차 재기동으로 healthy·E2E 정상 복구(다운타임
  ~10분). 다운로드했던 66GB 모델 디렉터리(`models/mistral-small-4-119b-nvfp4/`)는 **재사용 불가로 삭제**.
- **재도전 조건(참고용, 즉시 진행 안 함):** `mistral_common`(및 연쇄적으로 `transformers`/`vllm`)을 업그레이드한
  커스텀 이미지 빌드가 필요 — 이는 현재 검증 완료된 vLLM v0.17.1 이미지를 교체하는 것이라, 이미 검증된 다른
  모든 모델(Llama NVFP4, StarCoder2 FP8)까지 처음부터 재검증해야 하는 큰 작업이며 `CLAUDE.md` 버전 고정
  원칙과도 충돌. 별도 의사결정 없이는 진행하지 않는다.

**최종 결론:** 3종 모두 채택 불가(①용량 초과 ②아키텍처/버전 리스크 ③토크나이저 버전 비호환) →
**운영 구성은 선택지 D(§13, Llama 3.3-70B NVFP4 + StarCoder2-15B FP8)를 그대로 유지한다.**

---

## 14. 선택적 구성 전환 도구 + Continue YAML 버그 발견 (2026-07-11)

### 14.1 배경
사용자가 선택지 A(구, FP8 2트랙)와 선택지 D(현재, NVFP4+FIM15B)를 **필요에 따라 선택적으로 로드**하고
싶어해, 안전한 전환 도구를 구축했다. 향후 세 번째 구성이 추가될 가능성까지 고려해 확장 가능한 구조로 설계.

### 14.2 `scripts/switch_model_option.sh` + `env-profiles/`
- `env-profiles/option-<이름>.env` 파일 하나 = 구성 하나(`LABEL`, `MAIN_MODEL_PATH`, `MAIN_GPU_UTIL`,
  `MAIN_MAX_LEN`, `AUTOCOMPLETE_MODEL_PATH`, `AUTOCOMPLETE_GPU_UTIL`, `AUTOCOMPLETE_MAX_LEN`,
  `MAIN_CLIENT_LABEL`, `AUTOCOMPLETE_CLIENT_LABEL`). **새 모델 추가 시 파일만 하나 더 만들면 되고 스크립트
  수정은 불필요** — 사용자 요청("추후 한가지 모델이 더 추가 될 수 있으니")을 반영한 설계.
- `./switch_model_option.sh {list|status|<옵션명>}`: 모델 디렉터리 미스테이징 시 서비스 중단 전 사전 검증,
  **main→autocomplete 순차 기동**(§13.3의 동시기동 간섭 교훈 그대로 내장), 기동 실패 시 로그 출력 후 즉시 중단.
- 현재 `option-a.env`(구), `option-d.env`(현재 채택) 두 개 등록. `.gitignore`의 `*.env` 규칙이 이 파일들까지
  막고 있어 `!env-profiles/*.env` 예외 추가(시크릿 없는 파일이라 커밋 대상).

### 14.3 실측 중 발견한 버그: Continue YAML 라벨 파싱 오류 (신규)
전환 스크립트가 클라이언트 표시 라벨(`opencode.json`, `~/.continue/config.yaml`)도 함께 갱신하도록
설계했는데, A로 전환 후 **VS Code(Continue)의 모델 드롭다운이 완전히 비어버리는** 문제가 발생했다(완전
재시작으로도 재현 — 캐시 문제가 아님을 시사).

**근본 원인(확정):** 라벨에 `"선택지 A: FP8"`처럼 **콜론+공백**이 포함됐는데, `~/.continue/config.yaml`에
따옴표 없이(`name: Main — ... (선택지 A: FP8)`) 기록되면서, YAML 파서가 값 중간의 `": "`를 새 매핑
시작으로 오인 — **파일 전체 파싱이 깨져** Continue가 모델 목록을 아예 못 읽었다(`opencode.json`은 JSON이라
이 문제가 없어 정상 동작 — 증상이 Continue에만 국한된 이유).

**2차 발견:** YAML을 고쳐도 여전히 선택 안 됨 → Continue가 "현재 선택된 모델"을 **이름 문자열로 캐싱**하는
`~/.continue/index/globalContext.json`이 예전 라벨을 그대로 가리키고 있어, 목록엔 있어도 선택 상태가
깨져 있었음(자세히 보면 드롭다운 목록 자체는 비지 않고 "선택 안 됨" 상태였을 가능성 — 실제로는 YAML
파싱 실패가 선행 원인이라 목록 자체가 비어보인 것으로 최종 확인).

**조치(스크립트에 영구 반영, `switch_model_option.sh`):**
1. `~/.continue/config.yaml`의 name 값을 **항상 큰따옴표로 감싸도록** 수정(내부 큰따옴표는 이스케이프).
2. 전환 시 `~/.continue/index/globalContext.json`의 `selectedModelsByProfileId.local.{chat,edit,apply,autocomplete}`
   도 함께 갱신하도록 추가.
- 재현 테스트(D→D 무변경 전환 및 재전환)로 두 수정 모두 정상 동작 확인 — 이후 A↔D 전환에서 라벨·선택
  상태가 항상 일치함을 확인.

### 14.4 선택지 A 재검증 (StarCoder2-7B FP8, IDE 실사용)
전환 스크립트로 A로 전환 후 `ide_test_optionA_7b.py`(9개 함수)로 VS Code+Continue 자동완성을 실사용 테스트.

- **전체 파일 `ast.parse()` 문법 오류 없음** — 모든 완성이 문법적으로 완벽.
- subtract/is_even/square/max_of_three/celsius_to_fahrenheit/factorial/reverse_string 전부 정확.
- `Point.distance_to` 유클리드 거리 공식도 정확(§13.7에서 15B가 겪었던 `**2` 중복 없이 깨끗 — 이번엔
  사용자가 `return` 지점에서 적절히 멈춰 §13.7의 "완료 지점 이후 반복 수락" 함정도 재현 안 됨).
- `fizzbuzz`(docstring만 있던 빈 함수)를 다단계 완성으로 정확히 구현.
- 모델이 요청하지 않은 `Point.__str__`, `fizzbuzz_list` 두 함수를 자체적으로 추가 생성 — 둘 다 문법·로직
  정상(FIM 모델이 맥락상 자연스러운 확장을 스스로 제안한 사례).
- audit_log: 최근 30분 27건 중 stop 1건 + pending 26건(정상, 타이핑 취소) + error 0건.

**결론:** 7B(선택지 A)도 사용자가 "완료 지점에서 멈추기" 요령을 지키면 garbage 없이 정상 동작함을
재확인 — §13.7의 문제는 모델 크기보다 사용 패턴에 더 크게 좌우됨을 뒷받침하는 추가 증거.

### 14.5 최종 상태
테스트 완료 후 `./scripts/switch_model_option.sh d`로 운영 채택 구성(선택지 D)에 복귀, E2E 정상 확인.
GPU 92,838~93,xxx MiB 사용 / 여유 ~4.4GB, 클라이언트 라벨(`opencode.json`/Continue) 전부 "선택지 D"로 일치.

---

## 15. vLLM 0.20.0 업그레이드 리스크 검증 (2026-07-11)

### 15.1 배경
운영 스택은 vLLM **v0.17.1**로 고정되어 있다(§4). Mistral-Small-4-119B-NVFP4 시도(§13.9) 당시
`mistral_common 1.9.1`이 Tekken v15 토크나이저를 지원하지 못해 로드가 실패했고, 이후 검토 중인
Nemotron-3-Super-120B-A12B-NVFP4(§16, 별도 기록) 등 신규 아키텍처들도 최신 vLLM을 요구할 수 있어,
**v0.20.0으로 업그레이드했을 때의 리스크를 실측 기반으로 사전 검증**했다.

### 15.2 정적 분석
- `docker pull vllm/vllm-openai:v0.20.0` 완료(이미지 31.4GB).
- 드라이버/CUDA: `nvidia-smi` 기준 Driver 595.71.05 / 최대 지원 CUDA 13.2 — 0.20.0의 CUDA 13.0(.2) 요건에
  여유 있음, 드라이버 재설치 불필요.
- 이미지 내부 라이브러리 버전 직접 확인(`docker run --entrypoint bash ... python3 -c "..."`):
  `vllm 0.20.0` / `torch 2.11.0+cu130` / `transformers 5.6.2` / **`mistral_common 1.11.0`**
  (§13.9 실패의 직접 원인이었던 `>=1.11.0` 요건 충족 — Tekken v15 지원 확인).
- 양자화 방식 레지스트리(`QUANTIZATION_METHODS`) 확인: 우리 운영 모델이 쓰는 **`compressed-tensors`**
  (main NVFP4·FIM FP8 둘 다 `config.json`의 `quantization_config`가 `compressed-tensors` 포맷) 정상 등록됨.
  릴리스 노트의 "Petit NVFP4 removed"는 별도 경로(`petit_nvfp4`)이며 **우리 경로엔 영향 없음** 확인.
- 모델 아키텍처 레지스트리 확인: `NemotronHForCausalLM`/`NemotronHPuzzleForCausalLM`/
  `Mistral3ForConditionalGeneration`/`MistralLarge3ForCausalLM` 전부 등록됨 — §16 후보 모델들의
  아키텍처 자체는 0.20.0에서 지원됨(단, 실제 로드 가능 여부는 개별 검증 필요).

### 15.3 실측 검증 (운영 서비스 일시 중지 후 GPU 반납, 사용자 승인 하에 진행)
운영 v0.17.1 컨테이너를 순차 중지(`docker compose stop vllm-main vllm-autocomplete`)해 GPU를 반납한 뒤,
`VLLM_IMAGE=vllm/vllm-openai:v0.20.0`로 **운영과 동일한 `.env` 값**(main NVFP4 util=0.72/len=27648,
FIM FP8 util=0.20/len=8192)을 그대로 사용해 main → FIM 순차 기동, 각각 실제 추론까지 확인.

**main (Llama 3.3-70B NVFP4):**
- 가중치 로드 39.89GiB / 5.6초, 헬스체크 정상, `flashinfer.jit` FP4 GEMM 오토튜너 정상 동작(NVFP4
  CUTLASS/FlashInfer 커널 경로 그대로 활성).
- `/v1/chat/completions` 일반 응답 정상("1+2+3+4+5?" → "15").
- **tool calling(`--enable-auto-tool-choice --tool-call-parser llama3_json`) 정상** — `get_weather`
  함수 호출 테스트에서 올바른 JSON arguments로 `tool_calls` 응답 확인. §8 FR-9(에이전트 도구 호출) 영향 없음.
- GPU 사용량 71.5GB(96GB 중), 여유 26GB로 정상 범위.

**FIM (StarCoder2-15B FP8):**
- 가중치 로드 15.43GiB / 1.8초, 헬스체크 정상.
- `<fim_prefix>...<fim_suffix>...<fim_middle>` 완성 요청에 정확한 보완(`" + b"`) 반환 — FIM 동작 정상.
- **커널 선택 변화(비파괴적):** 0.17.1은 `CutlassFP8ScaledMMLinearKernel`을 선택했으나 0.20.0은
  `FlashInferFP8ScaledMMLinearKernel`을 선택(로그 확인) — 둘 다 Blackwell 지원 커널이며 기능·정확도
  차이 없음, 성능 재측정은 필요 시 별도 진행.

### 15.4 ⚠️ 핵심 발견: CUDA Graph 메모리 프로파일링 기본 활성화로 인한 KV 캐시 예산 축소
0.20.0부터 "CUDA graph memory profiling is enabled (default since v0.21.0)"이 적용되어(경고 로그에
정확한 버전 문구로 출력됨), **동일 `--gpu-memory-utilization` 값이 실측상 더 작은 유효 KV 캐시로
환산**된다. 로그가 직접 정량 수치까지 제시:

| 모델 | util 설정값 | v0.17.1 KV 캐시(실측) | v0.20.0 KV 캐시(실측) | 축소율 | 동일 KV 유지하려면 |
|------|------------|----------------------|----------------------|--------|---------------------|
| main (NVFP4) | 0.72 | 26.22 GiB (85,904 tok, 3.11x) | 24.96 GiB (81,792 tok, 2.96x) | **-4.8%** | util → 0.7303 |
| FIM (FP8) | 0.20 | (0.17.1 기준 미재측정, 참고용) | 1.64 GiB (21,424 tok, 2.61x) | 로그상 0.20→0.1938 환산 | util → 0.2062 |

두 경우 모두 **서비스 기동·헬스체크·추론은 정상**이었고(즉시 장애는 아님), 다만 §13 VRAM 튜닝 시
힘들게 맞춘 여유 마진(선택지 D 기준 GPU 여유 ~3.5GB)이 업그레이드 시 그대로 재검증 없이는
동시성 한도(`max concurrency`)가 최대 5% 가량 줄어들 수 있음을 의미한다.

### 15.5 결론 및 권고
- **호환성: 문제 없음.** 정적 분석·실측 모두에서 우리 운영 스택(compressed-tensors 양자화, NVFP4/FP8
  두 모델, tool calling, FIM)이 v0.20.0에서 정상 동작함을 확인했다.
- **즉시 업그레이드는 비권고, 계획적 전환은 Go.** 업그레이드 자체를 막을 결격 사유는 없으나,
  §15.4의 KV 캐시 축소 때문에 업그레이드 시 **§13와 동일한 절차로 VRAM 재튜닝(동시성 부하 테스트
  재실행)이 필요**하다 — "그냥 이미지 태그만 바꾸는" 무중단 전환은 위험, 반드시 재검증 후 전환.
- **부수 효과:** 0.20.0은 `mistral_common 1.11.0`을 번들해 §13.9에서 실패했던 Mistral-Small-4-119B의
  Tekken v15 이슈를 해소한다 — 향후 "선택지 C" 후보를 재검토한다면 업그레이드가 선행 조건이 된다.
  Nemotron-H 계열 아키텍처도 레지스트리엔 등록되어 있으나, 실제 로드 가능 여부(가중치 포맷·특수 캐시
  플래그 등)는 §15의 범위를 벗어나며 별도 실측이 필요하다.
- **작업 종료 후 조치:** 테스트에 사용한 GPU는 즉시 반납, 운영 컨테이너를 v0.17.1로 원복하고
  main→FIM 순차 기동 후 LiteLLM 게이트웨이 경유 실제 요청("ping"→"pong")까지 정상 확인,
  운영 중단 시간은 두 모델 교체 왕복 포함 약 20분(사용자 승인 하 진행, 실사용자 요청 없는 토요일
  낮 시간대 진행).

---

## 16. Mistral-Small-4-119B-NVFP4 재시도 및 Nemotron-3-Super-120B 검토 (2026-07-13)

### 16.1 배경
§13.9에서 Mistral-Small-4-119B-NVFP4 로드가 `mistral_common 1.9.1`의 Tekken v15 미지원으로 실패했고,
§15에서 vLLM 0.20.0이 `mistral_common 1.11.0`을 번들해 이 문제를 해소함을 확인했다. "선택지 C" 후보로
재검토를 진행했다.

### 16.2 Nemotron-3-Super-120B-A12B-NVFP4 사전 조사 (다운로드 미실시)
사용자가 먼저 이 모델을 제안해 조사했으나, 아래 리스크로 **다운로드 자체를 보류**하기로 결정:
- 가중치 80.37GB(단독) — 96GB 카드에서 FIM과 동시 상주 불가, 로드할 때마다 FIM을 내려야 함.
- `NemotronHForCausalLM`: 하이브리드 Mamba2+MoE(전문가 512개) 아키텍처, `modelopt` 혼합양자화(FP8+NVFP4
  2개 그룹) — 우리 스택이 다뤄본 적 없는 완전히 새로운 커널 경로.
- 공식 README가 vLLM **0.20.0**을 명시하고, `--trust-remote-code` + 커스텀 `reasoning-parser-plugin`
  (`super_v3_reasoning_parser.py`, 저장소에 동봉) 필요.
- 공식 테스트 하드웨어 목록(H100/H200/B200/GB200/DGX Spark)에 **RTX PRO 6000(워크스테이션 Blackwell,
  SM120)이 없음** — 하이브리드 Mamba 커널의 SM120 검증 이력 부재.
→ 사용자에게 리스크를 보고하고 보류 결정, 대신 아키텍처가 더 단순한 Mistral-Small-4-119B 재시도로 방향 전환.

### 16.3 Mistral-Small-4-119B-NVFP4 재다운로드 및 스테이징
- 저장소: `mistralai/Mistral-Small-4-119B-2603-NVFP4`(공식 Mistral AI 계정, gated 아님, Apache-2.0).
  RedHatAI 커뮤니티 양자화본과 바이트 단위로 동일 크기(70.81GB, blobs API 확인) — 공식 계정 사용.
- 실측 다운로드 용량 66GB(13개 safetensors 샤드, Mistral 네이티브 포맷: `params.json` +
  `consolidated-*.safetensors`, HF `config.json` 없음).
- `tekken.json`의 `"version": "v15"` 직접 확인(§13.9 실패 원인과 동일 버전, 재현성 확보).
- 라이선스 파일 부재(README 메타데이터 `license: apache-2.0`만 존재) → StarCoder2-15B 사례와 동일하게
  `MODEL_LICENSE_NOTICE.txt` 자체 작성 동봉 후 `stage_model.sh gate` 통과(체크섬 일치, 라이선스 확인,
  trivy 미설치로 이미지 스캔 SKIP — 기존 패턴과 동일).
- 아키텍처 상세(params.json): MLA(Multi-head Latent Attention, `kv_lora_rank=256`/`q_lora_rank=1024`)
  + MoE(전문가 128개 중 4개 활성 + 공유 전문가 1개), 36레이어. 양자화: `NVFP4A16`(compressed-tensors,
  group_size=16) — 이전에 성공한 다른 NVFP4 모델들과 동일 포맷.

### 16.4 로드 시도 (운영 서비스 일시 중지, GPU 전체 반납, vLLM 0.20.0 이미지)
`--tokenizer-mode mistral --config-format mistral --load-format mistral`(Mistral 네이티브 로더),
`--gpu-memory-utilization 0.82 --max-model-len 8192`, TP=1(단일 GPU, CLAUDE.md §2 제약 준수).

**1차: `--attention-backend TRITON_MLA`(README 권장값)**
- ✅ 가중치 로드 성공(66GB), FP4 GEMM 오토튜너 정상, MoE `trtllm::fused_moe` 커널 튜닝 정상,
  CUDA 그래프 캡처 성공, 헬스 라우트 정상 기동(`Application startup complete`).
  → **§13.9의 Tekken v15 문제가 vLLM 0.20.0에서 완전히 해소됨을 실측으로 재확인.**
- ❌ 그러나 **첫 채팅 요청에서 EngineCore가 크래시**: Triton 디코드 어텐션 커널
  (`triton_decode_attention.py:_fwd_grouped_kernel_stage1`) 컴파일 단계에서
  `ValueError('Cannot make_shape_compatible: incompatible dimensions at index 1: 256 and 512')`.
  이 모델의 `kv_lora_rank=256`(DeepSeek 계열의 일반적인 512와 다름)에 대해 TRITON_MLA 커널의 고정
  차원 가정이 맞지 않는 것으로 보이는 **vLLM 0.20.0 자체의 커널 버그**(우리 설정 문제 아님).

**2~4차: 대안 MLA 백엔드 전수 시도 — SM120에서 전부 거부됨**

| 백엔드 | 결과 | 사유(vLLM 자체 오류 메시지) |
|--------|------|------------------------------|
| `CUTLASS_MLA` | 즉시 기동 실패 | `compute capability not supported` |
| `FLASHINFER_MLA` | 즉시 기동 실패 | `compute capability not supported` |
| `FLASH_ATTN_MLA` | 즉시 기동 실패 | `compute capability not supported`, `FlashAttention MLA not supported on this device` |
| `FLASHMLA` | 즉시 기동 실패 | `compute capability not supported`, `FlashMLA Dense is only supported on Hopper devices.` |

**결론: vLLM 0.20.0이 제공하는 MLA 어텐션 백엔드 5종 중 SM120(워크스테이션 Blackwell)에서 시도라도
가능한 것은 TRITON_MLA 하나뿐이며, 그마저 이 모델의 커널 구성에서 실제 크래시가 난다. 즉 현재
시점에는 vLLM 버전과 무관하게 이 하드웨어에서 Mistral-Small-4-119B(MLA 아키텍처)를 안정적으로
서빙할 방법이 없다.** CUTLASS_MLA/FLASHINFER_MLA/FLASH_ATTN_MLA/FLASHMLA 4종 모두 SM90(Hopper)
이상 데이터센터급 GPU 전용으로 하드코딩되어 있어, vLLM이 SM120 워크스테이션 카드용 MLA 커널을
공식 지원하기 전까지는 상위 vLLM 버전으로 업그레이드해도 해결되지 않을 가능성이 높다.

### 16.5 후속 조치
- 테스트 컨테이너 즉시 제거, GPU 반납 확인(735MiB로 복귀).
- 운영 컨테이너 v0.17.1 main→autocomplete 순차 재기동, LiteLLM 게이트웨이 경유 실제 요청("ping"→"pong")
  정상 확인 — 운영 영향 없음.
- 다운로드한 `models/mistral-small-4-119b-nvfp4`(66GB)는 **삭제하지 않고 보존**하기로 결정(사용자
  확인, 2026-07-13) — 디스크 여유(1.3TB 중 66GB)가 충분하고, §13.9와 달리 이번엔 "아키텍처 자체가
  이 GPU에서 막힘"이라는 명확한 근본 원인이 있어 향후 vLLM이 SM120용 MLA 커널을 지원하면 재다운로드
  없이 바로 재검증 가능.
- **"선택지 C" 결론(2026-07-13 기준):** Nemotron-3-Super(하이브리드 Mamba, 미검증 하드웨어)와
  Mistral-Small-4(MLA, SM120 커널 미지원 확인)가 모두 막혀, 현재 운영 채택(선택지 D: Llama
  3.3-70B-NVFP4 + StarCoder2-15B-FP8)을 대체할 검증된 대안이 없다. **선택지 D 유지를 권고.**

---

## 17. gpt-oss-120b(OpenAI) 검증 — 최초로 성공한 "선택지 C" 후보 (2026-07-13)

### 17.1 배경
§16에서 Nemotron-3-Super(하이브리드 Mamba, 미검증 하드웨어)와 Mistral-Small-4-119B(MLA, SM120에서
전 백엔드 실패)가 모두 막힌 뒤, 아키텍처 리스크가 낮은 대안을 재조사했다. `gpt-oss-120b`(OpenAI,
Apache 2.0)는 표준 MoE(전문가 128개 중 4개 활성, sliding+full attention 교차) 구조로 **MLA도 하이브리드
Mamba도 아니며**, 비중국계·상업 사용 제한 없음을 확인 후 다운로드를 진행했다.

### 17.2 스테이징
- 저장소: `openai/gpt-oss-120b`(gated 아님). vLLM이 실제 로드하는 최상위 `model-*.safetensors`(15개
  샤드, native MXFP4)만 받고 `original/`(bf16 참조본, 65GB 추가) · `metal/`(Apple 전용)은 제외.
- 실측 다운로드 61GB. **1차 시도 중 약 5시간 무진행 스톨 발생**(HF Xet 전송 커넥션이 `CLOSE-WAIT`
  상태로 멈춤 — 과거에도 겪은 패턴) → 프로세스 종료 후 `huggingface_hub`의 `.incomplete` 청크 기반
  이어받기로 정상 재개, 완료까지 도달.
- LICENSE 파일이 저장소에 기본 포함(Apache 2.0 원문) — 별도 라이선스 고지 작성 불필요. `stage_model.sh
  gate` 통과(체크섬 일치, 라이선스 확인).

### 17.3 로드 테스트 (운영 서비스 일시 중지, GPU 반납, **vLLM 0.17.1 — 현재 운영 이미지 그대로**)
§15에서 확인한 대로 vLLM 0.17.1에 `mxfp4` 양자화·`GptOssForCausalLM`·`gptoss_reasoning_parser.py`가
이미 내장되어 있어 **0.20.0 업그레이드 없이 바로 시도**했다(Mistral-Small-4/Nemotron-Super와 달리
운영 이미지 그대로 검증 가능하다는 점에서 이미 리스크가 한 단계 낮음).

- `--tool-call-parser openai --enable-auto-tool-choice --reasoning-parser openai_gptoss`,
  `--gpu-memory-utilization 0.75 --max-model-len 8192`, 단독 구동(TP=1).
- ✅ 가중치 로드 65.97GiB/9초, 헬스체크 정상.
- **⚠ 알려진 SM120 이슈 실측 재현:** `Your GPU does not have native support for FP4 computation ...
  Weight-only FP4 compression will be used leveraging the Marlin kernel.` — `VLLM_USE_FLASHINFER_
  MOE_MXFP4_MXFP8=1` 환경변수를 줘도 우회되지 않음(NVIDIA 개발자 포럼에 보고된 SM120 미인식 버그와
  일치). Available KV cache 1.71GiB로 다소 타이트(util=0.75, max-model-len 8192 기준).
- ✅ **일반 채팅 정상**(reasoning 필드에 별도 사고과정 노출 — harmony 포맷 정상 파싱).
- ✅ **tool calling 정상**(`get_weather` 함수 호출 테스트, 올바른 JSON arguments). 로그에 `"For
  gpt-oss, we ignore --enable-auto-tool-choice and always enable tool use."` — gpt-oss는 vLLM에서
  tool use가 항상 활성화됨(별도 플래그 불필요).
- ✅ **처리량 실측 185.7 tok/s**(800 토큰 생성, 단일요청) — Marlin 폴백 경고("성능 저하 가능")에도
  불구하고 8B급 모델들(144~163 tok/s)보다 오히려 빠름. MoE 특성상 토큰당 5.1B만 활성화되기 때문으로
  추정 — **경고 문구만큼 치명적인 성능 저하는 실측되지 않음.**
- 테스트 종료 후 컨테이너 제거·GPU 반납, 운영 v0.17.1 main→autocomplete 순차 재기동, LiteLLM 게이트웨이
  경유 실제 요청("ping"→"pong") 정상 확인.

### 17.4 결론
**§13 이후 처음으로 아키텍처·하드웨어 양쪽 모두에서 성공한 "선택지 C" 후보.** Mistral-Small-4(MLA
전멸)·Nemotron-Super(미검증 하이브리드)와 달리, gpt-oss-120b는:
1. 운영 중인 vLLM 0.17.1 그대로 동작(버전 업그레이드 리스크 없음)
2. tool calling·reasoning 모두 정상, 처리량도 우수
3. 알려진 SM120 커널 폴백 이슈가 있으나 실사용에 지장 없는 수준으로 확인

**잔여 검증 항목(당시 미실시, §17.5에서 완료):** FIM(StarCoder2-15B)과 동시 상주 시 VRAM 예산 및
§13 수준의 동시성 부하 테스트.

### 17.5 FIM(StarCoder2-15B) 동시 상주 + 동시성 부하 테스트 (2026-07-13, 이어서 진행)

**VRAM 튜닝 (2회 시행착오, §13와 동일 패턴):**

| 시도 | `MAIN_GPU_UTIL`(gpt-oss) | `AUTOCOMPLETE_GPU_UTIL`(FIM) | 결과 |
|------|--------------------------|-------------------------------|------|
| 1차 | 0.75(기존 단독 검증값 유지) | 0.18 | ❌ FIM 기동 실패: `0.63 GiB KV cache 필요, 가용 0.22 GiB` |
| 2차 | 0.75 | 0.22 | ❌ FIM 기동 즉시 실패(프리체크): `Free memory (20.49/94.96 GiB) 가 요청한 0.22×94.96=20.89 GiB 보다 적음` — 0.4GiB 차이로 실패 |
| **최종** | 0.75 | **0.21** | ✅ **healthy** — FIM 가중치 15.43GiB + KV 3.09GiB(40,480 토큰) |

★main(gpt-oss)을 §17.3에서 검증한 util=0.75 그대로 두고 FIM만 미세조정한 것은, gpt-oss의 자체 KV
여유가 이미 1.71GiB로 빠듯해 main 쪽을 더 줄이면 §17.3의 재현성이 깨지기 때문 — FIM 쪽만 좁은
잔여 공간에 맞춰 정밀 튜닝(0.18→0.22→0.21)하는 방식으로 접근했다.

**최종 GPU 사용량: 96,848 / 97,887 MiB — 여유 1,039 MiB(≈1.0GiB).** 선택지 D(여유 3.5~4.5GiB)보다
**훨씬 타이트**하다 — gpt-oss 가중치(65.97GiB)가 Llama-NVFP4(39.89GiB)보다 26GiB 더 크기 때문에
당연한 결과. **실제 운영 채택 전에는 이 마진을 반드시 재확인/개선해야 한다**(드라이버 업데이트·
메모리 파편화에 D보다 훨씬 취약할 것으로 예상).

**기능 검증:** FIM 완성 정상(`" + b"` 정확 반환).

**동시성 부하 테스트(원시 vLLM 포트 직접 대상, LiteLLM 미경유 — 임시 컨테이너라 게이트웨이 미등록):**
- 8×3라운드(chat+FIM 혼합 48건): **48/48 성공(100%)**, chat p50 1.05s/p95 1.47s, FIM p50 0.50s/p95 0.51s.
- 20×3라운드(120건): **120/120 성공(100%)**, chat p50 1.62s/p95 1.65s, FIM p50 0.57s/p95 0.59s.
- 부하 중 GPU 사용량 변화 없음(96,689MiB 그대로) — §11.10에서 확인한 "KV 풀은 기동 시 고정 예약,
  동시요청 증가가 추가 VRAM을 요구하지 않음" 원리가 gpt-oss+FIM 조합에서도 동일하게 재현됨.
- 온도 50°C, 이상 없음.
- 테스트 종료 후 컨테이너 제거, 운영 v0.17.1 main→autocomplete 순차 재기동, LiteLLM 경유 실제 요청
  ("ping"→"pong") 정상 확인.

### 17.6 최종 결론 (선택지 E 후보)
gpt-oss-120b + StarCoder2-15B FIM 조합은 **기능·동시성 측면에서 선택지 D와 동등하게 검증 통과**했다.
다만 **VRAM 여유가 1GiB로 D(3.5~4.5GiB) 대비 훨씬 타이트**해, 실제 운영 채택 전 추가 조치가 필요하다:
- 옵션 1: `max-model-len`을 8192보다 낮춰 KV 예약을 줄이고 그만큼 안전마진 확보.
- 옵션 2: FIM을 StarCoder2-7B로 하향해 여유 확보(단 §13에서 확인한 대로 7B는 FIM 품질이 15B보다 불안정).
- 옵션 3: gpt-oss 쪽의 Marlin 폴백 이슈가 해결되면(SM120 네이티브 MXFP4 커널 지원 시) 활성화 메모리
  오버헤드가 줄어 마진이 자연 개선될 가능성 있음 — vLLM/FlashInfer 업스트림 이슈 추적 필요.
- 품질(응답 정확도) 비교는 아직 미실시 — 선택지 D 대비 실사용 품질 우위가 있는지는 별도 PoC 필요.

**요약:** gpt-oss-120b는 기술적으로 실행 가능한 첫 "선택지 C/E" 후보임이 확인됐으나, VRAM 마진 문제로
**즉시 운영 전환은 비권고**. 마진 개선 조치 후 재검증하거나, 품질 PoC로 전환 가치가 명확할 때 재추진.

### 17.7 옵션 2 실측: FIM StarCoder2-7B 하향으로 마진 개선 (2026-07-13, 이어서 진행)

§17.6의 옵션 2(FIM 7B 하향)를 실측했다. StarCoder2-7B FP8은 선택지 A 시절 이미 스테이징되어 있어
재다운로드 불필요(`models/starcoder2-7b-fp8`).

**VRAM 튜닝(1차 시도만에 성공, 15B 때의 2회 시행착오 대비 개선된 여유 덕):**
- main(gpt-oss) 설정은 §17.3~17.5와 동일(util=0.75) 유지.
- `AUTOCOMPLETE_GPU_UTIL=0.12` → ✅ 즉시 성공. 가중치 6.96GiB + **KV 3.34GiB(54,736 토큰)**
  — 15B(KV 3.09GiB)보다 오히려 KV 캐시가 더 넉넉함(가중치가 절반 이하라 그만큼 KV에 배분됨).

**최종 GPU 사용량: 88,149 / 97,887 MiB — 여유 9,738 MiB(≈9.5GiB).** 15B 조합의 1.0GiB 대비
**약 9배 개선** — 선택지 D(3.5~4.5GiB)보다도 오히려 여유로운 수준.

**기능 검증:** FIM 완성 자체는 정상 응답하지만, §13에서 이미 확인한 **7B의 EOS 불안정(정답 뒤 garbage
생성)이 이 조합에서도 그대로 재현**됨(`" + b\n\n/README.md\n# python-test\n\nThis"` — 정답 `" + b"`
뒤에 무관한 텍스트가 이어짐). 이 테스트는 vLLM을 직접 호출해 LiteLLM의 stop 토큰 오버레이가
적용되지 않은 raw 응답이며, 실제 운영에서는 `litellm/config.yaml`의 stop 리스트로 완화됨(§13).

**동시성 부하 테스트(20×3라운드, 120건):** **120/120 성공(100%)**, chat p50 1.50s/p95 1.85s,
FIM p50 0.31s/p95 0.33s(15B의 0.57s보다 빠름 — 모델 크기 축소 효과).

**결론:** VRAM 마진 문제는 FIM 7B 하향으로 **확실히 해결됨**(9.5GiB 여유, D보다도 안전). 다만
트레이드오프는 §13에서 이미 검증된 그대로 — **FIM 품질(EOS 안정성)이 15B보다 떨어짐**. 즉 "gpt-oss
main + FIM 7B" 조합은 **VRAM 안전성은 최고 수준이나 자동완성 품질은 선택지 A 시절 수준으로 회귀**하는
트레이드오프를 감수해야 한다. 최종 채택 여부는 (a) gpt-oss의 채팅/에이전트 품질이 선택지 D의 Llama
70B보다 우위인지, (b) FIM 품질 저하를 감수할 가치가 있는지 — 두 가지 품질 PoC로 §17.8에서 확인했다.

### 17.8 품질 PoC: gpt-oss-120b vs Llama 3.3-70B-NVFP4 (2026-07-13, `poc_quant_compare.py` 재사용)

기존 FP4 PoC(§6, `docs/POC_FP4_QUANT_COMPARISON.md`)에서 쓴 hard-set 7문항(함정추론·역산수학·논리오류
지적·엣지케이스코딩·엄격포맷·다단계추론·한국어함정) + easy-set 5문항을 그대로 재사용해 두 모델을
비교했다. Llama는 **운영 중단 없이** 현재 프로덕션(포트 8000)에 바로 실행, gpt-oss는 §17.3과 동일
설정으로 임시 기동해 테스트 후 즉시 원복했다.

**Llama 3.3-70B-NVFP4(선택지 D 운영, `max_tokens=320`):** hard-set **6.5/7** — 5문항 명확히 정답
(함정추론/역산수학/엣지케이스코딩/엄격포맷/한국어함정), 다단계추론(Sally 자매)은 다소 장황하지만
최종 결론 정답, **논리오류지적만 답이 다소 모호함**("펭귄이 난다는 걸 증명 못 했다"는 취지로 결론은
맞으나 "대전제가 거짓"이라는 핵심을 명료하게 짚지 못함). 평균 throughput 22.2 tok/s.

**gpt-oss-120b(`max_tokens=320`):** hard-set 5/7이 320토큰 내 완결(전부 정답), **2문항(논리오류지적/
한국어함정)은 320토큰 제한에 걸려 미완성**으로 잘림 — gpt-oss는 API 응답에 `reasoning`(사고과정)과
`content`(최종답)를 분리해 노출하는 harmony 포맷 특성상, 어려운 문제일수록 완결까지 필요한 총
생성량이 Llama보다 훨씬 크다. 해당 2문항만 `max_tokens=900`으로 재시도한 결과 **둘 다 정확히
정답**(논리오류지적: "전제가 거짓인 과도한 일반화" — Llama보다 오히려 더 명료, 275토큰; 한국어함정:
토끼 4·닭 6·검산까지 정확, 688토큰). **easy-set 5/5 전부 정답.** 평균 throughput 184~185 tok/s(Llama
대비 약 8배) — 어려운 문제에 2~3배 더 많은 토큰을 쓰지만 원시 속도가 훨씬 빨라 **체감 지연은 오히려
gpt-oss가 더 짧다**(예: 한국어함정 688토큰/185tok/s ≈ 3.7초 vs Llama 278토큰/22.2tok/s ≈ 12.6초).

**결론:**
1. **정확도: gpt-oss-120b가 근소하게 우위** — 충분한 토큰 예산 하에서 hard-set 7/7 vs Llama 6.5/7.
2. **실사용 설정상 함정:** 기본 `max_tokens=320`처럼 Llama 기준으로 튜닝된 예산을 그대로 쓰면 gpt-oss는
   어려운 질문 2/7에서 답을 끝맺지 못하는 리스크가 있다 — **운영 채택 시 `max_tokens`를 Llama보다
   넉넉히(600~900 이상) 잡아야 함**, LiteLLM/클라이언트 쪽 기본값 재조정 필요.
3. **속도는 gpt-oss가 명확히 우위**(8배) — 늘어난 토큰 소모를 상쇄하고도 남아 체감 지연은 더 짧음.
4. FIM 7B 트레이드오프(§17.7)는 여전히 유효 — 자동완성 품질 저하는 이 PoC로 상쇄되지 않음.

**종합 권고:** gpt-oss-120b(main) + StarCoder2-7B(FIM) 조합은 **채팅/에이전트 품질과 속도 모두 선택지
D 이상**이며 VRAM 마진도 더 안전하지만, **FIM 자동완성 품질 저하**가 유일한 남은 트레이드오프다.
IDE 자동완성 비중이 높은 사용자에게는 D 유지가, 채팅/에이전트(도구 호출) 비중이 높은 사용자에게는
gpt-oss 조합 전환이 더 유리할 수 있음 — 운영 채택 시 `max_tokens` 재조정과 FIM 품질 감내 여부를
사용자와 재확인 필요.

---

## 18. 선택지 E 운영 전환: gpt-oss-120b + StarCoder2-7B (2026-07-13)

### 18.1 배경 및 결정
§17.8 품질 PoC 결과를 근거로 사용자가 선택지 D→E(gpt-oss-120b+FIM 7B) 전환을 확정 결정했다. §17까지의
검증은 전부 `max-model-len=8192`(빠른 스모크 테스트용)로 진행됐는데, 실제 채택 전 사용자가 "운영 D와
동일한 컨텍스트(27648)로 맞춰서 재튜닝"을 요청 — VRAM 재튜닝부터 다시 진행했다.

### 18.2 컨텍스트 27648 기준 VRAM 재튜닝
- **main(gpt-oss)**: util=0.80으로 **1차 시도 성공**. 가중치 65.97GiB + KV 6.46GiB(94,064토큰,
  동시성 5.23x) — 8192 기준(1.71GiB)보다 오히려 KV가 커짐(util 상향 효과).
- **FIM(StarCoder2-7B)**: util=0.15 첫 시도로 성공했으나(KV 6.19GiB, 여유 겨우 1.6GiB) 마진이
  D보다 타이트해 **util=0.11로 재조정**(KV 2.39GiB) → **최종 여유 5,491MiB(5.4GiB)**, D(3.5~4.5GiB)와
  동등하거나 더 안전.
- 실사용 시나리오 부하테스트(`max_tokens=900`, 15×3라운드, chat+FIM 혼합 90건): **90/90 성공(100%)**,
  chat p50 14.66s(평균 820토큰 생성 — 900 예산의 대부분 사용, harmony 포맷 특성 재확인), FIM p50 0.30s.
  VRAM 부하 중 무변동(92,396MiB 고정) 재확인, 온도 71°C 정상.

### 18.3 인프라 파라미터화 (A↔D와 다른 신규 작업)
A↔D는 둘 다 Llama라 `docker-compose.yml`의 `--tool-call-parser llama3_json`이 고정값이어도 문제없었지만,
E는 다른 아키텍처라 다음을 새로 파라미터화해야 했다:
- `docker-compose.yml`: `--served-model-name`, `--tool-call-parser`를 env var화, `--reasoning-parser`
  등 모델별 추가 플래그를 담을 `MAIN_EXTRA_ARGS`, gpt-oss 전용 `VLLM_USE_FLASHINFER_MOE_MXFP4_MXFP8`을
  `MAIN_MXFP4_FLASHINFER`로 env화.
- `env-profiles/option-e.env` 신규 생성(`MAIN_SERVED_NAME=main-gptoss`, `MAIN_TOOL_PARSER=openai`,
  `MAIN_EXTRA_ARGS=--reasoning-parser openai_gptoss`, `MAIN_MXFP4_FLASHINFER=1` 등).
- `scripts/switch_model_option.sh` 대폭 확장: (a) 선택 키 6종 기본값 자동 리셋(`OPTIONAL_DEFAULTS`),
  (b) `sync_litellm_main_route()` — `litellm/config.yaml`의 메인 라우트(`model_name`/`litellm_params.model`)를
  새 served-name으로 sed 치환 후 litellm 재기동(설정이 `:ro` 마운트라 핫리로드 안 됨),
  (c) `update_client_config()` — `opencode.json`의 모델 **키**(라벨뿐 아니라)와 `~/.continue/config.yaml`의
  `model:` 필드까지 jq/python으로 old→new 치환(기존 `update_client_labels()`는 라벨만 바꿨음 — 이번엔
  키 자체가 바뀌어야 해서 재작성).
- `scripts/rotate_keys.sh`: 하드코딩된 `main-llama`를 `.env`의 `MAIN_SERVED_NAME`을 읽어오도록 변경(향후
  키 발급이 항상 현재 활성 모델과 일치하도록).

### 18.4 실측 중 발견·수정한 버그 4건
전환을 실제로 실행하며 아래 4개 버그를 실측으로 발견하고 즉시 수정했다(전부 스크립트에 영구 반영):

1. **`load_profile()`의 정규식이 숫자를 포함한 키를 통째로 누락**: `^([A-Z_]+)=(.*)$`가 `[A-Z_]`만 허용해
   `MAIN_MXFP4_FLASHINFER`처럼 숫자가 들어간 키를 조용히 건너뜀(에러 없이 스킵) — 그 결과 `MAIN_MXFP4_FLASHINFER=1`이
   프로파일에 명시돼 있었음에도 `.env`엔 기본값 `0`이 기록됨. `[A-Z0-9_]+`로 수정. (실제 서비스 동작에는
   영향 없었음 — 이 env var 자체가 SM120 미인식 버그를 우회 못 해 어차피 Marlin 폴백이 그대로였음, §18.5 참조.)
2. **`rotate_keys.sh`의 sed 치환 실수로 JSON에 잘못된 작은따옴표 삽입**: `\"'"$MAIN_SERVED_NAME"'\"` 형태로
   잘못 작성되어 `{"models":["'main-llama'",...]}`처럼 깨진 JSON이 생성됨. `\"$MAIN_SERVED_NAME\"`로 수정
   후 `DRY_RUN=1`로 재검증(기본값·오버라이드 값 둘 다 정상 JSON 확인).
3. **`~/.continue/config.yaml`의 최상위 `model:` 필드 누락**: 파이썬 패처가 `"- name:" `블록 안의 `model:`만
   치환하도록 작성돼, 블록 밖(파일 4번째 줄)의 최상위 기본 모델 지정(`model: litellm-onprem/main-llama`)이
   갱신 안 됨 — Continue가 여전히 구 모델을 기본으로 가리키는 상태로 남을 뻔했다(§14의 라벨 버그와는 다른
   신규 버그). 블록 밖 최상위 `model:` 라인을 별도로 먼저 처리하도록 로직 추가, 재현 테스트로 검증.
4. **★가장 중요: 기존 발급된 가상 키의 allowlist가 자동으로 안 바뀜.** served-name이 바뀌면 LiteLLM
   게이트웨이 라우트는 갱신되지만, **키별로 저장된 허용 모델 목록은 별도**라 기존 키가 전부
   `"key not allowed to access model. ... Tried to access main-gptoss"`로 막힘 — 실측 확인(OpenCode 실행
   시 발견). `/key/list`가 주는 **해시 토큰만으로 `/key/info`·`/key/update`가 그대로 동작**함을 확인해(평문
   키 불필요) `sync_key_allowlists()`를 신규 구현, `switch_to()`에 자동 편입. ★추가로 `/key/update`로 DB를
   갱신해도 LiteLLM의 인메모리 캐시 때문에 **즉시 반영 안 됨**(재현: 갱신 직후에도 구 allowlist로 거부) —
   키 갱신 발생 시 자동으로 LiteLLM을 재기동해 캐시를 비우도록 설계.

### 18.5 최종 검증
- `docker compose ps`: 전 서비스 healthy. GPU 92,401~92,506MiB/97,887MiB(여유 ~5.4GB) 유지.
- `MAIN_MXFP4_FLASHINFER` 버그 수정 후 vllm-main 재기동해 재확인 — **Marlin 폴백은 이 env var와
  무관하게 동일**(vLLM의 SM120 인식 자체가 안 되는 별개 업스트림 버그, §17.3 참조), KV 6.46GiB로 동일.
- LiteLLM 경유 실제 요청(`main-gptoss`, `autocomplete-starcoder2`) 정상, `main-gptoss`에 `max_tokens=10`
  요청 시 `finish_reason: "length"`+`content: null`(harmony 포맷 특성, §17.8에서 예견한 그대로 재현) →
  `max_tokens=900`으로는 정상 완결 확인.
- **OpenCode 실사용 검증**: `opencode run`으로 한국어 함정 추론 문제(닭·토끼 머리다리 문제)를 별도
  `max_tokens` 지정 없이 질의 → 완전하고 정확한 풀이 반환(클라이언트 기본 설정만으로 충분, §18.4 버그
  4건 수정 후 정상 동작).
- `~/.continue/config.yaml` 최상위 `model:` 필드까지 정상 확인(수동 보정 + 스크립트 버그 수정 동시 반영).

### 18.6 최종 결론
**선택지 E(gpt-oss-120b + StarCoder2-7B FP8) 운영 전환 완료.** CLAUDE.md §5, `docs/OPERATOR_GUIDE.md`
§10, `docs/USER_GUIDE.md`에 반영 완료. `scripts/switch_model_option.sh {a|d|e}`로 세 구성 중 언제든
재전환 가능하며, 이번에 발견·수정한 4개 버그로 인해 향후 "완전히 다른 아키텍처로 전환"하는 케이스도
안전하게 자동화됨(같은 계열 내 스왑은 기존과 동일하게 동작, 회귀 없음).

---

## 부록. 산출물 목록

| 구분 | 산출물 |
|------|------|
| IaC | `docker-compose.yml`, `.env(.example)` |
| 게이트웨이 | `litellm/config.yaml`, `litellm/Dockerfile`, `audit_logger.py`, `gemma_compat.py`, `autocomplete_compat.py` |
| PII | `presidio/recognizers/kr_custom.yaml`, `presidio/README.md` |
| 운영 스크립트 | `scripts/`: phase0_bootstrap, rotate_keys, backup, restore, stage_model, deploy_model, audit, anomaly_check, poc_quant_compare, poc_fim_compare, poc_concurrency_smoke, **switch_model_option**(§14, 구성 A/D 안전 전환) |
| 구성 프로파일 | `env-profiles/`: option-a.env(구), option-d.env(현재 채택) — 확장 가능(§14.2) |
| 문서 | `REQUIREMENTS.md`, `TEST_PLAN.md`, `CLAUDE.md`, `docs/OPERATOR_GUIDE.md`, `docs/USER_GUIDE.md`, `docs/POC_FP4_QUANT_COMPARISON.md`, 본 보고서 |
| 클라이언트 | `opencode.json`, `~/.continue/config.yaml` |
| 스테이징 모델 | Llama 8B(FP8/NVFP4), Gemma 9B/27B(FP8), StarCoder2-7B(FP8), Qwen2.5-Coder-7B(FP8), Mistral-24B(NVFP4) — 검증장비(5090) |
| 운영 스테이징 모델(구, §11.5) | Llama 3.3-70B-Instruct(FP8, ~68GB) — 운영장비(RTX PRO 6000) |
| **운영 스테이징 모델(현재 채택, §13)** | **Llama 3.3-70B-Instruct(NVFP4, ~40GB) + StarCoder2-15B(FP8, ~16GB)** — 운영장비(RTX PRO 6000) |
