#!/bin/bash
# railway-couchdb-start: single-node Apache CouchDB for Railway. Runs as root, then
# execs the image's /docker-entrypoint.sh (admin from COUCHDB_USER/COUCHDB_PASSWORD,
# cookie secret, ownership; drops to the couchdb user).
#
# Writes /opt/couchdb/etc/local.d/zz-railway.ini at every boot:
#   - single_node = true (creates _users, _replicator on the first boot)
#   - listens on :: (IPv4 and IPv6) port 5984
#   - every request needs a valid login except GET /_up (Railway's healthcheck)
#   - CORS for COUCHDB_CORS_ORIGINS (Obsidian Self-hosted LiveSync by default)
#     and the request/document size limits LiveSync recommends
#   - a server UUID kept in the volume, so replication checkpoints survive redeploys
# A bad value never stops the start (STANDARD 8.29); a too-short password locks
# the admin account with a random password instead.
set -uo pipefail
export LC_ALL=C

INI=/opt/couchdb/etc/local.d/zz-railway.ini
DATA=/opt/couchdb/data
log() { printf 'railway-couchdb: %s\n' "$*"; }
is_true() { case "${1,,}" in 1 | true | yes | on) return 0 ;; *) return 1 ;; esac; }

if ! [[ "${COUCHDB_USER:-}" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]; then
  log "WARNING: COUCHDB_USER='${COUCHDB_USER:-}' must be 1-64 letters, digits or _.@-; using 'admin'"
  export COUCHDB_USER=admin
fi
if [ "${#COUCHDB_PASSWORD}" -lt 12 ] 2>/dev/null || [ -z "${COUCHDB_PASSWORD:-}" ] || [[ "${COUCHDB_PASSWORD}" =~ [[:space:]\;] ]]; then
  log "WARNING: COUCHDB_PASSWORD is shorter than 12 characters or contains spaces/semicolons; the admin '${COUCHDB_USER}' is LOCKED with a random password."
  log "Set COUCHDB_PASSWORD on the CouchDB service to 12+ characters and redeploy to unlock it."
  COUCHDB_PASSWORD=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
  export COUCHDB_PASSWORD
fi
if [ "${#COUCHDB_SECRET}" -lt 32 ] 2>/dev/null || [ -z "${COUCHDB_SECRET:-}" ]; then
  log "WARNING: COUCHDB_SECRET is shorter than 32 characters; using a random one (sessions end at every redeploy)"
  COUCHDB_SECRET=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)
  export COUCHDB_SECRET
fi
export NODENAME="${NODENAME:-127.0.0.1}"

# Server UUID: generated once and kept in the volume.
UUID_FILE="$DATA/.railway-couchdb-uuid"
if ! grep -qE '^[0-9a-f]{32}$' "$UUID_FILE" 2>/dev/null; then
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$UUID_FILE"
fi
UUID=$(cat "$UUID_FILE")

ORIGINS="${COUCHDB_CORS_ORIGINS-app://obsidian.md,capacitor://localhost,http://localhost}"
if [ -n "$ORIGINS" ] && ! [[ "$ORIGINS" =~ ^[A-Za-z0-9:/.,*_-]+$ ]]; then
  log "WARNING: COUCHDB_CORS_ORIGINS has characters other than origins and commas; CORS is off"
  ORIGINS=""
fi
REQUIRE_LOGIN=true
is_true "${COUCHDB_REQUIRE_VALID_USER:-true}" || REQUIRE_LOGIN=false

MAX_DOC=${COUCHDB_MAX_DOCUMENT_SIZE:-50000000}
[[ "$MAX_DOC" =~ ^[0-9]+$ ]] || { log "WARNING: COUCHDB_MAX_DOCUMENT_SIZE is not a number; using 50000000"; MAX_DOC=50000000; }
MAX_REQ=${COUCHDB_MAX_HTTP_REQUEST_SIZE:-4294967296}
[[ "$MAX_REQ" =~ ^[0-9]+$ ]] || { log "WARNING: COUCHDB_MAX_HTTP_REQUEST_SIZE is not a number; using 4294967296"; MAX_REQ=4294967296; }

{
  cat <<EOF
; Written by railway-couchdb at every boot. Change the service variables, not
; this file; settings changed through /_node/_local/_config are written to
; docker.ini, which is recreated on every deploy.
[couchdb]
single_node = true
uuid = ${UUID}
max_document_size = ${MAX_DOC}

[chttpd]
bind_address = ::
port = 5984
; require_valid_user would also block /_up; this variant keeps the healthcheck open.
require_valid_user = false
require_valid_user_except_for_up = ${REQUIRE_LOGIN}
max_http_request_size = ${MAX_REQ}
enable_cors = $( [ -n "$ORIGINS" ] && echo true || echo false )

[chttpd_auth]
authentication_redirect = /_utils/session.html

[httpd]
WWW-Authenticate = Basic realm="couchdb"
enable_cors = $( [ -n "$ORIGINS" ] && echo true || echo false )
EOF
  if [ -n "$ORIGINS" ]; then
    cat <<EOF

[cors]
origins = ${ORIGINS}
credentials = true
headers = accept, authorization, content-type, origin, referer
methods = GET, PUT, POST, HEAD, DELETE
max_age = 3600
EOF
  fi
} > "$INI"
chmod 0644 "$INI"

log "single node, login required: ${REQUIRE_LOGIN}, CORS origins: ${ORIGINS:-none}, max document ${MAX_DOC} bytes"
exec /docker-entrypoint.sh /opt/couchdb/bin/couchdb
