# litellm/Dockerfile — 폐쇄망용 LiteLLM 이미지 (OSS + audit_logger 의존성 내장)
#
# 목적: 공식 litellm-database 이미지에는 asyncpg 가 없어 audit_logger.py(FR-5 Audit /
#   FR-7 이상탐지) 콜백이 무력화된다. 폐쇄망에선 런타임 pip install 이 불가하므로,
#   빌드 시점에 asyncpg 를 이미지에 내장하여 사전 스테이징(오프라인 반입) 대상에 포함한다.
#
# 빌드:
#   docker build -t onprem-litellm:v1.89.0-asyncpg ./litellm
#   → .env 의 LITELLM_IMAGE 를 이 태그로 고정(NFR-2 재현성).
#
# ⚠ 베이스 태그는 .env 의 LITELLM_IMAGE 라인(OSS 무료 라인)과 동일 버전으로 유지할 것.
ARG LITELLM_BASE=ghcr.io/berriai/litellm-database:v1.89.0
FROM ${LITELLM_BASE}

# audit_logger.py 가 asyncpg 우선 사용(없으면 콜백 비활성). 버전 고정(재현성).
# ★litellm 이미지는 /app/.venv (uv 기반) 사용 — pip 미포함 → ensurepip 로 부트스트랩 후 설치.
#   venv python(PATH상 /app/.venv/bin/python 우선)에 설치해야 콜백 런타임이 인식한다.
RUN python -m ensurepip \
    && python -m pip install --no-cache-dir "asyncpg==0.30.0"

# 설치 검증(빌드 실패로 조기 발견)
RUN python -c "import asyncpg; print('asyncpg', asyncpg.__version__)"
