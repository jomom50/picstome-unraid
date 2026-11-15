#!/usr/bin/env bash
#
# Picstome container entrypoint.
#
# Everything persistent lives under /data so a single Unraid appdata mapping
# captures the database, object storage, application storage and secrets.
set -Eeuo pipefail

APP_DIR="/var/www/html"
DATA_DIR="/data"

log()  { printf '[picstome] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

gen_secret() {
    php -r 'echo substr(str_replace(["+", "/", "="], "", base64_encode(random_bytes(64))), 0, (int) ($argv[1] ?? 32));' "${1:-32}"
}

# "10G" -> kilobytes, because Livewire's file rule is expressed in KB.
size_to_kb() {
    local value="${1:-}" number unit
    number="$(printf '%s' "${value}" | tr -cd '0-9')"
    unit="$(printf '%s' "${value}" | tr -cd 'a-zA-Z' | tr '[:lower:]' '[:upper:]')"

    [ -n "${number}" ] || { printf '5242880'; return 0; }

    case "${unit}" in
        G|GB) printf '%s' "$((number * 1024 * 1024))" ;;
        M|MB) printf '%s' "$((number * 1024))" ;;
        K|KB) printf '%s' "${number}" ;;
        *)    printf '%s' "$((number / 1024))" ;;
    esac
}

# PHP CLI runs as www-data so SQLite WAL files and the compiled caches keep the
# same ownership as the web process.
as_app_user() {
    setpriv --reuid=www-data --regid=www-data --init-groups -- env HOME=/tmp "$@"
}

# ---------------------------------------------------------------------------
# Defaults. Every value can be overridden from the container environment.
# ---------------------------------------------------------------------------
export APP_NAME="${APP_NAME:-Picstome}"
export APP_ENV="${APP_ENV:-production}"
export APP_DEBUG="${APP_DEBUG:-false}"
export APP_TIMEZONE="${APP_TIMEZONE:-UTC}"
export APP_LOCALE="${APP_LOCALE:-en}"
export APP_FALLBACK_LOCALE="${APP_FALLBACK_LOCALE:-en}"
export APP_URL="${APP_URL:-http://localhost}"

export LOG_CHANNEL="${LOG_CHANNEL:-stack}"
export LOG_STACK="${LOG_STACK:-single}"
export LOG_LEVEL="${LOG_LEVEL:-warning}"

export DB_CONNECTION="${DB_CONNECTION:-sqlite}"
export DB_DATABASE="${DB_DATABASE:-${DATA_DIR}/database.sqlite}"
export DB_FOREIGN_KEYS="${DB_FOREIGN_KEYS:-true}"

export SESSION_DRIVER="${SESSION_DRIVER:-database}"
export SESSION_LIFETIME="${SESSION_LIFETIME:-120}"
export CACHE_STORE="${CACHE_STORE:-database}"
export QUEUE_CONNECTION="${QUEUE_CONNECTION:-database}"
export DB_QUEUE_RETRY_AFTER="${DB_QUEUE_RETRY_AFTER:-3900}"
export FILESYSTEM_DISK="${FILESYSTEM_DISK:-local}"
export LIVEWIRE_TEMPORARY_FILE_UPLOAD_DISK="${LIVEWIRE_TEMPORARY_FILE_UPLOAD_DISK:-local}"

export S3_BUCKET="${S3_BUCKET:-picstome}"
export S3_REGION="${S3_REGION:-us-east-1}"

# This URL carries the S3 API calls as well as the links shown to browsers, so
# the container must be able to reach it itself. Left unset the entrypoint used
# to abort under "set -u"; fall back to the bundled MinIO so the container still
# boots, and say so loudly because browsers cannot use 127.0.0.1.
if [ -z "${PICSTOME_PHOTOS_URL:-}" ]; then
    echo "WARN: PICSTOME_PHOTOS_URL is not set. Falling back to http://127.0.0.1:9000." >&2
    echo "WARN: Set it to the address clients and this container both use for port 9000," >&2
    echo "WARN: for example http://192.168.1.10:9000." >&2
    PICSTOME_PHOTOS_URL="http://127.0.0.1:9000"
fi
export PICSTOME_PHOTOS_URL="${PICSTOME_PHOTOS_URL%/}"

