# 운영자 매뉴얼 (Operator Guide)

> 폐쇄망 On-Premise AI Assistant 인프라 운영 가이드.
> 대상: WISE 운영팀(인프라 관리자). 검증 환경(RTX 5090 32GB)에서 실증된 절차이며,
> 운영 장비(RTX PRO 6000 96GB, 동일 SM120)에 **모델/VRAM 분할값만 바꿔** 그대로 적용한다.
> 관련 문서: 사용자용은 `USER_GUIDE.md`, 요구사항 `REQUIREMENTS.md`, 검증계획 `TEST_PLAN.md`.

---

## 0. 한눈에 보는 구성

```
[개발자 IDE: OpenCode / VS Code(Continue)]
        │  OpenAI 호환 + 가상 키(sk-...)
        ▼
[LiteLLM 게이트웨이 :4000]  ── 가상키/RateLimit/PII(Presidio)/Audit/라우팅
        │                         │
        ├──► vLLM main   :8000   (Llama  — 채팅·에이전트·tool calling)
        ├──► vLLM sub    :8001   (Gemma  — 짧은 채팅·자동완성 대체)
        ├──► vLLM autocomplete :8003 (StarCoder2 — tab 자동완성 FIM)
        └──► vLLM gemma27b :8002  (운영 서브 실검증, 단독 기동)
[PostgreSQL]  키/스펜드/Audit       [Presidio analyzer:5002 / anonymizer:5001]
```

| 컴포넌트 | 컨테이너 | 포트(호스트) | 역할 |
|----------|----------|------|------|
| 게이트웨이 | litellm | 4000 | 인증·정책·라우팅·로깅 (유일한 외부 진입점) |
| 추론(메인) | vllm-main | 8000 | Llama 채팅/에이전트 |
| 추론(서브) | vllm-sub | 8001 | Gemma 채팅 |
| 추론(자동완성) | vllm-autocomplete | 8003 | StarCoder2 FIM |
| 추론(27B검증) | vllm-gemma27b | 8002 | Gemma 27B (단독) |
| DB | postgres | (내부전용) | 키·스펜드·Audit |
| PII | presidio-analyzer / anonymizer | 5002 / 5001 | 민감정보 탐지/마스킹 |

> **보안 원칙**: 개발자에게는 **가상 키(sk-...)** 만 배포한다. 마스터 키(`LITELLM_MASTER_KEY`)는 서버 `.env` 에만 두고 절대 노출하지 않는다. PostgreSQL은 호스트 포트를 노출하지 않는다(컨테이너 내부 전용).

---

## 1. 스택 기동 / 중지

Compose **프로파일**로 용도를 분리한다. core(postgres/presidio/litellm)는 프로파일이 없어 항상 함께 뜬다.

```bash
cd /opt/onprem-ai-validation          # 운영 설치 경로

# 용도별 기동
docker compose --profile phase-a  up -d    # 단일 모델(메인) + 거버넌스
docker compose --profile phase-b  up -d    # 메인 + 서브(2-트랙 라우팅)
docker compose --profile phase-ide up -d   # 메인 + 자동완성(StarCoder2) — IDE 풀세트
docker compose --profile phase-c  up -d    # 27B 단독 검증 (★다른 vLLM과 동시 금지)

# 중지 / 완전 제거
docker compose --profile phase-ide down    # 컨테이너 중지·제거 (볼륨/DB는 보존)
docker compose down -v                      # ★볼륨까지 삭제 — DB/키/Audit 소실. 주의!
```

- **VRAM 분할은 `.env`** 로 조정한다(`MAIN_GPU_UTIL`, `SUB_GPU_UTIL`, `AUTOCOMPLETE_GPU_UTIL`, `GEMMA27B_GPU_UTIL`). 한 카드에 여러 모델을 올릴 때 **합이 ~0.9 이하**가 되도록 유지(디스플레이/여유).
- 단일 모델만 띄울 땐 그 모델 util 을 크게: `MAIN_GPU_UTIL=0.85 docker compose --profile phase-a up -d`.
- 이미지 로드(모델 가중치)는 수십 초~분이 걸린다. healthcheck `start_period` 동안 `health: starting` 은 정상.

