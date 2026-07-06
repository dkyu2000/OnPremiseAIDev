#!/usr/bin/env bash
# scripts/migrate_import.sh — 실장비(RTX PRO 6000)에서 이관 번들 복원
#
# migrate_export.sh 가 만든 번들을 받아 5요소를 복원한다:
#   ① repo.bundle → 대상경로에 git clone
#   ② images/onprem-images.tar → docker load
#   ③ env/.env → <대상경로>/.env (0600)
#   ④ models/ → <대상경로>/models
#   ⑤ claude-memory/ → ~/.claude/projects/<대상경로 유래>/memory
#
# 사용:
#   ./migrate_import.sh <번들경로> [대상경로=/home/wiseop/onprem-ai-validation]
#   환경변수: SUDO=sudo (docker 에 sudo 필요한 환경)
#
# ⚠ 폐쇄망 전환 전(인터넷 창)에 실행 권장 — 이후 docker compose up / TEST_PLAN 재검증까지 끝내고 인터넷 분리.

set -euo pipefail

SRC="${1:?사용: $0 <번들경로> [대상경로]}"
TARGET="${2:-/home/wiseop/onprem-ai-validation}"
DK() { ${SUDO:-} docker "$@"; }

# docker 데몬 접근에 sudo 가 필요하면 자동 사용(SUDO 미지정 시).
if [ -z "${SUDO:-}" ] && ! docker info >/dev/null 2>&1; then
  SUDO=sudo; printf '\033[1;33mⓘ docker 데몬 접근에 sudo 사용(자동 감지)\033[0m\n'
fi

log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }

[ -d "$SRC" ] || { echo "번들 경로 없음: $SRC" >&2; exit 1; }
[ -f "$SRC/repo.bundle" ] || { echo "repo.bundle 없음 — 번들 경로 확인" >&2; exit 1; }

# ── 0) 체크섬 검증 ─────────────────────────────────────────────────────────
if [ -f "$SRC/MANIFEST.sha256" ]; then
  log "0) 체크섬 검증 (repo/images/env)"
  ( cd "$SRC" && grep -E '  (repo\.bundle|images/|env/)' MANIFEST.sha256 | sha256sum -c - ) \
    || { echo "체크섬 불일치 — 전송 손상 의심, 중단" >&2; exit 1; }
fi

# ── ① git clone ───────────────────────────────────────────────────────────
if [ -e "$TARGET/.git" ]; then
  warn "대상에 이미 git 리포 존재($TARGET) → clone 생략. 필요 시 'git -C $TARGET pull \"$SRC/repo.bundle\" --all'"
else
  log "① git clone → $TARGET"
  git clone "$SRC/repo.bundle" "$TARGET"
fi

# ── ② docker load ─────────────────────────────────────────────────────────
if [ -f "$SRC/images/onprem-images.tar" ]; then
  log "② docker load (이미지 복원)"
  DK load -i "$SRC/images/onprem-images.tar"
  [ -f "$SRC/images/IMAGES.list" ] && { echo "   복원 이미지:"; sed 's/^/   - /' "$SRC/images/IMAGES.list"; }
else
  warn "② 이미지 tar 없음 — 실장비 인터넷 창에서 docker compose pull / litellm 재빌드 필요"
fi

# ── ③ .env ────────────────────────────────────────────────────────────────
if [ -f "$SRC/env/.env" ]; then
  if [ -f "$TARGET/.env" ]; then
    warn "③ $TARGET/.env 이미 존재 → 덮어쓰지 않음. 수동 비교 필요"
  else
    log "③ .env 복원 (0600)"
    install -m 600 "$SRC/env/.env" "$TARGET/.env"
    warn "   실장비값 조정 필요: VRAM 96GB → gpu-memory-utilization / 동시상주 모델 상향, 운영키 재발급 권장"
  fi
else
  warn "③ .env 미포함 → cp $TARGET/.env.example $TARGET/.env 후 실장비 값으로 작성"
fi

# ── ④ 모델 ────────────────────────────────────────────────────────────────
if [ -d "$SRC/models" ]; then
  log "④ 모델 복원 → $TARGET/models"
  mkdir -p "$TARGET/models"
  if command -v rsync >/dev/null; then rsync -a --info=progress2 "$SRC/models/" "$TARGET/models/"
  else cp -a "$SRC/models/." "$TARGET/models/"; fi
else
  warn "④ 모델 미포함 → 외장 디스크에서 $TARGET/models 로 별도 복사"
fi

# ── ⑤ Claude Code 메모리 ──────────────────────────────────────────────────
if [ -d "$SRC/claude-memory" ]; then
  DEST_MEM="$HOME/.claude/projects/$(echo "$TARGET" | sed 's#/#-#g')/memory"
  log "⑤ Claude Code 메모리 복원 → $DEST_MEM"
  mkdir -p "$DEST_MEM"
  cp -a "$SRC/claude-memory/." "$DEST_MEM/"
  [ "$TARGET" = "/home/wiseop/onprem-ai-validation" ] || \
    warn "   대상경로가 원본과 달라 폴더명이 재계산됨(경로 유래). 위 경로에 배치했으니 Claude Code가 인식함."
fi

echo
log "복원 완료. 다음 단계(인터넷 창에서):"
cat <<EOF
   cd $TARGET
   # .env 실장비값 조정 후
   ${SUDO:+SUDO=sudo }docker compose up -d
   curl -s http://localhost:8000/health   # vLLM
   curl -s http://localhost:4000/health   # LiteLLM
   # TEST_PLAN Phase 0/A/B/C 재검증(96GB → 70B 메인 포함) → 통과 시 인터넷 분리 → OpenCode 런타임 전환
EOF
