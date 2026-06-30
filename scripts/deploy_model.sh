#!/usr/bin/env bash
# scripts/deploy_model.sh — Blue/Green 무중단 배포 + 롤백 (FR-10 ④)
#
# 스테이징 게이트(scripts/stage_model.sh gate) 통과 후, 새 가중치를 "green" vLLM 인스턴스로 띄워
# 헬스/스모크로 검증한 뒤 LiteLLM 라우팅을 green 으로 전환한다. 실패 시 blue 유지(무중단 롤백).
#
# 동작 원리(게이트웨이 레벨 Blue/Green):
#   - green vLLM 컨테이너(vllm-green)를 compose 네트워크에 기동 → LiteLLM Admin API(/model/new)로
#     동일 model_name 의 추가 deployment 로 등록 = 카나리(blue·green 동시 서빙, 트래픽 분산).
#   - 검증 후 blue deployment 를 /model/delete 로 제거 = 컷오버. 문제 시 green 제거 = 롤백.
#   - LiteLLM 은 STORE_MODEL_IN_DB=True 라 런타임 등록/삭제가 영속화된다(재기동에도 유지).
#
# ⚠ 단일 32GB GPU 제약(NFR-3/4):
#   - 소형 프록시(Llama 8B / Gemma 9B)는 blue+green 동시 상주 가능 → 진짜 카나리(--mode canary, 기본).
#   - 대형(Gemma 27B 등)은 VRAM 부족으로 동시 상주 불가 → --mode sequential:
#     blue 중지 후 green 기동(짧은 다운타임). 운영 RTX PRO 6000(96GB)에선 27B도 카나리 가능(이전성 메모).
#
# 사용:
#   ./deploy_model.sh deploy   <model_name> <new_model_dir> [--mode canary|sequential] [--auto-promote]
#   ./deploy_model.sh promote  <model_name>      # 카나리 검증 후 blue 제거(컷오버 확정)
#   ./deploy_model.sh rollback <model_name>      # green 제거 + vllm-green 정리(blue 복귀)
#   ./deploy_model.sh status   <model_name>      # 현재 deployment/컨테이너 상태
#
# 전제: 스택 기동 중(litellm:4000 정상), 새 가중치는 MODELS_DIR 아래 사전 스테이징+게이트 통과.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GREEN_NAME="vllm-green"
GREEN_HOST_PORT="${GREEN_HOST_PORT:-8010}"     # 디버그용 직접 노출(컨테이너 내부는 8000)
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-600}"        # green 헬스 대기(초). 모델 로드 고려.
CANARY_UTIL="${CANARY_UTIL:-0.40}"             # green VRAM 분할(blue 와 합산 ≤ ~0.9)

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }

# ── .env 로드(이미지/마스터키/경로) ────────────────────────────────────────
[[ -f "$ROOT/.env" ]] && set -a && . "$ROOT/.env" && set +a || warn ".env 없음 — 환경변수로 대체."
VLLM_IMAGE="${VLLM_IMAGE:?VLLM_IMAGE 필요(.env)}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY 필요(.env)}"
MODELS_DIR="${MODELS_DIR:-./models}"
MODELS_ABS="$(cd "$ROOT" && cd "$(dirname "$MODELS_DIR/.")" && pwd)"
LITELLM_BASE="${LITELLM_BASE:-http://localhost:4000}"
GEMMA_ATTN_BACKEND="${GEMMA_ATTN_BACKEND:-FLASHINFER}"

# compose 네트워크 자동 탐지(프로젝트 접두사 무관, 이름에 ai-net 포함)
NET="$(docker network ls --format '{{.Name}}' | grep -m1 'ai-net' || true)"
: "${NET:?ai-net 네트워크를 찾지 못함 — 스택이 기동되어 있어야 합니다(docker compose up).}"

# LiteLLM Admin API 호출
api() { # api <METHOD> <PATH> [json]
  curl -sS -X "$1" "$LITELLM_BASE$2" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
    ${3:+-d "$3"}
}

