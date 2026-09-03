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
