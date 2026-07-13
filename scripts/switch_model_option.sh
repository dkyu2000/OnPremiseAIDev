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
LITELLM_CONFIG="$ROOT/litellm/config.yaml"
REQUIRED_KEYS=(MAIN_MODEL_PATH MAIN_GPU_UTIL MAIN_MAX_LEN AUTOCOMPLETE_MODEL_PATH AUTOCOMPLETE_GPU_UTIL AUTOCOMPLETE_MAX_LEN)
# 선택 키: 프로파일에 없으면 Llama 계열 기본값으로 리셋(전환 후 .env에 이전 구성 값이 안 남도록).
# main이 Llama가 아닌 아키텍처(예: gpt-oss)로 바뀔 때만 프로파일에 명시한다.
declare -A OPTIONAL_DEFAULTS=(
  [MAIN_SERVED_NAME]=main-llama
  [MAIN_TOOL_PARSER]=llama3_json
  [MAIN_EXTRA_ARGS]=""
  [MAIN_MXFP4_FLASHINFER]=0
)

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
    if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
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

# ── LiteLLM 메인 라우트(model_name/litellm_params.model)를 새 served-name으로 동기화 ──
# main이 다른 아키텍처로 바뀌어 served-name 자체가 바뀔 때만 실제로 값이 달라진다(같은 계열
# 내 스왑이면 old==new라 무변경). 파일을 바꾼 뒤 litellm 컨테이너를 재기동해야 반영된다
# (config.yaml은 :ro 마운트이며 LiteLLM이 기동 시 1회만 읽음 — 핫리로드 안 됨).
sync_litellm_main_route() {
  local old_name="$1" new_name="$2"
  [[ "$old_name" == "$new_name" ]] && { ok "LiteLLM 메인 라우트명 변경 없음($new_name 유지)"; return 0; }
  [[ -f "$LITELLM_CONFIG" ]] || { warn "litellm/config.yaml 없음 — 스킵"; return 0; }

  log "litellm/config.yaml 메인 라우트 갱신: $old_name → $new_name"
  # "- model_name: <old>" 블록 안의 model_name과 litellm_params.model(openai/<old>)만 치환.
  # 다른 라우트(autocomplete-*)는 건드리지 않도록 정확한 토큰 경계로 매칭.
  sed -i \
    -e "s|^\(\s*-\s*model_name:\s*\)${old_name}\s*$|\1${new_name}|" \
    -e "s|^\(\s*model:\s*openai/\)${old_name}\s*$|\1${new_name}|" \
    "$LITELLM_CONFIG"

  if grep -q "model_name: ${new_name}" "$LITELLM_CONFIG" && grep -q "model: openai/${new_name}" "$LITELLM_CONFIG"; then
    ok "litellm/config.yaml 갱신 확인됨"
  else
    err "litellm/config.yaml에서 $new_name 을 찾지 못함 — 수동 확인 필요(파일 형식이 예상과 다를 수 있음)"
    return 1
  fi

  log "LiteLLM 재기동(설정 반영, :ro 마운트라 핫리로드 안 됨)"
  DC up -d --force-recreate litellm
  for i in $(seq 1 20); do
    sleep 5
    local status; status="$(docker inspect --format='{{.State.Health.Status}}' litellm 2>/dev/null || echo '?')"
    echo "  [$i] litellm status=$status"
    [[ "$status" == "healthy" ]] && { ok "litellm healthy"; return 0; }
  done
  err "litellm 헬스체크 타임아웃 — docker logs litellm 로 확인하세요"
  return 1
}

