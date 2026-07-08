# TEST_PLAN.md — 단계별 검증 계획

테스트 장비(RTX 5090 32GB, SM120)에서 운영 스택을 사전 검증하기 위한 실행 계획.
각 Phase는 **목표 → 절차 → 검증 체크리스트 → 합격 기준 → 운영 이전성** 순서로 구성한다.
모든 항목 통과 시 운영 장비(RTX PRO 6000 96GB) 본 구축 **Go** 판정.

> 명령 예시의 포트: vLLM main `8000`, vLLM sub `8001`, LiteLLM `4000`.
> 가상 키는 `$DEV_KEY`(일반), `$SENIOR_KEY`(시니어), `$ADMIN_KEY`(관리자)로 표기.

---

## Phase 0 — 환경 베이스라인 확정

**목표:** Blackwell SM120 구동 전제(드라이버/CUDA/커널/컨테이너)를 확정하고 고정 기록.

**절차**
```bash
# 1) GPU/드라이버 인식 (Driver 570+, VRAM 32GB 확인)
nvidia-smi

# 2) 커널/OS 확인 (Ubuntu 26.04 LTS 확정)
uname -r && lsb_release -a

# 3) nvidia-container-toolkit 동작 확인
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi

# 4) 컨테이너 내부 CUDA/torch 확인 (CUDA 12.8+, torch 2.6+ cu128)
docker run --rm --gpus all nvcr.io/nvidia/pytorch:25.02-py3 \
  python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.get_device_capability())"
```

**검증 체크리스트**
- [ ] `nvidia-smi`에 RTX 5090, Driver ≥ 570, 32GB 표시
- [ ] OS = **Ubuntu 26.04 LTS** (커널 7.0.0+) 확인
- [ ] 컨테이너에서 `get_device_capability()` → `(12, 0)` 출력
- [ ] CUDA ≥ 12.8, torch ≥ 2.6 (cu128)
- [ ] 확정 버전을 `CLAUDE.md §4` 및 `.env`에 기록

**합격 기준:** 위 4개 충족. **운영 이전성:** 동일 베이스라인을 운영 장비에 그대로 적용.

---

## Phase A — 스택 부트스트랩 + 거버넌스 (VRAM 무관, 100% 이전)

**목표:** 단일 소형 모델로 vLLM→LiteLLM→클라이언트 E2E를 띄우고, **모델 크기와 무관한 거버넌스 전체**를 검증.
(검증 항목: FR-1~7, FR-9, FR-10, FR-11)

**A-1. 단일 모델 서빙 (Llama 3.1-8B FP8)**
```bash
# core(postgres/presidio-analyzer/presidio-anonymizer/litellm)는 프로파일 없이 항상 기동.
# vllm-main 은 phase-a 프로파일 → 반드시 --profile 로 활성화한다.
docker compose --profile phase-a up -d
# main 단독이라 VRAM 여유 → .env override 권장: MAIN_GPU_UTIL=0.85
curl -s http://localhost:8000/health
curl -s http://localhost:4000/health
```
- [ ] vLLM/LiteLLM `/health` 200
- [ ] 가상 키로 `/v1/chat/completions` 정상 응답, garbage 출력 없음

**A-2. 3-Tier 키 + Rate Limit (FR-3, FR-4)**
```bash
# 일반 키 발급 예시 (60 RPM / 100K tpm, sub 모델 allowlist)
curl -s http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"rpm_limit":60,"tpm_limit":100000,"models":["sub-gemma"],"metadata":{"role":"developer"}}'
```
- [ ] 시니어/일반/관리자 키 발급, 한도·모델 allowlist 차등 적용
- [ ] 일반 키로 미허용 모델(main) 요청 → 거부
- [ ] RPM 초과 부하 → **429 + Retry-After**, 리셋 후 정상화
- [ ] 90일 로테이션 스크립트: 신규 키 발급 + 구 키 폐기 동작

**A-3. Audit Trail 5필드 (FR-5)**
- [ ] 임의 요청 1건이 WHO/WHEN/MODEL/PROMPT/OUTPUT 모두 채워져 Audit DB 적재
- [ ] 적재가 async (응답 지연에 영향 없음)
- [ ] PROMPT 해시 동반 저장