---

## 2. 헬스체크 / 로그 / 상태

```bash
# 헬스 (200 이면 정상)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000/health            # vLLM main
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4000/health/liveliness # LiteLLM

# 컨테이너 상태 / GPU
docker compose ps
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader

# 로그 (실시간)
docker compose logs -f litellm
docker compose logs -f vllm-main
docker compose logs --since 10m vllm-autocomplete | grep -i error

# 게이트웨이가 노출하는 모델 목록
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer <가상키>"
```

---

## 3. API 키 관리 (3-Tier) — FR-3

역할별 가상 키를 발급한다. 정책은 `scripts/rotate_keys.sh` 에 코드화되어 있다.

| 역할 | RPM | 일토큰(근사) | 모델 |
|------|-----|------|------|
| admin | 무제한 | 무제한 | 전체(main+sub+27b+autocomplete) |
| senior | 120 | 200K | main + sub + autocomplete |
| developer | 60 | 100K | sub + main + autocomplete |

```bash
# 마스터 키는 .env 에서 자동 로드됨
# 발급 (1인 1키 원칙)
./scripts/rotate_keys.sh generate developer hong_gildong      # 일반 개발자
./scripts/rotate_keys.sh generate senior  kim_senior          # 시니어
./scripts/rotate_keys.sh generate admin   ops_admin           # 관리자

# 90일 로테이션 (신규 발급 + 구 키 폐기)
./scripts/rotate_keys.sh rotate <OLD_KEY> developer hong_gildong

# 퇴사/이동 시 즉시 비활성화
./scripts/rotate_keys.sh delete <KEY>

# DRY_RUN=1 을 붙이면 실제 호출 없이 페이로드만 출력(점검용)
```

- 발급된 `key`(sk-...) 는 **안전 채널로 1회 전달**하고, 운영자는 평문 보관하지 않는다(키 식별은 `key_alias`/해시로).
- **90일 자동 만료**(`duration=90d`)가 이중 안전장치로 걸린다. 정기 로테이션은 cron 예시가 스크립트 주석에 있다.
- ★**신규 모델을 추가하면 키 정책에도 반영**해야 한다. 누락 시 그 모델 호출이 `403`(allowlist 거부)된다 → `rotate_keys.sh` 의 `role_payload` 모델 목록을 갱신하고 재발급(또는 `/key/update`).

---

## 4. Audit(감사) 조회 — FR-5

모든 요청은 `audit_log` 테이블에 5필드(WHO/WHEN/MODEL/PROMPT/OUTPUT)로 비동기 적재된다.
조회는 `scripts/audit.sh` 사용(전부 읽기 전용).

```bash
export SUDO=sudo                       # docker 가 sudo 필요한 환경만. 아니면 생략.

./scripts/audit.sh recent 20           # 최근 요청
./scripts/audit.sh stats               # 모델별/사용자별 집계
./scripts/audit.sh user <user_id>      # 특정 사용자
./scripts/audit.sh model main-llama    # 특정 모델
./scripts/audit.sh detail <id>         # 단일 레코드 전문(프롬프트/출력 전체)
./scripts/audit.sh pii                 # PII 마스킹된 요청 (<KR_RRN> 등)
./scripts/audit.sh errors              # 오류 요청
./scripts/audit.sh pending             # 취소·미완료 요청 흔적
./scripts/audit.sh anomalies           # 이상탐지 경보
./scripts/audit.sh psql                # 대화형 psql
```

- `finish_reason`: `stop`/`length`(정상), `error`(실패), **`pending`(취소된 자동완성 등 — WHO/WHEN/MODEL만 흔적, PROMPT는 PII 안전 위해 미기록)**.
- 각 레코드 `prompt_hash`(SHA-256)로 프롬프트 **위변조 검증** 가능.
- 보존기간은 `litellm/config.yaml` 의 `maximum_spend_logs_retention_period`(기본 90d).