# model_name 의 deployment 목록에서 특정 api_base 를 가진 model_id 추출
model_id_by_base() { # model_id_by_base <model_name> <api_base_substr>
  api GET /model/info "" | python3 - "$1" "$2" <<'PY'
import sys, json
name, sub = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin).get("data", [])
for m in data:
    if m.get("model_name") != name:
        continue
    base = (m.get("litellm_params") or {}).get("api_base") or ""
    if sub in base:
        print(m.get("model_info", {}).get("id") or m.get("model_info", {}).get("model_id") or "")
        break
PY
}

# Gemma 모델이면 attention 백엔드 환경변수, 아니면 Llama FA2
attn_env_args() { # <model_dir>
  if [[ "$1" == *gemma* ]]; then echo "-e VLLM_ATTENTION_BACKEND=$GEMMA_ATTN_BACKEND";
  else echo "-e VLLM_FLASH_ATTN_VERSION=2"; fi
}

# ── green vLLM 컨테이너 기동 + 헬스 게이트 ─────────────────────────────────
start_green() { # <model_name> <new_model_dir_basename>
  local model_name="$1" mdir="$2"
  [[ -d "$MODELS_ABS/$mdir" ]] || { err "새 가중치 없음: $MODELS_ABS/$mdir (게이트 먼저: stage_model.sh gate)"; exit 1; }

  docker rm -f "$GREEN_NAME" >/dev/null 2>&1 || true
  log "green 인스턴스 기동: $GREEN_NAME ← /models/$mdir (util=$CANARY_UTIL)"
  # shellcheck disable=SC2046
  docker run -d --name "$GREEN_NAME" --network "$NET" \
    --gpus '"device=0"' --ipc host --ulimit memlock=-1 --ulimit stack=67108864 \
    -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e CUDA_VISIBLE_DEVICES=0 \
    $(attn_env_args "$mdir") \
    -v "$MODELS_ABS:/models:ro" \
    -p "$GREEN_HOST_PORT:8000" \
    "$VLLM_IMAGE" \
    --model "/models/$mdir" --served-model-name "${model_name}-green" \
    --port 8000 --gpu-memory-utilization "$CANARY_UTIL" >/dev/null

  log "green 헬스 대기(최대 ${HEALTH_TIMEOUT}s)"
  local waited=0
  until curl -sf "http://localhost:$GREEN_HOST_PORT/health" >/dev/null 2>&1; do
    if ! docker ps -q -f "name=^${GREEN_NAME}$" | grep -q .; then
      err "green 컨테이너가 비정상 종료. 로그:"; docker logs --tail 40 "$GREEN_NAME" || true
      docker rm -f "$GREEN_NAME" >/dev/null 2>&1 || true; exit 2
    fi
    (( waited += 5 )); [[ $waited -ge $HEALTH_TIMEOUT ]] && { err "green 헬스 타임아웃."; docker logs --tail 40 "$GREEN_NAME"; docker rm -f "$GREEN_NAME"; exit 2; }
    sleep 5
  done
  ok "green /health 200"

  log "green 스모크 추론(garbage 출력 없는지 직접 확인)"
  local resp
  resp="$(curl -sS "http://localhost:$GREEN_HOST_PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model_name}-green\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: OK\"}],\"max_tokens\":8}")"
  echo "$resp" | python3 -c 'import sys,json; c=json.load(sys.stdin)["choices"][0]["message"]["content"]; print("  green 응답:",repr(c)); sys.exit(0 if c.strip() else 1)' \
    || { err "green 스모크 실패(빈/오류 응답). 롤백."; docker rm -f "$GREEN_NAME" >/dev/null 2>&1 || true; exit 3; }
  ok "green 스모크 통과"
}

# ── LiteLLM 에 green deployment 등록(카나리 시작) ──────────────────────────
register_green() { # <model_name>
  local model_name="$1"
  log "LiteLLM 에 green deployment 등록(카나리): $model_name → http://$GREEN_NAME:8000/v1"
  api POST /model/new "{\"model_name\":\"$model_name\",\"litellm_params\":{\"model\":\"openai/${model_name}-green\",\"api_base\":\"http://$GREEN_NAME:8000/v1\",\"api_key\":\"dummy\"},\"model_info\":{\"mode\":\"chat\"}}" >/dev/null
  ok "카나리 활성: '$model_name' 트래픽이 blue·green 으로 분산됨"
}

