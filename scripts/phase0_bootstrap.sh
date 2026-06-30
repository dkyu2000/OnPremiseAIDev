#!/usr/bin/env bash
# scripts/phase0_bootstrap.sh — Phase 0 호스트 부트스트랩 (TEST_PLAN Phase 0)
#
# 목적: 검증 장비(RTX 5090 / Blackwell SM120)에 컨테이너 GPU 런타임을 갖춘다.
#   ① 드라이버/GPU 인식 점검 (570+ 필요 — 이미 595 설치 시 통과)
#   ② docker 설치
#   ③ nvidia-container-toolkit 설치 + docker 런타임 등록
#   ④ 컨테이너에서 GPU 보이는지 검증
#
# 실행:  sudo bash scripts/phase0_bootstrap.sh
# 전제:  빌드/구축 단계라 인터넷 연결 가능(설치용). 운영 폐쇄망 머신은 오프라인 반입으로 대체.
# 멱등:  이미 설치된 단계는 건너뛴다.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "sudo 로 실행하세요:  sudo bash $0"; exit 1; }

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }

# ── ① 드라이버/GPU 인식 ───────────────────────────────────────────────────
# ★Blackwell(RTX 5090 / RTX PRO 6000)은 NVIDIA "open" 커널 모듈이 필수다.
#   proprietary 모듈이 로드되면 'RmInitAdapter failed' + "requires use of the NVIDIA open
#   kernel modules" 로그와 함께 nvidia-smi 가 'No devices were found' 를 낸다 → open 모듈로 교체.
log "1) NVIDIA 드라이버 / GPU 인식 점검 (Blackwell open 모듈 필수)"
if command -v nvidia-smi >/dev/null 2>&1; then
  VER="$(cat /proc/driver/nvidia/version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  BRANCH="${VER%%.*}"   # 예: 595
  echo "드라이버 버전: ${VER:-unknown} (브랜치 ${BRANCH:-?}, 요구: 570+)"
  if nvidia-smi -L >/dev/null 2>&1; then
    nvidia-smi -L
  else
    warn "nvidia-smi가 GPU를 못 잡습니다('No devices were found'). open 모듈 필요 여부 점검."
    NEEDS_OPEN=0
    if journalctl -k --no-pager 2>/dev/null | grep -qi 'open kernel modules'; then NEEDS_OPEN=1; fi
    OPEN_PKG="nvidia-driver-${BRANCH}-open"
    if [[ "$NEEDS_OPEN" == "1" ]] && apt-cache policy "$OPEN_PKG" 2>/dev/null | grep -q 'Candidate:'; then
      warn "Blackwell이 open 커널 모듈을 요구합니다. proprietary → open 으로 교체합니다: $OPEN_PKG"
      apt-get update
      apt-get install -y "$OPEN_PKG"
      update-initramfs -u || true
      printf '\033[1;33m재부팅이 필요합니다. 재부팅 후 이 스크립트를 다시 실행하세요:\033[0m\n  sudo reboot\n'
      exit 0
    else
      warn "open 모듈 자동 전환 조건 불충족. 수동 진단:"
      echo  "   journalctl -k | grep -iE 'NVRM|RmInitAdapter|open kernel'"
      echo  "   sudo apt-get install -y nvidia-driver-${BRANCH:-595}-open && sudo reboot"
      exit 1
    fi
  fi
else
  warn "nvidia-smi 없음 → 드라이버 미설치. Blackwell은 570+ open 모듈 필요. 예) sudo apt install nvidia-driver-595-open"
  exit 1
fi

# ── ② docker ──────────────────────────────────────────────────────────────
log "2) docker 설치"
if command -v docker >/dev/null 2>&1; then
  echo "docker 이미 설치됨: $(docker --version)"
else
  # 공식 convenience 스크립트(최신 우분투 대응). 폐쇄망 운영 머신은 .deb 오프라인 반입으로 대체.
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi
docker compose version >/dev/null 2>&1 && echo "compose: $(docker compose version)" \
  || warn "docker compose 플러그인 확인 필요(docker-compose-plugin)."

# ── ③ nvidia-container-toolkit ────────────────────────────────────────────
log "3) nvidia-container-toolkit 설치"
if command -v nvidia-ctk >/dev/null 2>&1; then
  echo "nvidia-container-toolkit 이미 설치됨: $(nvidia-ctk --version | head -1)"
else
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
fi

log "3-1) docker 런타임에 NVIDIA 등록"
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# ── ④ 컨테이너 GPU 검증 ───────────────────────────────────────────────────
log "4) 컨테이너에서 GPU 검증 (CUDA 12.8 base)"
if docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi; then
  echo
  printf '\033[1;32m✔ Phase 0 통과: 컨테이너에서 RTX 5090 인식됨. 이제 스택 기동 가능:\033[0m\n'
  echo "    cd $(dirname "$(dirname "$(readlink -f "$0")")") && docker compose --profile phase-a up -d"
else
  warn "컨테이너 GPU 검증 실패. 위 ①의 'No devices' 문제를 먼저 해결(재부팅)한 뒤 재실행하세요."
  exit 1
fi
