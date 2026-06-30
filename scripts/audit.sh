#!/usr/bin/env bash
# scripts/audit.sh — Audit DB(감사 로그) 조회 도구 (FR-5)
#
# LiteLLM/audit_logger 가 적재한 audit_log·anomaly_alerts 를 운영팀이 쉽게 조회한다.
# 모든 조회는 읽기 전용(SELECT)이다.
#
# 사용:
#   ./audit.sh recent [N]            최근 N건 요청 (기본 20)
#   ./audit.sh user <user_id> [N]    특정 사용자(가상키 alias) 요청
#   ./audit.sh model <model> [N]     특정 모델 요청 (main-llama|sub-gemma|autocomplete-starcoder2|prod-gemma27b)
#   ./audit.sh detail <id>           단일 레코드 전체(프롬프트/출력 전문 포함)
#   ./audit.sh pending               미완료(취소/진행중) 요청
#   ./audit.sh errors [N]            오류 요청
#   ./audit.sh pii                   PII 마스킹/차단 흔적(프롬프트에 <KR_RRN> 등) 확인
#   ./audit.sh anomalies             이상탐지 경보(anomaly_alerts)
#   ./audit.sh stats                 모델별/사용자별 집계
#   ./audit.sh sql "<SELECT ...>"    임의 SELECT (읽기전용 권장)
#   ./audit.sh psql                  대화형 psql 셸 진입
#
# 환경변수: PG_SERVICE(기본 postgres) / PG_USER(litellm) / PG_DB(litellm)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_SERVICE="${PG_SERVICE:-postgres}"
PG_USER="${PG_USER:-litellm}"
PG_DB="${PG_DB:-litellm}"
DC=(docker compose -f "$ROOT/docker-compose.yml")

# psql 실행 래퍼 (docker compose exec). sudo 가 필요한 환경이면 SUDO=sudo 로 호출.
q() { ${SUDO:-} "${DC[@]}" exec -T "$PG_SERVICE" psql -U "$PG_USER" -d "$PG_DB" "$@"; }

cmd="${1:-recent}"; shift || true

case "$cmd" in
  recent)
    N="${1:-20}"
    q -c "SELECT to_char(ts,'MM-DD HH24:MI:SS') AS \"시각(KST)\", user_id AS \"사용자\", model AS \"모델\",
                 total_tokens AS \"토큰\", finish_reason AS \"상태\", left(replace(prompt,chr(10),' '),40) AS \"프롬프트\"
          FROM audit_log ORDER BY id DESC LIMIT $N;"
    ;;
  user)
    U="${1:?user_id 필요 (예: dev-ide_continue-20260625)}"; N="${2:-30}"
    q -c "SELECT to_char(ts,'MM-DD HH24:MI:SS') AS \"시각\", model AS \"모델\", total_tokens AS \"토큰\",
                 finish_reason AS \"상태\", left(replace(prompt,chr(10),' '),45) AS \"프롬프트\"
          FROM audit_log WHERE user_id = '$U' ORDER BY id DESC LIMIT $N;"
    ;;
  model)
    M="${1:?model 필요}"; N="${2:-30}"
    q -c "SELECT to_char(ts,'MM-DD HH24:MI:SS') AS \"시각\", user_id AS \"사용자\", total_tokens AS \"토큰\",
                 finish_reason AS \"상태\", left(replace(coalesce(output,''),chr(10),' '),40) AS \"출력\"
          FROM audit_log WHERE model = '$M' ORDER BY id DESC LIMIT $N;"
    ;;
  detail)
    ID="${1:?id 필요}"
    q -x -c "SELECT id, ts, user_id, api_key_id, model, prompt_tokens, output_tokens, total_tokens,
                    finish_reason, request_id, prompt_hash, prompt, output
             FROM audit_log WHERE id = $ID;"
    ;;
  pending)
    q -c "SELECT to_char(ts,'MM-DD HH24:MI:SS') AS \"시각\", user_id AS \"사용자\", model AS \"모델\",
                 left(request_id,18) AS \"요청ID\"
          FROM audit_log WHERE finish_reason = 'pending' ORDER BY id DESC LIMIT 50;"
    ;;
  errors)
    N="${1:-30}"
    q -c "SELECT to_char(ts,'MM-DD HH24:MI:SS') AS \"시각\", user_id AS \"사용자\", model AS \"모델\"
          FROM audit_log WHERE finish_reason = 'error' ORDER BY id DESC LIMIT $N;"
    ;;
  pii)
    # 마스킹 흔적(<KR_RRN_..>, <EMAIL_ADDRESS_..> 등 placeholder)이 들어간 프롬프트
    q -c "SELECT to_char(ts,'MM-DD HH24:MI:SS') AS \"시각\", user_id AS \"사용자\",
                 left(replace(prompt,chr(10),' '),70) AS \"마스킹된 프롬프트\"
          FROM audit_log WHERE prompt ~ '<[A-Z_]+(_[0-9]+)?>' ORDER BY id DESC LIMIT 30;"
    ;;
  anomalies)
    q -c "SELECT to_char(ts,'MM-DD HH24:MI:SS') AS \"시각\", rule AS \"룰\", user_id AS \"사용자\", detail AS \"상세\"
          FROM anomaly_alerts ORDER BY id DESC LIMIT 30;"
    ;;
  stats)
    echo "── 모델별 ──"
    q -c "SELECT model AS \"모델\", count(*) AS \"건수\",
                 count(*) FILTER (WHERE finish_reason='pending') AS \"미완료\",
                 count(*) FILTER (WHERE finish_reason='error') AS \"오류\",
                 round(avg(total_tokens)) AS \"평균토큰\"
          FROM audit_log GROUP BY model ORDER BY 2 DESC;"
    echo "── 사용자별(상위 10) ──"
    q -c "SELECT user_id AS \"사용자\", count(*) AS \"건수\", sum(total_tokens) AS \"총토큰\"
          FROM audit_log WHERE user_id IS NOT NULL GROUP BY user_id ORDER BY 2 DESC LIMIT 10;"
    ;;
  sql)
    q -c "${1:?SELECT 문 필요}"
    ;;
  psql)
    ${SUDO:-} "${DC[@]}" exec "$PG_SERVICE" psql -U "$PG_USER" -d "$PG_DB"
    ;;
  *)
    grep -E '^#   \./audit\.sh' "$0" | sed 's/^# //'
    exit 2
    ;;
esac
