# Apache CouchDB 3.5: Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **Apache CouchDB 3.5** (18 chars) |
| Description | Single-node CouchDB with Fauxton, Obsidian LiveSync CORS and backups. (69 chars) |
| Category | Storage |
| Tags | couchdb, nosql, document-database, sync, obsidian, livesync, pouchdb, backups |
| Icon | `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/couchdb.svg` (200, image/svg+xml) |

## Base market templates

| Market template | Topology | Kept | Problems fixed |
|---|---|---|---|
| `eRC98l` "CouchDB" (140 active) | repo `Aravindha1234u/couchdb-railway` (Bitnami-based), volume `/bitnami/couchdb` | Generated admin password | Bitnami images are no longer freely published, 12-character password, no single-node setup, no healthcheck, no backups |
| `couchdb` (28 active) | `couchdb:latest`, volume `/opt/couchdb/data` | Official image, volume path, `COUCHDB_SECRET` | Empty required admin inputs, floating tag, system databases never created (CouchDB logs errors until `_users` exists), no healthcheck |
| `couchdb-obsidian-livesync` (7 active) | repo `gridalpha/obsidian-livesync-railway` | LiveSync CORS origins, private health port idea | Single purpose; no backups |

### Improvements over market templates

1. Official `couchdb:3.5.3` pinned by digest; Railway's init is PID 1, the image entrypoint is reused.
2. Single-node mode with `_users`/`_replicator` created on first boot; server UUID stored in the volume (stable replication checkpoints across redeploys); Erlang node name fixed.
3. Login required for everything except `GET /_up` (`require_valid_user_except_for_up`), which is the Railway healthcheck.
4. Obsidian Self-hosted LiveSync works out of the box: CORS with credentials for the Obsidian origins, 4 GB request and 50 MB document limits, Basic `WWW-Authenticate`.
5. Listens on `::` (IPv4 + IPv6).
6. Fail-closed admin password (under 12 characters → locked with a random password, log explains) instead of a crash or an open server (8.29).
7. Nightly couchbackup of every database (+ `_users`) to a Railway Bucket, read back and parsed, retention, and a restore-into-new-database command.

## Pinned versions (checked 2026-11-24)

| Service | Image / build | Version |
|---|---|---|
| CouchDB | repo `services/couchdb`, `FROM couchdb:3.5.3@sha256:0ba6b4b8…` | Apache CouchDB 3.5.3 (Debian trixie) |
| CouchDB Backup | repo `services/backup`, `node:24.22.3-alpine3.24` + `@cloudant/couchbackup@2.11.21` + rclone 1.76.0 | |

## Services

- **CouchDB**: entrypoint `railway-couchdb-start` → `/docker-entrypoint.sh /opt/couchdb/bin/couchdb`. Volume `/opt/couchdb/data`, public domain → 5984, healthcheck `/_up` (300 s), restart ON_FAILURE ×10, draining 30 s.
- **CouchDB Backup**: cron `15 4 * * *`, restart NEVER; `backup` (default), `list`, `restore` (start command `/usr/local/bin/couchdb-backup restore`).

## Resources and cost

| Service | Idle RAM | Typical |
|---|---|---|
| CouchDB | 0.22 GB (measured) | 0.2–1 GB |
| CouchDB Backup | 0 (runs once a day) | |

Fits the Trial plan for personal sync; about $1–3/month idle at Railway prices plus volume and bucket storage.

## Verification checklist

- [x] Both services SUCCESS; `/_up` 200 without login; `/`, `/_all_dbs`, `/_utils/` 401 without login.
- [x] Admin login: CouchDB 3.5.3, `_users` + `_replicator` created, single node `couchdb@127.0.0.1`.
- [x] Database created, 500 documents via `_bulk_docs`, Mango `_find` query.
- [x] CORS preflight from `app://obsidian.md`: 204 with allow-origin, credentials, methods, max-age 3600.
- [x] Backup cron: `_users` (1 doc) and `obsidian` (500 docs) uploaded, read back and parsed, MANIFEST, retention.
- [x] Restore command: `obsidian_restored` with 500 documents.
- [x] `COUCHDB_PASSWORD=abc`: deploy SUCCESS, admin locked (401), log explains; restoring the password unlocked it.
- [x] Server UUID and data unchanged across 4 redeploys.

## Open questions

- couchbackup skips attachments by default; databases that rely on attachments need `BACKUP_ATTACHMENTS=true` (experimental upstream) or Railway volume backups.
