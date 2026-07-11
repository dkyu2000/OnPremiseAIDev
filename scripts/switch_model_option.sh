#!/usr/bin/env bash
# scripts/switch_model_option.sh — 운영 모델 구성(선택지 A/D/...) 안전 전환
#
# env-profiles/option-*.env 에 정의된 구성으로 .env를 갱신하고, main→autocomplete
# 순차 기동으로 vllm-main/vllm-autocomplete를 재기동한다(동시 기동 시 서로 메모리
# 프로파일링이 간섭해 둘 다 실패하는 문제가 실측 확인됨 — 완료보고서 §13.3 참조).
#
# 사용:
#   ./switch_model_option.sh list              사용 가능한 구성 목록
#   ./switch_model_option.sh status             현재 .env에 적용된 구성 + 컨테이너 상태
#   ./switch_model_option.sh <옵션명>            전환 (예: a, d)
#
# 새 구성 추가: env-profiles/option-<이름>.env 파일만 추가하면 된다(본 스크립트 수정 불필요).
#   필수 키: LABEL, MAIN_MODEL_PATH, MAIN_GPU_UTIL, MAIN_MAX_LEN,
#            AUTOCOMPLETE_MODEL_PATH, AUTOCOMPLETE_GPU_UTIL, AUTOCOMPLETE_MAX_LEN
#   상세 형식: env-profiles/README.md 참조.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
PROFILE_DIR="$ROOT/env-profiles"
REQUIRED_KEYS=(MAIN_MODEL_PATH MAIN_GPU_UTIL MAIN_MAX_LEN AUTOCOMPLETE_MODEL_PATH AUTOCOMPLETE_GPU_UTIL AUTOCOMPLETE_MAX_LEN)

log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }

DC() { cd "$ROOT" && docker compose "$@"; }

# ── 프로파일 파일에서 KEY=VALUE 만 안전하게 파싱(임의 코드 실행 방지, source 미사용) ──
# 결과를 연관배열에 채운다: PROFILE[KEY]=VALUE
declare -A PROFILE
load_profile() {
  local file="$1"
  PROFILE=()
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val%\"}"; val="${val#\"}"   # 양끝 큰따옴표 제거(LABEL="..." 대응)
      PROFILE["$key"]="$val"
    fi
  done < "$file"
}

list_profiles() {
  log "사용 가능한 구성"
  local found=0
  for f in "$PROFILE_DIR"/option-*.env; do
    [[ -e "$f" ]] || continue
    found=1
    local name; name="$(basename "$f" .env)"; name="${name#option-}"
    load_profile "$f"
    printf "  %-8s %s\n" "$name" "${PROFILE[LABEL]:-(LABEL 없음)}"
  done
  [[ "$found" == "1" ]] || warn "env-profiles/option-*.env 파일이 없습니다."
}

current_status() {
  log "현재 .env 모델 구성"
  grep -E "^(MAIN_MODEL_PATH|MAIN_GPU_UTIL|MAIN_MAX_LEN|AUTOCOMPLETE_MODEL_PATH|AUTOCOMPLETE_GPU_UTIL|AUTOCOMPLETE_MAX_LEN)=" "$ENV_FILE" | sed 's/^/  /'
  log "컨테이너 상태"
  DC ps --format "table {{.Name}}\t{{.Status}}" 2>&1 | grep -E "vllm|NAME" || true
  log "GPU"
  nvidia-smi --query-gpu=memory.used,memory.total,memory.free --format=csv,noheader | sed 's/^/  /'
}

# ── .env 안의 지정 키만 in-place 치환(그 외 값/시크릿은 절대 건드리지 않음) ──
patch_env_key() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

