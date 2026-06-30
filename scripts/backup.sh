#!/usr/bin/env bash
# scripts/backup.sh — 백업 (FR-11)
#
# 대상: 키/스펜드/Audit DB(Postgres) + 설정 일체(litellm/, presidio/, docker-compose.yml, .env, .env.example).
# 산출물: backups/<timestamp>/  (db.sql.gz + config.tar.gz + manifest.txt)
# 복구는 scripts/restore.sh 참조. AC: 백업본으로 24시간 이내 스택 재기동 + 키·정책·로그 복원.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR:-$ROOT/backups}/$TS"
mkdir -p "$OUT"

PG_SERVICE="${PG_SERVICE:-postgres}"
PG_USER="${PG_USER:-litellm}"
PG_DB="${PG_DB:-litellm}"

echo "▶ [1/3] Postgres 덤프 (키/스펜드/Audit: audit_log, anomaly_alerts 포함)"
# pg_dump 를 컨테이너 내부에서 실행 → 호스트로 gzip 저장
docker compose -f "$ROOT/docker-compose.yml" exec -T "$PG_SERVICE" \
  pg_dump -U "$PG_USER" -d "$PG_DB" --clean --if-exists \
  | gzip > "$OUT/db.sql.gz"

echo "▶ [2/3] 설정 파일 아카이브"
tar -czf "$OUT/config.tar.gz" -C "$ROOT" \
  docker-compose.yml \
  litellm/config.yaml litellm/audit_logger.py litellm/gemma_compat.py litellm/autocomplete_compat.py litellm/Dockerfile \
  presidio/recognizers presidio/README.md \
  docs \
  opencode.json \
  .env.example \
  $( [[ -f "$ROOT/.env" ]] && echo .env )   # .env 는 시크릿 → 백업본 자체를 보안 매체에 보관할 것

echo "▶ [3/3] 매니페스트 작성"
{
  echo "backup_time_kst: $(TZ=Asia/Seoul date -Iseconds)"
  echo "host: $(hostname)"
  echo "db_dump: db.sql.gz ($(du -h "$OUT/db.sql.gz" | cut -f1))"
  echo "config:  config.tar.gz ($(du -h "$OUT/config.tar.gz" | cut -f1))"
  echo "images(pinned, .env 참조): VLLM/LITELLM/POSTGRES/PRESIDIO 태그는 .env 에 고정 — 동일 태그로 복구"
} > "$OUT/manifest.txt"

echo "✔ 백업 완료: $OUT"
echo "  ⚠ db.sql.gz 와 .env 는 시크릿/감사로그를 포함 → 백업본을 보안 매체에 보관(폐쇄망 정책)."
