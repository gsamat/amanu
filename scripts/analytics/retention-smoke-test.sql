\set ON_ERROR_STOP on

CREATE TABLE event_data (website_id uuid, created_at timestamptz);
CREATE TABLE revenue (website_id uuid, session_id uuid, created_at timestamptz);
CREATE TABLE heatmap_event (website_id uuid, session_id uuid, created_at timestamptz);
CREATE TABLE session_replay (website_id uuid, session_id uuid, created_at timestamptz);
CREATE TABLE website_event (website_id uuid, session_id uuid, created_at timestamptz);
CREATE TABLE session_data (website_id uuid, session_id uuid, created_at timestamptz);
CREATE TABLE session_link (website_id uuid, session_id uuid, created_at timestamptz);
CREATE TABLE session (website_id uuid, session_id uuid, created_at timestamptz);

\set website_id '8ece1241-c45f-4976-9b20-d7004b2359b8'
\set old_session '00000000-0000-0000-0000-000000000001'
\set new_session '00000000-0000-0000-0000-000000000002'

INSERT INTO event_data VALUES
    (:'website_id', now() - interval '2 years'),
    (:'website_id', now());
INSERT INTO revenue VALUES
    (:'website_id', :'old_session', now() - interval '2 years'),
    (:'website_id', :'new_session', now());
INSERT INTO heatmap_event SELECT * FROM revenue;
INSERT INTO session_replay SELECT * FROM revenue;
INSERT INTO website_event SELECT * FROM revenue;
INSERT INTO session_data SELECT * FROM revenue;
INSERT INTO session_link SELECT * FROM revenue;
INSERT INTO session VALUES
    (:'website_id', :'old_session', now() - interval '2 years'),
    (:'website_id', :'new_session', now());

\i /opt/amanu/retention.sql

DO $$
DECLARE
    relation text;
    remaining bigint;
BEGIN
    FOREACH relation IN ARRAY ARRAY[
        'event_data', 'revenue', 'heatmap_event', 'session_replay',
        'website_event', 'session_data', 'session_link', 'session'
    ] LOOP
        EXECUTE format('SELECT count(*) FROM %I', relation) INTO remaining;
        IF remaining <> 1 THEN
            RAISE EXCEPTION '% retained % rows, expected 1', relation, remaining;
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1 FROM session
        WHERE session_id = '00000000-0000-0000-0000-000000000001'
    ) THEN
        RAISE EXCEPTION 'old session survived retention';
    END IF;
END $$;

SELECT 'retention-smoke-test: pass';
