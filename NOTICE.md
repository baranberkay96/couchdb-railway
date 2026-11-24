# NOTICE

This Railway template is a community package. It is not affiliated with or endorsed by the Apache Software Foundation, the Apache CouchDB project, IBM, the Obsidian or Self-hosted LiveSync projects, or Railway. Apache CouchDB, CouchDB and the CouchDB logo are trademarks of the Apache Software Foundation.

## What this template runs

| Component | Source | License |
|---|---|---|
| Apache CouchDB 3.5.3 | official Docker image `couchdb:3.5.3` (digest `sha256:0ba6b4b8…`), https://github.com/apache/couchdb-docker; its `docker-entrypoint.sh` is used unmodified | Apache-2.0 |
| couchbackup / couchrestore 2.11.21 | npm `@cloudant/couchbackup` (https://github.com/IBM/couchbackup), installed at build time | Apache-2.0 |
| Node.js 24.22.3 | `node:24.22.3-alpine3.24` | MIT |
| Alpine packages | `bash`, `coreutils`, `ca-certificates`, `curl`, `jq`, `zstd` | per package (GPL-3.0-or-later, MIT, BSD) |
| rclone 1.76.0 | binary from `rclone/rclone:1.76.0` | MIT |

## Files written for this template

- `services/couchdb/Dockerfile`, `railway-couchdb-start.sh` (writes `local.d/zz-railway.ini` at every boot: single node, IPv4+IPv6 listener, login required except `/_up`, CORS and sizes for Obsidian LiveSync, server UUID kept in the volume; fail-closed admin password handling).
- `services/backup/Dockerfile`, `couchdb-backup.sh` (retention logic adapted from our own `56-pgvector` backup job).
- `TEMPLATE.md`, `README.md`, `template.json`, this file.

## Reused or not reused

- The marketplace templates in `../_market/` (`eRC98l` → `Aravindha1234u/couchdb-railway`, `couchdb`, `couchdb-obsidian-livesync` → `gridalpha/obsidian-livesync-railway`) were read for settings only (volume path, CORS origins for Obsidian, private health port idea). No files or text were copied.
- The CouchDB settings for LiveSync follow the option list in the Self-hosted LiveSync documentation (`docs/setup_own_server.md`, MIT); the ini file here is written from CouchDB's configuration reference.

## Upstream material checked (2026-11-24)

- `apache/couchdb-docker` `3.5.3/Dockerfile`, `docker-entrypoint.sh` (admin and secret written to `local.d/docker.ini` when missing, `NODENAME`, ownership fixes), `10-docker-default.ini`, `vm.args`.
- CouchDB 3.5 configuration reference: `[chttpd] require_valid_user_except_for_up`, `[couchdb] single_node`, `uuid`, `max_document_size`, `[cors]`.
- couchbackup README (`COUCH_URL`, full mode, attachments caveat).
