#!/usr/bin/env bash
#
# Creates the Picstome bucket once MinIO is healthy.
# Runs under supervisord as a one-shot program (autorestart=false).
set -Eeuo pipefail

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER is required}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"

ENDPOINT="http://127.0.0.1:9000"

log() { printf '[minio-init] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

for _ in $(seq 1 90); do
    if curl -fsS "${ENDPOINT}/minio/health/live" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! curl -fsS "${ENDPOINT}/minio/health/live" >/dev/null 2>&1; then
    log "MinIO did not become healthy in time; giving up."
    exit 1
fi

mc alias set picstome "${ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null
mc mb --ignore-existing "picstome/${S3_BUCKET}" >/dev/null

# Picstome renders photos with plain object URLs (not presigned ones), so the
# bucket has to be readable by anonymous visitors. Gallery links are what make
# the objects discoverable; object keys contain ULIDs.
mc anonymous set download "picstome/${S3_BUCKET}" >/dev/null

log "Bucket ${S3_BUCKET} is ready."
