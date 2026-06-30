# CLAUDE.md

> 이 파일은 Claude Code가 자동으로 읽는 프로젝트 컨텍스트입니다.
> 작업 시작 전 반드시 이 문서의 **제약(Constraints)** 과 **금지 사항(Never Do)** 을 우선 적용하세요.

## 1. 프로젝트 개요

LG CNS WISE 운영팀(50인)의 폐쇄망 On-Premise AI Assistant 인프라를 **본 도입 전에 검증**하기 위한
**테스트/검증 환경**을 구축한다. 본 리포지토리는 그 검증 환경의 IaC(Docker Compose) · 설정 · 검증 스크립트를 담는다.

- **테스트 장비:** Dell Precision 5860T + **RTX 5090 32GB (Blackwell, SM120 / compute capability 12.0)**
- **운영 목표 장비:** Dell Precision 7960 + **RTX PRO 6000 Blackwell 96GB (동일 SM120)**
- **핵심 의의:** 테스트 GPU(5090)와 운영 GPU(RTX PRO 6000)는 **동일 SM120**이다. 따라서 5090에서 해결한
  드라이버/CUDA/vLLM/FP8/FP4 이슈는 운영 장비로 **거의 1:1로 이전**된다. 이 환경의 목적은
  "70B 성능 측정"이 아니라 **"운영 스택 전체(거버넌스·라우팅·클라이언트·운영 워크플로우)를 미리 검증"** 하는 것이다.

## 2. ⚠️ 절대 제약 (Constraints) — 위반 시 빌드 실패

1. **VRAM 32GB:** Llama 3.3-70B(FP8 ~70GB)는 **이 장비에 절대 올라가지 않는다.** 시도하지 말 것.
   메인 모델 검증은 운영 장비에서 수행한다. 본 환경은 **프록시 모델 + 실제 서브 모델**로만 검증한다(§5).
2. **Blackwell SM120 소프트웨어 요건 (테스트·운영 공통):**
   - CUDA **12.8 이상** (13.0 가능) — 제안서의 "CUDA 12.4"는 Blackwell에 부족. 사용 금지.
   - NVIDIA Driver **570 이상** — 제안서의 "v550"은 부족.
   - PyTorch **2.6+ (cu128)**, vLLM **v0.17.0 이상** (SM120 전용 FP8 GEMM 최적화 포함 버전).
   - **FlashAttention 3는 Blackwell 미지원** → Llama 등 일반 모델은 `VLLM_FLASH_ATTN_VERSION=2` 설정.
   - **⚠ Gemma 2 예외:** Gemma 2(9B/27B)는 logit soft-capping 때문에 FA2 빌드가 softcap 미지원이면
     기동 실패하거나 **FlashInfer 백엔드를 요구**한다. SM120에선 FlashInfer head_size 이슈도 보고됨.
     → 모든 모델에 FA2를 일괄 강제하지 말 것. Gemma 서비스는 `VLLM_ATTENTION_BACKEND`(`.env`의
     `GEMMA_ATTN_BACKEND`, 기본 `FLASHINFER`)로 분리하고, 실패 시 `FLASH_ATTN`으로 전환해 실측한다(`TEST_PLAN` B-1/C-1).
3. **폐쇄망(Air-gapped):** 런타임에 인터넷이 **없다.** 모든 컨테이너 이미지·모델 가중치·의존성은
   사전 스테이징(오프라인 반입)된 것만 사용한다. 빌드 산출물은 외부 네트워크 의존성이 없어야 한다.
4. **단일 GPU:** 멀티 GPU 텐서 병렬/P2P(NCCL P2P, custom all-reduce) 설정을 넣지 말 것. 단일 카드 구성만.
5. **OSS·자체 호스팅 전용:** 외부 클라우드 의존 컴포넌트 금지(아래 §6).

## 3. 빌드 도구 vs 런타임 클라이언트 (혼동 주의)

| 구분 | 도구 | 용도 | 비고 |
|------|------|------|------|
| **빌드 시점** | **Claude Code** (Anthropic) | 이 인프라를 구축/설정하는 에이전트 | 인터넷 연결된 구축 단계에서 사용 |
| **런타임(운영)** | **OpenCode** (OSS) | 개발자가 폐쇄망에서 쓰는 IDE/CLI 에이전트 | LiteLLM(4000)을 OpenAI 호환 백엔드로 사용 |

> 폐쇄망에서는 Claude Code/Anthropic API가 동작하지 않는다. 런타임 클라이언트는 반드시 **OpenCode**다.

## 4. 기술 스택 & 고정 버전 (Pinned)

