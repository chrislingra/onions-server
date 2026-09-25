#!/bin/bash
# =============================================================================
# setup-nextcloud.sh -- Nextcloud + Collabora (Postgres, Redis) behind Traefik
#
# Call:  sudo /opt/<domain>/setup-nextcloud.sh   (the domain is this directory's name)
#
# Runs without a single question: from the installer (onions-server step 7), from the
# Verwalter (Environment > Installation, job "setup") or by hand. A second run brings the
# stack to the state written here and backs up the previous compose file first; data,
# database and users stay.
#
# 2026-09-25, GAP-ENV-INSTALL-VOLLBETRIEB-01 (operator: "alle mit einem Superadminkonto,
# das einheitlich ist und dessen kennwort in der Gui einmalig geaendert werden muss"):
#   1. No fixed password any more. Admin "manager" and the database password stood here
#      in plain text (GAP-INSTALL-PLAINTEXT-PW-01). The admin is now the platform's one
#      superadmin: login name admin, the password the Toolserver generated for its own
#      admin (/opt/toolserver/secrets/admin_password). Without a Toolserver one is
#      generated here. The database password is generated once and kept; an existing
#      installation keeps its own (read from config.php) -- Postgres reads it only when
#      the volume is created. Both live in credentials/db.env and credentials/admin.env
#      (mode 600), handed to the containers by env_file -- not in the compose file.
#   2. No read -p. "Update existing installation? (y/N)" stopped the Verwalter, which has
#      no terminal to answer from. A re-run always updates.
#   3. "docker compose" (v2 plugin) instead of docker-compose: a fresh host has only the
#      plugin (onions-server step 4).
#   4. No chown to "manager": the installer removes that user in its last step. The
#      directory belongs to root and the platform group onions (where it exists).
#   5. The Toolserver of this host gets its connector 'Nextcloud Primary' (admin, this
#      password) when it has none, and the catalogue marks Nextcloud installed
#      (toolserver-link.sh).
#   6. The admin name and password apply when Nextcloud installs itself on an empty
#      volume. On an existing installation the admin it already has stays as it is.
#   7. No self-registration (GAP-USR-KONTEN-NUR-IM-TOOLSERVER-01): every run disables the
#      apps that let an account come into being past the Toolserver (close_self_signup).
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOMAIN="$(basename "$SCRIPT_DIR")"
readonly BASE_DIR="/opt/nextcloud"
readonly COMPOSE_FILE="${BASE_DIR}/docker-compose.nextcloud.yml"
readonly CREDENTIALS_DIR="${BASE_DIR}/credentials"
readonly DB_ENV="${CREDENTIALS_DIR}/db.env"
readonly ADMIN_ENV="${CREDENTIALS_DIR}/admin.env"
readonly VOLUMES_DIR="${BASE_DIR}/volumes"
readonly LOG_FILE="${BASE_DIR}/setup.log"
readonly CONFIG_PHP="${VOLUMES_DIR}/nextcloud-data/config/config.php"

# The platform's one superadmin (see 1. above).
readonly ADMIN_USER="admin"
readonly SUPERADMIN_PW_FILE="/opt/toolserver/secrets/admin_password"
readonly DB_USER="nextcloud"
readonly DB_NAME="nextcloud"
readonly PLATFORM_GROUP="onions"
readonly WAIT_SECONDS=600

readonly INFO='\033[1;36m'
readonly SUCCESS='\033[1;32m'
readonly WARN='\033[1;33m'
readonly ERROR='\033[1;31m'
readonly NC='\033[0m'

log_info()    { echo -e "${INFO}[INFO]${NC} $1"; }
log_success() { echo -e "${SUCCESS}[OK]${NC} $1"; }
log_warn()    { echo -e "${WARN}[WARN]${NC} $1"; }
log_error()   { echo -e "${ERROR}[ERROR]${NC} $1"; }

# shellcheck source=toolserver-link.sh
if [[ -f "${SCRIPT_DIR}/toolserver-link.sh" ]]; then
    . "${SCRIPT_DIR}/toolserver-link.sh"
else
    ts_connector_register()  { log_warn "toolserver-link.sh missing in ${SCRIPT_DIR} -- connector not registered."; }
    ts_catalogue_installed() { log_warn "toolserver-link.sh missing in ${SCRIPT_DIR} -- catalogue not updated."; }
fi

check_prerequisites() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must run as root (sudo)."
        exit 1
    fi
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        log_error "Docker is not running."
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        log_error "The docker compose plugin is missing."
        exit 1
    fi
    if ! docker network ls --format '{{.Name}}' | grep -qx traefik_web; then
        log_error "Docker network 'traefik_web' not found -- Traefik comes first."
        exit 1
    fi
    log_success "Prerequisites met."
}

setup_directories() {
    mkdir -p "${CREDENTIALS_DIR}" "${VOLUMES_DIR}"/{nextcloud-data,postgres-data,redis-data}
    chmod 700 "${CREDENTIALS_DIR}"
    log_success "Directories present."
}

