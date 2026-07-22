# 운영자 매뉴얼 (Operator Guide)

> 폐쇄망 On-Premise AI Assistant 인프라 운영 가이드.
> 대상: WISE 운영팀(인프라 관리자). 검증 환경(RTX 5090 32GB)에서 실증된 절차이며,
> 운영 장비(RTX PRO 6000 96GB, 동일 SM120)에 **모델/VRAM 분할값만 바꿔** 그대로 적용한다.
> 관련 문서: 사용자용은 `USER_GUIDE.md`, 요구사항 `REQUIREMENTS.md`, 검증계획 `TEST_PLAN.md`.

---

## 0. 한눈에 보는 구성

> ★[2026-07-13 확정, 2026-07-14 G 추가로 갱신] 운영 구성은 main(+autocomplete, A/D/E 선택 시)을
> 사용한다. main에 실제로 어떤 모델이 실리는지, autocomplete를 함께 띄울지는 운영자가 선택하는
> **선택지 A/D/E/G**에 따라 다르다(§10 참조, 기본값은 E=gpt-oss-120b+FIM). **G를 선택하면
> autocomplete는 기동하지 않는다**(FIM 없이 main 컨텍스트를 최대 확보).
> vLLM sub(8001)/gemma27b(8002)는 Phase B/C 역사적 검증에만 쓰였고, 서브 채팅 모델 자체를 운영에서 쓰지
> 않기로 확정했으므로 **평소 기동하지 않는다**(어떤 선택지를 선택해도 무관하게 고정된 정책).

```
[개발자 IDE: OpenCode / VS Code(Continue)]
        │  OpenAI 호환 + 가상 키(sk-...)
        ▼
[LiteLLM 게이트웨이 :4000]  ── 가상키/RateLimit/PII(Presidio)/Audit/라우팅
        │                         │
        ├──► vLLM main   :8000   (선택지 A/D/E/G 중 운영자 선택 — 기본 E=gpt-oss-120b)  ★운영 상시 기동
        └──► vLLM autocomplete :8003 (StarCoder2 — tab 자동완성 FIM)     ★A/D/E만 기동, G는 미기동
[PostgreSQL]  키/스펜드/Audit       [Presidio analyzer:5002 / anonymizer:5001]

(역사적 검증 전용, 운영 미기동)
        ├──► vLLM sub    :8001   (Gemma  — Phase B 라우팅 검증용, 서브 채팅 미채택)
        └──► vLLM gemma27b :8002  (Gemma 27B — Phase C 서브 실검증용, 미채택)
```

| 컴포넌트 | 컨테이너 | 포트(호스트) | 역할 | 운영 상태 |
|----------|----------|------|------|------|
| 게이트웨이 | litellm | 4000 | 인증·정책·라우팅·로깅 (유일한 외부 진입점) | 상시 |
| 추론(메인) | vllm-main | 8000 | 채팅/에이전트(A/D=Llama, E/G=gpt-oss — §10에서 운영자 선택) | 상시 |
| 추론(자동완성) | vllm-autocomplete | 8003 | StarCoder2 FIM(7B 또는 15B, 선택지별 상이) | A/D/E만(G는 미기동) |
| 추론(서브) | vllm-sub | 8001 | Gemma 채팅 | ★미기동(Phase B 역사적 검증 전용) |
| 추론(27B검증) | vllm-gemma27b | 8002 | Gemma 27B (단독) | ★미기동(Phase C 역사적 검증 전용) |
| DB | postgres | (내부전용) | 키·스펜드·Audit | 상시 |
| PII | presidio-analyzer / anonymizer | 5002 / 5001 | 민감정보 탐지/마스킹 | 상시 |

> **보안 원칙**: 개발자에게는 **가상 키(sk-...)** 만 배포한다. 마스터 키(`LITELLM_MASTER_KEY`)는 서버 `.env` 에만 두고 절대 노출하지 않는다. PostgreSQL은 호스트 포트를 노출하지 않는다(컨테이너 내부 전용).

---

## 1. 스택 기동 / 중지

Compose **프로파일**로 용도를 분리한다. core(postgres/presidio/litellm)는 프로파일이 없어 항상 함께 뜬다.