# ── 발급된 모든 가상 키의 allowlist(키별 저장된 모델 목록)를 새 served-name으로 동기화 ──
# LiteLLM은 각 키에 허용 모델 목록을 별도로 저장한다 — served-name이 바뀌어도 키의 allowlist는
# 자동으로 안 바뀌어서, 기존에 발급된 모든 키가 "key not allowed to access model"로 막히는 문제가
# 실측 확인됨(완료보고서 §17). /key/list가 주는 해시 토큰만으로 /key/info·/key/update가 되므로
# 평문 키 없이도 전부 자동 처리 가능.
sync_key_allowlists() {
  local old_name="$1" new_name="$2"
  [[ "$old_name" == "$new_name" ]] && return 0
  local master_key
  master_key="$(grep -E '^LITELLM_MASTER_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  [[ -n "$master_key" ]] || { warn "LITELLM_MASTER_KEY 없음 — 키 allowlist 갱신 스킵"; return 0; }

  log "발급된 가상 키 allowlist 동기화: $old_name → $new_name"
  local tokens
  tokens="$(curl -s "http://localhost:4000/key/list" -H "Authorization: Bearer $master_key" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d.get('keys') or []))" 2>/dev/null || true)"
  if [[ -z "$tokens" ]]; then
    warn "발급된 키 없음 — 스킵"
    return 0
  fi

  local updated=0 skipped=0 failed=0
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    local info has_old
    info="$(curl -s "http://localhost:4000/key/info?key=$token" -H "Authorization: Bearer $master_key" 2>/dev/null || true)"
    has_old="$(python3 -c "
import json,sys
try:
    d=json.loads('''$info''')
    info=d.get('info', d)
    print('1' if '$old_name' in (info.get('models') or []) else '0')
except Exception:
    print('0')
" 2>/dev/null || echo 0)"
    if [[ "$has_old" == "1" ]]; then
      if curl -sf -X POST "http://localhost:4000/key/update" -H "Authorization: Bearer $master_key" \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"${token}\",\"models\":[\"${new_name}\",\"autocomplete-starcoder2\"]}" >/dev/null 2>&1; then
        updated=$((updated+1))
      else
        failed=$((failed+1))
      fi
    else
      skipped=$((skipped+1))
    fi
  done <<< "$tokens"

  if [[ "$failed" -gt 0 ]]; then
    err "키 allowlist 갱신 실패 ${failed}건 발생 — 수동 확인 필요(갱신 ${updated}건, 해당없음 ${skipped}건)"
  else
    ok "키 allowlist 동기화 완료: 갱신 ${updated}건, 해당없음(이미 최신/다른 모델) ${skipped}건"
  fi

  if [[ "$updated" -gt 0 ]]; then
    # ★LiteLLM이 키 정보를 인메모리 캐시하므로, DB 갱신만으론 실제 요청에 즉시 반영 안 됨
    #   (실측: /key/update 직후에도 구 allowlist로 거부됨). 재기동으로 캐시를 확실히 비운다.
    log "LiteLLM 재기동(키 캐시 무효화)"
    DC restart litellm
    for i in $(seq 1 15); do
      sleep 5
      local status; status="$(docker inspect --format='{{.State.Health.Status}}' litellm 2>/dev/null || echo '?')"
      echo "  [$i] litellm status=$status"
      [[ "$status" == "healthy" ]] && { ok "litellm healthy"; return 0; }
    done
    warn "litellm 재기동 헬스체크 타임아웃 — 수동 확인 필요"
  fi
}