backup_compose() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        local stamp
        stamp="$(date '+%Y%m%d-%H%M%S')"
        cp -p "$COMPOSE_FILE" "${COMPOSE_FILE}.${stamp}.bak"
        log_success "Previous compose file kept: $(basename "$COMPOSE_FILE").${stamp}.bak"
    fi
}

# secret_once <file> -- the content of <file>; generated on first use, never replaced.
secret_once() {
    local file="$1"
    if [[ ! -s "$file" ]]; then
        (umask 077; openssl rand -hex 16 > "$file")
    fi
    chmod 600 "$file"
    cat "$file"
}

load_secrets() {
    # Admin: the platform's superadmin password, or one of our own without a Toolserver.
    if [[ -s "$SUPERADMIN_PW_FILE" ]]; then
        ADMIN_PASSWORD="$(cat "$SUPERADMIN_PW_FILE")"
        log_success "Admin: the platform superadmin (${ADMIN_USER}, password from ${SUPERADMIN_PW_FILE})."
    else
        ADMIN_PASSWORD="$(secret_once "${CREDENTIALS_DIR}/admin_password")"
        log_warn "No Toolserver password found -- Nextcloud's admin password is in ${CREDENTIALS_DIR}/admin_password."
    fi
    # Database: an existing installation keeps the password it runs with.
    local dbfile="${CREDENTIALS_DIR}/db_password" known=""
    if [[ ! -s "$dbfile" && -f "$CONFIG_PHP" ]]; then
        known="$(sed -n "s/.*'dbpassword' => '\(.*\)',.*/\1/p" "$CONFIG_PHP" | head -1)"
        if [[ -n "$known" ]]; then
            (umask 077; printf '%s' "$known" > "$dbfile")
            log_success "Database password taken over from the existing installation."
        fi
    fi
    DB_PASSWORD="$(secret_once "$dbfile")"
}

set_permissions() {
    chown -R 33:33 "${VOLUMES_DIR}/nextcloud-data"   # www-data
    chown -R 70:70 "${VOLUMES_DIR}/postgres-data"    # postgres (alpine)
    chmod 700 "${VOLUMES_DIR}/postgres-data"
    chown -R 999:999 "${VOLUMES_DIR}/redis-data"     # redis
    local grp=root
    getent group "$PLATFORM_GROUP" >/dev/null && grp="$PLATFORM_GROUP"
    chown root:"$grp" "$BASE_DIR" "$CREDENTIALS_DIR"
    log_success "Permissions set (directory root:${grp}, volumes by container user)."
}

# Two env files, each handed only to the containers that need it (env_file in the compose
# file). Not .env: compose would read that for its own variables, and on the Onions server
# a .env of other use already lies there.
create_env_files() {
    (umask 077
     printf '# setup-nextcloud.sh -- database password (nextcloud-db, nextcloud)\nPOSTGRES_PASSWORD=%s\n' \
         "$DB_PASSWORD" > "$DB_ENV"
     printf '# setup-nextcloud.sh -- admin password (nextcloud: first installation; collabora: its console)\nNEXTCLOUD_ADMIN_PASSWORD=%s\npassword=%s\n' \
         "$ADMIN_PASSWORD" "$ADMIN_PASSWORD" > "$ADMIN_ENV")
    chmod 600 "$DB_ENV" "$ADMIN_ENV"
    log_success "Secrets written to ${CREDENTIALS_DIR}/ (mode 600), none in the compose file."
}

