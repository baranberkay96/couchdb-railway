# Deploy and Host Apache CouchDB with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/apache-couchdb-35?referralCode=20H68q)

Apache CouchDB is a document database that speaks HTTP and JSON and replicates between servers, browsers (PouchDB) and phones. This community template runs CouchDB 3.5 as a ready-to-use single node with the Fauxton admin UI, a login required for every request, CORS set up for Obsidian's Self-hosted LiveSync plugin, and daily backups of every database to a Railway Bucket.

## About Hosting Apache CouchDB

A fresh CouchDB container is not usable yet: the system databases must be created, an admin must exist, and on a public URL anonymous requests should be refused. Sync clients such as Obsidian LiveSync also need CORS, large request sizes and a stable server UUID so replication checkpoints survive restarts. This template configures single-node mode, creates the admin from generated variables, requires a login everywhere except the `/_up` healthcheck, keeps the server UUID in the volume, listens on IPv4 and IPv6, and backs up all databases nightly with couchbackup, compressed and verified, with retention and a restore command.

## Common Use Cases

- Self-hosted sync server for Obsidian (Self-hosted LiveSync plugin) across desktop and mobile
- Offline-first web and mobile apps that sync with PouchDB or Couchbase Lite-style clients
- A JSON document store with an HTTP API, Mango queries and map/reduce views
- Multi-device or multi-site replication with CouchDB's replicator
- Prototyping APIs without writing a backend

## Dependencies for Apache CouchDB Hosting

- Apache CouchDB 3.5 (included: `couchdb:3.5.3`)
- A Railway Bucket for backups (included, created by the template)

### Deployment Dependencies

- CouchDB documentation: https://docs.couchdb.org/en/stable/
- Docker image: https://hub.docker.com/_/couchdb
- couchbackup: https://github.com/IBM/couchbackup
- Obsidian Self-hosted LiveSync: https://github.com/vrtmrz/obsidian-livesync
- Railway Storage Buckets: https://docs.railway.com/storage-buckets

### Implementation Details

| Service | Source | Purpose |
|---|---|---|
| CouchDB | built from this repo (`services/couchdb`, `FROM couchdb:3.5.3`) | Single node, volume at `/opt/couchdb/data`, public HTTPS domain on 5984, healthcheck `/_up` |
| CouchDB Backup | built from this repo (`services/backup`) | Daily cron (04:15 UTC): couchbackup of every database (and `_users`), zstd, read back and parsed, 14-day retention (at least 3 runs kept) |
| Bucket | Railway Bucket | Private S3 storage for the backups |

**First steps**

1. Open `https://{your-domain}/_utils` (Fauxton) and log in with `COUCHDB_USER` (`admin`) and `COUCHDB_PASSWORD` from the CouchDB service's variables.
2. Create a database, or from the command line: `curl -u admin:{password} -X PUT https://{your-domain}/mydb`.
3. For apps, create a non-admin user in `_users` and add it to the database's `_security` members instead of using the admin.

**Obsidian Self-hosted LiveSync**: CORS for `app://obsidian.md`, `capacitor://localhost` and `http://localhost` is on by default, with the request and document sizes the plugin recommends. In the plugin, use URI `https://{your-domain}`, the admin username and password (or a dedicated user), and a database name such as `obsidian`; the plugin's "Check database configuration" should report everything as OK. Change `COUCHDB_CORS_ORIGINS` (comma-separated, empty = off) for other browser apps.

**Connecting other services**: `COUCHDB_URL` (admin, private network) and `COUCHDB_PUBLIC_URL` (HTTPS) are on the CouchDB service; reference them as `${{CouchDB.COUCHDB_URL}}`.

**Security**: every request except `GET /_up` needs a valid login (`COUCHDB_REQUIRE_VALID_USER=true`). The admin password is re-applied at every boot, so changing the variable and redeploying changes it. A password under 12 characters locks the admin with a random password (the log explains) instead of exposing the server.

**Backups and restore**: backups land in the Bucket under `couchdb/{timestamp}/{database}.jsonl.zst` with a `MANIFEST.txt` listing document counts. Trigger one with `railway cron run --service "CouchDB Backup"`. couchbackup does not include attachments by default (`BACKUP_ATTACHMENTS=true` is experimental); LiveSync stores notes as documents, so its vaults are covered. To restore, set the backup service's start command to `/usr/local/bin/couchdb-backup restore`, set `RESTORE_DATABASE` (and optionally `RESTORE_RUN`, `RESTORE_TARGET`), run it once and clear the start command. It restores into a new database (`{database}_restored`) and never overwrites one; replicate from there if you want to replace data.

**Scaling**: CouchDB idled at about 220 MB on Railway in our test, so it runs on every plan. Raise memory for large views and many concurrent replications, and grow the volume as databases grow; run `POST /{db}/_compact` (automatic compaction is on by default) to reclaim space.

**Versions and upgrades**: pinned to CouchDB 3.5.3. Change the tag and digest in `services/couchdb/Dockerfile` for newer 3.5.x releases; data files stay compatible within 3.x.

### Why Deploy Apache CouchDB on Railway?

Railway gives CouchDB an HTTPS domain, a persistent volume and a managed bucket for backups, so a secured sync server for your notes, apps or devices is online in minutes. There is no reverse proxy, certificate or firewall to set up, and you scale by raising the service limits.