---

## 5. PII 마스킹 정책 — FR-6

Presidio(자체 호스팅)로 입력·응답·로그에서 민감정보를 처리한다.

| 엔티티 | 정책 | 결과 |
|--------|------|------|
| KR_RRN(주민번호) | MASK | `<KR_RRN_1>` 로 치환 |
| DB_SECRET(DB비번/시크릿) | **BLOCK** | 요청 차단 → **HTTP 400 + 사유** |
| EMAIL / PHONE / CREDIT_CARD | MASK | 마스킹 |

- 정책 위치: 탐지=`presidio/recognizers/kr_custom.yaml`(analyzer), 조치(MASK/BLOCK)=`litellm/config.yaml` 의 `pii_entities_config`.
- **PERSON(사람 이름) 마스킹은 비활성**(한국어 오탐 심함). 한국어 이름 마스킹이 필요하면 ko spaCy 모델 도입 후 별도 검증.
- analyzer 직접 점검: `curl -s http://localhost:5002/analyze -H "Content-Type: application/json" -d '{"text":"...","language":"en","entities":["KR_RRN","DB_SECRET"]}'`

---

## 6. 이상 탐지 — FR-7

`audit_logger` 가 요청마다 실시간 평가 + `scripts/anomaly_check.sql` 로 배치 재점검.
- 룰① 사용자 평균 토큰 대비 **5배 초과**  / 룰② 동일 사용자 **시간당 300건 초과** → `anomaly_alerts` 적재.

```bash
# 배치 점검(cron 권장, 예: 10분마다)
docker compose exec -T postgres psql -U litellm -d litellm -f - < scripts/anomaly_check.sql
./scripts/audit.sh anomalies     # 경보 확인
```

---

## 7. 백업 / 복구 — FR-11

대상: 키/스펜드/Audit DB(Postgres) + 설정 일체.

```bash
# 백업 (backups/<timestamp>/ 에 db.sql.gz + config.tar.gz + manifest.txt)
sudo bash scripts/backup.sh

# 복구 (24h 이내 재기동, 키·정책·로그 보존)
./scripts/restore.sh backups/<timestamp>
```

- ⚠ `db.sql.gz` 와 `.env` 는 시크릿/감사로그 포함 → **백업본을 보안 매체에 보관**.
- 동일 이미지 태그(`.env`)로 복구해야 재현성 보장. 모델 가중치는 사전 스테이징 디렉터리에 별도 반입.

---

## 8. 오프라인 모델 업데이트 — FR-10

폐쇄망은 런타임 인터넷이 없으므로, 모델/이미지는 **사전 스테이징(오프라인 반입)** 후 검증한다.

```bash
# ① (분리망) 무결성 매니페스트 생성 → 반입 매체에 동봉
./scripts/stage_model.sh manifest ./models/<model_dir>

# ② (사내망) 게이트: 체크섬 + 라이선스 + (trivy 있으면)취약점 스캔
./scripts/stage_model.sh gate ./models/<model_dir> <image:tag>
#   → 체크섬 불일치/라이선스 누락/HIGH·CRITICAL 취약점이면 비0 종료(배포 차단)

# ③ Blue/Green 무중단 배포 (게이트웨이 레벨 카나리)
./scripts/deploy_model.sh deploy <model_name> ./models/<new_dir> --mode canary
./scripts/deploy_model.sh status  <model_name>
./scripts/deploy_model.sh promote <model_name>     # 컷오버(blue 제거) — 또는
./scripts/deploy_model.sh rollback <model_name>    # 롤백(green 제거)
```

- 라이선스 파일(LICENSE/NOTICE)을 모델 디렉터리에 **반드시 동봉**(게이트가 검사).
- 소형 모델은 `--mode canary`(blue·green 동시 상주). **대형(27B/70B 등)은 VRAM 부족 → `--mode sequential`**(짧은 다운타임). 운영 96GB에선 대형도 canary 가능.