**A-4. PII 마스킹 (FR-6)**
```bash
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $DEV_KEY" -H "Content-Type: application/json" \
  -d '{"model":"sub-gemma","messages":[{"role":"user","content":"내 주민번호는 900101-1234567 이고 DB 비번은 P@ssw0rd! 야"}]}'
```
- [ ] 모델 입력·서버 로그·Audit PROMPT에서 주민번호/DB 비번 **마스킹**
- [ ] 정책상 차단 케이스(DB_SECRET) → **400 + 사유** 반환(실측: LiteLLM presidio BLOCK = HTTP 400)

**A-5. 이상 탐지 (FR-7)**
- [ ] 합성 트래픽: 토큰량 평균 5배 초과 → 경보 레코드 생성
- [ ] 합성 트래픽: 시간당 300건 초과 → 경보 레코드 생성

**A-6. 클라이언트 연동 (FR-9)**
```bash
# OpenCode 설치(빌드 단계 인터넷; 폐쇄망은 npm 패키지 오프라인 반입)
npm install -g opencode-ai
# 설정: 프로젝트 루트 opencode.json (provider=litellm-onprem, baseURL=http://localhost:4000/v1,
#   apiKey={env:OPENCODE_LITELLM_KEY}). 가상 키는 평문 커밋 금지 → env 주입.
export OPENCODE_LITELLM_KEY=sk-...                       # ./scripts/rotate_keys.sh generate developer <user>
opencode run -m litellm-onprem/main-llama "17 곱하기 23은?"   # 비대화형 검증 / 대화형은 그냥 `opencode`
```
- [ ] OpenCode를 LiteLLM(4000)+가상 키로 연결, 요청 응답 확인
- [ ] 해당 요청이 Audit에 기록
- [ ] **★tool calling 필수(실측):** OpenCode/IDE 에이전트는 function calling 을 쓴다 → vLLM에
      `--enable-auto-tool-choice --tool-call-parser llama3_json`(Llama 계열) 미설정 시 `"auto" tool choice
      requires...` 오류로 연동 실패. docker-compose vllm-main 에 반영됨. 운영 모델에도 동일 적용.

**A-7. 백업/복구 (FR-11)**
- [ ] 설정 + 키/스펜드 DB 백업 → 스택 파기 → **24h 이내** 복원, 키·정책·로그 보존

**A-8. 오프라인 모델 업데이트 워크플로우 (FR-10)**
```bash
# ② 무결성/라이선스/취약점 게이트 (분리망에서 manifest 생성 → 사내망에서 verify)
./scripts/stage_model.sh manifest ./models/llama-3.1-8b-instruct-fp8     # (배포원) SHA256SUMS 동봉
./scripts/stage_model.sh gate     ./models/llama-3.1-8b-instruct-fp8 "$VLLM_IMAGE"  # (사내) 일괄 게이트
# ④ Blue/Green: green 카나리 기동 → 검증 → 컷오버 / 롤백 (8B 프록시는 동시상주 가능)
./scripts/deploy_model.sh deploy   main-llama ./models/llama-3.1-8b-instruct-fp8-v2 --mode canary
./scripts/deploy_model.sh status   main-llama
./scripts/deploy_model.sh promote  main-llama     # 또는 rollback main-llama
```
- [ ] `stage_model.sh gate`: 정상 가중치 통과 / **체크섬 변조 시 비0 종료(배포 차단)**
- [ ] 라이선스 파일 미동봉 시 게이트 실패(사유 출력)
- [ ] `deploy ... canary`: green `/health` 200 + 스모크 추론(garbage 없음) 통과 후 LiteLLM에 green deployment 등록
- [ ] `promote`: blue deployment 제거 → green 단독 컷오버. `rollback`: green 제거 → blue 복귀(무중단)
- [ ] **VRAM 메모:** 27B 등 대형은 `--mode sequential`(짧은 다운타임). 운영 96GB에선 대형도 canary 가능(이전성)