# ── 컷오버: blue deployment 제거 ───────────────────────────────────────────
promote() { # <model_name>
  local model_name="$1"
  log "컷오버: blue deployment 제거 → green 단독 서빙"
  local blue_id
  blue_id="$(model_id_by_base "$model_name" "vllm-main:8000")"
  [[ -z "$blue_id" ]] && blue_id="$(model_id_by_base "$model_name" "vllm-sub:8000")"
  [[ -z "$blue_id" ]] && blue_id="$(model_id_by_base "$model_name" "vllm-gemma27b:8000")"
  if [[ -z "$blue_id" ]]; then warn "blue deployment 를 찾지 못함(이미 컷오버됐을 수 있음)."; else
    api POST /model/delete "{\"id\":\"$blue_id\"}" >/dev/null
    ok "blue deployment 제거(id=$blue_id). 컷오버 완료 — green 단독 서빙."
  fi
  warn "blue 컨테이너(vllm-main 등) VRAM 회수하려면 해당 compose 서비스를 중지하세요."
}

# ── 롤백: green 제거 ───────────────────────────────────────────────────────
rollback() { # <model_name>
  local model_name="$1"
  log "롤백: green deployment + 컨테이너 제거(blue 복귀)"
  local green_id
  green_id="$(model_id_by_base "$model_name" "$GREEN_NAME:8000")"
  [[ -n "$green_id" ]] && api POST /model/delete "{\"id\":\"$green_id\"}" >/dev/null && ok "green deployment 제거(id=$green_id)"
  docker rm -f "$GREEN_NAME" >/dev/null 2>&1 && ok "vllm-green 컨테이너 제거" || warn "vllm-green 컨테이너 없음"
  ok "롤백 완료 — blue 단독 서빙 복귀."
}

status() { # <model_name>
  log "deployment 상태: $1"
  api GET /model/info "" | python3 - "$1" <<'PY'
import sys, json
name = sys.argv[1]
for m in json.load(sys.stdin).get("data", []):
    if m.get("model_name") == name:
        lp = m.get("litellm_params") or {}
        print(f"  - id={m.get('model_info',{}).get('id','?')}  base={lp.get('api_base')}")
PY
  echo "  green 컨테이너:"; docker ps -f "name=^${GREEN_NAME}$" --format '    {{.Names}}  {{.Status}}' || true
}

# ── deploy: 전체 흐름 ──────────────────────────────────────────────────────
deploy() {
  local model_name="$1" mdir="$2"; shift 2 || true
  local mode="canary" auto=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --mode) mode="$2"; shift 2;;
    --auto-promote) auto=1; shift;;
    *) err "알 수 없는 옵션: $1"; exit 2;;
  esac; done
  mdir="$(basename "$mdir")"

  if [[ "$mode" == "sequential" ]]; then
    warn "sequential 모드: VRAM 부족 대형 모델용. blue 중지 후 green 기동(짧은 다운타임 발생)."
    warn "→ blue 컨테이너를 먼저 중지하세요(예: docker compose stop vllm-gemma27b). 계속하려면 5초…"; sleep 5
  fi

  start_green "$model_name" "$mdir"
  register_green "$model_name"

  if [[ "$auto" == "1" ]]; then
    promote "$model_name"
  else
    echo
    ok "카나리 배포 완료(blue·green 병행). 트래픽/Audit 로 green 정상 확인 후:"
    echo "    컷오버:  $0 promote  $model_name"
    echo "    롤백:    $0 rollback $model_name"
  fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  deploy)   deploy "${1:?model_name}" "${2:?new_model_dir}" "${@:3}" ;;
  promote)  promote "${1:?model_name}" ;;
  rollback) rollback "${1:?model_name}" ;;
  status)   status "${1:?model_name}" ;;
  *) cat >&2 <<EOF
사용: $0 <명령>
  deploy   <model_name> <new_model_dir> [--mode canary|sequential] [--auto-promote]
  promote  <model_name>     카나리 검증 후 blue 제거(컷오버)
  rollback <model_name>     green 제거(blue 복귀)
  status   <model_name>     deployment/컨테이너 상태
EOF
     exit 2 ;;
esac
