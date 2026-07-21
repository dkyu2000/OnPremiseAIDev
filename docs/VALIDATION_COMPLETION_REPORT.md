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

### 18.7 운영 정책 확정: A/D/E 상시 운영자 선택제 (2026-07-13, 사용자 지시 반영)
전환 직후 사용자가 운영 정책을 명확히 했다: **선택지 A/D/E는 "이전 선택지를 대체하는 일회성 전환"이
아니라, 운영자가 상황에 따라 상시 자유롭게 선택할 수 있는 세 가지 정식 운영 옵션이다.** 초기 기동 시
기본값은 E이지만, D/A로의 전환도 언제든 정당한 운영 판단이다(예: FIM 품질 불만 접수 시 D로, gpt-oss
관련 이슈 발생 시 D/A로 임시 회피 등). 이 정책을 `CLAUDE.md` §5, `docs/OPERATOR_GUIDE.md` §10(운영자
선택 가이드 표 신규 추가 — 상황별 권장 구성)에 명시적으로 반영했다. `docs/OPERATOR_GUIDE.md` §0 아키텍처
다이어그램·컴포넌트 표도 "main = Llama"로 고정 서술하던 부분을 "main = 선택지에 따라 상이(기본 E)"로
정정했다. `docs/USER_GUIDE.md`는 사용자(개발자) 관점 문서라 항상 "현재 실제로 떠 있는 모델"만 알면
되므로 기본값(E) 기준으로 유지(운영자가 A/D로 전환하면 그때 갱신).

### 18.8 상세 메모리 구성(실측, 2026-07-13) — 선택지 E 운영 중

`nvidia-smi --query-compute-apps`(프로세스별 실사용량)와 vLLM 로그(`Model loading took`)를 대조해
가중치와 "KV+오버헤드(CUDA 컨텍스트·cudagraph 캡처 포함)"를 분리 측정. §13.9(선택지 A/D 비교)와
동일한 방법론.

| 서비스 | 모델 | 가중치 | KV+오버헤드(합산) | 프로세스 총합(실측) |
|--------|------|--------|---------------------|----------------------|
| vllm-main | gpt-oss-120b MXFP4 | 65.97 GiB | ~12.01 GiB | 77.98 GiB (79,852 MiB) |
| vllm-autocomplete | StarCoder2-7B FP8 | 6.96 GiB | ~4.77 GiB | 11.73 GiB (12,016 MiB) |
| **합계** | | **72.93 GiB** | **~16.78 GiB** | **89.71 GiB (91,868 MiB)** |

GPU 총 97,887 MiB 중 두 vLLM 프로세스가 91,868 MiB 사용, 나머지는 데스크톱/기타 프로세스(~630MiB) +
순수 여유(~4.7GiB, §18.2의 5.4GB 추정치와 시점차로 인한 근소한 차이 — 세션 중 데스크톱 앱 기동분 포함).
KV+오버헤드 세부: main은 순수 KV cache 6.46GiB + 오버헤드 ~5.55GiB, autocomplete는 순수 KV cache
2.59GiB + 오버헤드 ~2.18GiB(둘 다 vLLM `Available KV cache memory` 로그 기준, 재기동 시점에 따라
0.1~0.2GiB 편차 있음 — §18.2의 2.39GiB는 이전 기동 시점 값).

### 18.9 선택지 A/D/E 3자 비교 (2026-07-13 종합)

§13.9(A vs D)에 §17~18(E 실측)을 더해 세 선택지를 한 표로 종합 비교한다. §10 "운영자 선택 가이드"의
근거 데이터.

| 항목 | 선택지 A(구) | 선택지 D(구) | 선택지 E(현재 기본값) |
|---|---|---|---|
| main 모델 | Llama 3.3-70B-Instruct FP8 | Llama 3.3-70B-Instruct NVFP4 | **gpt-oss-120b MXFP4**(다른 아키텍처) |
| FIM 모델 | StarCoder2-7B FP8 | StarCoder2-15B FP8 | StarCoder2-**7B** FP8 |
| served-model-name | main-llama | main-llama | **main-gptoss** |
| main 가중치 | 67.72 GiB | 39.89 GiB (-27.83) | 65.97 GiB |
| FIM 가중치 | 7.32 GiB | 15.43 GiB (+8.11) | 6.96 GiB |
| main KV 캐시(27648) | ~8.7~9.0 GiB(근사) | 26.2 GiB(정밀) | 6.46 GiB(정밀) |
| FIM KV 캐시(8192) | ~2.2 GiB(근사) | 2.14 GiB | 2.39~2.59 GiB |
| GPU 총사용 | 96,462 MiB | 93,659 MiB | 92,500 MiB |
| GPU 여유 | 1.4 GiB(매우 타이트) | 3.5 GiB(여유) | **4.6~5.4 GiB(가장 여유)** |
| main 정밀도 | FP8(손실 거의 없음) | NVFP4(대형 모델 안전, §6 PoC) | MXFP4(네이티브 — SM120 미인식→Marlin 폴백이나 처리량 지장 없음, §17.3) |
| main 처리량(단일요청, 800토큰) | **9.7 tok/s**(§18.10) | **9.5 tok/s**(§18.10) | **185 tok/s**(8B급보다 빠름, MoE 토큰당 5.1B만 활성화) |
| FIM 품질(garbage 재현) | 정답 뒤 관련없는 텍스트 자주 발생 | 4회 중 3회 자연스럽게 stop, 훨씬 안정적 | A와 동일(7B 재사용, garbage 재현, §17.7/§18.2) |
| 채팅 품질 PoC(hard-set 7문항) | **5/7 정답 + 1 오답 + 1 미완성**(§18.10 — 320토큰 제한) | 6.5/7(§17.8) | **7/7**(단, `max_tokens` 900 이상 필요 — 320 이하는 잘림) |
| 동시성/부하 테스트 | 24~48건 100%, 30분 소크 6,676건 100% | 100~228건 100%, 30분 소크 6,552건 100% | 168/168+90/90건 100%(`max_tokens`≥900, §17.6/§18.2), 30분 소크 6,494건 **88.9%**(`max_tokens=300` — 원인은 harmony 포맷 길이초과, 시스템 장애 아님, §18.11) |
| .env 핵심값 | `MAIN_GPU_UTIL=0.83`, `MAIN_MAX_LEN=27648`, `AUTOCOMPLETE_GPU_UTIL=0.10` | `MAIN_GPU_UTIL=0.72`, `MAIN_MAX_LEN=27648`, `AUTOCOMPLETE_GPU_UTIL=0.20` | `MAIN_GPU_UTIL=0.80`, `MAIN_MAX_LEN=27648`, `AUTOCOMPLETE_GPU_UTIL=0.11` |
| 모델 경로 | llama-3.3-70b-instruct-fp8 / starcoder2-7b-fp8 | llama-3.3-70b-instruct-nvfp4 / starcoder2-15b-fp8 | gpt-oss-120b / starcoder2-7b-fp8 |

### 18.10 잔여 측정 보완: A 처리량/품질, D 처리량 (2026-07-13, 이어서 진행)

§18.9에서 미측정으로 남았던 항목을 `scripts/switch_model_option.sh {a|d|e}`로 순차 전환하며 보완했다
(전환 4회 자동 수행 — A 전환 시 §18.4에서 수정한 4개 버그가 실전에서도 전부 정상 동작함을 재확인:
키 allowlist 자동 갱신·`~/.continue/config.yaml` 최상위 필드 갱신 포함).

- **선택지 A 처리량**: 800토큰 생성 기준 **9.7 tok/s**(70B FP8 dense, 단일요청 배치=1 — MoE인 gpt-oss와
  달리 매 토큰 전체 파라미터가 활성화되어 느림, 예상 범위).
