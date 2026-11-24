#!/bin/bash
# CouchDB backups to a Railway Bucket with couchbackup (Apache-2.0), with retention.
# Runs once and exits: "CouchDB Backup" is a Railway cron job.
#
#   couchdb-backup backup    every database -> Bucket, verify, prune (default)
#   couchdb-backup list      list the backup runs stored in the Bucket
#   couchdb-backup restore   RESTORE_DATABASE from RESTORE_RUN into a NEW database RESTORE_TARGET
#
# couchbackup reads each database's changes feed and writes the winning revision
# of every document (no attachments unless BACKUP_ATTACHMENTS=true, which
# couchbackup marks experimental). The stream is compressed with zstd and
# uploaded with rclone without touching local disk.
#
# Bucket layout (one folder per run, UTC timestamp):
#   {BACKUP_PREFIX}/20261124T041500Z/{database}.jsonl.zst
#   {BACKUP_PREFIX}/20261124T041500Z/MANIFEST.txt    written last; a run without it is incomplete
set -Eeuo pipefail

PREFIX="${BACKUP_PREFIX:-couchdb}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:-6}"
DATABASES="${BACKUP_DATABASES:-}"
WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-300}"
INCOMPLETE_GRACE_DAYS=2
RUN_RE='^[0-9]{8}T[0-9]{6}Z$'
DB_RE='^[a-z][a-z0-9_$()+/-]*$'
REMOTE=""
BASE=""
WORK="${TMPDIR:-/tmp}/couchdb-backup.$$"

log() { printf '[couchdb-backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

require_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "$3" ] || die "$1 must be a whole number >= $3 (got '$2')"
}