**합격 기준:** A-1~A-8 전 항목 통과.
**운영 이전성:** 이 계층은 모델 크기와 무관 → 운영 장비에서 **동일하게 동작**(가장 확실한 이전 구간).

---

## Phase B — 2-트랙 동시 서빙 + 라우팅

> ★**[2026-07-07 운영 결정] 본 Phase는 기술적으로 전부 통과했으나, 운영은 서브 채팅 모델(Gemma)을 채택하지
> 않기로 확정했다.** 사유: 운영 96GB 카드에서 main(70B)+FIM만으로 이미 VRAM 여유 ~1.4GB로 타이트해 서브 모델을
> 얹을 여유가 없고, 단일 채팅 모델 구조가 운영 단순성 측면에서 유리하다고 판단. 아래 결과는 **역사적 검증 기록**으로
> 보존하며, 운영 구성은 CLAUDE.md §5 / OPERATOR_GUIDE §10 "선택지 A(main+FIM 2-트랙)"를 따른다.

**목표:** main+sub를 한 카드에 동시 상주시켜 운영의 듀얼 모델 라우팅 패턴을 검증. (FR-1, FR-8)

**B-1. 듀얼 인스턴스 동시 상주 (Llama 8B + Gemma 9B, FP8)**
```bash
# 동일 GPU에 두 vLLM 인스턴스: --gpu-memory-utilization 분할 (예: 각 0.4)
docker compose --profile phase-b up -d        # core + vllm-main + vllm-sub
nvidia-smi   # 두 모델 VRAM 동시 점유 확인 (~17GB + KV 여유)
```
- [ ] 8000(main)·8001(sub) 동시 `/health` 200
- [ ] 두 모델 VRAM 동시 점유, OOM 없음
- [x] **Gemma2 attention 백엔드 실측 [2026-06-25]:** `VLLM_ATTENTION_BACKEND=FLASHINFER` 지정에도 vLLM 0.17.1
      V1 엔진이 **FLASH_ATTN 자동 선택** → Gemma2 softcap 정상, **garbage 없음**, SM120 head_size 이슈 미발생.
      실동작 백엔드 = FLASH_ATTN 으로 `.env`에 고정 기록(NFR-2). 운영 RTX PRO 6000 동일 SM120에 이전.

**B-2. 라우팅 매트릭스 (FR-8)**
- [ ] 자동완성/짧은 Q&A(<2–4K) → **sub(Gemma)** 라우팅
- [ ] JIRA 분석(4K–16K)·로그 분석(8K+)·문서/알고리즘 → **main(Llama)** 라우팅
- [ ] `model=` 명시 → 권한 범위 내 해당 모델 직접 사용
- [ ] **Fallback:** main 인스턴스 중지 시 sub로 자동 전환
- [ ] 보안 위반 400(PII BLOCK) / 권한 위반 403 / Rate Limit 429 예외 정상

**B-3. 소규모 동시성 스모크**
- [x] **[2026-06-30 실측]** 동시 8×3 + 동시 10×2 = **44/44 성공(100%)**, main/sub 정확히 균등 분배.
      KV 캐시 안정(OOM 없음, VRAM 피크 30.5GB). 콜드스타트(첫 묶음 ~31s) 후 워밍 상태 동시 10건 ~1.2s(p50 0.47s).
      스크립트: `scripts/poc_concurrency_smoke.py <키> <동시수> <라운드>`. (50인 풀로드는 운영 96GB 장비에서)

**합격 기준:** B-1~B-3 통과.
**운영 이전성:** 운영도 한 카드에 vLLM 2개(Llama+Gemma) 구성 → 라우팅/동시상주 메커니즘 그대로 이전(모델 크기만 상이).

---

## Phase C — 운영 서브 모델 실검증 + FP4 디리스킹

