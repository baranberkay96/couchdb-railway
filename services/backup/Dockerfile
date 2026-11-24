# CouchDB Backup (Railway cron job): couchbackup/couchrestore (Apache-2.0, pinned
# npm release) on Node 24 Alpine, zstd, jq, curl, and rclone from the official image.
FROM rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466 AS rclone

FROM node:24.22.3-alpine3.24@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5

ARG COUCHBACKUP_VERSION=2.11.21

RUN apk add --no-cache bash coreutils ca-certificates curl jq zstd \
 && npm install --global --omit=dev --ignore-scripts "@cloudant/couchbackup@${COUCHBACKUP_VERSION}" \
 && npm cache clean --force

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --chmod=0755 couchdb-backup.sh /usr/local/bin/couchdb-backup

ENV HOME=/tmp \
    NODE_ENV=production

RUN couchbackup --version \
 && couchrestore --version \
 && rclone version >/dev/null \
 && zstd --version >/dev/null \
 && jq --version >/dev/null \
 && date -u -d @0 +%Y >/dev/null \
 && bash -n /usr/local/bin/couchdb-backup

USER node
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/couchdb-backup"]
CMD ["backup"]
