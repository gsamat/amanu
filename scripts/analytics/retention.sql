\set ON_ERROR_STOP on

BEGIN;

-- Event properties have no foreign key, so remove them before their events.
DELETE FROM event_data
WHERE website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
  AND created_at < CURRENT_TIMESTAMP - INTERVAL '1 year';

DELETE FROM revenue
WHERE website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
  AND created_at < CURRENT_TIMESTAMP - INTERVAL '1 year';

DELETE FROM heatmap_event
WHERE website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
  AND created_at < CURRENT_TIMESTAMP - INTERVAL '1 year';

DELETE FROM session_replay
WHERE website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
  AND created_at < CURRENT_TIMESTAMP - INTERVAL '1 year';

DELETE FROM website_event
WHERE website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
  AND created_at < CURRENT_TIMESTAMP - INTERVAL '1 year';

DELETE FROM session_data
WHERE website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
  AND created_at < CURRENT_TIMESTAMP - INTERVAL '1 year';

DELETE FROM session_link
WHERE website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
  AND created_at < CURRENT_TIMESTAMP - INTERVAL '1 year';

-- Umami has no foreign keys on its event tables. Drop only old sessions for
-- which no retained child row remains, so a live session can never be orphaned.
DELETE FROM session AS s
WHERE s.website_id = '8ece1241-c45f-4976-9b20-d7004b2359b8'
  AND s.created_at < CURRENT_TIMESTAMP - INTERVAL '1 year'
  AND NOT EXISTS (SELECT 1 FROM website_event e WHERE e.session_id = s.session_id)
  AND NOT EXISTS (SELECT 1 FROM session_data d WHERE d.session_id = s.session_id)
  AND NOT EXISTS (SELECT 1 FROM session_link l WHERE l.session_id = s.session_id)
  AND NOT EXISTS (SELECT 1 FROM revenue r WHERE r.session_id = s.session_id)
  AND NOT EXISTS (SELECT 1 FROM heatmap_event h WHERE h.session_id = s.session_id)
  AND NOT EXISTS (SELECT 1 FROM session_replay p WHERE p.session_id = s.session_id);

COMMIT;