# ── 클라이언트 설정(opencode.json, ~/.continue/config.yaml)의 모델 키 + 표시 라벨을 갱신 ──
# served-name이 바뀌면(예: main-llama→main-gptoss) 클라이언트가 요청하는 model 필드 자체를
# 새 이름으로 바꿔야 실제로 연결된다(라벨만 바꾸면 예쁘게 보일 뿐 요청은 여전히 구 이름으로
# 나가 404가 남 — 실측 확인). 같은 계열 내 스왑(old==new)이면 키는 그대로 두고 라벨만 갱신.
update_client_config() {
  local old_main="$1" new_main="$2"
  local main_label="${PROFILE[MAIN_CLIENT_LABEL]:-}"
  local ac_label="${PROFILE[AUTOCOMPLETE_CLIENT_LABEL]:-}"

  if [[ -f "$ROOT/opencode.json" ]] && command -v jq >/dev/null 2>&1; then
    log "opencode.json 갱신"
    local tmp; tmp="$(mktemp)"
    jq --arg old "$old_main" --arg new "$new_main" --arg label "$main_label" '
      .model = (.model | sub("/" + $old + "$"; "/" + $new)) |
      .provider["litellm-onprem"].models[$new] = (
        (.provider["litellm-onprem"].models[$old] // {}) + (if $label != "" then {name: $label} else {} end)
      ) |
      if $old != $new then .provider["litellm-onprem"].models |= del(.[$old]) else . end
    ' "$ROOT/opencode.json" > "$tmp" && mv "$tmp" "$ROOT/opencode.json"
    ok "opencode.json: $old_main → $new_main${main_label:+ (\"$main_label\")}"
  fi

  local continue_cfg="$HOME/.continue/config.yaml"
  if [[ -f "$continue_cfg" ]] && command -v python3 >/dev/null 2>&1; then
    log "~/.continue/config.yaml 갱신(best-effort)"
    # 각 "- name: ..." 블록 안에서 "model: <old_served_name>" 을 찾아 model 값과 name(라벨)을 함께 교체.
    # 블록 사이 줄 수에 의존하지 않고 "가장 최근에 본 name 줄"을 기억하는 방식이라 안전함.
    python3 - "$continue_cfg" "$old_main" "$new_main" "$main_label" "autocomplete-starcoder2" "autocomplete-starcoder2" "$ac_label" <<'PYEOF'
import re, sys
path, old_main, new_main, main_label, old_ac, new_ac, ac_label = sys.argv[1:8]
targets = {old_main: (new_main, main_label), old_ac: (new_ac, ac_label)}
with open(path) as f:
    lines = f.readlines()

# ★최상위 기본 모델 지정("model: litellm-onprem/<served-name>", "- name:" 블록 밖의 zero-indent
#   라인)도 함께 바꿔야 함 — 블록 컨텍스트 안 라인만 처리하면 이 줄이 누락돼 Continue가 여전히
#   구 모델을 기본으로 가리키는 버그가 실측 확인됨.
changed_top = []
for i, line in enumerate(lines):
    m0 = re.match(r'^model:\s*(\S+)\s*$', line)
    if m0:
        prefix_provider, _, cur_served = m0.group(1).rpartition('/')
        if cur_served == old_main and new_main:
            lines[i] = f'model: {prefix_provider}/{new_main}\n' if prefix_provider else f'model: {new_main}\n'
            changed_top.append(old_main)
        break  # 최상위 model: 은 파일에 1개뿐(모델 목록 블록 진입 전)

last_name_idx = None
changed = list(changed_top)
for i, line in enumerate(lines):
    m = re.match(r'^(\s*-\s*name:\s*).*$', line)
    if m:
        last_name_idx = (i, m.group(1))
        continue
    m2 = re.match(r'^(\s*model:\s*)(\S+)\s*$', line)
    if m2 and m2.group(2) in targets and last_name_idx is not None:
        new_model, label = targets[m2.group(2)]
        if new_model:
            lines[i] = f'{m2.group(1)}{new_model}\n'
        if label:
            idx, prefix = last_name_idx
            # ★반드시 큰따옴표로 감쌀 것: 라벨에 ": "(콜론+공백)이 들어가면 따옴표 없는 YAML
            #   스칼라가 매핑으로 잘못 해석돼 config.yaml 전체 파싱이 깨진다(실측 확인된 버그).
            safe_val = label.replace('"', '\\"')
            lines[idx] = f'{prefix}"{safe_val}"\n'
        changed.append(m2.group(2))
        last_name_idx = None
with open(path, 'w') as f:
    f.writelines(lines)
print("갱신됨:", changed if changed else "(대상 없음)")
PYEOF
    ok "~/.continue/config.yaml 갱신 시도 완료(형식이 예상과 다르면 수동 확인 필요)"
  fi

  # ★Continue는 "현재 선택된 모델"을 이름(문자열)으로 캐싱한다(~/.continue/index/globalContext.json).
  #   config.yaml만 바꾸고 이 캐시를 안 맞춰주면, 캐시가 가리키는 이름이 더 이상 models 목록에
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

  # 전환 전 현재 served-name 기억(라우트/클라이언트 갱신 시 old→new 치환에 필요)
  local old_served_name
  old_served_name="$(grep -E '^MAIN_SERVED_NAME=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  old_served_name="${old_served_name:-main-llama}"
  local new_served_name="${PROFILE[MAIN_SERVED_NAME]:-${OPTIONAL_DEFAULTS[MAIN_SERVED_NAME]}}"

  log ".env 갱신 (시크릿·이미지태그 등 다른 값은 그대로 유지)"
  for k in "${REQUIRED_KEYS[@]}"; do
    patch_env_key "$k" "${PROFILE[$k]}"
    echo "  $k=${PROFILE[$k]}"
  done
  for k in "${!OPTIONAL_DEFAULTS[@]}"; do
    local v="${PROFILE[$k]:-${OPTIONAL_DEFAULTS[$k]}}"
    patch_env_key "$k" "$v"
    echo "  $k=$v"
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

  sync_litellm_main_route "$old_served_name" "$new_served_name" || { err "LiteLLM 라우트 동기화 실패 — vLLM은 정상이나 게이트웨이 경유 연결이 안 될 수 있음. 수동 확인 필요."; }

  sync_key_allowlists "$old_served_name" "$new_served_name"

  update_client_config "$old_served_name" "$new_served_name"

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