# ── 서비스 healthy 대기(크래시 시 로그 찍고 즉시 중단) ──
wait_healthy() {
  local svc="$1" max_tries="${2:-40}"
  for i in $(seq 1 "$max_tries"); do
    sleep 15
    local status restarts
    status="$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo '?')"
    restarts="$(docker inspect --format='{{.RestartCount}}' "$svc" 2>/dev/null || echo '?')"
    echo "  [$i] $svc status=$status restarts=$restarts"
    if [[ "$status" == "healthy" ]]; then return 0; fi
    if [[ "$restarts" != "0" && "$restarts" != "?" ]]; then
      err "$svc 기동 실패(재시작 발생) — 최근 로그:"
      DC logs --tail=40 "$svc" 2>&1 | grep -iE "ValueError|Available KV cache|error" | tail -20
      return 1
    fi
  done
  err "$svc 헬스체크 타임아웃"
  return 1
}

# ── 클라이언트 설정(opencode.json, ~/.continue/config.yaml)의 표시 라벨을 갱신 ──
# 서빙명(main-llama/autocomplete-starcoder2)은 안 바뀌므로 기능상 필수는 아니지만,
# 라벨이 실제 로드된 모델과 달라 혼동을 주는 것을 방지한다(실측: 사용자가 "모델이 안
# 보인다"고 오인한 사례 — 실제로는 라벨만 구 버전이었음).
update_client_labels() {
  local main_label="${PROFILE[MAIN_CLIENT_LABEL]:-}"
  local ac_label="${PROFILE[AUTOCOMPLETE_CLIENT_LABEL]:-}"

  if [[ -n "$main_label" && -f "$ROOT/opencode.json" ]] && command -v jq >/dev/null 2>&1; then
    log "opencode.json 라벨 갱신"
    local tmp; tmp="$(mktemp)"
    jq --arg n "$main_label" '.provider["litellm-onprem"].models["main-llama"].name = $n' \
      "$ROOT/opencode.json" > "$tmp" && mv "$tmp" "$ROOT/opencode.json"
    ok "opencode.json: main-llama → \"$main_label\""
  fi

  local continue_cfg="$HOME/.continue/config.yaml"
  if [[ -f "$continue_cfg" ]] && command -v python3 >/dev/null 2>&1; then
    log "~/.continue/config.yaml 라벨 갱신(best-effort)"
    # 각 "- name: ..." 블록 안에서 "model: <서빙명>" 이 나오면, 그 블록의 name 을 교체.
    # 블록 사이 줄 수에 의존하지 않고 "가장 최근에 본 name 줄"을 기억하는 방식이라 안전함.
    python3 - "$continue_cfg" "$main_label" "$ac_label" <<'PYEOF'
import re, sys
path, main_label, ac_label = sys.argv[1], sys.argv[2], sys.argv[3]
targets = {"main-llama": main_label, "autocomplete-starcoder2": ac_label}
with open(path) as f:
    lines = f.readlines()
last_name_idx = None
changed = []
for i, line in enumerate(lines):
    m = re.match(r'^(\s*-\s*name:\s*).*$', line)
    if m:
        last_name_idx = (i, m.group(1))
        continue
    m2 = re.match(r'^\s*model:\s*(\S+)\s*$', line)
    if m2 and m2.group(1) in targets and targets[m2.group(1)] and last_name_idx is not None:
        idx, prefix = last_name_idx
        # ★반드시 큰따옴표로 감쌀 것: 라벨에 ": "(콜론+공백)이 들어가면 따옴표 없는 YAML
        #   스칼라가 매핑으로 잘못 해석돼 config.yaml 전체 파싱이 깨진다(실측 확인된 버그).
        safe_val = targets[m2.group(1)].replace('"', '\\"')
        lines[idx] = f'{prefix}"{safe_val}"\n'
        changed.append(m2.group(1))
        last_name_idx = None
with open(path, 'w') as f:
    f.writelines(lines)
print("갱신됨:", changed if changed else "(대상 없음)")
PYEOF
    ok "~/.continue/config.yaml 라벨 갱신 시도 완료(형식이 예상과 다르면 수동 확인 필요)"
  fi

  # ★Continue는 "현재 선택된 모델"을 이름(문자열)으로 캐싱한다(~/.continue/index/globalContext.json).
  #   config.yaml의 라벨만 바꾸고 이 캐시를 안 맞춰주면, 캐시가 가리키는 이름이 더 이상 models 목록에
  #   없어 UI 드롭다운이 통째로 비어 보이는 문제가 실측 확인됨. 항상 함께 갱신한다.
  local continue_ctx="$HOME/.continue/index/globalContext.json"
  if [[ -f "$continue_ctx" ]] && command -v python3 >/dev/null 2>&1; then
    log "~/.continue/index/globalContext.json 선택 캐시 갱신(best-effort)"
    python3 - "$continue_ctx" "$main_label" "$ac_label" <<'PYEOF'
import json, sys
path, main_label, ac_label = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        d = json.load(f)
    sel = d.get("selectedModelsByProfileId", {}).get("local")
    if sel is not None:
        if main_label:
            for k in ("chat", "edit", "apply"):
                if k in sel and sel[k] is not None:
                    sel[k] = main_label
        if ac_label and "autocomplete" in sel and sel["autocomplete"] is not None:
            sel["autocomplete"] = ac_label
        with open(path, "w") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
        print("갱신됨")
    else:
        print("selectedModelsByProfileId.local 없음 — 스킵")
except Exception as e:
    print(f"스킵(형식 다름): {e}")
PYEOF
  fi
}