- **선택지 A 품질 PoC(hard-set, `max_tokens=320`)**: 7문항 중 **5문항 확실한 정답**(함정추론/역산수학/
  엣지케이스코딩/엄격포맷/다단계추론). **1문항 명백한 오답**(논리오류지적 — "펭귄은 알을 낳지 않고
  새끼를 낳기 때문"이라는 사실관계 자체가 틀린 근거를 댐, 대전제 오류라는 핵심을 전혀 못 짚음 — D/E보다
  뚜렷하게 나쁨). **1문항은 320토큰 제한으로 미완성**(한국어함정 — 정답 방향(C=6, R=4)으로 가던 중 "닭은
  6"에서 잘림, D/E는 같은 예산에서 완결했었음 — A가 이 특정 질문에서 더 장황한 경향).
- **선택지 D 처리량**: 800토큰 생성 기준 **9.5 tok/s**(A와 사실상 동일 — 단일요청 배치=1에서는
  FP8→NVFP4 양자화 포맷 차이보다 카드의 메모리 대역폭이 지배적 병목이라는 결론, §6/§13의 "동시성·
  총처리량은 늘지만 단일요청 디코드 속도는 유사"라는 기존 관찰과 일치).

### 18.11 선택지 E 30분 소크 테스트 (2026-07-13, 잔여 과제 해소)

D→A→D→E 순으로 4회 자동 전환 후(각 전환마다 §18.4의 버그 수정 4건이 실전에서도 정상 동작함을 매번
재확인) E로 복귀해 §11.10/§13.8과 동일 방법론으로 30분 소크 테스트를 실행했다: 50명 동시 시뮬레이션,
think-time 5~20초, chat(70%, `main-gptoss`, `max_tokens=300`)+FIM(30%, `autocomplete-starcoder2`)
혼합, LiteLLM 게이트웨이 경유 실제 가상 키 사용.

**결과: 6,494건 처리, 전반부 89.0%/후반부 88.9% 성공 — A/D의 100%와 달리 처음으로 실패가 관측됨.**

- **GPU/안정성 측면은 A/D와 동일하게 완벽**: VRAM 92,388MiB로 30분 내내 1MiB도 변하지 않음(누수 없음),
  온도 83~88°C에서 안정화, **지연 드리프트 0.90s→0.90s(변화 없음)**. 실패 720건 전부 `err=None`(예외/
  타임아웃 없음) — 인프라·시스템 레벨 장애는 전무.
- **실패 원인 특정(추가 조사, 시스템 문제 아님):** 실패 표본을 재현한 결과, 실패는 전부 `finish_reason:
  "length"` — §17.8/§18.2에서 이미 확인한 gpt-oss의 harmony 포맷(reasoning+content 분리) 특성이
  `max_tokens=300`에서 재현된 것. 소크 테스트에 쓴 프롬프트 9종을 동일 조건(`max_tokens=300`,
  `temperature=0`)으로 개별 재현한 결과 **2/9(약 22%)가 매번 `length`로 잘림**("파이썬에서 리스트
  길이 구하는 함수?", "리팩터링 팁 세 가지를 짧게 알려줘" — 겉보기엔 간단해 보이는 질문도 gpt-oss가
  장황하게 사고과정을 전개하면 예산을 초과함). chat이 전체 트래픽의 70%이므로 0.7×0.22≈15%가
  이론치, 실측 11.1%(720/6,494)와 근사.
- **★핵심 교훈: 어려운 질문에서만이 아니라 "간단해 보이는 질문"에서도 harmony 포맷이 예산을 초과할
  수 있다.** §17.8에서는 hard-set(의도적으로 어려운 7문항)만 테스트했었는데, 이번 soak test로 **평범한
  질문도 위험군**임이 추가로 확인됨 — `max_tokens=900` 권장(§18/OPERATOR_GUIDE §10)이 hard-set뿐
  아니라 일반 사용 전반에 적용돼야 함을 강화하는 근거.
- §18.2에서 이미 `max_tokens=900` 조건으로 90/90(100%) 성공을 확인했으므로(동일 gpt-oss+27648
  컨텍스트), **900 이상으로 설정하면 이 실패 유형은 재현되지 않을 것으로 판단**되나, 30분 규모의
  soak test를 900 기준으로 재실행하지는 않았다(잔여 과제로 남김).

**결론: 선택지 E는 시스템 안정성(GPU/메모리/지연 드리프트)은 A/D와 동등하게 완벽하지만, 낮은
`max_tokens`(300 이하) 설정 시 A/D에는 없는 "답변 미완성" 유형의 실패가 발생할 수 있음이 실측
확인됨.** `docs/OPERATOR_GUIDE.md` §10에 "E 운영 시 클라이언트 `max_tokens` 기본값을 900 이상으로
설정"을 필수 권고로 승격 반영.

### 18.12 사용자 편의를 위한 컨텍스트 소폭 확장 재튜닝 (2026-07-14)

운영팀(사용자) 요청: OpenCode에서 `/opsx:explore` 등 반복 작업 중 세션이 컨텍스트 한도(27648)를
넘겨 `max_tokens must be at least 1, got -N` 오류가 자주 발생 — 편의를 위해 컨텍스트를 2배로
늘리는 방안을 검토해달라는 요청에서 시작.

**2배(약 55000) 확장은 기각.** 현재 KV캐시(6.46GiB@27648)와 동일한 동시성을 유지하려면 KV 예산이
거의 2배(~12.9GiB) 필요한데, 가용 여유는 4.7GB뿐이라 산술적으로 불가능(기동 실패 또는 동시성
급감 중 택일). 대신 **여유 안에서 가능한 소폭 확장**으로 재검토:

- **적용값**: `MAIN_MAX_LEN` 27648→**32768**(+18.5%), `MAIN_GPU_UTIL` 0.80→**0.81**.
- **실측 결과**: `vllm-main` 재기동 후 KV캐시 7.41GiB 확보(107,888토큰), GPU 총사용 93,424MiB/
  97,887MiB(**여유 3,818MiB=3.7GB**). 컨테이너 healthy, autocomplete/litellm 영향 없음(main만
  단독 재기동).
- **★사전 추정 오류 발견 및 정정**: 애초 "동시성 5.23x"(§17.5 기록)를 근거로 "동시 처리 5명"을
  유지하며 확장 가능할 것으로 추정했으나, 실측 KV(7.41GiB→107,888토큰)에서 토큰당 실제 메모리
  비용을 역산해 기존 설정(6.46GiB@27648)에 그대로 대입하면 **실제 동시성은 약 3.4x**였던 것으로
  재계산됨(5.23x는 부정확한 과거 기록으로 판단). 재튜닝 후 실제 동시성은 약 3.3x — 즉 **이번
  변경은 동시성을 거의 그대로 유지하면서 컨텍스트만 18.5% 확장한 결과**이며, 사용자가 요청한
  "동시성 5명 유지"는 애초 이 하드웨어 여유(가용 총 VRAM 97.9GB, 가중치만 72.93GiB 고정 소모)로는
  27648 기준으로도 달성된 적이 없었던 목표였음을 확인·공유함.
- **여유 3.7GB는 선택지 D(3.5~4.5GB)와 동급** — §2의 "여유 타이트한 구성은 재기동 실패 리스크
  최고"(구 선택지 A, 여유 30MiB) 사례와는 명확히 다른 안전 범위.
- **후속 반영**: `env-profiles/option-e.env`(`MAIN_GPU_UTIL=0.81`/`MAIN_MAX_LEN=32768`),
  `CLAUDE.md` §5, `OPERATOR_GUIDE.md` §10, `USER_GUIDE.md`(FAQ 3건) 전부 갱신. 클라이언트
  `opencode.json`(본 리포/`opencode.json.example`/test_prj/test_prj_schedule 전체)의
  `limit.context`도 26000→**30000**으로 동반 상향(서버 실한도 32768보다 여유 둠, 기존 원칙 유지).
- **결론**: "컨텍스트를 2배로"라는 원 요청은 VRAM 한계로 불가하나, 안전 마진 내에서 실질적인
  개선(+18.5% 컨텍스트, 동시성 손실 없음)을 제공하는 선에서 확정. 추가 확장은 여유가 위험
  구간(1GB 이하)에 진입하므로 권장하지 않음 — 더 필요하면 A/D로 임시 전환하거나 근본적으로는
  워크플로우 개선(§USER_GUIDE.md의 "공유 메모 파일" 패턴, 세션 분리)을 우선 권장.

### 18.13 선택지 G 신설: gpt-oss-120b 단독(FIM 없음, 컨텍스트 최대 확보) (2026-07-14)

§18.12 재튜닝 직후 사용자가 "FIM 없이 main만 올려서 KV캐시를 최대한 확보"하는 새 선택지를
요청했다. 진행 전 두 가지를 확인함(AskUserQuestion):
1. G 적용 시 IDE tab 자동완성이 완전히 꺼지는 것에 동의 — 사용자 확인: "G는 채팅/에이전트
   전용, FIM 필요 시 A/D/E로 전환".
2. 목표 컨텍스트 — 사용자 확인: "65536(현재의 2배)".

**인프라 변경(A/D/E와 다른 신규 패턴 — 최초의 1-트랙 구성):**
- `scripts/switch_model_option.sh`에 `AUTOCOMPLETE_ENABLED=false` 프로파일 키 지원 추가.
  `REQUIRED_KEYS`를 `MAIN_REQUIRED_KEYS`/`AUTOCOMPLETE_REQUIRED_KEYS`로 분리해, solo 프로파일은
  autocomplete 관련 키 없이도 유효성 검증을 통과하도록 함. solo일 때는 모델 디렉터리 검증도
  main만 수행하고, `vllm-autocomplete`는 기동하지 않고 정지 상태로 유지(순차 기동 로직 자체가
  불필요 — 단독 프로세스라 §13.3의 "동시기동 시 메모리 프로파일링 간섭" 문제가 원천적으로 없음).
- **부수적으로 발견한 잠재 버그를 함께 고침**: 기존 스크립트는 선택지 전환 시 `opencode.json`의
  모델 키/라벨은 갱신했지만 `limit.context`(클라이언트가 선언하는 컨텍스트 한도)는 갱신하지
  않았다. A/D(27648)→E(32768, §18.12 재튜닝)→G(65536)처럼 선택지마다 서버 실한도가 달라지는
  경우가 실제로 생기면서, 방치하면 "서버보다 큰 context를 클라이언트가 들고 있어 max_tokens
  음수 오류가 재발"하는 문제가 될 수 있음을 인지 — `MAIN_CLIENT_CONTEXT` 프로파일 키를 추가하고
  `update_client_config()`가 이 값을 `opencode.json`에 함께 반영하도록 확장(A/D=26000, E=30000,
  G=60000으로 각 프로파일에 기록). 향후 어떤 선택지로 전환하든 클라이언트 context가 자동으로
  같이 맞춰진다.

**실측 결과(`switch_model_option.sh g` 1차 시도로 즉시 성공):**

| 항목 | 값 |
|---|---|
| main 가중치 | 65.97GiB(고정) |
| `MAIN_GPU_UTIL` | 0.90 |
| `MAIN_MAX_LEN` | 65536 |
| KV캐시(실측) | 15.96GiB, 232,352토큰 |
| 동시성(풀컨텍스트 기준) | 약 3.55x |
| GPU 총사용/여유 | 91,055MiB / **6,187MiB(6.05GB)** |

여유 6.05GB는 지금까지의 A/D/E 어떤 구성보다도 크다 — FIM(가중치+KV 9.35GiB)을 완전히 뺀 효과가
사전 추정(약 9.8GB 이론 여유, util 0.90 가정)보다는 작았지만(vLLM 오버헤드가 예상보다 더 소모),
그래도 E(3.7GB)의 약 1.6배 수준. E2E 검증: LiteLLM 경유 `main-gptoss` 정상 응답(200) 확인,
`autocomplete-starcoder2` 요청은 의도대로 연결 오류(500, 컨테이너 미기동) 확인.

**결론**: G는 여섯 선택지(A/B/C/D/E/G, B/C는 미채택) 중 컨텍스트(65536)·GPU 여유(6.05GB) 모두
최대이며, FIM을 완전히 포기하는 대가로 얻는 트레이드오프임을 `CLAUDE.md`/`OPERATOR_GUIDE.md`
§10 "운영자 선택 가이드" 표에 명시 반영. `env-profiles/option-g.env`, `env-profiles/README.md`
(solo 구성 설명 추가) 갱신 완료.

### 18.14 선택지 F 시도·철회: Llama 3.3-70B NVFP4 단독 (2026-07-14, 당일 폐기)

G의 solo 패턴을 Llama-NVFP4에 적용한 "선택지 F"를 사용자 요청으로 신설·실측까지 완료했으나,
**실사용 품질 미달로 당일 폐기**했다(사용자 결정: "F는 삭제하고 G 중심으로 정리").

- **실측 기록(참고 가치)**: weights 39.89GiB, util 0.90 → KV 43.29GiB(141,840토큰). 1차 시도
  `MAIN_MAX_LEN=98304`(동시성 1.44x), 사용자 요청으로 2차 재튜닝 `40000`(동시성 G 수준 3.55x).
  GPU 여유 6.9GB. **이 수치들은 "Llama 계열 solo 구성이 필요해질 경우"의 베이스라인으로 유효.**
- **철회 사유**: ①실사용에서 채팅/에이전트 품질이 gpt-oss 대비 명확히 체감 열세(품질 PoC 6.5/7
  vs 7/7, 처리량 1/8~1/20의 기존 실측과 일치하는 사용자 평가), ②Llama로 전환 후 OpenCode
  슬래시 명령(`/opsx:explore <파일>`)을 통째로 파일 경로로 오인하는 도구 호출 파싱 불안정이
  간헐 재현(gpt-oss에서는 미재현 — 모델별 tool-calling 신뢰도 차이).
- **부산물(유지됨)**: 이 작업으로 추가된 `MAIN_CLIENT_CONTEXT` 프로파일 키(전환 시 클라이언트
  context 자동 동기화)와 `AUTOCOMPLETE_ENABLED=false` solo 지원은 F 폐기와 무관하게 스크립트에
  남아 G 등 다른 구성에서 계속 사용된다.
- `env-profiles/option-f.env` 삭제, `CLAUDE.md`/`env-profiles/README.md`에서 F 항목 제거(본 절이
  유일한 기록).

---

## 19. 2차 개선 프로젝트 (2026-07-15~)

운영 중 확인된 요구("gpt-oss-120b 이상의 품질", "KV 캐시 효율화")를 목표로 한 단계별 개선
프로젝트. 로드맵: **Phase 1** 모델 품질 경쟁(GLM-4.5-Air 등 후보 vs gpt-oss) → **Phase 2**
vLLM 0.20.2+ 업그레이드 검증 → **Phase 3** KV 효율화(TurboQuant/TriAttention/fp8 KV) 실측 →
**Phase 4** SGLang 전환은 보류(TurboQuant이 vLLM에만 병합돼 있어 전환 시 오히려 손해 — 사전
분석으로 기각). 관련 배경: 중국계 모델 정책이 "테스트 용도 한정 허용"으로 변경됨(2026-07-14,
CLAUDE.md §5 각주).

### 19.1 Phase 1: GLM-4.5-Air NVFP4 품질 PoC (2026-07-15)

**후보 선정 근거**: GLM-4.6은 vLLM 소스 확인 결과 `GlmMoeDsaForCausalLM(DeepseekV2ForCausalLM)`
상속 = DeepSeek와 동일한 MLA 어텐션 → SM120 전멸(§16 Mistral과 동일 원인)이 예상되어 배제.
GLM-4.5-Air(`Glm4MoeForCausalLM`)는 표준 어텐션(kv_lora_rank 없음)으로 안전 확인 후 선정.
공식 zai-org FP8은 104.83GiB로 GPU 초과 → 커뮤니티 NVFP4(`Firworks/GLM-4.5-Air-nvfp4`,
57.68GiB, nvfp4-pack-quantized, 사용자 승인)로 진행.

**다운로드 이슈**: HF 비인증 다운로드가 2회 연속 장시간 정체(연결이 소리 없이 끊긴 채 프로세스만
생존) + `hf download` 재시작 시 진행 중이던 파일의 이어받기 실패(새 임시파일로 재시작) 확인 →
남은 파일만 `curl -C -`(이어받기) + 정체 자동감지(`--speed-time 60 --speed-limit 51200`) 재시도
루프로 전환해 해결. **향후 대용량 모델 반입 시 이 curl 패턴 재사용 권장.** 전체 파일 크기 대조
(HF 메타데이터 vs 로컬)로 무결성 검증 통과(13/13).

**기동 실측(vLLM 0.17.1 그대로, 단독, util 0.90, max-len 8192)**:

| 항목 | GLM-4.5-Air NVFP4 | 비교: gpt-oss-120b(G) |
|---|---|---|
| 아키텍처 | 106B/12B active MoE, 표준 어텐션(FLASH_ATTN) | 120B/5.1B active MoE |
| 기동 | ✅ 0.17.1 즉시 성공(업그레이드 불필요) | ✅ |
| 가중치 | 57.75GiB | 65.97GiB(−8.2GiB 유리) |
| KV 토큰당 비용(역산) | **~184KB/token** | ~72KB/token(**2.5배 유리**) |
| 스모크 테스트 | 정상(garbage 없음, 한국어 OK) | — |

**품질 PoC(§17.8과 동일 hard/easy-set, temperature=0)**:

| 조건 | GLM-4.5-Air | gpt-oss-120b(§17.8 기록) |
|---|---|---|
| hard-set @900tok | 3/7 완결(완결분 전부 정답, 4개 thinking 잘림) | 7/7 |
| hard-set @2000tok | **7/7 전부 정답** | (측정 불필요 — 900에서 이미 7/7) |
| easy-set @900tok | 4/5 완결(전부 정답, 1개 잘림) | — |
| 처리량(단일 요청) | 87~91 tok/s | 184~185 tok/s(**2배 유리**) |

- GLM도 thinking 모드 기본 활성(`<think>…</think>` 인라인, chat template에서 `/nothink`로 끄기
  가능). **thinking이 gpt-oss의 harmony보다도 길어서** 완결에 필요한 max_tokens가 900으로도
  부족(hard 4/7, easy 1/5 잘림) — **GLM 채택 시 max_tokens 2000+ 필요**(gpt-oss는 900).

**Phase 1 결론: GLM-4.5-Air는 "동급"이지 "이상"이 아님 — gpt-oss-120b 유지.**
품질은 hard-set 7/7로 대등하나, ①처리량 절반, ②응답당 토큰 소모 2배 이상(thinking 길이),
③KV 토큰당 비용 2.5배(solo 구성 시 유효 컨텍스트 용량 열세: 같은 util 0.90에서 GLM 144K vs
gpt-oss 232K 토큰)로 **세 가지 효율 지표 모두 열세**. 교체할 근거 없음. 단, **중국계·비중국계
통틀어 gpt-oss 외에 이 하드웨어에서 정상 동작이 확인된 첫 번째 대등 품질 백업 후보**라는 가치가
있음(§16의 Mistral/Nemotron은 기동조차 실패). 모델 파일은 `models-test/glm-4.5-air-nvfp4`에
보존(테스트 전용 — 운영 정책상 정식 선택지 등록 금지, CLAUDE.md §5 각주).

테스트 후 G 원복 및 LiteLLM 경유 E2E 정상(200) 재확인 완료.

### 19.2 Phase 2: vLLM v0.20.2 업그레이드 검증 + KV 효율화 사전 실측 (2026-07-15)

TurboQuant 최소 요건(v0.20.2+) 충족 버전으로 §15와 동일 방법론(운영 중지 → 동일 파라미터 단독
기동 → 실측 → 원복) 검증. 대상 모델은 현재 운영 기본인 gpt-oss-120b(선택지 G 파라미터:
util 0.90 / max-len 65536).

**정적 확인**: v0.20.2에 TurboQuant KV dtype 4종(`turboquant_k8v4`/`turboquant_4bit_nc`/
`turboquant_k3v4_nc`/`turboquant_3bit_nc`) + `nvfp4` KV 등 신규 옵션 정식 포함 확인.

**★기동 실패 1회 — 업그레이드 시 반드시 반영해야 할 설정 변경:**
`VLLM_USE_FLASHINFER_MOE_MXFP4_MXFP8=1`(0.17.1에서는 무시되고 Marlin 폴백)을 v0.20.2는 **"백엔드
강제 지정"으로 해석**해 SM120 미지원 커널(FLASHINFER_TRTLLM_MXFP4_MXFP8)을 강제하다 기동 거부
(`kernel does not support current device`). 플래그 제거 후 Marlin 자동 선택으로 정상 기동.
→ **운영 전환 시 `env-profiles/option-e.env`/`option-g.env`의 `MAIN_MXFP4_FLASHINFER=1`을 0으로
바꿔야 함**(잊으면 기동 실패).

**실측 결과(gpt-oss-120b, util 0.90 / max-len 65536 동일 조건):**

| 항목 | v0.17.1(운영) | v0.20.2 | 판정 |
|---|---|---|---|
| MXFP4 백엔드 | MARLIN | MARLIN(자동) | 동일 |
| 어텐션 백엔드 | FLASH_ATTN | TRITON_ATTN(유일 후보로 변경) | 성능 영향 없음(아래) |
| KV캐시 메모리 | 15.96GiB | 14.71GiB(−7.8%, §15의 CUDA graph 효과) | 예상 범위 |
| **KV 토큰 용량** | 232,352 | **380,128(+64%)** | ★대폭 개선 |
| 풀컨텍스트 동시성 | 3.55x | **5.8x** | ★개선 |
| 품질(hard-set @900) | 7/7 | **7/7** | 유지 |
| 처리량(단일) | 184~185 tok/s | **191.5 tok/s(+3.5%)** | 소폭 개선 |
| tool calling / reasoning 분리 | 정상 | 정상 | 유지 |

- KV 토큰 용량 +64%는 0.20.x가 gpt-oss의 sliding window 레이어 KV를 윈도우 크기만큼만 할당하는
  개선 덕분으로 추정 — **메모리가 줄었는데 용량이 늘어난, 이번 검증의 최대 수확.**
- ★API 변경: 응답의 reasoning 필드명이 `reasoning_content`→**`reasoning`**으로 변경됨(0.20.2
  직접 호출 기준). LiteLLM 경유 시 정규화 여부는 운영 전환 검증 때 클라이언트(OpenCode/Continue)
  실사용으로 확인할 것.

**Phase 3 사전 실측(같은 중단 시간 내 보너스 테스트):**

| KV 효율화 옵션 | 결과 | KV 토큰 용량 | 품질/처리량 |
|---|---|---|---|
| `turboquant_k8v4` | ❌ **기동 거부** | — | — |
| `fp8` | ✅ 성공 | **767,241(운영 대비 3.3배!)** | hard-set 7/7 / 191.7 tok/s(동일) |

- **TurboQuant × gpt-oss 비호환의 원인은 SM120이 아니라 attention sinks**: 에러 메시지가 정확히
  `TURBOQUANT: [attention sinks not supported]` — gpt-oss 고유의 어텐션 싱크 구조를 TurboQuant
  커널이 미지원. **sinks가 없는 GLM-4.5-Air/Llama에는 여전히 적용 가능성이 있음**(Phase 3에서
  검증 예정). GPU 세대 문제가 아니므로 업스트림이 sinks 지원을 추가하면 gpt-oss도 가능해질 수 있음.
- **fp8 KV는 gpt-oss에서 완벽 동작**: 토큰 용량 767K(= util 0.90/65536 기준 풀컨텍스트 동시
  **11.7명**), 품질·처리량 저하 없음(hard-set 기준 — 운영 채택 전 소크 테스트 권장).

**Phase 2 결론: v0.20.2 업그레이드 Go.** 품질/기능 저하 없이 KV 용량 +64%(auto) 또는
+230%(fp8 KV)를 얻는다. 운영 전환 시 체크리스트: ①`MAIN_MXFP4_FLASHINFER=0`으로 변경,
②`VLLM_IMAGE=vllm/vllm-openai:v0.20.2`, ③reasoning 필드명 변경의 클라이언트 영향 확인,
④전환 후 동시성 부하 테스트 재실행(§13 방법론). 테스트 후 G(0.17.1) 원복·E2E 정상(200) 확인.

### 19.3 운영 전환 실행: vLLM v0.17.1 → v0.20.2 (2026-07-15, 사용자 승인)

§19.2 체크리스트대로 실제 운영 전환을 수행했다(선택지 G 구성 유지, 엔진만 교체).

**변경 사항:**
- `.env`: `VLLM_IMAGE=vllm/vllm-openai:v0.20.2`, `MAIN_MXFP4_FLASHINFER=1→0`
- `env-profiles/option-e.env`/`option-g.env`: `MAIN_MXFP4_FLASHINFER=0`으로 영구 수정(주석으로
  0.20.2 기동 거부 사유 명시 — 향후 어떤 프로파일 전환에도 이 함정 재발 방지)
- `.env.example`, `CLAUDE.md` §2/§4 고정 버전 표 갱신
- KV dtype은 `auto` 유지(fp8 KV는 §19.2에서 검증됐으나 소크 테스트 후 별도 채택 결정 — Phase 3)

**전환 후 검증(전부 통과):**

| 검증 항목 | 결과 |
|---|---|
| vllm-main healthy | ✅ MARLIN 자동 선택, KV 380,114토큰(+64%) |
| LiteLLM 경유 채팅 E2E | ✅ 200, **LiteLLM이 `reasoning`→`reasoning_content`로 정규화해줌**(클라이언트 영향 없음 확인) |
| LiteLLM 경유 tool calling | ✅ 정상 — 단 **v0.20.2는 tool 정의의 `description` 필드를 필수로 검증**(누락 시 400). OpenCode/Continue는 항상 포함하므로 실사용 영향 없음, 직접 API 호출 스크립트만 주의 |
| OpenCode 실사용(도구 호출 포함 작업) | ✅ Glob/Read 도구 호출·한국어 응답 정상 |
| 동시성 부하(8×3, 20×3 라운드) | ✅ **84/84(100%)**, 평균 지연 1.73s/2.69s, OOM·오류 없음 |
| GPU | 88,976MiB 사용 / **여유 8.27GB**(0.17.1 때 6.05GB보다 증가 — KV 메모리 회계 효율화 효과) |

**결과: 운영 스택이 v0.20.2로 전환 완료.** 같은 하드웨어·같은 모델·같은 util로 KV 토큰 용량
+64%(풀컨텍스트 동시성 3.55x→5.8x), GPU 여유 +2.2GB, 처리량 +3.5%를 얻었다. fp8 KV 채택(용량
3.3배)은 Phase 3에서 결정.

### 19.4 전환 직후 30분 소크 테스트 (2026-07-15, 같은 날)

§11.10/§18.11과 동일 방법론(50명, think-time 5~20초), 단 G 구성이라 100% chat, §18.11의 교훈을
반영해 `max_tokens=900`으로 실행.

**결과: 5,713건, 전반부 95.0%/후반부 94.3% 성공. 시스템 안정성 지표는 전부 완벽:**
- VRAM 30분 내내 88,973~89,082MiB(변동 ±0.1% — 누수 없음), 온도 86~87°C 안정.
- **지연 드리프트 없음**: p50 1.98s→1.76s(오히려 감소), p95 14.6s 유지.
- 실패 305건(5.3%) 전부 `err=None`(예외/타임아웃/시스템 오류 0건).

**실패 원인 재현·특정(§18.11과 동일 유형, 시스템 문제 아님):** 소크 프롬프트 10종을 동일 조건으로
개별 재현한 결과 "파이썬에서 리스트 길이 구하는 함수?" 1종이 `max_tokens=900`에서도 `finish_reason:
length`로 잘림 — §18.11에서 300 기준 위험군으로 지목했던 바로 그 프롬프트로, harmony 사고과정이
간단한 질문에서 장황해지는 gpt-oss 고유 특성이 900에서도 간헐 재발(동시 배치 상황의 비결정성으로
확률적 발생 — 단독 재현은 900에서 잘리고, 오늘 동시성 스모크 84/84에서는 통과). **1200으로 올리면
3/3 안정 완결 실측** — max_tokens 권고를 900→**1200 이상**으로 상향(OpenCode/Continue 클라이언트는
`output: 4096`이라 원래 영향 없음, 직접 API 호출 자동화만 해당).

**판정: v0.20.2 운영 전환 최종 안정 확인.** 실패는 전부 §18.11에서 이미 규명된 harmony 토큰 예산
유형이고 엔진 업그레이드와 무관(0.17.1에서도 동일 프롬프트가 동일하게 잘렸음), 시스템·메모리·지연
관점에서는 30분 연속 부하에서 결함 0건.

### 19.5 Phase 3: fp8 KV캐시 운영 채택 (2026-07-15, 같은 날)

§19.2에서 검증(품질 hard-set 7/7, 처리량 동일)된 fp8 KV캐시를 운영에 적용했다.
`MAIN_EXTRA_ARGS`에 `--kv-cache-dtype fp8` 추가(`.env` + `env-profiles/option-g.env` 영구 반영,
compose 수정 불필요).

**적용 후 실측:**

| 항목 | auto(§19.3) | fp8 KV(채택) |
|---|---|---|
| KV 토큰 용량 | 380,114 | **763,621(2.0배, 0.17.1 대비 3.3배)** |
| 풀컨텍스트(65536) 동시성 | 5.8x | **11.7x** |
| E2E 품질 스팟체크(함정 산수) | — | 정답("4"), stop 완결 |
| 동시성 스모크(8×3/20×3) | 84/84 | **84/84(100%)**, p50 1.07s/1.70s(auto보다 소폭 빠름) |
| GPU | 여유 8.27GB | 여유 8.24GB(동일 수준) |

- ★롤백 주의: fp8 KV+attention sinks 조합은 v0.20.2에서만 검증됨 — 0.17.1로 롤백할 일이 생기면
  `MAIN_EXTRA_ARGS`에서 `--kv-cache-dtype fp8`을 함께 제거할 것(option-g.env 주석에 명시).
- 선택지 E(2-트랙)는 아직 0.20.2/fp8 KV 재검증 전 — E로 전환할 일이 생기면 §13 방법론으로 재튜닝
  후 적용할 것.

**2차 개선 프로젝트 결산(Phase 1~3 완료):** 시작 시점(v0.17.1, KV 232K) 대비 최종(v0.20.2+fp8 KV,
KV 763K) **토큰 용량 3.3배·풀컨텍스트 동시성 3.55x→11.7x**, 품질(hard-set 7/7)·처리량(191 tok/s)
유지, GPU 여유 6.05→8.24GB. 모델 교체 없이(gpt-oss 유지) 엔진·KV 최적화만으로 달성.
잔여 선택 과제: TurboQuant×GLM/Llama 검증(sinks 없는 모델용 — 현재 gpt-oss 채택 상태에서는
실익 없어 보류), Phase 4(SGLang)는 기각 유지.

### 19.6 KV 효율화 3종 비교: TurboQuant / TriAttention / fp8 KV (2026-07-15, 선택지 G 기준)

원래 Phase 3 계획대로 세 기법을 전부 실측 비교했다(공통: gpt-oss-120b, v0.20.2, util 0.90,
max-len 65536, 격리 테스트 후 운영 원복).

| 기법 | 기동 | 품질(hard-set @900) | 처리량 | KV 효과 | 비고 |
|---|---|---|---|---|---|
| (기준) auto | ✅ | 7/7 | 191.5 tok/s | 380K토큰 | §19.2 |
| **fp8 KV(운영 채택)** | ✅ | 7/7 | 191.7 tok/s | **763K토큰(2배)** — 정직한 용량 확장 | §19.5 |
| **TurboQuant**(`turboquant_k8v4`) | ❌ 기동 거부 | — | — | — | gpt-oss attention sinks 미지원(§19.2, SM120 문제 아님) |
| **TriAttention**(플러그인 v0.2.0) | ✅ | **7/7** | 192.2 tok/s | 할당량 불변(380K), **요청당 KV를 budget(2048토큰)으로 상한** — 긴 컨텍스트 동시성↑ | 아래 상세 |

**TriAttention 검증 상세(SM120에서 실동작 확인 — 공식 미검증 하드웨어였으나 성공):**
- 설치: `pip install .`(vLLM 플러그인 엔트리포인트 자동 등록) → `vllm-triattn:v0.20.2` 이미지 커밋.
- ★필수 설정 2가지(둘 다 빠지면 실패): ①`TRIATTN_RUNTIME_SPARSE_STATS_PATH` — 모델별 사전 계산
  통계 필요. **리포에 gpt-oss-120b용 통계(`triattention/vllm/stats/gpt_oss_120b_stats.pt`)가 동봉**
  되어 있어 바로 사용 가능(미설정 시 budget 초과 요청에서
  `TRIATTN_FATAL_TRITON_SCORING_REQUIRED:stats_path_not_set`로 크래시 — 실측). ②이미지 커밋 시
  entrypoint 원복(`vllm serve`).
- 활성 로그가 vLLM 로깅 설정에 눌려 안 보이므로 주의 — 활성 여부는 "budget 초과 요청이 fatal 없이
  성공하는가"로 판별(REQUIRE_TRITON_SCORING=true 기본값 덕분에 미동작 시 크래시로 드러남).
- **needle 테스트 통과**: 6,710토큰 문서 맨 앞에 심은 비밀 코드명을 budget 2048 상태에서 정확히
  회수 — 중요도 기반 토큰 선별이 실제로 유효(단순 절단이 아님).
- 8,837토큰 요약 요청 정상(3.0s), hard-set 7/7, 처리량 저하 없음.

**비교 결론(선택지 G/gpt-oss 기준):**
- **fp8 KV가 운영 기본으로 우월**: 근사 없이(양자화만) 용량을 정직하게 2배 늘리고, 설정 한 줄로
  끝나며, 외부 플러그인 의존이 없다. 현재 운영 채택 유지.
- **TriAttention은 "검증된 예비 카드"**: SM120+gpt-oss에서 실동작·품질 유지가 확인됐고, fp8 KV와
  방향이 달라(용량 확장 vs 요청당 사용량 상한) **초장문 다중 사용자 시나리오가 실제로 병목이 되면
  fp8 KV 위에 추가 적용을 검토**할 가치가 있다(조합 가능성은 미검증 — 필요 시점에 별도 확인).
  단 커뮤니티 프로젝트(v0.2.0) 의존성·업스트림 미병합·모델별 통계 파일 필요가 운영 리스크.
- **TurboQuant는 gpt-oss와 구조적 비호환**(sinks) — 모델을 바꾸지 않는 한 대상 아님.

### 19.7 추가 모델 후보 재검토: Mistral 재시도 실패, Nemotron-3-Super 신규 검증 (2026-07-15~)

사용자 요청("gpt-oss-120b 이상의 추가 모델")으로 후보를 재검토했다. 사전 조사 결론:
- **Nemotron-3-Super-120B-A12B**: 공개 벤치마크에서 gpt-oss-120b 대비 실질 우위 확인 —
  **SWE-Bench Verified 60.5 vs 41.9**(개발자 에이전트 용도에 결정적), MMLU-Pro 83.7 vs 80.7,
  컨텍스트 256K vs 128K. 단 속도 ~2배 느림, AIME는 gpt-oss 우위. 공식 NVIDIA NVFP4(80.37GB) 존재,
  v0.20.2에 `NemotronHForCausalLM` 정식 등록 확인 → **다운로드·검증 진행**(1순위).
- **GLM-5.2(754B)/Qwen3-235B/MiniMax**: 96GB 초과로 물리적 불가. **Llama 4 Scout**: 들어가지만
  벤치마크상 gpt-oss 이상 아님. **DeepSeek/Kimi 계열**: MLA로 SM120 불가.

**Mistral-Small-4-119B 재시도(v0.20.2) — 최종 실패 확정:**
- v0.20.2의 MLA 백엔드 지원을 소스에서 직접 확인: CUTLASS_MLA(major==10)/FLASHMLA(9,10)/
  FLASHINFER_MLA(10)/FLASHATTN_MLA(9) — **전용 커널 4종 모두 여전히 SM120(major 12) 미지원**.
- 실측: 기동·가중치 로드(66.21GiB)·헬스체크까지는 통과(TRITON_MLA 선택, MLA의 KV 압축 덕에
  761K토큰 확보)했으나, **첫 추론에서 §16과 동일한 Triton 커널 크래시 재현**
  (`CompilationError: Cannot make_shape_compatible: incompatible dimensions at index 1: 256 and 512`
  — kv_lora_rank=256 형상 불일치). 0.20.0→0.20.2에서 수정되지 않음.
- **결론: MLA 계열은 vLLM이 SM120용 MLA 커널을 정식 추가하기 전까지 이 하드웨어에서 불가**(§16
  결론 유지·강화). 모델 파일은 보존(향후 vLLM 메이저 업그레이드 시 재시도 후보).

**Nemotron-3-Super 메모리 사전 분석(다운로드된 config.json 실수치 기반, 실측 전 추정):**

아키텍처가 특이하다 — 88개 레이어 중 **어텐션이 단 8개**(hybrid_override_pattern에서 `*`=8,
Mamba2 `M`=40, MoE `E`=40), 그 8개도 극단적 GQA(num_key_value_heads=2, head_dim=128).

| 항목 | gpt-oss-120b(운영 실측) | Nemotron-3-Super(config 기반 계산) |
|---|---|---|
| 가중치 | 65.97GiB | ~74.9GiB(+9GiB) |
| KV/토큰(BF16) | 40.6KB | **8.0KB(1/5)** |
| Mamba 고정 상태 | 없음 | 시퀀스당 80MiB(길이 무관, 동시 수에 비례) |
| 네이티브 컨텍스트 | 131K | **262K** |

util 0.90 가정 시 KV 풀 ~8.7GiB(가중치가 커서 gpt-oss의 14.7GiB보다 작음)이나 토큰당 비용이
1/5이라 **BF16 KV만으로 ~110만 토큰**(gpt-oss fp8 KV의 763K를 상회), 256K 풀컨텍스트 동시 ~4명
추정. 요약: 가중치는 더 무겁지만 KV 경제성 5배 — **gpt-oss가 물리적으로 불가능한 초장문(256K)
작업이 가능한 구조**. 단 GPU 여유 마진 축소(util 하향 조정 가능성)와 Mamba 상태의 동시 수 비례
증가는 실측으로 확정 필요. 다운로드(80GB) 진행 중 — 완료 후 격리 기동/품질 PoC 예정.

### 19.8 신규 후보 3종 격리 검증 결과: Nemotron-3-Super / Gemma 4-31B / Qwen3.6-27B (2026-07-15~16)

사용자 요청("gpt-oss 이상 후보 검증")으로 3개 모델을 §17 방법론(격리 기동→스모크→KV 실측→hard-set
PoC→tool calling→needle→처리량→운영 원복)으로 순차 검증했다. 각 테스트 사이 운영(G) 원복·E2E 200
확인 유지.

**종합 비교표 (기준선: gpt-oss-120b 운영 구성, vLLM v0.20.2, util 0.90, max-len 65536):**

| 항목 | gpt-oss-120b(운영) | Nemotron-3-Super | Gemma 4-31B | Qwen3.6-27B |
|---|---|---|---|---|
| 라이선스/출처 | Apache 2.0 | NVIDIA Open License | Apache 2.0 | Apache 2.0(중국계·테스트 전용) |
| 배치 | `models/` | `models/` | `models/` | `models-test/` |
| 가중치 | 65.97GiB | 69.54GiB | **31.49GiB** | **28.51GiB** |
| 기동(SM120) | ✅ | ✅ **하이브리드 Mamba 최초 성공** | ✅ | ✅ **GDN(DeltaNet) 최초 성공** |
| KV 실측 | 763K토큰(fp8 KV) | **198.6만 토큰**(BF16!) — 30.3x@65K | 266.9K — 4.07x | 791.7K — 12.08x |
| hard-set | 7/7 | **7/7** | **7/7** | 6/7(논리 문항 오답) |
| 응답 토큰경제(hard 7문항) | 2,122tok | **1,598~1,859tok(최고)** | **933tok(즉답형 최고)** | 7,325tok(과잉사고) |
| tool calling | ✅ openai | ✅ **qwen3_coder 파서**(hermes 아님 주의) | ✅ gemma4 파서 | ✅ qwen3_xml 파서 |
| needle(~10K토큰) | — | ✅ | ✅ | ✅ |
| 처리량(단일) | **191 tok/s** | 85.3 | 41.7 | 47.8 |
| 특이 함정 | — | ★`--max-num-seqs 256` 필수(Mamba 블록 393 한계로 기본값 1024면 기동 거부 — 실측 1회 실패 후 해결) | KV 토큰당 ~192KB(비쌈) | thinking이 GLM급으로 장황, max_tokens 4000에서도 오답 1건 |

**개별 결론:**
- **Nemotron-3-Super = 유일한 실질 승격 후보.** 품질 hard-set 7/7 + 응답 토큰경제 우수 + KV 198.6만
  토큰(운영 fp8 KV의 2.6배, 그것도 BF16 기준 — fp8 KV 적용 여지 추가) + 네이티브 256K. 공개 벤치마크
  (SWE-Bench 60.5 vs 41.9)와 합치면 **에이전트/코딩 품질에서 gpt-oss 이상이 기대되는 최초의 검증
  통과 모델**. 트레이드오프는 처리량 절반(85 vs 191 tok/s)과 가중치 +3.6GiB. **승격 결정 전 후속
  과제**: OpenCode 실전 에이전트 작업 비교(SWE 성향 검증) + 동시성 부하/소크 테스트.
- **Gemma 4-31B = 우수한 경량 백업.** 7/7 품질을 gpt-oss 절반 이하 크기(31.49GiB)로 달성, thinking
  없는 즉답형이라 토큰경제 최고(933tok). 단 단일 처리량 41.7 tok/s(최저)와 KV 토큰당 비용(192KB)이
  높아 대규모 동시보다는 소수 사용자·간결 응답 시나리오에 적합. FIM 동시상주 여유는 최대(가중치가
  작아 StarCoder2-15B와도 여유롭게 공존 가능 — 미실측).
- **Qwen3.6-27B = 승격 대상 아님.** 6/7(한국어 논리 문항에서 §18.10의 Llama-FP8과 유사한 유형의
  오답) + 과잉사고 토큰경제(7,325tok — 실사용 비용·지연 직결) + 중국계 테스트 전용 정책. 다만 이
  테스트로 **GDN 하이브리드 커널의 SM120 동작이 확인**된 것이 최대 수확(Qwen3-Coder-Next/
  Qwen3.5-122B 검증의 관문 통과).

**파이프라인 이슈 기록(재발 방지):** ①2026-07-15 밤 백그라운드 알림 1건 유실로 파이프라인이
일시 정지(다운로드 완료 감시) — 이후 폴백 웨이크업(30분 주기)을 병행해 해결. ②2026-07-16 HF
CloudFront 504 장애로 Coder-Next 다운로드 중단, 이때 받은 파일 7개가 HTML 오류 페이지로 저장됨
(★교훈: curl 다운로드 후 `head -c 15`로 `<!DOCTYPE` 검사 필수). ③복구 스크립트의 pkill이 자기
재시작 명령까지 죽여 구버전 스크립트가 이틀 대기하는 사고 — 중첩 스크립트 대신 직접 백그라운드
명령 사용으로 전환. Qwen3-Coder-Next/Qwen3.5-122B 검증은 §19.9로 별도 기록 예정.

### 19.9 후속 검증: Qwen3-Coder-Next / Qwen3.5-122B / Nemotron+fp8 KV (2026-07-18~20)

**④ Qwen3-Coder-Next-NVFP4 (RedHatAI 공식, 44.3GiB, `models-test/`) — 전 항목 통과, 다크호스:**
- 기동 즉시 성공(GDN 커널·FLASH_ATTN). KV 37.78GiB → **160.3만 토큰**(24.46x@65K).
- **hard-set 7/7 전부 정답**(끝부분 검수 완료), thinking 없이 간결("5 minutes"를 3토큰) — 토큰경제
  1,157tok(우수). needle ✅, tool calling(qwen3_coder) ✅.
- **처리량 123.5 tok/s — 신규 후보 중 최고**(3B active MoE). 코딩 특화 모델임에도 일반 hard-set
  만점이라는 점이 인상적. 256K 네이티브 컨텍스트.
- 다운로드 중 HF 504 장애 여파로 총 3회 재시도 필요했음(§19.8 교훈 항목 참조).

**⑤ Qwen3.5-122B-A10B-NVFP4 (NVIDIA 공식, 73.2GiB, `models-test/`) — 동작하나 과잉사고 심각:**
- ★기동 시행착오 2회: ①util 0.90/0.87 모두 동일 지점 OOM(93.33GiB 사용 — GDN 상태 풀이
  `max_num_seqs`(기본 1024)에 비례해 util과 무관하게 커짐), ②`--max-num-seqs 128`도 "Mamba cache
  blocks (122)" 초과로 거부. **최종 성공 조합: util 0.87 / max-len 32768 / `--max-num-seqs 96`**
  (Nemotron의 max-num-seqs 함정과 동일 계열 — 하이브리드 모델 공통 주의사항으로 승격).
- KV 6.06GiB → 375K 토큰(11.45x@32K). needle ✅, tool calling(qwen3_xml) ✅. 처리량 79.9 tok/s.
- **hard-set 6/7**: 5문항 정답 + 엣지케이스코딩은 4000예산에서 2,667tok로 완결(정답) +
  **논리오류지적은 4000토큰으로도 미완결**(사고가 끝나지 않음). 총 토큰 소모 ~11K로 **전체 후보 중
  최악의 과잉사고** — 도구 사용 벤치마크(BFCL) 명성과 별개로 응답 지연·비용 관점에서 실사용 부적합.

**⑥ Nemotron-3-Super + fp8 KV 조합 (참고 실측):**
- 정상 기동·추론(크래시 없음)하나 KV 토큰 용량 198.6만→199.1만(**+0.25% — 사실상 무효과**).
- 사전 분석("Nemotron의 병목은 어텐션 KV가 아니라 Mamba 상태 블록/가중치") 실측 확정 —
  **Nemotron 채택 시 fp8 KV 플래그 불필요**(무해하나 무의미).

### 19.10 운영기(RTX PRO 6000) 전체 모델 검증 총괄표 + vLLM/KV 효율화 정리 (2026-07-20)

#### 19.10.1 전체 모델 검증 총괄 (성공/실패 전부, 시간순)

| # | 모델 | 양자화/크기 | 결과 | 품질(hard-set) | 처리량 | KV 토큰(측정 조건) | 판정/용도 |
|---|---|---|---|---|---|---|---|
| 1 | Llama 3.3-70B-Instruct | FP8 / 67.7GiB | ✅ | 5/7(오답1+미완1) | 9.7 tok/s | — (§11 A구성) | 선택지 A(운영 선택 가능, 보수적) |
| 2 | StarCoder2-7B (FIM) | FP8 / 7.0GiB | ✅ | — (FIM 전용) | — | — | A/E FIM. EOS 불안정 트레이드오프 |
| 3 | StarCoder2-15B (FIM) | FP8 / 15.4GiB | ✅ | — (FIM 전용) | — | — | D FIM. EOS 안정 |
| 4 | Llama 3.3-70B-Instruct | NVFP4 / 39.9GiB | ✅ | 6.5/7 | 9.5 tok/s | 43.29GiB(단독, §18.14) | 선택지 D. 단독구성 F는 품질 열세로 폐기 |
| 5 | **gpt-oss-120b** | MXFP4 / 66.0GiB | ✅ | **7/7 @900** | **191 tok/s** | **763K**(fp8 KV, 65536) | ★**현 운영(G/E 기본값)** |
| 6 | Mistral-Small-4-119B | NVFP4 / 66.2GiB | ❌ **3회 실패** | — | — | — | MLA×SM120 커널 부재(0.17.1/0.20.0/0.20.2 동일) — vLLM이 SM120 MLA 지원 전까지 불가 |
| 7 | GLM-4.5-Air | NVFP4 / 57.8GiB | ✅ | 7/7 @2000 | 87~91 tok/s | 144K(8192 기준) | 품질 동급이나 효율 열세 — 백업(테스트 전용) |
| 8 | **Nemotron-3-Super-120B-A12B** | NVFP4 / 69.5GiB | ✅ | **7/7 @900** | 85.3 tok/s | **1.99M**(BF16!, 65536) | ★**유일 실질 승격 후보**(SWE-Bench 60.5). 함정: max-num-seqs 256·qwen3_coder 파서 |
| 9 | Gemma 4-31B-it | FP8 / 31.5GiB | ✅ | **7/7 @900** | 41.7 tok/s | 267K(65536) | 경량 백업(토큰경제 최고 933tok, Apache 2.0) |
| 10 | Qwen3.6-27B | FP8 / 28.5GiB | ✅ | 6/7(오답1) | 47.8 tok/s | 792K(65536) | 제외(과잉사고 7.3K tok). GDN 커널 관문 통과가 수확 |
| 11 | **Qwen3-Coder-Next** | NVFP4 / 44.3GiB | ✅ | **7/7 @2000** | **123.5 tok/s** | **1.60M**(65536) | ★다크호스 — 코딩 특화+만점+고속(테스트 전용) |
| 12 | Qwen3.5-122B-A10B | NVFP4 / 73.2GiB | ✅(조건부) | 6/7(미완1) | 79.9 tok/s | 375K(32768) | 제외(과잉사고 최악 ~11K tok, OOM 함정 2회) |
| 13 | Solar Open 100B | NVFP4(파일 56.0GiB, 실제 로딩 **91.6GiB**) | ❌ **실패**(OOM) | — | — | — | VRAM 용량 초과 — 재시도 무의미(§19.11) |

**핵심 요약(최종)**: 13개 검증 완료 — **11개 성공, 2개 실패**(Mistral-Small-4: MLA 커널 부재 /
Solar Open 100B: VRAM 용량 초과). 품질 만점(7/7)은 gpt-oss·Nemotron·GLM·Gemma4·Coder-Next 5개.
**종합 우위는 여전히 gpt-oss**(품질+처리량+생태계), 승격 도전자는 **Nemotron**(에이전트 품질·
초장문), 특수 목적 후보는 **Coder-Next**(코딩)·**Gemma4**(경량). 2차 개선 프로젝트 모델 탐색
단계는 이것으로 종료 — 결론은 **"현 운영(gpt-oss-120b, 선택지 G, vLLM v0.20.2, fp8 KV) 유지,
Nemotron을 승격 후보로 별도 실전 검증(OpenCode 비교+부하테스트) 진행 여부는 운영팀 결정 대기"**.

#### 19.10.2 vLLM 업그레이드 이력 + KV 효율화 여정

| 시점 | 이벤트 | 효과 |
|---|---|---|
| 2026-07-07 | v0.17.1로 운영 Go-Live | 기준선 |
| 2026-07-11 | v0.20.0 리스크 검증(§15, 미전환) | CUDA graph 회계 변화(-5% KV) 발견, 호환성 확인 |
| 2026-07-15 | **v0.20.2 운영 전환**(§19.2~3) | gpt-oss KV 232K→380K(+64%, sliding window 회계 개선), 처리량 +3.5%, TurboQuant/fp8 KV 기반 확보. ★함정: `MAIN_MXFP4_FLASHINFER=1` 기동 거부 |
| 2026-07-15 | **fp8 KV캐시 운영 채택**(§19.5) | KV 380K→**763K(시작 대비 3.3배)**, 품질 무손실, 30분 소크 통과 |
| 2026-07-15 | KV 효율화 3종 비교(§19.6) | TurboQuant: gpt-oss sinks 비호환 / TriAttention: SM120 실동작 확인(예비 카드) / fp8 KV: 채택 |

#### 19.10.3 모델별 KV 효율화 기법 추천표

| 모델 | KV/토큰(실측) | fp8 KV | TurboQuant | TriAttention | 최종 추천 |
|---|---|---|---|---|---|
| gpt-oss-120b(운영) | 40.6→20.4KB | ✅ **채택 완료**(2배) | ❌ sinks 비호환(실측) | ✅ 동작(needle 통과, 예비) | **fp8 KV**(적용 중) |
| Nemotron-3-Super | 6.6KB(초저가) | 무효과(+0.25% 실측) | 미검증(실익 없음) | 통계 파일 없음 | **불필요** — 아키텍처가 이미 최적화 |
| GLM-4.5-Air | 184KB(고가) | 미실측(효과 클 전망) | 가능성(sinks 없음, 미검증) | 미검증 | 채택 시 **fp8 KV 우선 실측** |
| Gemma 4-31B | 192KB(고가) | 미실측(효과 클 전망) | 미검증 | 미검증 | 채택 시 **fp8 KV 우선 실측** |
| Qwen3.6/122B/Coder-Next(GDN 하이브리드) | 24~66KB(저가) | 효과 제한 전망(Nemotron 사례 유추) | 미검증 | Qwen3.6용 통계 일부 존재 | 필요 시 fp8 KV 실측(기대치 낮음) |
| Llama 3.3-70B(A/D) | ~314KB 추정(GQA 8헤드×80층) | 미실측(**최대 수혜 전망**) | 가능성(sinks 없음) | 통계 없음(8B용만) | A/D 재활성 시 **fp8 KV 최우선 실측** |
| Mistral-Small-4 | — (기동 불가) | — | — | — | 해당 없음 |
| StarCoder2(FIM) | 소형·ctx 8192 | 불필요 | — | — | 불필요 |

**일반 원칙(실측으로 확립)**: ①KV가 비싼 표준 어텐션 모델(GLM/Gemma/Llama)일수록 fp8 KV 효과가
크고, ②하이브리드(Mamba/GDN) 모델은 KV가 원래 싸서 효과가 미미하며(Nemotron +0.25% 실측),
③TurboQuant은 attention sinks 모델(gpt-oss) 비호환, ④TriAttention은 모델별 통계 파일 존재 여부가
선결 조건. **"모델을 바꾸면 효율화 기법도 다시 골라야 한다"** — 기법은 모델 아키텍처에 종속된다.

### 19.11 Solar Open 100B NVFP4 — 실패 (VRAM 용량 초과, 2026-07-20)

Upstage Solar Open 100B(102B/12B active MoE, 커뮤니티 NVFP4 양자화 `Firworks/Solar-Open-100B-nvfp4`,
파일 크기 56.0GiB)를 검증했다. **한국어 도메인 벤치마크에서 gpt-oss 이상을 공식 주장**하는 후보였으나
이 하드웨어에서 기동 자체가 불가능함을 확인했다.

- **1차 시도(util 0.87, max-len 32768, max-num-seqs 128)**: 가중치 로딩 단계에서
  **`Model loading took 91.6 GiB memory`** — 파일 크기(56.0GiB)의 **1.6배**를 실제로 점유. 이어서
  MoE 워크스페이스용 1.03GiB 추가 할당 시도 중 `CUDA out of memory`로 크래시(GPU 총 94.96GiB 중
  93.92GiB 사용 상태, 여유 182MiB).
- **원인 분석**: Solar Open의 MoE 레이어가 TensorRT-LLM/cutlass 기반 `FusedMoeRunner` 커널을
  사용하는데(스택트레이스 확인), 이 경로가 NVFP4 압축 가중치를 실행 시점에 상당 부분 **역양자화/
  재배치하여 로드**하는 것으로 추정된다 — 다른 NVFP4 모델(Llama/Nemotron/Qwen 3종)은 전부 파일
  크기와 비슷한 수준으로 로드됐던 것과 대조적. **★신규 교훈: NVFP4 파일 크기는 실제 런타임 VRAM
  점유량을 보장하지 않는다 — MoE 커널 구현체에 따라 1.5배 이상 차이 날 수 있다.**
  gpu_memory_utilization 하향/max-num-seqs 축소로 해결 가능한 문제가 아님(가중치 로딩 자체가
  전체 예산을 이미 초과) — 추가 시도 없이 실패로 결론.
- **판정**: **이 GPU(96GB)에서 기동 불가.** 재시도 가치 없음(파라미터 튜닝으로 해결되는 유형이
  아님). 모델 파일은 `models-test/`에 보존(향후 공식 zai-org/Upstage 발 더 작은 양자화가 나오거나
  vLLM의 NVFP4 MoE 로딩 경로가 개선되면 재검토 가능).
- 운영(G) 영향 없음 — 원복 및 E2E 200 확인 완료.

**총괄표(§19.10.1) 갱신**: Solar Open 100B를 #13 실패 사례로 추가 — Mistral-Small-4(MLA 커널 부재)에
이은 **두 번째이자 마지막 실패 사례**(VRAM 용량 초과). 최종 검증 결과: 13개 모델 중 **11개 성공,
2개 실패**.

### 19.12 선택지 L(Nemotron) 실전검증(OpenCode 실사용) — 발견 버그 4건 및 조치 (2026-07-20~21)

승격 후보 Nemotron-3-Super(선택지 L)를 사용자가 OpenCode로 실제 개발 작업(OpenSpec `apply` 워크플로,
스케줄 앱/Todo 앱 구현)에 투입해 실전검증하는 과정에서 인프라 버그 4건을 발견·조치했다. 격리된
PoC/소크 테스트만으로는 드러나지 않고 **장시간 에이전틱 세션에서만 나타나는 유형**이라는 공통점이
있다 — 향후 다른 선택지(H/S)를 실전검증할 때도 동일 클래스의 문제가 재현될 수 있으므로 점검 순서를
남겨둔다.

**① `--reasoning-parser` 누락 — CoT 원문이 content에 그대로 노출**
- 증상: 모든 응답에 "We need to continue working on the task..." 식 원문 사고과정이 답변 본문에
  섞여 나옴(세션 제목 생성 결과에서도 동일 증상). 매 턴 대화 히스토리에 CoT 전문이 누적되어 컨텍스트
  소모 속도가 비정상적으로 빨라짐.
- 원인: vLLM에 Nemotron 전용 파서(`nemotron_v3`, `DeepSeekR1ReasoningParser` 상속)가 이미 내장돼
  있으나 `option-l.env` 최초 등록 시 `--reasoning-parser` 인자 자체를 빠뜨림.
- 조치: `MAIN_EXTRA_ARGS`에 `--reasoning-parser nemotron_v3` 추가. 재기동 후 `reasoning_content`가
  `content`와 분리되어 응답되는 것을 curl로 직접 확인.

**② 장시간 세션 컨텍스트 초과 — 압축(compaction) 요청 자체가 거부됨**
- 증상: OpenSpec `apply` 작업이 tasks.md 특정 섹션에서 진행이 멈춘 것처럼 보임. 사용자에게는 별도
  에러 표시 없이 그냥 응답이 안 옴.
- 원인: vllm-main 로그에서 `VLLMValidationError: 입력 61,441 + 출력 4096 > max-model-len(65536)`
  확인. OpenCode가 컨텍스트 한도 근처에서 자동 압축(요약)을 시도하는데, 압축 요청 자체의 입력이 이미
  한도를 넘겨 vLLM이 400으로 거부 — 압축이 컨텍스트를 줄이기는커녕 실패만 하고 끝나 계속 정지 상태로
  보임.
- 조치(①과 별개, 근본적 여유 확보): Nemotron의 `max_position_embeddings`는 262,144(256K)로 65536은
  gpt-oss(E) 설정을 그대로 물려받은 값일 뿐 모델/KV 한계가 아님을 확인. `--max-model-len`을
  65536→**131072**로, 클라이언트 컨텍스트(`opencode.json`)도 60000→**120000**으로 동반 상향(여유
  마진 5,536→11,072로 2배 이상 확보). 재기동 후 KV 풀은 오히려 2,459,160토큰(기존 1,986,244보다
  커짐, 131072 기준 동시성 18.76x)으로 실측, curl E2E 정상.
- ①·② 모두 적용 후 재현: 별도 세션(`test_prj_schedule_Nemotron-3_fail`)에서 동일 유형의 400
  컨텍스트 초과가 재발했으나 이번엔 **재시도로 15초 내 자동 복구**됨(①로 CoT 누적 속도가 줄어든
  덕에 완전 정지까지는 안 갔지만, 근본적으로 여유 마진이 계속 소진되는 구조 자체는 남아있어 ②의
  128K 확장이 유효한 추가 안전판임).

**③ presidio-analyzer 컨테이너 순간 재시작 → PII 가드레일 500 (원인 미확정, 모니터링 항목)**
- 증상: litellm 로그에 `Presidio PII analysis failed: ServerDisconnectedError` /
  `ClientConnectorError(Connection refused)` 500 에러 2건.
- 조사: `docker events`로 `presidio-analyzer`가 정확히 그 시각에 `die`(exitCode 143=SIGTERM)
  →1초 후 `start`로 재시작한 것을 확인. 컨테이너 자체 로그엔 재시작 직전 예외 트레이스가 없고(직전까지
  정상 INFO 로그), 헬스체크도 설정돼 있지 않으며(§docker-compose.yml presidio-analyzer 서비스),
  이 세션 중 해당 컨테이너를 조작한 스크립트도 없어 **트리거를 특정하지 못함**.
- 조치: 근본 수정 보류(재현 시 재조사) — 다만 OpenCode/사용자 요청은 자체 재시도로 무사 통과됨
  (LiteLLM `num_retries: 2` 또는 클라이언트 재시도로 추정). 재발 빈도가 늘면 presidio-analyzer에
  헬스체크·재시작 알림을 추가하는 것을 권장.

**④ OpenCode Context/토큰/비용 패널이 항상 "0 tokens / 0% used / $0.00" — LiteLLM 스트리밍 usage
유실 (2건 중첩 버그, 몽키패치로 조치)**
- 증상: OpenCode 사이드바의 Context/토큰/비용이 실제 대화 진행과 무관하게 항상 0으로 고정.
- 원인 A(업스트림 버그 1, BerriAI/litellm [#25389](https://github.com/BerriAI/litellm/issues/25389),
  1.89.0 기준 미해결): vLLM은 OpenAI 스펙대로 스트리밍 종료 시 `finish_reason` 청크 뒤에 별도로
  `usage`만 담긴 빈 `choices:[]` 청크를 추가로 보내는데, LiteLLM이 `finish_reason`을 보는 즉시 스트림
  소비를 멈춰버려 그 usage 청크를 통째로 버림. vllm-main(8000) 직접 스트리밍 테스트로 vLLM 쪽은
  정상 전송함을 확인, LiteLLM을 거치면 사라지는 것까지 재현 확인.
- 1차 시도(설정만으로 우회): `litellm/config.yaml`의 main-nemotron `litellm_params`에
  `fake_stream: true` 추가 — LiteLLM→vLLM 요청을 non-streaming으로 바꿔 완전한 응답(+usage)을
  통짜로 받은 뒤 클라이언트에는 그걸 흉내내어 스트리밍처럼 전달하는 방식. 원인 A는 우회되지만
  **원인 B(별개의 업스트림 버그)를 새로 만남**: `llms/base_llm/base_model_iterator.py`의
  `convert_model_response_to_streaming()`이 완결된 `ModelResponse`를 스트리밍 청크로 변환할 때
  `id`/`object`/`created`/`model`/`choices`만 복사하고 **`usage`를 빠뜨림** — 소스 추적으로 확인.
  결과: `fake_stream: true`를 걸어도 여전히 usage 미전달(재현 확인).
- 2차 조치(몽키패치): `litellm/audit_logger.py`(기존에 콜백으로 이미 로드되는 파일)에
  `convert_model_response_to_streaming`을 감싸 `model_response.usage`를 결과 청크에 복사해 넣는
  몽키패치 추가. sync/async 두 fake_stream 경로(`MockResponseIterator`) 모두 같은 모듈 함수를
  참조하므로 패치 하나로 양쪽 다 적용됨(단, `presidio.py`/`main.py` 등에서 별도로 `from ... import`한
  참조는 패치 범위 밖 — 우리 경로엔 영향 없음, §자세한 내용은 `audit_logger.py` 주석 참조).
  재기동 후 curl 스트리밍 테스트로 `usage` 필드가 최종 청크에 정상 포함되는 것을 확인.
- **트레이드오프(사용자 확인 후 채택)**: `fake_stream: true`는 LiteLLM→vLLM 요청 자체를
  non-streaming으로 바꾸므로 **TTFT(첫 토큰까지 시간)가 늘어난다** — Nemotron은 답변 전 reasoning이
  길 때가 많아 체감 지연이 더 클 수 있음(첫 토큰이 오기 전까지 화면에 아무것도 안 뜨다가 한번에
  쏟아지는 형태로 바뀜). 사용자가 "간단한 설정 우선 적용 + 추후 중계서버로 전환 준비"를 명시적으로
  선택.
- **추후 전환 예정(미구현, 설계만 기록): 중계 프록시 방식.** vllm-main과 litellm 사이에 경량
  reverse proxy를 하나 더 두고, vLLM이 보내는 마지막 두 청크(`finish_reason` 청크 + 별도 `usage`
  청크)를 프록시 단에서 하나로 병합해 LiteLLM에 전달한다. 이렇게 하면 원인 A(LiteLLM이 두 번째 청크를
  못 읽는 문제)가 애초에 발생하지 않아 **진짜 토큰 단위 실시간 스트리밍을 유지하면서** usage도
  정상 전달된다 — `fake_stream`의 TTFT 저하 없이 근본 해결. 요구되는 작업: (1) 프록시 서비스 코드
  (vLLM SSE를 파싱해 `choices`가 있는 마지막 청크와 그다음 `usage`-only 청크를 만나면 하나로 합쳐
  재전송하는 경량 asyncio/aiohttp 서버, 수십 줄 규모), (2) `docker-compose.yml`에 서비스 추가(예:
  `stream-usage-fix`, vllm-main과 같은 `ai-net` 네트워크), (3) `litellm/config.yaml`의
  `api_base`를 `http://vllm-main:8000/v1` → 신규 프록시 주소로 변경 + `fake_stream: true` 제거 +
  `audit_logger.py`의 몽키패치 블록 제거(더 이상 필요 없어짐), (4) 순수 스트리밍 재검증(청크 수·TTFT·
  usage 값 정합성). 선택지 L 뿐 아니라 G/H/S 등 다른 모든 모델에도 동일하게 적용 가능한 범용 해결책
  (모델별이 아니라 게이트웨이 레벨 문제이므로) — 구현 시 `litellm/config.yaml`의 모델별
  `fake_stream: true`를 전부 걷어내고 `api_base`만 프록시로 일괄 전환하면 됨.
- 사용자 매뉴얼(`docs/USER_GUIDE.md`) "OpenCode 토큰/비용 표시" 항목에 임시 조치 상태와 증상 재현
  시 확인 방법을 함께 기록.

| 구분 | 산출물 |
|------|------|
| IaC | `docker-compose.yml`, `.env(.example)` |
| 게이트웨이 | `litellm/config.yaml`, `litellm/Dockerfile`, `audit_logger.py`, `gemma_compat.py`, `autocomplete_compat.py` |
| PII | `presidio/recognizers/kr_custom.yaml`, `presidio/README.md` |
| 운영 스크립트 | `scripts/`: phase0_bootstrap, rotate_keys, backup, restore, stage_model, deploy_model, audit, anomaly_check, poc_quant_compare, poc_fim_compare, poc_concurrency_smoke, **switch_model_option**(§14, 구성 A/D 안전 전환) |
| 구성 프로파일 | `env-profiles/`: option-a.env, option-d.env, option-e.env(기본값) — 셋 다 운영자 상시 선택 가능(§10, §18.7) |
| 문서 | `REQUIREMENTS.md`, `TEST_PLAN.md`, `CLAUDE.md`, `docs/OPERATOR_GUIDE.md`, `docs/USER_GUIDE.md`, `docs/POC_FP4_QUANT_COMPARISON.md`, 본 보고서 |
| 클라이언트(실제 사용 중) | `opencode.json`, `~/.continue/config.yaml` |
| **클라이언트 배포용 템플릿(신규, 시크릿 없음)** | **`opencode.json.example`, `continue-config.yaml.example`, `AGENTS.md.example`**(전역 한국어 응답 지침, §USER_GUIDE.md "설정" 참조) — 사용자 배포용, 서버주소/키만 교체하면 됨 |
| 스테이징 모델 | Llama 8B(FP8/NVFP4), Gemma 9B/27B(FP8), StarCoder2-7B(FP8), Qwen2.5-Coder-7B(FP8), Mistral-24B(NVFP4) — 검증장비(5090) |
| 운영 스테이징 모델(구, §11.5~§13) | Llama 3.3-70B-Instruct(FP8 ~68GB, 선택지 A) / NVFP4 ~40GB+StarCoder2-15B(선택지 D) — 운영장비(RTX PRO 6000) |
| **운영 스테이징 모델(현재 기본값, §17~18)** | **gpt-oss-120b(MXFP4, ~66GB) + StarCoder2-7B(FP8, ~7GB)** — 운영장비(RTX PRO 6000), 선택지 A/D로 언제든 전환 가능 |