```bash
cd /opt/onprem-ai-validation          # 운영 설치 경로

# 용도별 기동
docker compose --profile phase-prod up -d  # ★운영 채택: 메인(70B) + 자동완성(StarCoder2) 2-트랙
docker compose --profile phase-a  up -d    # 단일 모델(메인, 검증용 8B) + 거버넌스
docker compose --profile phase-b  up -d    # 메인 + 서브(2-트랙 라우팅) — ★역사적 검증 전용, 운영 미사용
docker compose --profile phase-ide up -d   # 메인 + 자동완성(StarCoder2, 검증용 8B) — IDE 풀세트 검증
docker compose --profile phase-c  up -d    # 27B 단독 검증 — ★역사적 검증 전용, 운영 미사용 (다른 vLLM과 동시 금지)

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
./scripts/audit.sh model main-gptoss   # 특정 모델(현재 기본 E. A/D 선택 시 main-llama)
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
| (phase-b 전용) Gemma 가 에이전트(OpenCode)에서 실패 | Gemma2 chat template 이 system/tools 미지원 | `litellm/gemma_compat.py`(system 병합+tools 제거) 콜백 — ★운영은 Gemma 미사용이라 해당 없음 |
| 신규 모델 호출 `403 key not allowed` | 키 allowlist 에 모델 누락 | `rotate_keys.sh` 모델 목록 갱신 + 재발급/`key/update` |
| tab 자동완성이 안 뜸 | Llama/Gemma 는 FIM 미지원(instruct) | **FIM 전용 코드 모델**(StarCoder2 등) 별도 배포 |
| 자동완성 요청이 Audit 누락 | 취소(abort) 요청은 success 콜백 미발생 | `audit_logger` pre_call pending 기록(반영됨) |
| 에이전트가 코드 실행 실패 `Python executable not found` | 호스트에 `python` 명령 부재(`python3`만) | `sudo apt install python-is-python3` (에이전트의 bash 코드 실행에 필요) |
| 에이전트 요청 `400 ... context length is only N tokens` | OpenCode 등 에이전트는 system+도구정의+대화 누적으로 입력↑ → max-model-len 초과 | `.env` `MAIN_MAX_LEN` 확대(예 32768~). Llama 3.1 은 128K 지원, 운영 70B 도 동일. KV 증가분 VRAM 고려 |
| 자동완성 모델 바꿨더니 빈 제안(0 tok) | Continue 가 모델별 FIM 토큰 추론 실패 — 커스텀 모델명을 Qwen 으로 인식 못해 StarCoder2 토큰(`<fim_prefix>`)을 Qwen(`<\|fim_prefix\|>`)에 전송 | `litellm/autocomplete_compat.py` 콜백이 게이트웨이에서 FIM 토큰 정규화(반영됨). 타 코드모델(DeepSeek-Coder 등)도 동일 패턴 |
| 에이전트에서 `Rate limit exceeded`(적게 쓴 듯한데 발생) | OpenCode 등 에이전트는 **1 프롬프트당 tool 왕복으로 모델 수십~수백 회 호출** → 일반 채팅 기준 RPM(60) 금방 초과 + 재시도 악순환 | 에이전트 사용 키는 **RPM/TPM 대폭 상향**(예 600 RPM/2M TPM). `rotate_keys.sh` 의 에이전트 사용자 등급을 상향하거나 전용 등급 신설 |
| 에이전트가 개발 서버(Flask/Node 등) 백그라운드 기동 명령에서 응답 없이 멈춤 | OpenCode bash 도구가 `nohup ... &`로 정상 백그라운드 처리된 명령도 종료를 계속 기다리는 한계(2026-07-21~22 실측, 명령어 자체는 터미널 직접 실행 시 정상) | ★[2026-07-22 1차] `~/.config/opencode/AGENTS.md`(리포 템플릿 `AGENTS.md.example`)에 지침 추가만으로는 불충분함이 실측 확인됨 — 신규 세션이 지침을 **인지(복창)**하는 것과 실행 시 **준수**하는 것은 별개였고, 실제 세션에서 `nohup npm run dev`/`nohup node index.js` 시도가 2시간 동안 20회 가까이 재현됨(permission 설정이 없어 모든 bash 명령이 기술적으로 무조건 자동 allow였던 것이 근본 원인). ★[2026-07-22 2차, 확정] `~/.config/opencode/opencode.jsonc`에 `permission.bash`로 `"nohup *": "deny"`, `"* &": "deny"` 추가 — 프롬프트 수준 권고가 아니라 명령 실행 자체를 차단하는 기술적 강제로 전환(`docs/USER_GUIDE.md` §3 참조) |

---

## 10. 운영 모델 구성 (Phase C 검증 반영, 2026-06-29 / ★2026-07-08 최종 채택·실측 반영)

Phase C 실측 결과를 반영한 운영 권장 구성. SM120(5090) 검증분은 운영 RTX PRO 6000(동일 SM120)에 그대로 이전된다.

> ★**[2026-07-13 운영 정책 확정, 2026-07-14 G 추가] 선택지 A/D/E/G 네 구성 모두 운영자가 자유롭게
> 선택·전환 가능한 정식 운영 옵션이다. 초기 기동 시 기본값은 선택지 E(아래).** E는 아키텍처가 다른 `gpt-oss-120b`(OpenAI,
> 표준 MoE)로, 이전 기본값이던 D(Llama NVFP4+FIM 15B) 대비 품질 PoC에서 근소 우위(hard-set 7/7 vs
> 6.5/7) + 처리량 8배가 실측 확인되어 기본값으로 채택됐다(완료보고서 §17). FIM은 VRAM 마진 확보를 위해
> 15B→7B로 하향(품질 트레이드오프 있음 — 상세는 아래 "운영자 선택 가이드" 참조). D/A는 폐기된 게 아니라
> **운영자가 상황에 따라 언제든 선택할 수 있는 대안**으로 계속 유지된다. 서브 채팅 모델(Gemma 트랙)을
> 쓰지 않는다는 결정(운영 단순성 우선, 2026-07-07)은 세 옵션과 무관하게 그대로 유지 — 선택지 B/C는
> 여전히 미채택. `scripts/switch_model_option.sh {a|d|e}`로 세 구성 중 언제든 전환.

**선택지 A — 2-트랙(FP8, 품질 최우선·안정) — ★[운영자 선택 가능, 최초 채택 2026-07-07]:**

| 역할 | 모델 | 양자화 | VRAM(이론치) | VRAM(실측, RTX PRO 6000) |
|------|------|--------|------|------|
| 채팅·에이전트 | Llama 3.3-70B-Instruct | FP8 | ~70GB | 가중치 67.72GB |
| 자동완성(FIM) | StarCoder2-7B | FP8 | ~7GB | 실사용 ~13.6GB(가중치 7.4GB + CUDA 컨텍스트/cudagraph 오버헤드) |

이론치는 합 ~77GB/KV 여유 ~19GB였으나, **실측 결과 총 사용량 96.4GB/97.9GB(여유 1.4GB만 남음)**. 차이 원인:
① `gpu_memory_utilization`은 vLLM 자체 텐서(가중치+KV) 예산일 뿐 프로세스별 CUDA 컨텍스트·cudagraph 캡처
오버헤드는 포함하지 않음, ② 두 vLLM 프로세스가 각각 별도 오버헤드를 가짐. 실제 채택 파라미터(`.env`):
`MAIN_GPU_UTIL=0.83`, `MAIN_MAX_LEN=27648`(이론상 32768 목표했으나 KV 부족으로 하향), `AUTOCOMPLETE_GPU_UTIL=0.10`.
VRAM 여유가 매우 타이트하므로(1.4GB) 동시 부하 급증 시 OOM 리스크를 주기적으로 재확인할 것(§동시성 스모크).

**선택지 B — 3-트랙 (서브 모델까지, FP4 활용) — ★평가했으나 미채택:**

| 역할 | 모델 | 양자화 | VRAM(약) |
|------|------|--------|------|
| 채팅·에이전트 | Llama 3.3-70B-Instruct | **NVFP4** | ~38GB |
| 서브 채팅 | Gemma 2-27B | FP8 | ~27GB |
| 자동완성(FIM) | StarCoder2-7B | FP8 | ~7GB |

합 ~72GB. **FP4 디리스킹 성공으로 현실화됨**(아래).

**선택지 C — NVFP4 모델 상향 (최고 품질 지향) — ★평가했으나 미채택(선택지 A로 대체):**

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

**선택지 D — 2-트랙(main NVFP4 + FIM 15B, 서브 없음) — ★[운영자 선택 가능, 최초 채택 2026-07-08]:**

선택지 B(NVFP4 main + 27B 서브 + FIM)에서 **서브만 제거**하고 절감된 VRAM을 FIM 모델 상향에 쓴 구성. 선택지
A(FP8) 대비 main 가중치를 NVFP4로 줄여, 서브 없이도 FIM을 7B→15B로 키울 여유를 확보했다.

| 역할 | 모델 | 양자화 | 가중치(실측) | KV 여유(실측) |
|------|------|--------|------|------|
| 채팅·에이전트 | Llama 3.3-70B-Instruct | **NVFP4** | 39.89GiB | 26.2GiB (컨텍스트 27648 기준) |
| 자동완성(FIM) | **StarCoder2-15B**(구 7B에서 상향) | FP8 | 15.43GiB | 2.14GiB (컨텍스트 8192 기준) |

**GPU 총사용 ~90.5GB/97.9GB(여유 ~4.5GB)** — 선택지 A의 여유 30MiB 대비 훨씬 안전. 실제 채택 파라미터(`.env`):
`MAIN_MODEL_PATH=/models/llama-3.3-70b-instruct-nvfp4`, `MAIN_GPU_UTIL=0.72`, `MAIN_MAX_LEN=27648`,
`AUTOCOMPLETE_MODEL_PATH=/models/starcoder2-15b-fp8`, `AUTOCOMPLETE_GPU_UTIL=0.20`, `AUTOCOMPLETE_MAX_LEN=8192`.

- **NVFP4 실동작 확인:** 로그 `Using NvFp4LinearBackend.FLASHINFER_CUTLASS for NVFP4 GEMM` — Phase C에서 8B로
  검증했던 FP4 경로가 70B에서도 그대로 실동작(SM120 파리티 재확인).
- **★기동 순서 필수(순차):** main과 autocomplete를 **동시에** `docker compose up -d`로 올리면 서로의 메모리
  프로파일링이 간섭해 실제보다 훨씬 부족하게 계산되어 **둘 다 기동 실패**한다(실측: main "Available KV cache:
  -2.73GiB", autocomplete "-33.84GiB"). 반드시 main을 먼저 올려 healthy 확인 후 autocomplete를 올릴 것.
- **FIM 품질 개선 확인:** 동일한 "정답 뒤 garbage 생성" 재현 테스트에서 7B는 관련없는 텍스트를 계속 생성했으나,
  15B는 짧은 프롬프트에서도 4회 중 3회가 자연스러운 `finish_reason: stop`으로 끊기고, 나머지도 맥락상 타당한
  코드 연장(`Triangle(3,4).area()`, `print(multiply(...))`)이었다 — 모델 크기 상향이 실제 체감 품질을 높임.
- **라이선스:** 둘 다 RedHatAI 사전 양자화 체크포인트(ungated). NVFP4는 Llama 3.3 Community License(원본 미양자화
  리포에서 LICENSE 확보), StarCoder2-15B는 BigCode OpenRAIL-M v1(7B와 동일 라이선스 계열).

**선택지 E — 2-트랙(gpt-oss-120b + FIM 7B, 다른 아키텍처) — ★[운영 채택, 2026-07-13 실장비 실측]:**

D 이후 "선택지 C"(더 큰/다른 메인 모델) 후보를 재검토하며 Nemotron-3-Super(하이브리드 Mamba+MoE, 미검증
SM120)와 Mistral-Small-4-119B(MLA, SM120에서 vLLM/SGLang 전 백엔드 실패)를 시도했으나 둘 다 하드웨어
한계로 좌절됐다. 세 번째 후보 `gpt-oss-120b`(OpenAI, 표준 MoE — MLA도 하이브리드 Mamba도 아님)는 성공했다.

| 역할 | 모델 | 양자화 | 가중치(실측) | KV 여유(실측, 컨텍스트 32768/8192) |
|------|------|--------|------|------|
| 채팅·에이전트 | **gpt-oss-120b**(OpenAI, 128 전문가 중 4개 활성) | **MXFP4**(네이티브) | 65.97GiB | 7.41GiB, 107,888토큰(풀컨텍스트 동시성 약 3.3x) |
| 자동완성(FIM) | StarCoder2-**7B**(15B에서 하향 — VRAM 확보) | FP8 | 6.96GiB | 2.39GiB |

**GPU 총사용 ~93.4GB/97.9GB(여유 ~3.7GB)** — D(여유 ~3.5~4.5GB)와 동급 안전 마진. ★[2026-07-14
재튜닝, 완료보고서 §18.12] 사용자 편의를 위해 `MAIN_MAX_LEN`을 27648→32768(+18.5%)로 상향하고
`MAIN_GPU_UTIL`을 0.80→0.81로 소폭 올렸다. **주의**: 이전에 이 표에 있던 "동시성 5.23x" 수치는
실측 재검증 결과 부정확했던 것으로 판명됨(27648/0.80 기준으로도 실제로는 약 3.4x였음) — 즉 이번
재튜닝은 동시성 손실 없이 컨텍스트만 확장한 결과. 실제 채택 파라미터(`.env`,
`scripts/switch_model_option.sh e`로 자동 적용): `MAIN_MODEL_PATH=/models/gpt-oss-120b`,
`MAIN_SERVED_NAME=main-gptoss`, `MAIN_TOOL_PARSER=openai`, `MAIN_EXTRA_ARGS=--reasoning-parser openai_gptoss`,
`MAIN_GPU_UTIL=0.81`, `MAIN_MAX_LEN=32768`, `AUTOCOMPLETE_MODEL_PATH=/models/starcoder2-7b-fp8`,
`AUTOCOMPLETE_GPU_UTIL=0.11`, `AUTOCOMPLETE_MAX_LEN=8192`.

- **아키텍처 전환 특이사항(A↔D와 다른 점):** A↔D는 둘 다 Llama라 served-model-name(`main-llama`)을 고정
  유지했지만, E는 완전히 다른 모델이라 **`main-gptoss`로 이름 자체를 변경**했다. 이 경우
  `litellm/config.yaml`의 메인 라우트, 클라이언트 설정(`opencode.json`/`~/.continue/config.yaml`)의 모델
  키, **그리고 기존에 발급된 모든 가상 키의 allowlist**까지 함께 바뀌어야 한다(마지막 항목은 `switch_model_option.sh`
  최초 구현에 빠져있던 버그였고, 실측 중 발견해 스크립트에 정식으로 추가함 — 완료보고서 §18 참조).
- **SM120 MXFP4 커널 미인식(업스트림 버그):** `Your GPU does not have native support for FP4 computation...
  Marlin kernel` 경고가 항상 뜬다(`VLLM_USE_FLASHINFER_MOE_MXFP4_MXFP8=1`로도 우회 안 됨 — vLLM이 SM120을
  인식 못 해 발생하는 별개 버그). 실사용 처리량은 185 tok/s로 지장 없음(8B급보다 빠름 — MoE 특성상 토큰당
  5.1B만 활성화).
- **★harmony 포맷(필수 권고 — 운영 시 반드시 확인):** gpt-oss는 reasoning(사고과정)과 content(최종답)를
  분리 응답한다. `max_tokens`가 작으면 `finish_reason: "length"`로 잘려 **content가 null로 반환**될
  수 있다 — **어려운 질문뿐 아니라 "리스트 길이 구하는 함수?"처럼 간단해 보이는 질문도 위험군**임이
  30분 소크 테스트에서 실측 확인됐다(`max_tokens=300`에서 프롬프트 9종 중 2종이 매번 잘림, 전체
  트래픽의 11.1%가 실패 — 완료보고서 §18.11). **클라이언트 `max_tokens` 기본값을 최소 900 이상으로
  설정할 것**(실측: 900에서 안정적으로 완결, §18.2에서 동일 조건 90/90 100% 성공 재확인). OpenCode/
  Continue 클라이언트는 자체 기본값이 이보다 넉넉해 정상 동작 확인됨(`opencode.json`의 `limit.output:
  4096`으로 이미 충분) — 문제는 **직접 API를 호출하는 자체 스크립트/자동화**에서 작은 `max_tokens`를
  하드코딩했을 때 발생한다.
- **FIM 7B 트레이드오프:** §13에서 확인한 StarCoder2-7B의 EOS 불안정(정답 뒤 관련없는 텍스트 생성)이 재현됨.
  LiteLLM stop 토큰 설정(`litellm/config.yaml`)으로 완화되나 완전히 해결되지는 않는다. IDE 자동완성을 많이
  쓰는 사용자는 이 트레이드오프를 감안할 것.
- **품질 PoC 결과(완료보고서 §17.8, `poc_quant_compare.py` hard/easy-set 재사용):** 충분한 토큰 예산에서
  gpt-oss가 hard-set **7/7**(Llama 6.5/7 — 논리 문항이 다소 모호)로 근소 우위, 처리량은 **8배**(184 vs 22 tok/s).
- ★[2026-07-14 재튜닝] 사용자 편의를 위해 `MAIN_MAX_LEN` 27648→**32768**, `MAIN_GPU_UTIL` 0.80→**0.81**로
  소폭 상향(GPU 여유 5.4GB→**3.7GB**). 상세: 완료보고서 §18.12.

**선택지 G — gpt-oss-120b 단독(FIM 없음, 2026-07-14 신설, 완료보고서 §18.13):**

autocomplete(FIM) 컨테이너를 아예 기동하지 않아, StarCoder2-7B가 쓰던 VRAM(가중치+KV 총 9.35GiB)이
전부 main의 KV캐시로 넘어간다. **채팅/에이전트 전용 — IDE tab 자동완성이 필요 없거나, 긴 대화·큰
문서를 다루는 컨텍스트 확보가 더 중요한 사용자에게 적합.**

| 항목 | 값 |
|------|-----|
| 메인 | gpt-oss-120b(MXFP4), FIM 없음 |
| `MAIN_MAX_LEN` | **65536**(E의 2배) |
| KV캐시(실측) | 15.96GiB(232,352토큰), 동시성 약 3.55x |
| GPU 여유(실측) | **~6.05GB**(다섯 선택지 중 가장 여유로움) |
| 클라이언트 `context` | 60000 |

- 단독 프로세스라 A/D/E의 "동시기동 시 서로 메모리 프로파일링 간섭"(§13.3) 문제 자체가 없음 — main만
  올리면 끝, 순차 기동 개념이 적용되지 않는다.
- **주의**: 이 구성이 활성인 동안 `autocomplete-starcoder2` 라우트로 오는 요청은 전부 연결 오류(500)를
  반환한다(백엔드 컨테이너가 꺼져 있음) — IDE tab 자동완성을 쓰는 사용자가 있다면 사전 공지 필요.
- 전환: `scripts/switch_model_option.sh g`.

**여섯 선택지 비교 요약:**

| 선택지 | 메인 | 성격 | 상태 |
|--------|------|------|----------|
| **A** | Llama 70B-FP8 + FIM 7B | 검증된 안정·빠름, VRAM 매우 타이트(~1.4GB) | ✅ **운영자 선택 가능**(최초 채택 2026-07-07) |
| B | Llama 70B-NVFP4 + 27B-FP8 서브 | 서브 모델 다양성·부하분산 | ❌ 미채택(서브 채팅 모델 자체를 쓰지 않기로 결정) |
| C | 123B-NVFP4 / Nemotron-Super / Mistral-Small-4 | 같은 VRAM 에 더 큰/다른 모델 → 품질 상향 | ❌ 미채택(하드웨어 한계 또는 실익 낮음, gpt-oss로 대체) |
| **D** | Llama 70B-**NVFP4** + FIM **15B** | 안정적 Llama 응답 스타일 + 준수한 FIM 품질, VRAM 여유 ~3.5~4.5GB | ✅ **운영자 선택 가능**(최초 채택 2026-07-08) |
| **E** | **gpt-oss-120b**(MXFP4) + FIM **7B** | 채팅/에이전트 품질·속도 최우수, 컨텍스트 32768, VRAM 여유 ~3.7GB, FIM은 7B 수준 | ✅ **기본값(운영 시작 구성)**, 2026-07-13(2026-07-14 컨텍스트 재튜닝) |
| **G** | **gpt-oss-120b**(MXFP4) 단독, FIM 없음 | 컨텍스트 최대(65536), VRAM 여유 최대(~6.05GB), FIM 사용 불가 | ✅ **운영자 선택 가능**(신설 2026-07-14) |

> ★[2026-07-13 운영 정책 확정, 2026-07-14 G 추가] **A/D/E/G 네 구성 모두 정식 운영 옵션이며, 운영자가
> 상황에 따라 자유롭게 선택·전환할 수 있다.** 초기 기동 시 기본값은 **E**이지만, "고정 채택"이 아니라
> "기본 시작점"이다. 서브 채팅 모델(Gemma 트랙, B/C 계열)은 앞으로도 사용하지 않는다(2026-07-07 결정,
> 유지) — 이건 네 옵션과 무관하게 확정된 정책이다. 전환 방법: `scripts/switch_model_option.sh {a|d|e|g}`
> (§전환 가이드 참조).

**운영자 선택 가이드 — 언제 어떤 구성을 쓸까:**

| 상황 | 권장 구성 | 이유 |
|------|-----------|------|
| 기본/평상시 | **E** | 채팅·에이전트(도구 호출) 품질·속도가 가장 좋고 FIM도 함께 제공 |
| IDE 자동완성(FIM) 품질 불만 다수 접수 | **D** | FIM이 StarCoder2-15B라 7B(A/E)보다 EOS 안정성이 높음(정답 뒤 garbage 생성 적음) |
| gpt-oss 관련 이슈(예: SM120 커널 버그 악화, 응답이 자주 잘림) 발생 시 임시 회피 | **D** 또는 **A** | 검증된 Llama 계열로 즉시 복귀, 안정성 우선 |
| 긴 대화·큰 문서 작업이 잦고 FIM은 필요 없음, VRAM 여유를 최대한 확보하고 싶을 때 | **G** | 여섯 선택지 중 컨텍스트(65536)·여유(~6.05GB) 모두 가장 큼, 단 FIM 완전 불가 |
| 순수 안정성 최우선(신규 변수 최소화), FIM 품질 크게 안 중요 | **A** | 가장 오래 검증된 조합(단, VRAM 여유 ~1.4GB로 재기동 시 실패 리스크가 가장 높음 — 권장도는 낮음) |

> 전환은 main(+autocomplete, A/D/E만) 재기동을 수반해 **수 분간 서비스 중단**이 생긴다(A/D/E는 순차
> 기동 필요, G는 main만 단독 기동, §전환 가이드). 사용량이 적은 시간대에 진행하고, 전환 전후로
> `scripts/switch_model_option.sh status`로 상태를 확인할 것.

**FP4 Go/No-Go 결론 → Go ✅ (2026-07-08 운영 채택으로 확정)**
- 검증장비(5090, SM120)에서 **NVFP4(W4A4) 기동·추론 성공**. vLLM 0.17.1 이 `FLASHINFER_CUTLASS` FP4 GEMM 경로 사용,
  garbage 없음, VRAM 절반, throughput 양호(8B 163 tok/s).
- **PoC 품질 비교 결과(상세: `docs/POC_FP4_QUANT_COMPARISON.md`):**
  - 까다로운 추론에선 **모델 크기 ≫ 양자화** — 24B-NVFP4 가 8B-FP8 을 함정/논리/한국어 추론에서 압도 → **70B-NVFP4 전략 지지**.
  - **FP4 degeneration(반복 붕괴) 리스크는 작은 모델 한정** — 8B-NVFP4 는 긴 한국어 추론에서 붕괴, 24B-NVFP4 는 안정.
    ⇒ **대형 메인은 NVFP4 안전 / 소형(자동완성·서브)은 FP8 권장**.
- **운영 적용 전 확인 과제 → 해소됨:** ① 70B NVFP4 체크포인트 출처 확정(`RedHatAI/Llama-3.3-70B-Instruct-NVFP4`,
  ungated, LICENSE는 미양자화 원본 리포에서 확보) — 27B NVFP4는 서브 미채택으로 불필요해짐. ② `70B-FP8 vs
  70B-NVFP4` 정식 정량 비교는 미수행이나, 선택지 D 실사용 검증(완료보고서 §13)에서 garbage 없는 정상 응답을
  확인해 운영 투입 가능 수준으로 판단, 실제 채택함. 필요 시 사후 정밀 품질 비교는 여전히 유효한 과제.

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
- [x] **모델 교체** — 검증 모델(8B/7B) → 운영 모델(70B FP8/FIM 7B)로 `.env` `MAIN_MODEL_PATH`·`docker-compose` `phase-prod` 프로파일 갱신, 사전 스테이징+게이트 완료(2026-07-07). ★서브(27B/9B)는 운영 미채택이라 교체 대상에서 제외.
- [x] **선택지 D 전환(NVFP4 main + FIM 15B)** — `.env` `MAIN_MODEL_PATH`→NVFP4, `AUTOCOMPLETE_MODEL_PATH`→15B, `MAIN_GPU_UTIL=0.72`/`AUTOCOMPLETE_GPU_UTIL=0.20`로 재산정, 순차 기동으로 healthy 확인, E2E 완료(2026-07-08, §10 선택지 D).
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
