# Presidio 커스텀 Recognizer 반입 절차 (FR-6)

LiteLLM 게이트웨이의 Presidio 가드레일(`litellm/config.yaml`)은 두 **커스텀 엔티티**를 사용한다:

| 엔티티 | 의미 | LiteLLM 정책 | 결과 |
|--------|------|--------------|------|
| `KR_RRN` | 주민등록번호 | `MASK` | 모델 입력·로그·Audit에서 마스킹 |
| `DB_SECRET` | DB 비밀번호/시크릿/커넥션 시크릿 | `BLOCK` | 요청 차단 → **422 + 사유** (FR-6 AC) |

이 두 엔티티는 **Presidio 표준 엔티티가 아니므로**, `presidio-analyzer` 컨테이너가
`recognizers/kr_custom.yaml`의 `PatternRecognizer`를 로드해야 인식된다.
LiteLLM(게이트웨이)이 아니라 **analyzer 측 설정**이라는 점에 주의.

## 1. 마운트 + 환경변수 (docker-compose.yml)

`presidio-analyzer` 서비스에 아래가 적용되어 있다:

```yaml
volumes:
  - ./presidio/recognizers:/opt/presidio/recognizers:ro
environment:
  - RECOGNIZER_REGISTRY_CONF_FILE=/opt/presidio/recognizers/kr_custom.yaml
```

`RECOGNIZER_REGISTRY_CONF_FILE`은 Presidio의 `RecognizerRegistryProvider`가 읽는 레지스트리
설정 파일 경로다. analyzer 기동 시 이 파일의 recognizer들이 기본 recognizer에 더해 로드된다.

> ⚠ **빌드 시점 확인(Phase A-4):** 고정한 `presidio-analyzer` 이미지 태그(`2.2.355`)가 이 환경변수를
> 인식하는지 반드시 확인한다. 버전에 따라 변수명이 다르거나(`ANALYZER_CONF_FILE` 등) 코드 기반 등록만
> 지원할 수 있다. 미지원이면 아래 2번(커스텀 이미지) 경로를 사용한다.

## 2. (Fallback) 환경변수 미지원 시 — 커스텀 이미지

이미지가 레지스트리 conf 파일 주입을 지원하지 않으면, 폐쇄망 반입용 커스텀 이미지를 빌드한다:

```dockerfile
# presidio/Dockerfile.analyzer (예시)
FROM mcr.microsoft.com/presidio-analyzer:2.2.355
COPY recognizers/kr_custom.yaml /opt/presidio/recognizers/kr_custom.yaml
ENV RECOGNIZER_REGISTRY_CONF_FILE=/opt/presidio/recognizers/kr_custom.yaml
```

또는 `add_recognizers_from_yaml()`을 호출하는 얇은 부트스트랩 스크립트를 ENTRYPOINT로 추가한다.
빌드 결과 이미지는 사전 스테이징(오프라인 반입) 대상에 포함한다(NFR-1).

## 3. 검증 (analyzer 직접 호출)

스택 기동 후 analyzer가 커스텀 엔티티를 탐지하는지 직접 확인한다(LiteLLM 우회):

```bash
# 주민등록번호 탐지 → KR_RRN 결과가 나와야 함
curl -s http://localhost:5002/analyze -H "Content-Type: application/json" -d '{
  "text": "내 주민번호는 900101-1234567 입니다",
  "language": "en",
  "entities": ["KR_RRN", "DB_SECRET"]
}'

# DB 시크릿 탐지 → DB_SECRET 결과가 나와야 함
curl -s http://localhost:5002/analyze -H "Content-Type: application/json" -d '{
  "text": "db password=P@ssw0rd! and postgres://app:secretpw@db:5432/prod",
  "language": "en",
  "entities": ["KR_RRN", "DB_SECRET"]
}'
```

각 호출이 해당 엔티티 span을 반환하면 성공. 이후 LiteLLM 경유 E2E(TEST_PLAN A-4)에서
KR_RRN은 마스킹, DB_SECRET은 422 차단이 되는지 확인한다.

## 4. 정책 매핑 위치

- **탐지(인식)**: 이 디렉토리 `kr_custom.yaml` (analyzer)
- **조치(MASK/BLOCK)**: `litellm/config.yaml`의 `guardrails[].litellm_params.pii_entities_config`
