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
# bucket has to be readable by anonymous visitors. "set download" also allows
# ListBucket, which would let anyone enumerate every client's photo keys, so
# grant GetObject only.
POLICY_FILE="$(mktemp)"
cat > "${POLICY_FILE}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": ["*"]},
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::${S3_BUCKET}/*"]
    }
  ]
}
JSON
mc anonymous set-json "${POLICY_FILE}" "picstome/${S3_BUCKET}" >/dev/null
rm -f "${POLICY_FILE}"

log "Bucket ${S3_BUCKET} is ready."