> ★**[2026-07-07 운영 결정]** C-1(Gemma 2-27B 서브 실검증)은 통과했으나, Phase B와 동일한 사유로 서브 채팅
> 모델은 운영 미채택(역사적 검증 기록으로 보존). C-2(NVFP4 디리스킹)는 서브와 무관한 일반 양자화 기술검증으로,
> 결론 자체는 유효하나 운영 메인 모델은 **FP8(안정성 우선)로 채택**해 NVFP4는 현재 적용하지 않는다(§운영 결정,
> CLAUDE.md §5 / OPERATOR_GUIDE §10 "선택지 A" 참조). 필요 시 향후 품질/용량 요구가 바뀌면 재검토 가능한 자료로 남긴다.

**목표:** ① 운영 실제 모델(Gemma 2-27B)을 SM120에서 실측, ② 운영의 FP4 듀얼 경로 Go/No-Go 판단.

**C-1. Gemma 2-27B (FP8 ~27GB) 단일 실검증**
```bash
docker compose --profile phase-c up -d        # core + vllm-gemma27b (★단독)
nvidia-smi   # ~27GB 점유, KV 여유 제한적 → 동시성 낮게
```
- [x] **Gemma2 attention 백엔드 실측 [2026-06-29]:** 27B도 9B와 동일 — FLASHINFER 지정에도 vLLM 0.17.1 이
      **FLASH_ATTN 자동 선택**, softcap 정상, SM120 head_size 이슈 미발생.
- [x] FP8 정합성: 출력 품질 정상, **garbage 없음**(양자컴퓨터 한국어 설명·코드 생성 정상). VRAM 31.5GB(빡빡, 단독 필수).
- [x] SM120 FP8 throughput: **~49 tok/s**(단일요청 디코드, 5090). 운영 용량산정 입력값.
- [x] LiteLLM 경유 라우팅 + gemma_compat(system 병합) 정상.
- [x] **참고:** Llama 3.3-70B는 32GB 불가 → 메인 모델 실검증은 운영 장비에서 수행. 본 검증은 커뮤니티 FP8 양자화본.

**C-2. NVFP4 디리스킹 → 조건부 Go ✅ [2026-06-29]**
- [x] NVFP4(W4A4) Llama 3.1-8B 기동 **성공** + garbage 없는 정상 추론(영/한). VRAM ~19GB(FP8의 절반).
- [x] **flashinfer CUTLASS FP4 GEMM 경로 동작 확인:** 로그 `Using NvFp4LinearBackend.FLASHINFER_CUTLASS for NVFP4 GEMM`
      — Marlin 우회, SM120 FP4 실동작. throughput 163 tok/s(8B 단일요청).
- [x] 결론: 운영 "FP4 듀얼/3-트랙" 경로 **현실성 = 조건부 Go**(잔여: 70B/27B NVFP4 가용성·출처, FP4 품질 정밀평가) → 제안서 피드백 반영(REQUIREMENTS §3).
- [x] **품질 PoC 3-way(`docs/POC_FP4_QUANT_COMPARISON.md`):** 8B-FP8/8B-NVFP4/24B-NVFP4 — 까다로운 추론은 모델크기≫양자화,
      FP4 degeneration 리스크는 소형 한정 → **대형=NVFP4 / 소형=FP8** 운영 권장 도출.

**합격 기준:** C-1 통과(필수) ✅. C-2 판정 도출 ✅(조건부 Go).
**운영 이전성:** SM120 동일 → FP8/FP4 결론이 RTX PRO 6000에 그대로 적용.

---

## 종료 기준 (운영 본 구축 Go 판정)

- [ ] Phase 0/A/B 전 항목 통과
- [ ] Phase C-1 통과 및 FP8 용량/성능 실측치 확보
- [ ] Phase C-2 FP4 Go/No-Go 판정 완료
- [ ] 확정 버전·설정 전부 고정 기록(재현 가능)
- [ ] REQUIREMENTS §3 잔여 검증 항목 = **FP4 Go/No-Go**만 (OS/드라이버/CUDA, LiteLLM 무료 OSS는 확정됨). 제안서 본문 반영안 정리

> 위 충족 시: 운영 장비에서 본 환경 설정을 **모델 교체(8B/9B → 70B/27B) 및 VRAM 분할값만 조정**하여 재배포.