urlencode() { node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"; }

validate_settings() {
  require_uint BACKUP_RETENTION_DAYS "${RETENTION_DAYS}" 1
  require_uint BACKUP_KEEP_MIN "${KEEP_MIN}" 1
  require_uint BACKUP_WAIT_SECONDS "${WAIT_SECONDS}" 0
  require_uint BACKUP_ZSTD_LEVEL "${ZSTD_LEVEL}" 1
  [ "${ZSTD_LEVEL}" -le 19 ] || die "BACKUP_ZSTD_LEVEL must be 1-19"
  [[ "${PREFIX}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ "/${PREFIX}/" != */./* ]] && [[ "/${PREFIX}/" != */../* ]] \
    || die "BACKUP_PREFIX must be a folder path of letters, digits, '.', '_' and '-'"
  local var missing=()
  for var in COUCHDB_HOST COUCHDB_USER COUCHDB_PASSWORD; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "CouchDB connection not configured (missing: ${missing[*]})"
  BASE="http://${COUCHDB_HOST}:${COUCHDB_PORT:-5984}"
  mkdir -p "${WORK}"
  chmod 0700 "${WORK}"
  printf 'user = "%s:%s"\n' "${COUCHDB_USER}" "${COUCHDB_PASSWORD//\"/\\\"}" > "${WORK}/curl.conf"
  # couchbackup/couchrestore take the server URL with credentials from the environment.
  # Experimental in couchbackup; a backup taken with it must be restored with it.
  if [ "${BACKUP_ATTACHMENTS:-false}" = true ]; then export COUCH_ATTACHMENTS=true; fi
  COUCH_URL="http://$(urlencode "${COUCHDB_USER}"):$(urlencode "${COUCHDB_PASSWORD}")@${COUCHDB_HOST}:${COUCHDB_PORT:-5984}"
  export COUCH_URL
}

configure_remote() {
  local var missing=()
  for var in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Bucket not configured (missing: ${missing[*]})"
  export RCLONE_CONFIG="${HOME:-/tmp}/rclone.conf"
  : > "${RCLONE_CONFIG}"
  export RCLONE_CONFIG_BUCKET_TYPE=s3
  export RCLONE_CONFIG_BUCKET_PROVIDER=Other
  export RCLONE_CONFIG_BUCKET_ENDPOINT="${BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_BUCKET_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
  export RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  export RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  export RCLONE_CONFIG_BUCKET_CHUNK_SIZE=16M
  REMOTE="bucket:${BACKUP_S3_BUCKET}/${PREFIX}"
}

couch() { curl -sS --fail -K "${WORK}/curl.conf" --max-time 120 "$@"; }

wait_for_couchdb() {
  local waited=0
  until couch "${BASE}/_up" >/dev/null 2>&1 && couch "${BASE}/_session" >/dev/null 2>&1; do
    [ "${waited}" -ge "${WAIT_SECONDS}" ] && die "CouchDB at ${BASE} not ready (or login refused) after ${WAIT_SECONDS}s"
    log "waiting for CouchDB at ${BASE}"
    sleep 10
    waited=$((waited + 10))
  done
  SERVER_VERSION="$(couch "${BASE}/" | jq -r '.version')"
}

list_databases() {
  if [ -n "${DATABASES}" ]; then
    printf '%s\n' ${DATABASES//,/ }
  elif [ "${BACKUP_INCLUDE_USERS:-true}" = true ]; then
    couch "${BASE}/_all_dbs" | jq -r '.[] | select((startswith("_") | not) or . == "_users")'
  else
    couch "${BASE}/_all_dbs" | jq -r '.[] | select(startswith("_") | not)'
  fi
}

object_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._$()+-' '_'; }

# Documents in a couchbackup file (lines that are JSON arrays of documents).
count_docs() {
  node -e '
    const rl = require("readline").createInterface({ input: process.stdin });
    let docs = 0;
    rl.on("line", (line) => { if (line.startsWith("[")) docs += JSON.parse(line).length; });
    rl.on("close", () => console.log(docs));'
}

run_backup() {
  local run_id dest db obj failed=0 dumped=() size docs expected
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${REMOTE}/${run_id}"
  log "starting run ${run_id} -> ${PREFIX}/${run_id}/ in bucket ${BACKUP_S3_BUCKET} (CouchDB ${SERVER_VERSION})"
  while IFS= read -r db; do
    [ -n "${db}" ] || continue
    [[ "${db}" =~ ${DB_RE} ]] || [ "${db}" = _users ] || { log "ERROR: skipping '${db}': not a CouchDB database name"; failed=1; continue; }
    obj="$(object_name "${db}").jsonl.zst"
    expected="$(couch "${BASE}/$(urlencode "${db}")" | jq -r '.doc_count + .doc_del_count')"
    log "backing up ${db} (${expected} document(s) incl. deleted) -> ${obj}"
    if couchbackup --db "${db}" --mode full 2> "${WORK}/couchbackup.log" \
         | zstd -q -T0 "-${ZSTD_LEVEL}" | rclone rcat --retries 1 "${dest}/${obj}"; then
      docs="$(rclone cat "${dest}/${obj}" | zstd -q -dc | count_docs)" || docs=""
      size="$(rclone size --json "${dest}/${obj}" 2>/dev/null | sed -nE 's/.*"bytes":[[:space:]]*([0-9]+).*/\1/p')"
      if [ -n "${docs}" ]; then
        log "database ${db} done (${docs} document(s), ${size:-?} bytes compressed, read back and parsed)"
        dumped+=("${db}:${obj}:${docs}:${size:-0}")
      else
        log "ERROR: ${db}: the uploaded backup does not decompress or parse"; failed=1
      fi
    else
      sed 's/^/[couchdb-backup] couchbackup: /' "${WORK}/couchbackup.log" | grep -v 'http' | tail -n 5 || true
      log "ERROR: database ${db} failed"; failed=1
    fi
  done < <(list_databases)
  [ "${#dumped[@]}" -gt 0 ] || { log "ERROR: no database was backed up"; failed=1; }
  [ "${failed}" -eq 0 ] || die "run ${run_id} is incomplete (no MANIFEST.txt); older backups were left untouched"
  {
    printf 'run=%s\nserver_version=%s\nformat=couchbackup full mode, zstd level %s, attachments %s\n' \
      "${run_id}" "${SERVER_VERSION}" "${ZSTD_LEVEL}" "${BACKUP_ATTACHMENTS:-false}"
    printf 'database=%s\n' "${dumped[@]}"
  } | rclone rcat "${dest}/MANIFEST.txt"
  log "run ${run_id} complete: ${#dumped[@]} database(s)"
  CURRENT_RUN="${run_id}"
}

list_runs() {
  rclone lsf --dirs-only "${REMOTE}/" 2>/dev/null | sed 's#/$##' | grep -E "${RUN_RE}" | sort || true
}

list_complete_runs() {
  rclone lsf -R --files-only --max-depth 2 --include 'MANIFEST.txt' "${REMOTE}/" 2>/dev/null \
    | sed 's#/MANIFEST.txt$##' | grep -E "${RUN_RE}" | sort || true
}

prune() {
  local now cutoff incomplete_cutoff complete=() run keep protected=" " total
  now="$(date -u +%s)"
  cutoff="$(date -u -d "@$((now - RETENTION_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  incomplete_cutoff="$(date -u -d "@$((now - INCOMPLETE_GRACE_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  while IFS= read -r run; do [ -n "${run}" ] && complete+=("${run}"); done < <(list_complete_runs)
  total="${#complete[@]}"
  keep=$((total - KEEP_MIN))
  for run in ${complete[@]+"${complete[@]}"}; do
    if [ "${keep}" -le 0 ]; then protected="${protected}${run} "; fi
    keep=$((keep - 1))
  done
  log "retention: ${total} complete run(s), keep ${RETENTION_DAYS} days, at least ${KEEP_MIN}"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "${run}" = "${CURRENT_RUN:-}" ] && continue
    case "${protected}" in *" ${run} "*) continue ;; esac
    if printf '%s\n' ${complete[@]+"${complete[@]}"} | grep -qx "${run}"; then
      [[ "${run}" < "${cutoff}" ]] || continue
      log "deleting expired run ${run}"
    else
      [[ "${run}" < "${incomplete_cutoff}" ]] || continue
      log "deleting incomplete run ${run}"
    fi
    rclone purge "${REMOTE}/${run}" || log "WARNING: could not delete ${run}"
  done < <(list_runs)
}

show_runs() {
  local complete=" " run
  while IFS= read -r run; do complete="${complete}${run} "; done < <(list_complete_runs)
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    case "${complete}" in *" ${run} "*) printf '%s complete\n' "${run}" ;; *) printf '%s incomplete\n' "${run}" ;; esac
  done < <(list_runs)
}

# Restore into a NEW database; an existing one is never touched.
run_restore() {
  local run="${RESTORE_RUN:-latest}" db="${RESTORE_DATABASE:-}" target obj code
  [[ "${db}" =~ ${DB_RE} ]] || die "RESTORE_DATABASE must name the database to restore (got '${db}')"
  target="${RESTORE_TARGET:-${db}_restored}"
  [[ "${target}" =~ ${DB_RE} ]] || die "RESTORE_TARGET '${target}' is not a valid CouchDB database name"
  if [ "${run}" = latest ]; then
    run="$(list_complete_runs | tail -n 1)"
    [ -n "${run}" ] || die "no complete backup run in ${PREFIX}/"
  fi
  [[ "${run}" =~ ${RUN_RE} ]] || die "RESTORE_RUN must be 'latest' or a run folder like 20261124T041500Z"
  obj="$(object_name "${db}").jsonl.zst"
  rclone lsf "${REMOTE}/${run}/" | grep -qxF "${obj}" || die "${PREFIX}/${run}/${obj} does not exist"
  code="$(curl -s -o /dev/null -w '%{http_code}' -K "${WORK}/curl.conf" "${BASE}/$(urlencode "${target}")")"
  [ "${code}" = 404 ] || die "database ${target} already exists (HTTP ${code}); set RESTORE_TARGET to a new name"
  couch -X PUT "${BASE}/$(urlencode "${target}")" >/dev/null
  log "restoring ${PREFIX}/${run}/${obj} into new database ${target}"
  rclone cat "${REMOTE}/${run}/${obj}" | zstd -q -dc | couchrestore --db "${target}" 2> "${WORK}/couchrestore.log" \
    || { grep -v 'http' "${WORK}/couchrestore.log" | tail -n 5; die "couchrestore failed; database ${target} is incomplete"; }
  log "restore finished: ${target} has $(couch "${BASE}/$(urlencode "${target}")" | jq -r '.doc_count') document(s)"
}

main() {
  # A Railway start command such as "/usr/local/bin/couchdb-backup restore" arrives as
  # arguments of the entrypoint; drop the repeated program name.
  case "${1:-}" in */couchdb-backup | couchdb-backup) shift ;; esac
  local cmd="${1:-backup}"
  case "${cmd}" in
    backup)
      validate_settings
      configure_remote
      wait_for_couchdb
      run_backup
      prune
      log "done"
      ;;
    list)
      configure_remote
      show_runs
      ;;
    restore)
      validate_settings
      configure_remote
      wait_for_couchdb
      run_restore
      ;;
    *) die "unknown command '${cmd}' (use: backup, list, restore)" ;;
  esac
}

main "$@"