| 계층 | 컴포넌트 | 버전/설정 | 메모 |
|------|----------|-----------|------|
| OS/커널 | **Ubuntu 26.04 LTS (확정)** | 커널 7.0.0+ | 테스트=운영 동일 베이스라인 (검증장비 실측: 26.04 / 7.0.0-22-generic) |
| 드라이버/CUDA | NVIDIA 570+ / CUDA 12.8+ | — | Blackwell 필수 |
| 컨테이너 | Docker + Docker Compose + nvidia-container-toolkit | — | — |
| 추론 엔진 | **vLLM v0.17.0+** | `VLLM_FLASH_ATTN_VERSION=2` | NGC `nvcr.io/nvidia/pytorch` 기반 이미지 권장 |
| 게이트웨이 | **LiteLLM — OSS(무료) 전용** (지원 라인 1.86~1.89 중 1개 고정) | PostgreSQL 백엔드 | Enterprise 기능 미사용 |
| PII 마스킹 | **Presidio** (자체 호스팅) | LiteLLM `guardrail: presidio` | 폐쇄망 가능한 유일한 OSS PII 경로 |
| 키/스펜드 DB | PostgreSQL | — | LiteLLM 가상 키·사용량 |
| 클라이언트 | OpenCode + VS Code/IntelliJ | — | OpenAI 호환 백엔드 |

> 정확한 마이너 버전은 **빌드 시점에 확정 후 본 표에 기록**한다(재현성). 임의 `latest` 태그 사용 금지.

## 5. 모델 구성 (테스트 장비 전용)

검증 목적별로 **두 트랙**을 분리한다.

- **운영 서브 모델 실검증:** `Gemma 2-27B (FP8, ~27GB)` 단일 — 운영에 실제로 들어갈 모델을 SM120에서 실측.
- **2-트랙 라우팅 패턴 검증:** `Llama 3.1-8B-Instruct (FP8, ~8GB)` [메인 프록시] + `Gemma 2-9B-it (FP8, ~9GB)` [서브]
  - vLLM 인스턴스 2개(포트 8000/8001)를 한 카드에 `--gpu-memory-utilization` 분할로 동시 상주.
  - LiteLLM(4000)이 라우팅 매트릭스(§REQUIREMENTS FR-8)에 따라 분기.
- **IDE tab 자동완성(FIM) 검증:** `StarCoder2-7B (FP8, ~8GB)` [autocomplete] — Llama/Gemma(instruct)는 FIM 미지원이라
  inline 자동완성 불가 → FIM 전용 코드 모델 별도. phase-ide 프로파일(main+autocomplete)로 검증(포트 8003).
  운영 최적 구성: **Llama 3.3-70B FP8(채팅·에이전트) + StarCoder2-7B FP8(자동완성)** 2-트랙(96GB 단일 카드).
- 중국계 모델(Qwen/DeepSeek 등)은 **보안 정책상 사용 금지** (제안서 기준) — 자동완성 모델도 비중국계(StarCoder2/CodeLlama)로 한정.

## 6. 🚫 금지 사항 (Never Do)

- 인터넷에서 런타임 다운로드를 전제하는 설정(클라우드 가드레일 Lakera/Aporia 호스티드, 외부 텔레메트리, 외부 SSO).
- **LiteLLM Enterprise 라이선스 키(`LITELLM_LICENSE`) 설정 금지** — 무료 OSS 기능만 사용. Audit 보존정책/SSO/자동 키 로테이션 등 Enterprise 기능은 자체 콜백·스크립트로 대체.
- `--dtype fp8`를 Ampere 이하에서 가정하는 코드(이 장비는 Blackwell이므로 무관하나, 하드코딩된 가정 금지).
- 멀티 GPU 전제 설정.
- 모델 가중치/이미지를 빌드 중 인터넷에서 받도록 하는 단계(반드시 사전 스테이징 디렉터리 참조).
- 마스터 키를 애플리케이션 코드/클라이언트에 노출. 클라이언트는 항상 **가상 키(sk-...)** 사용.
- 시크릿(키, DB 비밀번호)을 리포지토리에 평문 커밋. `.env`/secrets로 분리하고 `.gitignore` 처리.

## 7. 표준 명령 (Claude Code가 사용할 것)

```bash
# 환경 확인
nvidia-smi                        # GPU/드라이버 인식, VRAM 32GB 확인
nvcc --version                    # CUDA 12.8+ 확인 (컨테이너 내부)

# 스택 기동/중지
docker compose up -d
docker compose down

# 헬스체크
curl -s http://localhost:8000/health        # vLLM (main)
curl -s http://localhost:8001/health        # vLLM (sub, Phase B)
curl -s http://localhost:4000/health        # LiteLLM gateway

# 로그
docker compose logs -f vllm-main
docker compose logs -f litellm
```

## 8. 검증/완료 정의 (Definition of Done)

- 각 기능은 `REQUIREMENTS.md`의 FR-x 수용 기준을 충족해야 한다.
- 실행 절차·합격 기준은 `TEST_PLAN.md`의 Phase 0/A/B/C를 따른다.
- 모든 검증 항목 통과 = 운영 장비(RTX PRO 6000) 본 구축 **Go** 판정.

## 9. 불확실할 때

- 버전·플래그가 불명확하면 임의 추정하지 말고 **최신 공식 문서를 빌드 단계에서 확인**한 뒤 본 문서/`.env`에 고정 기록.
- Blackwell SM120 관련 오류(예: "no kernel image", garbage output)는 **드라이버/CUDA/torch 버전 불일치**를
  최우선 의심한다(§2). AWQ/FP8 정합성 이슈 시 `VLLM_FLASH_ATTN_VERSION=2` 및 양자화 백엔드부터 점검.