# Photos are served straight from your own object store by default. The other
# mode proxies every image through wsrv.nl, a public service that cannot reach
# an address only your LAN can see, which shows up as broken images in the
# lightbox while the grid still works.
export PICSTOME_PHOTO_CDN_DOMAIN="${PICSTOME_PHOTO_CDN_DOMAIN:-bunny}"

# Gallery grid thumbnails are generated at this size. The upstream 500 px look
# soft on a large or high-density screen, so match the 1000 px lightbox size.
export PICSTOME_PHOTO_SMALL_THUMB_RESIZE="${PICSTOME_PHOTO_SMALL_THUMB_RESIZE:-1000}"
export AUTO_MIGRATE="${AUTO_MIGRATE:-true}"

export UPLOAD_MAX_SIZE="${UPLOAD_MAX_SIZE:-512M}"
# Incoming files are buffered here before processing. It has to live on the
# persistent volume: /tmp is the container layer, and a multi-gigabyte upload
# there can fill the Docker image on the host.
export UPLOAD_TMP_DIR="${UPLOAD_TMP_DIR:-${DATA_DIR}/tmp}"
# Livewire's own rule for temporary uploads is in kilobytes, so follow the
# configured limit instead of silently capping uploads at 5 GiB.
export LIVEWIRE_TEMPORARY_FILE_UPLOAD_MAX_KB="${LIVEWIRE_TEMPORARY_FILE_UPLOAD_MAX_KB:-$(size_to_kb "${UPLOAD_MAX_SIZE}")}"
export PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-512M}"
export PHP_MAX_EXECUTION_TIME="${PHP_MAX_EXECUTION_TIME:-300}"
# Hard ceiling php-fpm puts on a single request; big uploads need the room.
export PHP_REQUEST_TIMEOUT="${PHP_REQUEST_TIMEOUT:-1800}"
export QUEUE_WORKER_TIMEOUT="${QUEUE_WORKER_TIMEOUT:-3700}"
export QUEUE_WORKER_TRIES="${QUEUE_WORKER_TRIES:-1}"

export TRUSTED_PROXIES="${TRUSTED_PROXIES:-}"

# Picstome grants the /admin screens (queue, stats, emails, translations) and
# the admin-only Sync feature through this list, not through a database role.
# The first admin account is created from PICSTOME_ADMIN_EMAIL below, so treat
# that address as an admin unless a list was provided explicitly. This has to be
# exported before the configuration is cached, because config/picstome.php
# reads it when the cache is built.
export PICSTOME_ADMIN_EMAILS="${PICSTOME_ADMIN_EMAILS:-${PICSTOME_ADMIN_EMAIL:-}}"

# Outgoing mail is sent "from" the admin address unless one is configured. Left
# unset the framework falls back to hello@example.com, which most providers
# reject, so the template's "leave empty to use the admin email" would be a lie.
if [ -z "${MAIL_FROM_ADDRESS:-}" ] && [ -n "${PICSTOME_ADMIN_EMAIL:-}" ]; then
    export MAIL_FROM_ADDRESS="${PICSTOME_ADMIN_EMAIL}"
fi

# The configured admin is the operator of a self-hosted install, so their team
# is kept off the hosted free plan (1 GB, one contract and one invoice a month).
# Set to false to let the admin keep the free plan like any other account.
export PICSTOME_ADMIN_UNLIMITED="${PICSTOME_ADMIN_UNLIMITED:-true}"

if [ -z "${PICSTOME_PHOTOS_URL}" ]; then
    export PICSTOME_PHOTOS_URL="http://127.0.0.1:9000"
    warn "PICSTOME_PHOTOS_URL is not set. Photos will only resolve inside the container."
fi

# Behind a TLS-terminating proxy the app must believe the request is HTTPS,
# otherwise asset and share links are generated as http:// and get blocked.
if [ -z "${FORCE_HTTPS:-}" ]; then
    case "${APP_URL}" in
        https://*) FORCE_HTTPS="true" ;;
        *) FORCE_HTTPS="false" ;;
    esac
fi

export FORCE_HTTPS

if [ "${FORCE_HTTPS}" = "true" ]; then
    export HTTPS_VALUE="on"
    export SERVER_PORT_VALUE="443"
    export SESSION_SECURE_COOKIE="${SESSION_SECURE_COOKIE:-true}"
else
    export HTTPS_VALUE="off"
    export SERVER_PORT_VALUE="80"
fi

