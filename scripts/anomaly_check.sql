-- scripts/anomaly_check.sql — 이상 탐지 배치 룰 (FR-7)
--
-- audit_logger.py 가 요청별 실시간으로 anomaly_alerts 를 적재하지만,
-- 본 SQL 은 동일 두 룰을 배치/수동(cron, psql) 로도 점검·재생성할 수 있게 한다.
--
-- 실행:
--   docker compose exec -T postgres psql -U litellm -d litellm -f - < scripts/anomaly_check.sql
-- 또는 cron:
--   */10 * * * * docker compose exec -T postgres psql -U litellm -d litellm -f /scripts/anomaly_check.sql

-- 룰 ① 토큰량이 사용자 평균 대비 5배 초과 (표본 5건 이상인 사용자만)
WITH stats AS (
    SELECT user_id, AVG(total_tokens)::float AS avg_tokens, COUNT(*) AS n
    FROM audit_log
    WHERE total_tokens IS NOT NULL AND user_id IS NOT NULL
    GROUP BY user_id
    HAVING COUNT(*) >= 5
),
recent AS (  -- 최근 10분 내 요청만 평가(중복 경보 방지)
    SELECT a.id, a.user_id, a.total_tokens, s.avg_tokens, s.n
    FROM audit_log a
    JOIN stats s USING (user_id)
    WHERE a.ts > now() - interval '10 minutes'
      AND a.total_tokens > 5 * s.avg_tokens
)
INSERT INTO anomaly_alerts (ts, rule, user_id, detail, audit_id)
SELECT now(), 'token_5x_avg', r.user_id,
       jsonb_build_object('total_tokens', r.total_tokens,
                          'avg_tokens', round(r.avg_tokens::numeric, 1),
                          'factor', 5, 'samples', r.n),
       r.id
FROM recent r
WHERE NOT EXISTS (  -- 동일 audit_id 중복 경보 방지
    SELECT 1 FROM anomaly_alerts x WHERE x.audit_id = r.id AND x.rule = 'token_5x_avg'
);

-- 룰 ② 동일 사용자 시간당 300건 초과
INSERT INTO anomaly_alerts (ts, rule, user_id, detail, audit_id)
SELECT now(), 'hourly_300', user_id,
       jsonb_build_object('count_last_hour', cnt, 'limit', 300),
       NULL
FROM (
    SELECT user_id, COUNT(*) AS cnt
    FROM audit_log
    WHERE ts > now() - interval '1 hour' AND user_id IS NOT NULL
    GROUP BY user_id
    HAVING COUNT(*) > 300
) over_limit
WHERE NOT EXISTS (  -- 최근 1시간 내 동일 사용자 중복 경보 방지
    SELECT 1 FROM anomaly_alerts x
    WHERE x.rule = 'hourly_300' AND x.user_id = over_limit.user_id
      AND x.ts > now() - interval '1 hour'
);

-- 최근 경보 확인
SELECT ts, rule, user_id, detail FROM anomaly_alerts ORDER BY ts DESC LIMIT 20;