create_compose_file() {
    cat > "$COMPOSE_FILE" <<EOF
services:
  nextcloud-db:
    image: postgres:16-alpine
    container_name: nextcloud_db
    restart: unless-stopped
    volumes:
      - ./volumes/postgres-data:/var/lib/postgresql/data
    networks: [traefik_web]
    env_file: [./credentials/db.env]
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  redis_nextcloud:
    image: redis:7-alpine
    container_name: redis_nextcloud
    restart: unless-stopped
    volumes:
      - ./volumes/redis-data:/data
    networks: [traefik_web]
    command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru --save 900 1

  nextcloud:
    image: nextcloud:stable
    container_name: nextcloud
    restart: unless-stopped
    volumes:
      - ./volumes/nextcloud-data:/var/www/html
    networks: [traefik_web]
    env_file: [./credentials/db.env, ./credentials/admin.env]
    environment:
      POSTGRES_HOST: nextcloud-db
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      NEXTCLOUD_ADMIN_USER: ${ADMIN_USER}
      NEXTCLOUD_TRUSTED_DOMAINS: nextcloud.${DOMAIN}
      REDIS_HOST: redis_nextcloud
      REDIS_HOST_PORT: 6379
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: nextcloud.${DOMAIN}
      OVERWRITECLIURL: https://nextcloud.${DOMAIN}
    depends_on: [nextcloud-db, redis_nextcloud]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/status.php"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nextcloud.rule=Host(\`nextcloud.${DOMAIN}\`)"
      - "traefik.http.routers.nextcloud.entrypoints=websecure"
      - "traefik.http.routers.nextcloud.tls.certresolver=http_resolver"
      - "traefik.http.services.nextcloud.loadbalancer.server.port=80"

  collabora:
    image: collabora/code:latest
    container_name: collabora_office
    restart: unless-stopped
    networks: [traefik_web]
    env_file: [./credentials/admin.env]
    environment:
      domain: nextcloud.${DOMAIN}
      username: ${ADMIN_USER}
      extra_params: --o:ssl.enable=false --o:ssl.termination=true
    cap_add: [MKNOD]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.collabora.rule=Host(\`office.${DOMAIN}\`)"
      - "traefik.http.routers.collabora.entrypoints=websecure"
      - "traefik.http.routers.collabora.tls.certresolver=http_resolver"
      - "traefik.http.services.collabora.loadbalancer.server.port=9980"

networks:
  traefik_web:
    external: true
EOF
    sed -i '1s/^\xEF\xBB\xBF//; s/\r$//' "$COMPOSE_FILE"
    chmod 640 "$COMPOSE_FILE"
    log_success "Compose file written (no secrets in it)."
}

save_endpoints() {
    # No password in here -- where they are is enough.
    cat > "${CREDENTIALS_DIR}/nextcloud-credentials.txt" <<EOF
Nextcloud -- endpoints
======================
Nextcloud:        https://nextcloud.${DOMAIN}
Collabora Office: https://office.${DOMAIN}

Admin:            ${ADMIN_USER} (when Nextcloud installed itself here; an older installation keeps its own)
Admin password:   the platform superadmin's -- ${SUPERADMIN_PW_FILE}, or ${CREDENTIALS_DIR}/admin_password without a Toolserver
Database:         ${DB_NAME}, user ${DB_USER}, password in ${CREDENTIALS_DIR}/db_password
Secrets for compose: ${DB_ENV}, ${ADMIN_ENV}

Status: cd ${BASE_DIR} && docker compose -f docker-compose.nextcloud.yml ps
Logs:   docker logs -f nextcloud
Written: $(date '+%Y-%m-%d %H:%M')
EOF
    chmod 600 "${CREDENTIALS_DIR}/nextcloud-credentials.txt"
}

start_stack() {
    log_info "Bringing the stack to the state above (docker compose up -d)..."
    (cd "$BASE_DIR" && docker compose -f docker-compose.nextcloud.yml up -d)
}

# Ready means installed, not merely answering: status.php answers long before the first
# installation has finished.
wait_for_nextcloud() {
    log_info "Waiting until Nextcloud is installed and answers (first start: several minutes)..."
    local waited=0
    while (( waited < WAIT_SECONDS )); do
        if docker exec nextcloud curl -sf http://localhost/status.php 2>/dev/null | grep -q '"installed":true'; then
            echo
            log_success "Nextcloud is installed and answers."
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
        echo -n "."
    done
    echo
    log_error "Nextcloud did not finish within ${WAIT_SECONDS}s -- see: docker logs nextcloud"
    return 1
}

# Accounts come from the Toolserver only (operator 2026-09-25: "Nextcloudkonten werden im
# toolserver angelegt nicht in nextcloud"; GAP-USR-KONTEN-NUR-IM-TOOLSERVER-01). Nextcloud
# ships without self-registration; these apps would add it -- a visitor's own sign-up
# (registration) or accounts born from a share (guests). Whoever enabled one is overruled on
# every run. The Toolserver's user list names any account it did not create.
readonly SELF_SIGNUP_APPS=(registration guests)
close_self_signup() {
    local app enabled
    enabled="$(docker exec -u www-data nextcloud php occ app:list --enabled 2>/dev/null || true)"
    for app in "${SELF_SIGNUP_APPS[@]}"; do
        if grep -q "^  - ${app}:" <<<"$enabled"; then
            docker exec -u www-data nextcloud php occ app:disable "$app" >/dev/null
            log_success "App '${app}' disabled."
        fi
    done
    log_success "No self-registration: accounts are created in the Toolserver only."
}

link_toolserver() {
    ts_connector_register nextcloud "Nextcloud Primary" "https://nextcloud.${DOMAIN}" "$ADMIN_PASSWORD" \
        "{\"base_url\": \"https://nextcloud.${DOMAIN}\", \"username\": \"${ADMIN_USER}\"}"
    ts_catalogue_installed nextcloud
}

main() {
    mkdir -p "$BASE_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "=================================================================="
    log_info " Nextcloud + Collabora -- https://nextcloud.${DOMAIN}"
    log_info " Target: ${BASE_DIR}   Started: $(date '+%Y-%m-%d %H:%M')"
    log_info "=================================================================="
    check_prerequisites
    setup_directories
    load_secrets
    backup_compose
    set_permissions
    create_env_files
    create_compose_file
    save_endpoints
    start_stack
    wait_for_nextcloud
    close_self_signup
    link_toolserver
    echo
    log_success "Nextcloud ready: https://nextcloud.${DOMAIN}   Collabora: https://office.${DOMAIN}"
    log_info "Login: ${ADMIN_USER} with the platform superadmin's password (on a new installation)."
    log_info "Collabora is not connected to Nextcloud yet: in Nextcloud, Apps > Nextcloud Office, then"
    log_info "  Administration settings > Office > URL https://office.${DOMAIN}"
}

main "$@"