# ---------------------------------------------------------------------------
# Persistent layout
# ---------------------------------------------------------------------------
mkdir -p "${DATA_DIR}/minio" "${DATA_DIR}/storage" "${DATA_DIR}/logs" "${UPLOAD_TMP_DIR}"
mkdir -p \
    "${DATA_DIR}/storage/app/private" \
    "${DATA_DIR}/storage/app/public" \
    "${DATA_DIR}/storage/framework/cache/data" \
    "${DATA_DIR}/storage/framework/sessions" \
    "${DATA_DIR}/storage/framework/views" \
    "${DATA_DIR}/storage/logs"

if [ -L "${APP_DIR}/storage" ] || [ -d "${APP_DIR}/storage" ]; then
    rm -rf "${APP_DIR}/storage"
fi
ln -sfn "${DATA_DIR}/storage" "${APP_DIR}/storage"
mkdir -p "${APP_DIR}/bootstrap/cache"

log "Using ${DATA_DIR} for database, photos and application storage."

# ---------------------------------------------------------------------------
# Application key (generated once, then reused across restarts)
# ---------------------------------------------------------------------------
if [ -n "${APP_KEY:-}" ]; then
    :
elif [ -s "${DATA_DIR}/app.key" ]; then
    APP_KEY="$(cat "${DATA_DIR}/app.key")"
else
    APP_KEY="base64:$(php -r 'echo base64_encode(random_bytes(32));')"
    printf '%s' "${APP_KEY}" > "${DATA_DIR}/app.key"
    chmod 600 "${DATA_DIR}/app.key"
    log "Generated a new APP_KEY and stored it in ${DATA_DIR}/app.key."
fi
export APP_KEY

# Laravel reads the .env file before the container environment, so this only
# carries the key; every other setting comes from the container environment.
umask 0077
printf 'APP_KEY=%s\n' "${APP_KEY}" > "${APP_DIR}/.env"
umask 0022

# ---------------------------------------------------------------------------
# MinIO credentials (generated once, then reused)
# ---------------------------------------------------------------------------
CREDENTIALS_FILE="${DATA_DIR}/s3-credentials"
if [ -s "${CREDENTIALS_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${CREDENTIALS_FILE}"
else
    MINIO_ROOT_USER="picstome$(gen_secret 10 | tr '[:upper:]' '[:lower:]')"
    MINIO_ROOT_PASSWORD="$(gen_secret 40)"
    {
        printf 'MINIO_ROOT_USER=%s\n' "${MINIO_ROOT_USER}"
        printf 'MINIO_ROOT_PASSWORD=%s\n' "${MINIO_ROOT_PASSWORD}"
    } > "${CREDENTIALS_FILE}"
    chmod 600 "${CREDENTIALS_FILE}"
    log "Generated S3 credentials for the bundled object store."
fi
export MINIO_ROOT_USER MINIO_ROOT_PASSWORD

export AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}"
export AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}"
export AWS_DEFAULT_REGION="${S3_REGION}"
export AWS_BUCKET="${S3_BUCKET}"
export AWS_ENDPOINT="${PICSTOME_PHOTOS_URL}"
export AWS_URL="${PICSTOME_PHOTOS_URL}/${S3_BUCKET}"
export AWS_USE_PATH_STYLE_ENDPOINT="true"

# ---------------------------------------------------------------------------
# nginx + PHP configuration
# ---------------------------------------------------------------------------
mkdir -p /etc/nginx/conf.d