switch_to() {
  local opt="$1"
  local file="$PROFILE_DIR/option-${opt}.env"
  [[ -f "$file" ]] || { err "프로파일 없음: $file"; list_profiles; exit 2; }

  load_profile "$file"
  for k in "${REQUIRED_KEYS[@]}"; do
    [[ -n "${PROFILE[$k]:-}" ]] || { err "프로파일 $file 에 $k 누락"; exit 2; }
  done

  log "전환 대상: ${PROFILE[LABEL]:-$opt}"

  # 모델 디렉터리 실존 확인(사전 스테이징 여부) — 서비스 중단 전에 미리 검증
  local models_dir; models_dir="$(grep -E '^MODELS_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2- || echo ./models)"
  for pathkey in MAIN_MODEL_PATH AUTOCOMPLETE_MODEL_PATH; do
    local rel="${PROFILE[$pathkey]#/models/}"
    local dir="$ROOT/${models_dir#./}/$rel"
    if [[ ! -d "$dir" ]]; then
      err "$pathkey 가 가리키는 모델 디렉터리가 없습니다: $dir"
      err "→ 먼저 scripts/stage_model.sh 로 스테이징하세요. 전환 중단(서비스는 그대로 유지됨)."
      exit 3
    fi
  done
  ok "모델 디렉터리 존재 확인"

  log ".env 갱신 (시크릿·이미지태그 등 다른 값은 그대로 유지)"
  for k in "${REQUIRED_KEYS[@]}"; do
    patch_env_key "$k" "${PROFILE[$k]}"
    echo "  $k=${PROFILE[$k]}"
  done

  log "기존 vLLM 서비스 중지"
  DC stop vllm-main vllm-autocomplete 2>&1

  log "main 기동(단독) — 순차 기동 1/2"
  DC up -d vllm-main
  wait_healthy vllm-main || { err "main 기동 실패. autocomplete는 올리지 않고 중단."; exit 1; }
  ok "main healthy"

  log "autocomplete 기동 — 순차 기동 2/2"
  DC up -d vllm-autocomplete
  wait_healthy vllm-autocomplete || { err "autocomplete 기동 실패."; exit 1; }
  ok "autocomplete healthy"

  update_client_labels

  ok "전환 완료: ${PROFILE[LABEL]:-$opt}"
  nvidia-smi --query-gpu=memory.used,memory.total,memory.free --format=csv,noheader | sed 's/^/  GPU: /'
  echo "  E2E 확인: curl http://localhost:4000/v1/chat/completions -H \"Authorization: Bearer <키>\" ..."
}

cmd="${1:-}"
case "$cmd" in
  list)   list_profiles ;;
  status) current_status ;;
  ""|-h|--help)
    cat >&2 <<EOF
사용: $0 {list | status | <옵션명>}
  list          사용 가능한 구성 목록(env-profiles/option-*.env)
  status        현재 .env 구성 + 컨테이너/GPU 상태
  <옵션명>       해당 구성으로 전환 (예: a, d)
EOF
    exit 2 ;;
  *) switch_to "$cmd" ;;
esac
