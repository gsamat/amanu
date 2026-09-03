# Amanu analytics server

Umami 3.3.0 and its private PostgreSQL database run on `misch`. Docker binds
Umami to `127.0.0.1:8095`; the system Caddy serves it at
`https://stats.amanu.me`.

The live copy is `/opt/amanu-stats`. Its `.env` and
`/root/.config/amanu-stats/admin-password` are mode `0600` and must not be
committed. Caddy uses `/etc/caddy/conf.d/amanu-stats.caddy` and removes client
addresses from its access log.

Useful commands on the server:

```sh
cd /opt/amanu-stats
docker compose ps
docker compose logs --tail=100 umami
docker compose pull
docker compose up -d
```

The public website identifier is compiled into `AnalyticsSink.Endpoint`.
Changing or recreating the Umami website therefore requires an app release.

`amanu-stats-retention.timer` runs `retention.sql` daily and removes event,
property, identity-link, and orphaned session rows older than one year.

## Product reports

`reports.sql` idempotently provisions four saved Umami funnels. Umami's native
funnels count sessions, so the long activation funnel is visibly labelled an
approximation. The shorter processing funnels are still useful for finding
drop-off inside a run.

`weekly_digest.py` runs `weekly-digest.sql` and writes a rolling seven-day
Markdown report to `reports/latest.md` plus a dated copy. Unlike the native
funnels, its activation cohort joins events across sessions with Umami's
`distinct_id`, which is the random installation UUID sent by Amanu. Install the
checked-in service and timer as `/etc/systemd/system/amanu-stats-weekly-digest.*`;
it runs on Monday mornings. Reports remain on `misch` unless an explicit
delivery channel is added later.

To provision the reports manually on the server:

```sh
cd /opt/amanu-stats
set -a; . ./.env; set +a
docker compose exec -T database psql -X -v ON_ERROR_STOP=1 \
  -U "$UMAMI_DB_USER" -d "$UMAMI_DB_NAME" < reports.sql
```
