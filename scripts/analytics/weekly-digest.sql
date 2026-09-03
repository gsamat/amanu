\set ON_ERROR_STOP on

-- One compact JSON object is easier to move across docker exec without CSV
-- quoting surprises. The period is a rolling seven days ending at execution.
WITH bounds AS (
    SELECT
        CURRENT_TIMESTAMP AS period_end,
        CURRENT_TIMESTAMP - INTERVAL '7 days' AS period_start,
        CURRENT_TIMESTAMP - INTERVAL '14 days' AS previous_start
), properties AS (
    SELECT
        website_event_id,
        jsonb_object_agg(data_key, string_value) FILTER (WHERE string_value IS NOT NULL) AS data
    FROM event_data, bounds
    WHERE website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
      AND created_at >= bounds.previous_start
    GROUP BY website_event_id
), events AS (
    SELECT
        e.event_id,
        e.event_name,
        e.created_at,
        COALESCE(s.distinct_id, s.session_id::text) AS identity,
        COALESCE(p.data, '{}'::jsonb) AS data
    FROM website_event e
    JOIN session s ON s.session_id = e.session_id
    LEFT JOIN properties p ON p.website_event_id = e.event_id
    CROSS JOIN bounds
    WHERE e.website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
      AND e.created_at >= bounds.previous_start
      AND e.event_name IS NOT NULL
), current_events AS (
    SELECT e.* FROM events e, bounds b
    WHERE e.created_at >= b.period_start AND e.created_at < b.period_end
), previous_events AS (
    SELECT e.* FROM events e, bounds b
    WHERE e.created_at >= b.previous_start AND e.created_at < b.period_start
), latest_current AS (
    SELECT DISTINCT ON (identity) identity, data
    FROM current_events
    ORDER BY identity, created_at DESC
), current_installs AS (
    SELECT identity, MIN(created_at) AS installed_at
    FROM current_events WHERE event_name = 'installed' GROUP BY identity
), activated AS (
    SELECT DISTINCT i.identity
    FROM current_installs i
    WHERE EXISTS (
        SELECT 1 FROM current_events e
        WHERE e.identity = i.identity AND e.event_name = 'setup_completed'
          AND e.created_at >= i.installed_at
    )
      AND EXISTS (
        SELECT 1 FROM current_events e
        WHERE e.identity = i.identity AND e.event_name = 'recording_finished'
          AND e.created_at >= i.installed_at
    )
      AND EXISTS (
        SELECT 1 FROM current_events e
        WHERE e.identity = i.identity AND e.event_name = 'transcript_finished'
          AND e.created_at >= i.installed_at
    )
), current_metrics AS (
    SELECT jsonb_build_object(
        'installed', COUNT(*) FILTER (WHERE event_name = 'installed'),
        'setup_completed', COUNT(*) FILTER (WHERE event_name = 'setup_completed'),
        'activated', (SELECT COUNT(*) FROM activated),
        'active_users', COUNT(DISTINCT identity) FILTER (WHERE event_name = 'transcript_finished'),
        'recording_started', COUNT(*) FILTER (WHERE event_name = 'recording_started'),
        'recording_finished', COUNT(*) FILTER (WHERE event_name = 'recording_finished'),
        'transcript_finished', COUNT(*) FILTER (WHERE event_name = 'transcript_finished'),
        'summary_finished', COUNT(*) FILTER (WHERE event_name = 'summary_finished'),
        'speaker_names_finished', COUNT(*) FILTER (WHERE event_name = 'speaker_names_finished'),
        'transcript_fallback', COUNT(*) FILTER (WHERE event_name = 'transcript_fallback'),
        'artifact_opened', COUNT(*) FILTER (WHERE event_name = 'artifact_opened')
    ) AS value FROM current_events
), previous_metrics AS (
    SELECT jsonb_build_object(
        'installed', COUNT(*) FILTER (WHERE event_name = 'installed'),
        'active_users', COUNT(DISTINCT identity) FILTER (WHERE event_name = 'transcript_finished')
    ) AS value FROM previous_events
), stt AS (
    SELECT COALESCE(jsonb_agg(row ORDER BY count DESC), '[]'::jsonb) AS value
    FROM (
        SELECT jsonb_build_object(
            'engine', COALESCE(data->>'engine', 'unknown'),
            'model', COALESCE(data->>'model', 'unknown'),
            'count', COUNT(*)
        ) AS row, COUNT(*) AS count
        FROM current_events WHERE event_name = 'transcript_finished'
        GROUP BY data->>'engine', data->>'model'
    ) q
), summaries AS (
    SELECT COALESCE(jsonb_agg(row ORDER BY count DESC), '[]'::jsonb) AS value
    FROM (
        SELECT jsonb_build_object(
            'backend', COALESCE(data->>'backend', 'unknown'),
            'model', COALESCE(data->>'model', 'unknown'),
            'count', COUNT(*)
        ) AS row, COUNT(*) AS count
        FROM current_events WHERE event_name = 'summary_finished'
        GROUP BY data->>'backend', data->>'model'
    ) q
), failures AS (
    SELECT COALESCE(jsonb_agg(row ORDER BY count DESC), '[]'::jsonb) AS value
    FROM (
        SELECT jsonb_build_object(
            'event', event_name,
            'reason', COALESCE(data->>'reason', 'unknown'),
            'count', COUNT(*)
        ) AS row, COUNT(*) AS count
        FROM current_events
        WHERE event_name IN (
            'recording_start_failed', 'transcript_failed',
            'summary_backend_failed', 'summary_failed', 'speaker_names_failed',
            'model_download_failed', 'system_track_silent', 'session_interrupted'
        )
        GROUP BY event_name, data->>'reason'
    ) q
), versions AS (
    SELECT COALESCE(jsonb_agg(row ORDER BY users DESC), '[]'::jsonb) AS value
    FROM (
        SELECT jsonb_build_object(
            'version', COALESCE(data->>'app_version', 'unknown'),
            'users', COUNT(DISTINCT identity)
        ) AS row, COUNT(DISTINCT identity) AS users
        FROM current_events
        GROUP BY data->>'app_version'
    ) q
), recording_triggers AS (
    SELECT COALESCE(jsonb_agg(row ORDER BY count DESC), '[]'::jsonb) AS value
    FROM (
        SELECT jsonb_build_object(
            'trigger', COALESCE(data->>'trigger', 'unknown'),
            'count', COUNT(*)
        ) AS row, COUNT(*) AS count
        FROM current_events WHERE event_name = 'recording_started'
        GROUP BY data->>'trigger'
    ) q
), configurations AS (
    SELECT COALESCE(jsonb_agg(row ORDER BY users DESC), '[]'::jsonb) AS value
    FROM (
        SELECT jsonb_build_object(
            'transcription_engine', COALESCE(data->>'transcription_engine', 'unknown'),
            'cloud_provider', COALESCE(data->>'transcription_cloud_provider', 'unknown'),
            'summary_backend', COALESCE(data->>'summary_backend', 'unknown'),
            'users', COUNT(*)
        ) AS row, COUNT(*) AS users
        FROM latest_current
        GROUP BY data->>'transcription_engine',
                 data->>'transcription_cloud_provider',
                 data->>'summary_backend'
    ) q
)
SELECT jsonb_build_object(
    'period', jsonb_build_object(
        'start', to_char(bounds.period_start AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
        'end', to_char(bounds.period_end AT TIME ZONE 'UTC', 'YYYY-MM-DD')
    ),
    'metrics', current_metrics.value,
    'previous', previous_metrics.value,
    'stt', stt.value,
    'summaries', summaries.value,
    'failures', failures.value,
    'versions', versions.value,
    'recording_triggers', recording_triggers.value,
    'configurations', configurations.value
)::text
FROM bounds, current_metrics, previous_metrics, stt, summaries, failures,
     versions, recording_triggers, configurations;