---

## 9. 트러블슈팅 (검증 중 실제로 겪은 사례)

| 증상 | 원인 | 조치 |
|------|------|------|
| vLLM "no kernel image" / garbage 출력 | 드라이버/CUDA/torch ↔ SM120 불일치 | Driver 570+/CUDA 12.8+/torch cu128+, vLLM 0.17+ 확인 |
| Audit 가 안 쌓임 | LiteLLM 이미지에 **asyncpg 부재** | `litellm/Dockerfile`(asyncpg 내장) 커스텀 이미지 사용 — `.env` `LITELLM_IMAGE` |
| Audit 콜백 `unrecognized configuration parameter "connection_limit"` | Prisma 가 DATABASE_URL 에 쿼리 추가 | `audit_logger.py` 가 DSN 쿼리스트링 제거(반영됨) |
| PII 마스킹이 안 됨 | guardrail `default_on:true` 누락 | `litellm/config.yaml` 의 guardrail 에 `default_on: true` |
| 응답에 `<PERSON>` 남발 | PERSON 마스킹의 한국어 오탐 | `pii_entities_config` 에서 PERSON 제거(반영됨) |
| IDE 에이전트 `"auto" tool choice requires...` | vLLM tool 파서 미설정 | main 에 `--enable-auto-tool-choice --tool-call-parser llama3_json` |
| Gemma 가 에이전트(OpenCode)에서 실패 | Gemma2 chat template 이 system/tools 미지원 | `litellm/gemma_compat.py`(system 병합+tools 제거) 콜백 |
| 신규 모델 호출 `403 key not allowed` | 키 allowlist 에 모델 누락 | `rotate_keys.sh` 모델 목록 갱신 + 재발급/`key/update` |
| tab 자동완성이 안 뜸 | Llama/Gemma 는 FIM 미지원(instruct) | **FIM 전용 코드 모델**(StarCoder2 등) 별도 배포 |
| 자동완성 요청이 Audit 누락 | 취소(abort) 요청은 success 콜백 미발생 | `audit_logger` pre_call pending 기록(반영됨) |
| 에이전트가 코드 실행 실패 `Python executable not found` | 호스트에 `python` 명령 부재(`python3`만) | `sudo apt install python-is-python3` (에이전트의 bash 코드 실행에 필요) |
| 에이전트 요청 `400 ... context length is only N tokens` | OpenCode 등 에이전트는 system+도구정의+대화 누적으로 입력↑ → max-model-len 초과 | `.env` `MAIN_MAX_LEN` 확대(예 32768~). Llama 3.1 은 128K 지원, 운영 70B 도 동일. KV 증가분 VRAM 고려 |
| 자동완성 모델 바꿨더니 빈 제안(0 tok) | Continue 가 모델별 FIM 토큰 추론 실패 — 커스텀 모델명을 Qwen 으로 인식 못해 StarCoder2 토큰(`<fim_prefix>`)을 Qwen(`<\|fim_prefix\|>`)에 전송 | `litellm/autocomplete_compat.py` 콜백이 게이트웨이에서 FIM 토큰 정규화(반영됨). 타 코드모델(DeepSeek-Coder 등)도 동일 패턴 |
| 에이전트에서 `Rate limit exceeded`(적게 쓴 듯한데 발생) | OpenCode 등 에이전트는 **1 프롬프트당 tool 왕복으로 모델 수십~수백 회 호출** → 일반 채팅 기준 RPM(60) 금방 초과 + 재시도 악순환 | 에이전트 사용 키는 **RPM/TPM 대폭 상향**(예 600 RPM/2M TPM). `rotate_keys.sh` 의 에이전트 사용자 등급을 상향하거나 전용 등급 신설 |

---

## 10. 운영 모델 구성 (Phase C 검증 반영, 2026-06-29)

Phase C 실측 결과를 반영한 운영 권장 구성. SM120(5090) 검증분은 운영 RTX PRO 6000(동일 SM120)에 그대로 이전된다.

