# Apache CouchDB 3.5 (single node) for Railway.
#
# Base: the official couchdb image (Debian trixie), pinned by tag and digest.
# Added: a start script that writes local.d/zz-railway.ini at every boot and
# then runs the image's own /docker-entrypoint.sh. Railway's init is PID 1, so
# the image's tini is not used.
#
# Upgrade: change the tag/digest to a newer 3.5.x release and redeploy.
FROM couchdb:3.5.3@sha256:0ba6b4b8dd823232185fa2c7de04634b925be62f97c9b7cbece7dd9119470e17

COPY --chmod=0755 railway-couchdb-start.sh /usr/local/bin/railway-couchdb-start
RUN bash -n /usr/local/bin/railway-couchdb-start \
 && test -x /docker-entrypoint.sh \
 && test -x /opt/couchdb/bin/couchdb

ENTRYPOINT ["/usr/local/bin/railway-couchdb-start"]
CMD []
