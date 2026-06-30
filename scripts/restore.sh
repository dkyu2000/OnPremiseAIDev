#!/usr/bin/env bash
# scripts/restore.sh — 복구 (FR-11)
#
# 사용: ./restore.sh <backups/<timestamp> 디렉토리>
# 절차: 설정 복원 → 스택 기동 → DB 복원 → 헬스 확인. (AC: 24h 이내 재기동, 키·정책·로그 보존)
#
# ⚠ 동일 이미지 태그(.env)로 복구해야 재현성 보장(NFR-2). 모델 가중치는 사전 스테이징 디렉토리에 별도 반입.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?복구할 백업 디렉토리를 지정하세요 (예: backups/20260625-031500)}"
[[ -d "$SRC" ]] || { echo "백업 디렉토리 없음: $SRC" >&2; exit 1; }

PG_SERVICE="${PG_SERVICE:-postgres}"
PG_USER="${PG_USER:-litellm}"
PG_DB="${PG_DB:-litellm}"

echo "▶ [1/4] 설정 파일 복원"
tar -xzf "$SRC/config.tar.gz" -C "$ROOT"
[[ -f "$ROOT/.env" ]] || echo "  ⚠ .env 가 없습니다. 백업본/보안매체에서 .env 를 먼저 복원하세요(시크릿)."

echo "▶ [2/4] core + DB 기동 (postgres healthy 대기)"
docker compose -f "$ROOT/docker-compose.yml" up -d postgres
# postgres healthy 까지 대기
for i in $(seq 1 30); do
  if docker compose -f "$ROOT/docker-compose.yml" exec -T "$PG_SERVICE" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "▶ [3/4] DB 복원 (audit_log·anomaly_alerts·키·스펜드 포함)"
gunzip -c "$SRC/db.sql.gz" | \
  docker compose -f "$ROOT/docker-compose.yml" exec -T "$PG_SERVICE" \
  psql -U "$PG_USER" -d "$PG_DB"

echo "▶ [4/4] 게이트웨이 기동 + 헬스 확인"
docker compose -f "$ROOT/docker-compose.yml" up -d litellm presidio-analyzer presidio-anonymizer
sleep 5
curl -sS http://localhost:4000/health/liveliness && echo " ← litellm OK" || echo " ← litellm 헬스 확인 필요"

echo "✔ 복구 완료. 가상 키/정책/Audit 로그가 복원되었는지 확인하세요:"
echo "    docker compose exec postgres psql -U $PG_USER -d $PG_DB -c 'SELECT count(*) FROM audit_log;'"
