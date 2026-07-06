#!/usr/bin/env bash
# scripts/migrate_export.sh — 실장비 이관용 번들 생성 (현재=테스트 장비, 인터넷 창에서 실행)
#
# 폐쇄망 실장비(RTX PRO 6000)로 "그대로" 옮기기 위한 5요소를 한 디렉터리에 모은다:
#   ① repo.bundle          : git 전체(모든 브랜치/태그) — 인프라 IaC·설정·스크립트·CLAUDE.md 등
#   ② images/*.tar         : docker save (프로파일 뒤 vLLM + 로컬빌드 onprem-litellm 포함)
#   ③ env/.env             : 시크릿(.gitignore 대상) — 안전 채널 전제, 0600
#   ④ models/              : 사전 스테이징 모델 가중치(~80GB, .gitignore 대상)
#   ⑤ claude-memory/       : ~/.claude 프로젝트 메모리(검증 진행상황 기억) → Claude Code "그대로"
#   + MANIFEST.sha256, README_IMPORT.txt
#
# 사용:
#   ./migrate_export.sh <대상경로>            전체 번들 생성 (예: /media/usb/onprem-migration)
#   옵션: --no-models(모델 별도 이전) / --no-secrets(.env 제외) / --no-images(이미지 별도)
#   환경변수: SUDO=sudo (docker 에 sudo 필요한 환경)
#
# 이 스크립트는 읽기 전용(소스 장비를 변경하지 않음). 산출물만 <대상경로>에 쓴다.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DC() { ${SUDO:-} docker compose -f "$ROOT/docker-compose.yml" "$@"; }
DK() { ${SUDO:-} docker "$@"; }

# docker 데몬 접근에 sudo 가 필요하면 자동 사용(SUDO 미지정 시). 데몬 붙는 docker 명령에만 적용.
if [ -z "${SUDO:-}" ] && ! docker info >/dev/null 2>&1; then
  SUDO=sudo; printf '\033[1;33mⓘ docker 데몬 접근에 sudo 사용(자동 감지)\033[0m\n'
fi

WITH_MODELS=1; WITH_SECRETS=1; WITH_IMAGES=1
DEST=""
for a in "$@"; do
  case "$a" in
    --no-models)  WITH_MODELS=0 ;;
    --no-secrets) WITH_SECRETS=0 ;;
    --no-images)  WITH_IMAGES=0 ;;
    -*)           echo "알 수 없는 옵션: $a" >&2; exit 2 ;;
    *)            DEST="$a" ;;
  esac
done
[ -n "$DEST" ] || { echo "사용: $0 <대상경로> [--no-models|--no-secrets|--no-images]" >&2; exit 2; }

OUT="$DEST/onprem-migration"
mkdir -p "$OUT"/{images,env,claude-memory}
MANIFEST="$OUT/MANIFEST.sha256"
: > "$MANIFEST"

log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
sha()  { sha256sum "$1" | awk -v p="$2" '{print $1"  "p}' >> "$MANIFEST"; }

# ── ① git 번들 ────────────────────────────────────────────────────────────
log "① git 번들 생성 (모든 브랜치/태그)"
git -C "$ROOT" bundle create "$OUT/repo.bundle" --all
sha "$OUT/repo.bundle" "repo.bundle"

# ── ② docker 이미지 save ──────────────────────────────────────────────────
if [ "$WITH_IMAGES" = 1 ]; then
  log "② docker 이미지 목록 수집 (프로파일 포함)"
  mapfile -t IMAGES < <(DC config 2>/dev/null | awk '/image:/{print $2}' | sort -u)
  printf '   - %s\n' "${IMAGES[@]}"
  TAR="$OUT/images/onprem-images.tar"
  # resume: 이미 유효한 tar(끝에 manifest 포함)가 있으면 재-save 생략 → 대용량 재작업 방지
  if [ -f "$TAR" ] && ${SUDO:-} tar -tf "$TAR" >/dev/null 2>&1; then
    log "   기존 유효 tar 재사용(재-save 생략): $TAR"
  else
    log "   docker save → images/onprem-images.tar (용량 큼)"
    DK save "${IMAGES[@]}" -o "$TAR"
  fi
  # ★sudo docker save 산출물은 root:600 → 사용자 소유로 바꿔야 이후 sha256sum/전송이 가능
  ${SUDO:-} chown "$(id -u):$(id -g)" "$TAR"
  printf '%s\n' "${IMAGES[@]}" > "$OUT/images/IMAGES.list"
  sha "$TAR" "images/onprem-images.tar"
else
  log "② 이미지 스킵(--no-images) — 실장비에서 별도 docker load/build 필요"
fi

# ── ③ 시크릿(.env) ────────────────────────────────────────────────────────
if [ "$WITH_SECRETS" = 1 ] && [ -f "$ROOT/.env" ]; then
  log "③ .env 복사 (0600) — ⚠ 시크릿 포함, 안전 채널로만 반출"
  install -m 600 "$ROOT/.env" "$OUT/env/.env"
  sha "$OUT/env/.env" "env/.env"
else
  log "③ 시크릿 스킵 — 실장비에서 .env.example 기반 재작성 필요(운영키 재발급 권장)"
fi

# ── ④ 모델 가중치 ─────────────────────────────────────────────────────────
if [ "$WITH_MODELS" = 1 ] && [ -d "$ROOT/models" ]; then
  log "④ 모델 가중치 복사 (~80GB, rsync 재개 가능)"
  if command -v rsync >/dev/null; then
    rsync -a --info=progress2 "$ROOT/models/" "$OUT/models/"
  else
    cp -a "$ROOT/models/." "$OUT/models/"
  fi
  ( cd "$OUT/models" && find . -type f -exec sha256sum {} \; ) > "$OUT/models.sha256" 2>/dev/null || true
  echo "models/  (개별 체크섬: models.sha256)" >> "$MANIFEST"
else
  log "④ 모델 스킵(--no-models) — 외장 디스크로 별도 이전"
fi

# ── ⑤ Claude Code 메모리 ──────────────────────────────────────────────────
SRC_MEM="$HOME/.claude/projects/$(echo "$ROOT" | sed 's#/#-#g')/memory"
if [ -d "$SRC_MEM" ]; then
  log "⑤ Claude Code 메모리 복사 ($SRC_MEM)"
  cp -a "$SRC_MEM/." "$OUT/claude-memory/"
  echo "claude-memory/  (원본 프로젝트경로: $ROOT)" >> "$MANIFEST"
else
  log "⑤ 메모리 디렉터리 없음 — 스킵"
fi

# ── README ────────────────────────────────────────────────────────────────
cat > "$OUT/README_IMPORT.txt" <<EOF
On-Prem AI 검증환경 이관 번들
생성: $(date -Is)  /  원본경로: $ROOT
실장비에서:  scripts/migrate_import.sh 를 이 번들 경로로 실행
  예)  ./migrate_import.sh $OUT /home/wiseop/onprem-ai-validation
전제: 실장비 사용자/경로를 원본과 동일하게(/home/wiseop/onprem-ai-validation) 유지하면
      Claude Code 메모리가 자동 매핑됨. 다르면 import 스크립트가 대상경로 기준으로 배치.
EOF

log "완료 → $OUT"
du -sh "$OUT" 2>/dev/null || true
echo "체크섬 검증:  (cd $OUT && sha256sum -c MANIFEST.sha256)"