# The app sends guests from / to the login screen. LANDING_REDIRECT is read by
# the patched home route (patches/0002-landing-redirect.patch) and sends them to
# a public page instead, while signed-in visitors still get the dashboard. It
# must be in the environment when the config cache is built below, because
# config/app.php reads it at that point.
if [ -n "${LANDING_REDIRECT:-}" ]; then
    case "${LANDING_REDIRECT}" in
        /* | http://* | https://*) : ;;
        *)
            warn "LANDING_REDIRECT must start with / or http(s)://; ignoring '${LANDING_REDIRECT}'."
            unset LANDING_REDIRECT
            ;;
    esac
fi
export LANDING_REDIRECT="${LANDING_REDIRECT:-}"
if [ -n "${LANDING_REDIRECT}" ]; then
    log "Guests landing on / will be sent to ${LANDING_REDIRECT}."
fi

envsubst '${UPLOAD_MAX_SIZE} ${HTTPS_VALUE} ${SERVER_PORT_VALUE}' \
    < /etc/nginx/templates/picstome.conf.template \
    > /etc/nginx/conf.d/picstome.conf
rm -f /etc/nginx/sites-enabled/default

cat > /usr/local/etc/php/conf.d/zz-picstome.ini <<PHPINI
upload_max_filesize = ${UPLOAD_MAX_SIZE}
post_max_size = ${UPLOAD_MAX_SIZE}
upload_tmp_dir = ${UPLOAD_TMP_DIR}
memory_limit = ${PHP_MEMORY_LIMIT}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
max_input_time = ${PHP_REQUEST_TIMEOUT}
date.timezone = ${APP_TIMEZONE}
expose_php = Off
PHPINI

# php-fpm terminates a request that runs longer than this, which a slow upload
# of a large file will hit.
sed -i "s/^request_terminate_timeout = .*/request_terminate_timeout = ${PHP_REQUEST_TIMEOUT}/" \
    /usr/local/etc/php-fpm.d/zz-picstome.conf

touch "${DB_DATABASE}"
chown www-data:www-data "${DATA_DIR}" "${DB_DATABASE}" 2>/dev/null || true
chown -R www-data:www-data "${DATA_DIR}/storage" "${UPLOAD_TMP_DIR}" 2>/dev/null || true
chown -R www-data:www-data "${APP_DIR}/bootstrap/cache" 2>/dev/null || true
chown www-data:www-data "${APP_DIR}/.env" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
if [ "${AUTO_MIGRATE}" = "true" ]; then
    log "Running database migrations."
    as_app_user php artisan migrate --force --no-interaction || die "Database migrations failed."
fi

if [ ! -e "${APP_DIR}/public/storage" ]; then
    php artisan storage:link --no-interaction >/dev/null 2>&1 || warn "Could not create the public storage link."
fi

# ---------------------------------------------------------------------------
# First admin account
# ---------------------------------------------------------------------------
if [ -n "${PICSTOME_ADMIN_EMAIL:-}" ]; then
    # A missing password is only a problem when the account still has to be
    # created; docker/first-run.php generates and stores one in that case, so an
    # existing install that simply relies on its saved password stays quiet.
    export PICSTOME_ADMIN_PASSWORD="${PICSTOME_ADMIN_PASSWORD:-}"
    as_app_user php artisan tinker --execute="require '/usr/local/share/picstome/first-run.php';" \
        || warn "First-run admin bootstrap failed; register an account in the web UI instead."
else
    warn "PICSTOME_ADMIN_EMAIL is not set; no admin account will be created."
fi

# ---------------------------------------------------------------------------
# Caches
# ---------------------------------------------------------------------------
as_app_user php artisan config:clear >/dev/null 2>&1 || true
as_app_user php artisan config:cache >/dev/null 2>&1 || warn "Could not cache the configuration."
as_app_user php artisan view:cache >/dev/null 2>&1 || warn "Could not cache the Blade views."

# ---------------------------------------------------------------------------
# Photo storage reachability
# ---------------------------------------------------------------------------
# PICSTOME_PHOTOS_URL carries the app's own S3 calls, not just the links shown
# to browsers, and the S3 disk is configured not to throw. A URL this container
# cannot reach therefore fails every upload silently. Probe it in the
# background so the first screen of `docker logs` says so instead.
(
    sleep 20
    probe="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "${AWS_URL}/" 2>/dev/null || true)"
    code="${probe%% *}"
    redirect="${probe#* }"

    if [ -z "${code}" ] || [ "${code}" = "000" ]; then
        warn "Cannot reach ${PICSTOME_PHOTOS_URL} from inside this container, so uploads will fail."
        warn "Use an address the container itself can resolve, or add --add-host <host>:<lan-ip>."
    elif [ -n "${redirect}" ] && [ "${redirect}" != "${probe}" ] && [ "${redirect}" != "${AWS_URL}/" ]; then
        # A proxy that redirects http to https turns a signed PUT into a GET, and
        # the SDK reports the follow-up lookup as NoSuchKey instead of the cause.
        warn "${PICSTOME_PHOTOS_URL} redirects to ${redirect%"${S3_BUCKET}"*/}, so S3 writes fail."
        warn "Set the Photo Storage URL to that address (usually the https one) and restart."
    fi
) &

log "Starting services (web, php-fpm, queue worker, scheduler, object storage)."
exec "$@"