**선택지 A — 2-트랙 (품질 최우선, 안정):**

| 역할 | 모델 | 양자화 | VRAM(약) |
|------|------|--------|------|
| 채팅·에이전트 | Llama 3.3-70B-Instruct | FP8 | ~70GB |
| 자동완성(FIM) | StarCoder2-7B (또는 CodeLlama-7B) | FP8 | ~7GB |

합 ~77GB, KV 여유 ~19GB. 가장 안정적. 짧은 Q&A는 70B가 흡수.

**선택지 B — 3-트랙 (서브 모델까지, FP4 활용):**

| 역할 | 모델 | 양자화 | VRAM(약) |
|------|------|--------|------|
| 채팅·에이전트 | Llama 3.3-70B-Instruct | **NVFP4** | ~38GB |
| 서브 채팅 | Gemma 2-27B | FP8 | ~27GB |
| 자동완성(FIM) | StarCoder2-7B | FP8 | ~7GB |

합 ~72GB. **FP4 디리스킹 성공으로 현실화됨**(아래).

**선택지 C — NVFP4 모델 상향 (최고 품질 지향):**

NVFP4 가 FP8 대비 VRAM 을 절반으로 줄이므로, **같은 ~70GB 메모리에 70B 대신 123B급 모델을 적재**할 수 있다.
PoC(`docs/POC_FP4_QUANT_COMPARISON.md`)에서 "모델 크기 ≫ 양자화"를 확인 → 같은 VRAM 에서 더 큰 모델이 품질 우위.

| 역할 | 모델 | 양자화 | VRAM(약) |
|------|------|--------|------|
| 채팅·에이전트 | **Mistral Large 2 (123B)** 또는 Command-A (111B) | **NVFP4** | ~70–73GB |
| 자동완성(FIM) | StarCoder2-7B | FP8 | ~7GB |

합 ~77–80GB(선택지 A 와 동일 VRAM 프로파일), KV 여유 ~16–19GB. **메인만 70B→123B 로 격상**.

- ★**단일 96GB 상한 = 123B급.** 405B(NVFP4 ~234GB)·675B(~403GB)는 단일 카드 불가(멀티 GPU 필요 → 정책상 금지).
- **전제 조건:** ① 123B NVFP4 **공식/신뢰 체크포인트 출처 확정**(검색된 123B NVFP4 는 커뮤니티본 위주, Mistral 공식 NVFP4 는 675B만),
  ② 96GB 장비에서 **`70B-FP8 vs 123B-NVFP4` 품질 직접 비교** 후 채택, ③ tool calling 파서 확인(Mistral=`mistral`).
- **트레이드오프:** 123B 는 70B 대비 **디코드 ~1.7배 느림**(채팅 허용 가능, 자동완성은 별도 FIM 이라 무관). degeneration 리스크는 대형이라 낮음(PoC 상 24B 안정).

**세 선택지 비교 요약:**

| 선택지 | 메인 | 성격 | 우선순위 |
|--------|------|------|----------|
| **A** | 70B-FP8 | 검증된 안정·빠름 | 출시 기본값(권장) |
| **B** | 70B-NVFP4 + 27B-FP8 서브 | 서브 모델 다양성·부하분산 | 동시 사용자↑·서브 필요 시 |
| **C** | 123B-NVFP4 | 같은 VRAM 에 더 큰 모델 → 품질 상향 | 품질 최우선·속도 양보 가능 시 |

> 출시는 A 로 시작하고, B/C 는 각각 PoC(서브 라우팅 효용 / 123B 품질 우위)로 검증한 뒤 전환을 권장한다.

**FP4 Go/No-Go 결론 → 조건부 Go ✅**
- 검증장비(5090, SM120)에서 **NVFP4(W4A4) 기동·추론 성공**. vLLM 0.17.1 이 `FLASHINFER_CUTLASS` FP4 GEMM 경로 사용,
  garbage 없음, VRAM 절반, throughput 양호(8B 163 tok/s).
