"""
litellm/audit_logger.py — LiteLLM 커스텀 로깅 콜백 (폐쇄망 / OSS)

매핑:
  FR-5 Audit Trail : 모든 요청/응답을 5필드(WHO/WHEN/MODEL/PROMPT/OUTPUT)로 비동기 적재.
                     PROMPT 는 (Presidio 마스킹 후) 본문 + SHA-256 해시(위변조 검증)를 함께 저장.
  FR-7 이상 탐지   : Audit DB 기반 2룰 평가 →
                     ① 토큰량이 사용자 평균 대비 5배 초과
                     ② 동일 사용자 시간당 300건 초과
                     위반 시 anomaly_alerts 레코드 생성.

연동:
  - litellm/config.yaml → litellm_settings.callbacks: ["audit_logger.audit_handler"]
  - docker-compose.yml → litellm.volumes 에 ./litellm/audit_logger.py:/app/audit_logger.py:ro 마운트
  - DB 접속: 환경변수 DATABASE_URL (LiteLLM 과 동일한 PostgreSQL)

설계 원칙:
  - async 콜백(async_log_success_event)만 사용 → 동기 응답 경로를 막지 않는다(FR-5: async).
  - 콜백 내부 예외는 모두 흡수(콜백 실패가 사용자 응답에 영향 주지 않도록).
  - DDL 은 멱등(CREATE TABLE IF NOT EXISTS). 별도 마이그레이션 단계 불필요.

폐쇄망 의존성 주의:
  - DB 드라이버는 asyncpg 를 우선 사용한다. litellm-database 이미지에 보통 포함되어 있으나,
    고정한 LiteLLM 버전 이미지에 실제 존재하는지 빌드 시점(Phase A-3)에 확인할 것.
    (확인: `docker compose exec litellm python -c "import asyncpg; print(asyncpg.__version__)"`)
  - asyncpg 부재 시 이 콜백은 경고만 남기고 무력화된다(응답에는 영향 없음). 그 경우
    requirements 에 asyncpg 를 사전 스테이징하여 이미지에 포함시킨다.
"""

import os
import json
import hashlib
import logging
from datetime import datetime, timezone, timedelta
from urllib.parse import urlsplit, urlunsplit

from litellm.integrations.custom_logger import CustomLogger

logger = logging.getLogger("audit_logger")

KST = timezone(timedelta(hours=9))  # FR-5 WHEN: KST(ms)

# 이상 탐지 임계값 (FR-7)
ANOMALY_TOKEN_FACTOR = 5      # ① 사용자 평균 토큰 대비 N배 초과
ANOMALY_HOURLY_LIMIT = 300    # ② 동일 사용자 시간당 요청 건수 초과
ANOMALY_MIN_SAMPLES = 5       # 평균 비교를 신뢰하기 위한 최소 과거 표본 수

try:
    import asyncpg  # type: ignore
except Exception:  # pragma: no cover - 폐쇄망 이미지에 부재할 수 있음
    asyncpg = None
    logger.warning("audit_logger: asyncpg 미설치 → Audit/이상탐지 콜백 비활성화. 이미지에 asyncpg 반입 필요.")


_DDL = """
CREATE TABLE IF NOT EXISTS audit_log (
    id            BIGSERIAL PRIMARY KEY,
    ts            TIMESTAMPTZ  NOT NULL,           -- WHEN (KST 저장; tz 포함)
    latency_ms    INTEGER,                          -- WHEN: latency
    user_id       TEXT,                             -- WHO
    api_key_id    TEXT,                             -- WHO (해시된 키 식별자)
    model         TEXT,                             -- MODEL (라우팅 결과)
    prompt_tokens INTEGER,
    output_tokens INTEGER,
    total_tokens  INTEGER,                          -- MODEL: token 수
    prompt        TEXT,                             -- PROMPT (Presidio 마스킹 후 본문)
    prompt_hash   CHAR(64),                         -- PROMPT: SHA-256 (위변조 검증)
    output        TEXT,                             -- OUTPUT: 응답 본문
    finish_reason TEXT,                             -- OUTPUT: finish_reason
    request_id    TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_user_ts ON audit_log (user_id, ts);
-- pre_call '대기(pending)' 레코드를 완료 시 갱신하기 위한 request_id 조회용
CREATE INDEX IF NOT EXISTS idx_audit_request ON audit_log (request_id);

CREATE TABLE IF NOT EXISTS anomaly_alerts (
    id          BIGSERIAL PRIMARY KEY,
    ts          TIMESTAMPTZ NOT NULL,
    rule        TEXT NOT NULL,                       -- 'token_5x_avg' | 'hourly_300'
    user_id     TEXT,
    detail      JSONB,
    audit_id    BIGINT REFERENCES audit_log(id)
);
"""


