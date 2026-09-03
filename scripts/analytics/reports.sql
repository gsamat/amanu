\set ON_ERROR_STOP on

-- Umami's built-in funnels are session-based. They are excellent for the
-- short processing paths below. The activation report is explicitly labelled
-- as an approximation; weekly_digest.py computes its exact cross-session
-- counterpart from the persistent, pseudonymous distinct_id.
WITH owner AS (
    SELECT user_id FROM "user" WHERE username = 'admin' LIMIT 1
), saved(report_id, name, description, parameters) AS (
    VALUES
    (
        'a1000000-0000-4000-8000-000000000001'::uuid,
        'Activation (cross-session approximation)',
        'Built-in funnels are session-based; use the weekly digest for exact UUID activation.',
        '{"window":10080,"steps":[{"type":"event","value":"installed","filters":[]},{"type":"event","value":"setup_completed","filters":[]},{"type":"event","value":"recording_finished","filters":[]},{"type":"event","value":"transcript_finished","filters":[]}]}'::jsonb
    ),
    (
        'a1000000-0000-4000-8000-000000000002'::uuid,
        'Core processing pipeline',
        'Recording through transcript and summary; session-based by Umami design.',
        '{"window":1440,"steps":[{"type":"event","value":"recording_started","filters":[]},{"type":"event","value":"recording_finished","filters":[]},{"type":"event","value":"transcript_finished","filters":[]},{"type":"event","value":"summary_finished","filters":[]}]}'::jsonb
    ),
    (
        'a1000000-0000-4000-8000-000000000003'::uuid,
        'Automatic recording pipeline',
        'Mic-activity and calendar starts through transcript; session-based.',
        '{"window":1440,"steps":[{"type":"event","value":"recording_started","filters":[{"property":"trigger","operator":"neq","value":"manual"},{"property":"trigger","operator":"neq","value":"cli"}]},{"type":"event","value":"recording_finished","filters":[{"property":"trigger","operator":"neq","value":"manual"},{"property":"trigger","operator":"neq","value":"cli"}]},{"type":"event","value":"transcript_finished","filters":[]}]}'::jsonb
    ),
    (
        'a1000000-0000-4000-8000-000000000004'::uuid,
        'Transcript value pipeline',
        'Transcript followed by speaker naming and summary; session-based.',
        '{"window":1440,"steps":[{"type":"event","value":"transcript_finished","filters":[]},{"type":"event","value":"speaker_names_finished","filters":[]},{"type":"event","value":"summary_finished","filters":[]}]}'::jsonb
    )
)
INSERT INTO report (
    report_id, user_id, website_id, type, name, description, parameters, updated_at
)
SELECT
    saved.report_id,
    owner.user_id,
    '8ece1241-c45f-4976-9b20-d7004b2359b8'::uuid,
    'funnel',
    saved.name,
    saved.description,
    saved.parameters,
    CURRENT_TIMESTAMP
FROM saved CROSS JOIN owner
ON CONFLICT (report_id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    parameters = EXCLUDED.parameters,
    updated_at = CURRENT_TIMESTAMP;