- **PoC 품질 비교 결과(상세: `docs/POC_FP4_QUANT_COMPARISON.md`):**
  - 까다로운 추론에선 **모델 크기 ≫ 양자화** — 24B-NVFP4 가 8B-FP8 을 함정/논리/한국어 추론에서 압도 → **70B-NVFP4 전략 지지**.
  - **FP4 degeneration(반복 붕괴) 리스크는 작은 모델 한정** — 8B-NVFP4 는 긴 한국어 추론에서 붕괴, 24B-NVFP4 는 안정.
    ⇒ **대형 메인은 NVFP4 안전 / 소형(자동완성·서브)은 FP8 권장**.
- **운영 적용 전 확인 과제:** ① 70B/27B **NVFP4 체크포인트 가용성·출처** 확정, ② 96GB 장비에서 `70B-FP8 vs 70B-NVFP4` 최종 품질 비교.

**Phase C FP8 실측치(용량산정 참고):** Gemma 2-27B FP8 단일요청 디코드 **~49 tok/s**(5090). 운영 96GB는 더 큰 KV/배치로 동시성↑.

- 확정 버전(드라이버/CUDA/vLLM/LiteLLM 태그): `CLAUDE.md §4` 및 `.env` 참조(재현성, NFR-2).
- ⚠ 본 검증의 Gemma 27B FP8·NVFP4 체크포인트는 **커뮤니티/RedHat 양자화**다. 운영은 양자화 출처를 확정·재스테이징할 것.

---

## 부록 A. 운영 전환(Go-Live) 체크리스트

검증 환경에서 운영 장비로 전환할 때 1회 수행한다. **검증 중 누적된 데이터/키를 모두 비우고 운영 값으로 재설정**한다.

- [ ] **검증 데이터 초기화** — audit/이상탐지 로그를 전부 비우고 깨끗한 상태로 시작:
  ```bash
  docker compose exec postgres psql -U litellm -d litellm \
    -c "TRUNCATE audit_log, anomaly_alerts RESTART IDENTITY CASCADE;"
  ```
- [ ] **테스트 키 전량 삭제 후 운영 키 발급** — 검증용 가상 키를 모두 폐기하고, 실제 사용자에게 1인 1키로 재발급:
  ```bash
  # 남은 키 확인 → 전부 삭제(key_aliases) → 운영 사용자별 발급
  ./scripts/rotate_keys.sh generate developer <실사용자>   # 반복
  ```
- [ ] **시크릿 재생성** — `LITELLM_MASTER_KEY`, `POSTGRES_PASSWORD` 를 운영용 강난수로 교체(`.env`), 보안 매체 보관
- [ ] **모델 교체** — 검증 모델(8B/9B/7B) → 운영 모델(70B/27B/FIM)로 `.env` 모델 경로·`docker-compose` 갱신, 사전 스테이징+게이트
- [ ] **VRAM 분할 재조정** — 운영 장비(96GB) 기준 `*_GPU_UTIL` 값 재산정(§10)
- [ ] **확정 버전 점검** — 드라이버/CUDA/vLLM/LiteLLM 태그가 `.env`·`CLAUDE.md §4` 와 일치(재현성, NFR-2)
- [ ] **백업 1회** — 운영 초기 상태 백업(`scripts/backup.sh`)
- [ ] 헬스체크 전 항목 200, 가상 키로 E2E 1건 + Audit 적재 확인

## 부록 B. 표준 점검 체크리스트 (일상 운영)

- [ ] `docker compose ps` 전 컨테이너 healthy
- [ ] `nvidia-smi` VRAM/온도 정상
- [ ] `./scripts/audit.sh anomalies` 신규 경보 확인
- [ ] `./scripts/audit.sh errors` 비정상 오류율 점검
- [ ] 주간: `scripts/backup.sh` 백업 + 보안 매체 보관
- [ ] 분기: 키 90일 로테이션, 퇴사자 키 정리