class AuditLogger(CustomLogger):
    """LiteLLM CustomLogger: 비동기 Audit 적재 + 이상 탐지."""

    def __init__(self):
        super().__init__()
        self._pool = None
        self._ddl_ready = False
        self._db_url = os.environ.get("DATABASE_URL")

    @staticmethod
    def _sanitize_dsn(db_url):
        """asyncpg 용 DSN 정규화.
        - postgresql+asyncpg:// → postgresql:// (SQLAlchemy 스킴 보정)
        - 쿼리스트링 제거: LiteLLM(Prisma)이 런타임에 DATABASE_URL 에 붙이는
          connection_limit/pool_timeout/schema 등은 asyncpg 가 PostgreSQL 서버
          설정으로 오인 → 'unrecognized configuration parameter' 에러를 낸다.
        """
        dsn = db_url.replace("postgresql+asyncpg://", "postgresql://")
        parts = urlsplit(dsn)
        return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))

    async def _get_pool(self):
        """asyncpg 풀 lazy 초기화 + DDL 멱등 생성."""
        if asyncpg is None or not self._db_url:
            return None
        if self._pool is None:
            self._pool = await asyncpg.create_pool(dsn=self._sanitize_dsn(self._db_url), min_size=1, max_size=4)
        if not self._ddl_ready:
            async with self._pool.acquire() as conn:
                await conn.execute(_DDL)
            self._ddl_ready = True
        return self._pool

    # ── LiteLLM pre-call 훅: 요청 수신 시점에 '대기(pending)' 흔적 기록 ──────────
    #   취소(abort)된 자동완성 요청은 success/failure 콜백을 타지 않으므로, 여기서 먼저
    #   WHO/WHEN/MODEL/request_id 를 남긴다. 완료되면 success/failure 에서 이 레코드를 갱신.
    #   ★PROMPT 는 여기서 기록하지 않는다(Presidio 마스킹 순서 미보장 → PII 노출 위험). 마스킹이
    #     끝난 success 시점에만 채운다. abort 면 pending(프롬프트 없음) 으로 남아 흔적만 보존.
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        try:
            if not data.get("litellm_call_id"):
                return data
            pool = await self._get_pool()
            if pool is None:
                return data
            rec = self._extract_request(data, user_api_key_dict)
            async with pool.acquire() as conn:
                await self._insert_pending(conn, rec)
        except Exception as e:  # 기록 실패가 요청을 막지 않도록 흡수
            logger.warning("audit_logger: pre_call(pending) 기록 실패: %s", e)
        return data

    # ── LiteLLM 비동기 success 콜백 ─────────────────────────────────────────
    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        try:
            pool = await self._get_pool()
            if pool is None:
                return
            record = self._extract(kwargs, response_obj, start_time, end_time)
            async with pool.acquire() as conn:
                audit_id = await self._complete_audit(conn, record)  # pending 갱신 or 신규
                await self._check_anomalies(conn, record, audit_id)
        except Exception as e:  # 콜백 실패가 응답에 영향 주지 않도록 흡수
            logger.warning("audit_logger: success 콜백 처리 실패: %s", e)

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        # 실패도 WHO/WHEN/MODEL 까지는 감사 흔적으로 남긴다(익명 요청 불가 원칙).
        try:
            pool = await self._get_pool()
            if pool is None:
                return
            record = self._extract(kwargs, response_obj, start_time, end_time)
            record["finish_reason"] = record.get("finish_reason") or "error"
            async with pool.acquire() as conn:
                await self._complete_audit(conn, record)
        except Exception as e:
            logger.warning("audit_logger: failure 콜백 처리 실패: %s", e)

    # ── 필드 추출 (5필드) ───────────────────────────────────────────────────
    def _extract(self, kwargs, response_obj, start_time, end_time):
        litellm_params = kwargs.get("litellm_params") or {}
        metadata = litellm_params.get("metadata") or {}

        # WHO — LiteLLM 가상 키/사용자 식별자 (익명 요청 불가)
        user_id = (
            metadata.get("user_api_key_user_id")
            or kwargs.get("user")
            or metadata.get("user_api_key_alias")
        )
        api_key_id = metadata.get("user_api_key_hash") or metadata.get("user_api_key")

        # PROMPT — chat: messages / completion(FIM 자동완성): prompt 필드
        messages = kwargs.get("messages")
        if messages:
            prompt_text = self._stringify_messages(messages)
        else:
            p = kwargs.get("prompt")
            prompt_text = p if isinstance(p, str) else (json.dumps(p, ensure_ascii=False) if p else "")
        prompt_hash = hashlib.sha256(prompt_text.encode("utf-8")).hexdigest()

        # OUTPUT + MODEL token 수
        output_text, finish_reason = self._extract_output(response_obj)
        usage = self._get_usage(response_obj)

        # WHEN — latency
        latency_ms = None
        try:
            latency_ms = int((end_time - start_time).total_seconds() * 1000)
        except Exception:
            pass

        return {
            "ts": datetime.now(KST),
            "latency_ms": latency_ms,
            "user_id": str(user_id) if user_id is not None else None,
            "api_key_id": str(api_key_id) if api_key_id is not None else None,
            "model": kwargs.get("model") or response_obj.get("model") if isinstance(response_obj, dict) else kwargs.get("model"),
            "prompt_tokens": usage.get("prompt_tokens"),
            "output_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
            "prompt": prompt_text,
            "prompt_hash": prompt_hash,
            "output": output_text,
            "finish_reason": finish_reason,
            "request_id": (response_obj.get("id") if isinstance(response_obj, dict) else None)
            or kwargs.get("litellm_call_id"),
        }

    @staticmethod
    def _stringify_messages(messages):
        try:
            parts = []
            for m in messages:
                role = m.get("role", "")
                content = m.get("content", "")
                if isinstance(content, list):  # multimodal content blocks
                    content = json.dumps(content, ensure_ascii=False)
                parts.append(f"{role}: {content}")
            return "\n".join(parts)
        except Exception:
            return json.dumps(messages, ensure_ascii=False, default=str)

    @staticmethod
    def _extract_output(response_obj):
        # chat: choices[].message.content / completion(FIM): choices[].text — 둘 다 지원
        try:
            choices = response_obj["choices"] if isinstance(response_obj, dict) else response_obj.choices
            first = choices[0]
            if isinstance(first, dict):
                msg = first.get("message")
                content = (msg.get("content") if isinstance(msg, dict) else getattr(msg, "content", None)) if msg is not None else None
                if content is None:
                    content = first.get("text")            # text completion
                finish = first.get("finish_reason")
            else:
                msg = getattr(first, "message", None)
                content = getattr(msg, "content", None) if msg is not None else None
                if content is None:
                    content = getattr(first, "text", None)  # text completion
                finish = getattr(first, "finish_reason", None)
            return content, finish
        except Exception:
            return None, None

    @staticmethod
    def _get_usage(response_obj):
        try:
            usage = response_obj["usage"] if isinstance(response_obj, dict) else response_obj.usage
            if usage is None:
                return {}
            if not isinstance(usage, dict):
                usage = usage.model_dump() if hasattr(usage, "model_dump") else dict(usage)
            return usage
        except Exception:
            return {}

    # ── pre_call 요청 정보 추출 (WHO/WHEN/MODEL/request_id; PROMPT 제외) ───────
    def _extract_request(self, data, user_api_key_dict):
        def g(o, k):
            return o.get(k) if isinstance(o, dict) else getattr(o, k, None)
        user_id = g(user_api_key_dict, "user_id") or g(user_api_key_dict, "key_alias")
        api_key_id = g(user_api_key_dict, "api_key")
        return {
            "ts": datetime.now(KST),
            "user_id": str(user_id) if user_id is not None else None,
            "api_key_id": str(api_key_id) if api_key_id is not None else None,
            "model": data.get("model"),
            "request_id": data.get("litellm_call_id"),
        }

    # ── 적재 ────────────────────────────────────────────────────────────────
    async def _insert_pending(self, conn, r):
        # 동일 request_id 의 pending 중복 방지(혹시 pre_call 이 두 번 불릴 경우)
        await conn.execute(
            """
            INSERT INTO audit_log (ts, user_id, api_key_id, model, request_id, finish_reason)
            SELECT $1,$2,$3,$4,$5,'pending'
            WHERE NOT EXISTS (SELECT 1 FROM audit_log WHERE request_id = $5 AND finish_reason = 'pending')
            """,
            r["ts"], r["user_id"], r["api_key_id"], r["model"], r["request_id"],
        )

    async def _complete_audit(self, conn, r):
        """완료/실패 시: pre_call 의 pending 레코드가 있으면 갱신, 없으면 신규 INSERT."""
        rid = r.get("request_id")
        if rid:
            row = await conn.fetchrow(
                """
                UPDATE audit_log
                   SET ts=$2, latency_ms=$3, prompt_tokens=$4, output_tokens=$5, total_tokens=$6,
                       prompt=$7, prompt_hash=$8, output=$9, finish_reason=$10
                 WHERE request_id=$1 AND finish_reason='pending'
                 RETURNING id
                """,
                rid, r["ts"], r["latency_ms"], r["prompt_tokens"], r["output_tokens"],
                r["total_tokens"], r["prompt"], r["prompt_hash"], r["output"], r["finish_reason"],
            )
            if row:
                return row["id"]
        return await self._insert_audit(conn, r)

    async def _insert_audit(self, conn, r):
        return await conn.fetchval(
            """
            INSERT INTO audit_log
              (ts, latency_ms, user_id, api_key_id, model,
               prompt_tokens, output_tokens, total_tokens,
               prompt, prompt_hash, output, finish_reason, request_id)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
            RETURNING id
            """,
            r["ts"], r["latency_ms"], r["user_id"], r["api_key_id"], r["model"],
            r["prompt_tokens"], r["output_tokens"], r["total_tokens"],
            r["prompt"], r["prompt_hash"], r["output"], r["finish_reason"], r["request_id"],
        )

    # ── 이상 탐지 (FR-7) ─────────────────────────────────────────────────────
    async def _check_anomalies(self, conn, r, audit_id):
        user_id = r.get("user_id")
        if not user_id:
            return

        # ① 토큰량 평균 5배 초과
        total = r.get("total_tokens") or 0
        if total > 0:
            row = await conn.fetchrow(
                """
                SELECT AVG(total_tokens)::float AS avg_tokens, COUNT(*) AS n
                FROM audit_log
                WHERE user_id = $1 AND total_tokens IS NOT NULL AND id <> $2
                """,
                user_id, audit_id,
            )
            avg_tokens = (row["avg_tokens"] if row else None) or 0
            n = (row["n"] if row else 0) or 0
            if n >= ANOMALY_MIN_SAMPLES and avg_tokens > 0 and total > ANOMALY_TOKEN_FACTOR * avg_tokens:
                await self._insert_alert(
                    conn, "token_5x_avg", user_id, audit_id,
                    {"total_tokens": total, "avg_tokens": round(avg_tokens, 1),
                     "factor": ANOMALY_TOKEN_FACTOR, "samples": n},
                )

        # ② 시간당 300건 초과
        cnt = await conn.fetchval(
            """
            SELECT COUNT(*) FROM audit_log
            WHERE user_id = $1 AND ts > (now() - interval '1 hour')
            """,
            user_id,
        )
        if cnt and cnt > ANOMALY_HOURLY_LIMIT:
            await self._insert_alert(
                conn, "hourly_300", user_id, audit_id,
                {"count_last_hour": cnt, "limit": ANOMALY_HOURLY_LIMIT},
            )

    async def _insert_alert(self, conn, rule, user_id, audit_id, detail):
        await conn.execute(
            """
            INSERT INTO anomaly_alerts (ts, rule, user_id, detail, audit_id)
            VALUES ($1,$2,$3,$4,$5)
            """,
            datetime.now(KST), rule, user_id, json.dumps(detail, ensure_ascii=False), audit_id,
        )
        logger.warning("audit_logger: ANOMALY[%s] user=%s detail=%s", rule, user_id, detail)


# config.yaml 의 callbacks: ["audit_logger.audit_handler"] 가 참조하는 인스턴스
audit_handler = AuditLogger()
