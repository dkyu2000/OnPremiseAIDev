#!/usr/bin/env bash
# scripts/rotate_keys.sh — 3-Tier 가상 키 발급 + 90일 로테이션 (FR-3)
#
# LiteLLM OSS 의 /key/generate · /key/delete 로 역할별 가상 키를 발급/폐기한다.
# (Enterprise 자동 키 로테이션 미사용 → 본 스크립트 + cron 으로 자체 구현)
#
# 사용:
#   ./rotate_keys.sh generate <admin|senior|developer> [user_id]
#   ./rotate_keys.sh rotate   <old_key>  <admin|senior|developer> [user_id]   # 신규 발급 후 구 키 폐기
#   ./rotate_keys.sh delete   <key>
#   DRY_RUN=1 ./rotate_keys.sh ...   # 호출 페이로드만 출력(실호출 안 함)
#
# 정책(REQUIREMENTS FR-3): ★[2026-07-07] 서브 채팅 모델 운영 미채택 → 전 역할 main+autocomplete만, RPM/TPM만 차등
#   역할        RPM       일토큰    모델
#   admin       무제한    무제한    main + autocomplete + 관리
#   senior      120       200K      main + autocomplete
#   developer   60        100K      main + autocomplete
#
# 주의: LiteLLM 키는 분당 tpm_limit 는 지원하나 "일 토큰" 직접 한도는 없다.
#   → 일 토큰 한도는 tpm_limit(분당) 로 근사하고, 정확한 일일 상한은 이상탐지(FR-7)/budget 으로 보완한다.
#   90일 자동 만료를 위해 duration="90d" 로도 발급한다(이중 안전장치).
#
# ★[검증 발견] 에이전트 클라이언트(OpenCode 등)는 1 프롬프트당 tool 왕복으로 모델을 수십~수백 회 호출한다.
#   일반 채팅 기준 RPM(developer 60)으로는 금방 초과된다. 에이전트를 쓰는 사용자에게는 senior 이상 등급을
#   부여하거나, 아래 rpm/tpm 값을 에이전트 부하에 맞게 상향한다(예: RPM 600, TPM 2M). 운영 규모(50인)에서
#   에이전트 동시 사용 시 게이트웨이 총 RPM/TPM 용량도 함께 산정할 것.

set -euo pipefail

LITELLM_BASE="${LITELLM_BASE:-http://localhost:4000}"

# 마스터 키 로드 (.env 우선, 환경변수 override 가능)
if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  ENV_FILE="${ENV_FILE:-$(dirname "$0")/../.env}"
  if [[ -f "$ENV_FILE" ]]; then
    LITELLM_MASTER_KEY="$(grep -E '^LITELLM_MASTER_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  fi
fi
: "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY 가 필요합니다 (.env 또는 환경변수)}"

DRY_RUN="${DRY_RUN:-0}"

# 역할 → 발급 페이로드(JSON) 생성
role_payload() {
  local role="$1" user_id="${2:-}"
  local meta="{\"role\":\"$role\"$( [[ -n "$user_id" ]] && echo ",\"user_id\":\"$user_id\"" )}"
  # ★[2026-07-07 운영 결정] 서브 채팅 모델(sub-gemma, prod-gemma27b)은 운영 미채택 →
  #   전 역할이 main-llama + autocomplete-starcoder2만 사용. 역할 차등은 rpm/tpm 한도로만 구분.
  case "$role" in
    admin)
      # 무제한: rpm/tpm 미설정. main + 자동완성.
      echo "{\"models\":[\"main-llama\",\"autocomplete-starcoder2\"],\"duration\":\"90d\",\"key_alias\":\"admin-${user_id:-shared}-$(date +%Y%m%d)\",\"metadata\":$meta}"
      ;;
    senior)
      echo "{\"rpm_limit\":120,\"tpm_limit\":200000,\"models\":[\"main-llama\",\"autocomplete-starcoder2\"],\"duration\":\"90d\",\"key_alias\":\"senior-${user_id:-x}-$(date +%Y%m%d)\",\"metadata\":$meta}"
      ;;
    developer)
      # ★autocomplete-starcoder2 포함: IDE tab 자동완성(FIM)은 모든 개발자가 사용
      echo "{\"rpm_limit\":60,\"tpm_limit\":100000,\"models\":[\"main-llama\",\"autocomplete-starcoder2\"],\"duration\":\"90d\",\"key_alias\":\"dev-${user_id:-x}-$(date +%Y%m%d)\",\"metadata\":$meta}"
      ;;
    *) echo "알 수 없는 역할: $role (admin|senior|developer)" >&2; return 2 ;;
  esac
}

api() {  # api <METHOD> <PATH> [json]
  local method="$1" path="$2" data="${3:-}"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY_RUN] $method $LITELLM_BASE$path  ${data}" >&2
    return 0
  fi
  curl -sS -X "$method" "$LITELLM_BASE$path" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    ${data:+-d "$data"}
}

generate() {
  local role="$1" user_id="${2:-}"
  local payload; payload="$(role_payload "$role" "$user_id")"
  echo "▶ 키 발급: role=$role user=${user_id:-(none)}" >&2
  api POST /key/generate "$payload"
  echo
}

delete_key() {
  local key="$1"
  echo "▶ 키 폐기: ${key:0:8}…" >&2
  api POST /key/delete "{\"keys\":[\"$key\"]}"
  echo
}

rotate() {  # rotate <old_key> <role> [user_id]
  local old_key="$1" role="$2" user_id="${3:-}"
  echo "▶ 로테이션: 신규 발급 → 구 키 폐기" >&2
  generate "$role" "$user_id"
  delete_key "$old_key"
  echo "✔ 로테이션 완료. 신규 키를 사용자에게 안전 채널로 전달하고 구 키 사용을 중단시킬 것." >&2
}

# 90일 cron 예시(주석):
#   0 3 1 */3 * cd /opt/onprem-ai-validation && ./scripts/rotate_keys.sh rotate <OLD> <role> <user> >> /var/log/key_rotate.log 2>&1
# 퇴사/이동 시 즉시 비활성화: ./rotate_keys.sh delete <key>

cmd="${1:-}"; shift || true
case "$cmd" in
  generate) generate "$@" ;;
  rotate)   rotate "$@" ;;
  delete)   delete_key "$@" ;;
  *) echo "사용: $0 {generate <role> [user] | rotate <old_key> <role> [user] | delete <key>}" >&2; exit 2 ;;
esac
