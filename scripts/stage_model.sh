#!/usr/bin/env bash
# scripts/stage_model.sh — 오프라인 모델/이미지 스테이징 검증 게이트 (FR-10 ①②③)
#
# 오프라인 모델 업데이트 워크플로우 4단계 중 "사내망 반입 직후 검증" 부분을 자동화한다.
#   ① (분리망에서 다운로드 — 본 스크립트 범위 밖)
#   ② 무결성/라이선스/취약점 검증   ← 본 스크립트
#   ③ 사설 레지스트리/스테이징 디렉터리 적재 후 재검증 ← 본 스크립트(verify)
#   ④ Blue/Green 무중단 배포 + 롤백 ← scripts/deploy_model.sh
#
# 사용:
#   ./stage_model.sh manifest <model_dir>           # 분리망에서: SHA256SUMS 생성(반입 매체에 동봉)
#   ./stage_model.sh verify   <model_dir>           # 사내망에서: SHA256SUMS 대조(무결성 재검증)
#   ./stage_model.sh scan-image <image[:tag]>       # Trivy 가 있으면 이미지 CVE 스캔(폐쇄망: DB 사전반입)
#   ./stage_model.sh gate     <model_dir> <image>   # ②③ 일괄: verify + 라이선스 + 스캔 → 통과 시 0
#
# 설계: 멱등/비파괴(읽기 검증만). 실패 시 비0 종료코드 → ④ 배포 단계로 진행 금지.
# 폐쇄망: 외부 통신 없음. Trivy 미설치/취약점DB 미반입 시 스캔은 SKIP(경고)하되 무결성·라이선스는 필수.

set -euo pipefail

SUMFILE="SHA256SUMS"                 # model_dir 안에 두는 무결성 매니페스트
# 라이선스로 인정할 파일명(대소문자 무시). 사전 스테이징 시 모델 디렉터리에 동봉.
LICENSE_GLOBS=("LICENSE" "LICENSE.txt" "LICENSE.md" "LICENCE" "COPYING" "*license*")

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }

need_dir() { [[ -d "$1" ]] || { err "모델 디렉터리 없음: $1"; exit 1; }; }

# ── ② SHA-256 매니페스트 생성 (분리망/배포원) ──────────────────────────────
gen_manifest() {
  local dir="$1"; need_dir "$dir"
  log "SHA256SUMS 생성: $dir (가중치 무결성 매니페스트)"
  # 가중치/설정 파일만 대상. 매니페스트/라이선스 자체는 제외.
  ( cd "$dir" && find . -type f \
      ! -name "$SUMFILE" \
      -print0 | sort -z | xargs -0 sha256sum > "$SUMFILE" )
  ok "생성 완료: $dir/$SUMFILE ($(wc -l < "$dir/$SUMFILE") 파일)"
  echo "  → 이 $SUMFILE 을 반입 매체에 함께 담아 사내망에서 'verify' 로 대조하세요."
}

# ── ③ 무결성 재검증 (사내망 반입 후) ───────────────────────────────────────
verify_manifest() {
  local dir="$1"; need_dir "$dir"
  [[ -f "$dir/$SUMFILE" ]] || { err "$dir/$SUMFILE 없음 → 먼저 'manifest' 로 생성/동봉 필요."; exit 1; }
  log "무결성 검증: $dir/$SUMFILE 대조"
  if ( cd "$dir" && sha256sum -c --quiet "$SUMFILE" ); then
    ok "체크섬 일치 — 반입 중 변조/손상 없음"
  else
    err "체크섬 불일치 — 반입본이 손상/변조됨. 배포 중단."
    exit 2
  fi
}

# ── 라이선스 동봉 확인 ─────────────────────────────────────────────────────
check_license() {
  local dir="$1"; need_dir "$dir"
  log "라이선스 파일 확인: $dir"
  local found=""
  for g in "${LICENSE_GLOBS[@]}"; do
    found="$(find "$dir" -maxdepth 2 -type f -iname "$g" 2>/dev/null | head -1 || true)"
    [[ -n "$found" ]] && break
  done
  if [[ -n "$found" ]]; then
    ok "라이선스 동봉 확인: ${found#$dir/}"
  else
    err "라이선스 파일을 찾지 못함(LICENSE/COPYING 등). 라이선스 검토 완료 후 동봉하여 재반입."
    exit 3
  fi
}

# ── 이미지 취약점 스캔 (Trivy, 폐쇄망: DB 사전반입) ─────────────────────────
scan_image() {
  local image="$1"
  log "이미지 취약점 스캔: $image"
  if ! command -v trivy >/dev/null 2>&1; then
    warn "trivy 미설치 → 스캔 SKIP. 폐쇄망 반입 전 분리망에서 'trivy image --severity HIGH,CRITICAL $image' 수행 권장."
    return 0
  fi
  # 폐쇄망: --offline-scan + 사전반입 취약점 DB(TRIVY_DB 캐시) 전제. HIGH/CRITICAL 발견 시 비0.
  if TRIVY_NO_PROGRESS=1 trivy image --offline-scan --severity HIGH,CRITICAL \
       --exit-code 1 --no-progress "$image"; then
    ok "HIGH/CRITICAL 취약점 없음: $image"
  else
    err "HIGH/CRITICAL 취약점 발견: $image → 패치 이미지로 교체 후 재반입."
    exit 4
  fi
}

# ── ②③ 일괄 게이트 ─────────────────────────────────────────────────────────
gate() {
  local dir="$1" image="${2:-}"
  verify_manifest "$dir"
  check_license   "$dir"
  if [[ -n "$image" ]]; then scan_image "$image"; else warn "이미지 인자 미지정 → 이미지 스캔 생략."; fi
  echo
  ok "스테이징 게이트 통과 → 배포 가능: ./scripts/deploy_model.sh ... (FR-10 ④ Blue/Green)"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  manifest)   gen_manifest "${1:?model_dir 필요}" ;;
  verify)     verify_manifest "${1:?model_dir 필요}" ;;
  scan-image) scan_image "${1:?image 필요}" ;;
  gate)       gate "${1:?model_dir 필요}" "${2:-}" ;;
  *) cat >&2 <<EOF
사용: $0 <명령>
  manifest   <model_dir>          분리망에서 SHA256SUMS 생성(반입 매체 동봉)
  verify     <model_dir>          사내망에서 SHA256SUMS 대조(무결성 재검증)
  scan-image <image[:tag]>        Trivy 이미지 CVE 스캔(HIGH/CRITICAL)
  gate       <model_dir> [image]  verify + 라이선스 + 스캔 일괄 게이트
EOF
     exit 2 ;;
esac
