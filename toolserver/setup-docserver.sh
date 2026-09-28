#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# setup-docserver.sh -- document processing stack of the Toolserver
# Contains: Apache Tika (legacy formats: .doc, .xls, .ppt, .rtf, .epub),
#           Docling (text from PDF, DOCX, XLSX, PPTX, HTML, images),
#           Gotenberg (HTML/Office -> PDF, PDF merge/split)
# Network:  traefik_web, internal only -- no Traefik route, no public name
# Reached by the Toolserver by container name: tika:9998 | docling:5001 | gotenberg:3000
#           (docker-compose.toolserver.yml: DOCSERVER_TIKA_URL, DOCLING_URL, DOCSERVER_GOTENBERG_URL)
#
# Call:  sudo /opt/<domain>/setup-docserver.sh   (the domain is this directory's name)
#
# 2026-09-27 (GAP-ENV-KUNDE-WEITERE-DIENSTE-01): taken over from the setup script of the
# Onions server into the installer. Without it a new host had no Docling, and Knowledge
# read text formats only -- no PDF, no Office file. Operator 2026-09-25: "alle uebrigen
# container die wir brauchen fuer den Vollbetrieb bereits waehrend der
# terminalinstallation" -- step 7 runs it after Weaviate and Nextcloud; the Verwalter runs
# it again from Environment > Installation (job "setup").
# Changed against the original:
#   1. A re-run no longer tears the stack down ("docker compose down" + deleting the compose
#      file): the compose file is backed up and rewritten, "up -d" recreates what changed.
#   1a. The services are those of the stack that runs on the Onions server (Tika, Docling,
#      Gotenberg, read from its compose file on 2026-09-27). The old script still built a
#      PaddleOCR image; that container was decommissioned on 2026-09-17 and the Toolserver
#      has not called it since v1648 -- it is not built here.
#   2. No "usermod -aG docker" with a fixed fallback user: group membership is the installer's
#      business (step 3); here it is only done for a SUDO_USER that exists.
#   3. The catalogue of the Toolserver marks the docserver installed (toolserver-link.sh),
#      and sichern.sh is written (sicherung.sh): the settings and the compose file; the
#      model caches are left out, they are downloaded again.
#   4. Texts in English, like the whole installer.
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOMAIN="$(basename "$SCRIPT_DIR")"
readonly BASE_DIR="/opt/docserver"
readonly COMPOSE_FILE="${BASE_DIR}/docker-compose.docserver.yml"
readonly CREDENTIALS_DIR="${BASE_DIR}/credentials"
readonly VOLUMES_DIR="${BASE_DIR}/volumes"

INFO_COLOR='\033[1;36m'
SUCCESS_COLOR='\033[1;32m'
WARN_COLOR='\033[1;33m'
ERROR_COLOR='\033[1;31m'
NC='\033[0m'

log_info()    { echo -e "${INFO_COLOR}[INFO]${NC} $1"; }
log_success() { echo -e "${SUCCESS_COLOR}[OK]${NC} $1"; }
log_warn()    { echo -e "${WARN_COLOR}[WARN]${NC} $1"; }
log_error()   { echo -e "${ERROR_COLOR}[ERROR]${NC} $1"; }

# shellcheck source=toolserver-link.sh
if [[ -f "${SCRIPT_DIR}/toolserver-link.sh" ]]; then
    . "${SCRIPT_DIR}/toolserver-link.sh"
else
    ts_catalogue_installed() { log_warn "toolserver-link.sh missing in ${SCRIPT_DIR} -- catalogue not updated."; }
fi

check_prerequisites() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must run as root (sudo)."
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

create_dirs() {
    mkdir -p "${VOLUMES_DIR}"/{docling-models,gotenberg-fonts}
    mkdir -p "${CREDENTIALS_DIR}"
    chown -R 1000:1000 "${VOLUMES_DIR}"
    log_success "Directory structure present."
}

backup_compose() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        local stamp
        stamp="$(date '+%Y%m%d-%H%M%S')"
        cp -p "$COMPOSE_FILE" "${COMPOSE_FILE}.${stamp}.bak"
        log_success "Previous compose file kept: $(basename "$COMPOSE_FILE").${stamp}.bak"
    fi
}

create_compose() {
    cat > "$COMPOSE_FILE" <<EOF
# Docserver stack -- document processing, internal only (written by setup-docserver.sh)
# Toolserver access: tika:9998 | docling:5001 | gotenberg:3000
services:

  # Apache Tika -- legacy formats (.doc, .xls, .ppt, .rtf, .epub); disjoint with Docling.
  tika:
    image: apache/tika:latest
    container_name: tika
    restart: always
    networks: [traefik_web]
    expose: ["9998"]
    labels:
      - "traefik.enable=false"
    healthcheck:
      test: ["CMD", "bash", "-c", "(echo > /dev/tcp/localhost/9998) 2>/dev/null"]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 30s

  # Docling -- CPU only; idle ~700 MB, 2-4 GB per image-heavy PDF. One worker and two
  # threads keep a single document's memory bounded; 8 GB is the ceiling.
  docling:
    image: quay.io/docling-project/docling-serve-cpu:latest
    container_name: docling
    restart: always
    environment:
      DOCLING_SERVE_MAX_SYNC_WAIT: "600"
      DOCLING_SERVE_ENG_LOC_NUM_WORKERS: "1"
      DOCLING_NUM_THREADS: "2"
      OMP_NUM_THREADS: "2"
      MKL_NUM_THREADS: "2"
    deploy:
      resources:
        limits:
          memory: 8G
    volumes:
      - docling-models:/opt/app-root/src/.cache/docling
    networks: [traefik_web]
    expose: ["5001"]
    labels:
      - "traefik.enable=false"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:5001/health || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 60s

  gotenberg:
    image: gotenberg/gotenberg:8
    container_name: gotenberg
    restart: always
    networks: [traefik_web]
    expose: ["3000"]
    labels:
      - "traefik.enable=false"
    command:
      - gotenberg
      - --chromium-disable-javascript=true
      - --chromium-allow-list=file:///tmp/.*
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:3000/health || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 20s

networks:
  traefik_web:
    external: true

volumes:
  docling-models: {}
EOF
    sed -i '1s/^\xEF\xBB\xBF//; s/\r$//' "$COMPOSE_FILE"
    chmod 664 "$COMPOSE_FILE"
    log_success "Compose file written."
}

save_endpoints() {
    cat > "${CREDENTIALS_DIR}/docserver-endpoints.txt" <<EOF
Docserver -- internal endpoints
===============================
Reachable only inside the Docker network traefik_web (no public access).

Tika      : http://tika:9998       PUT /tika (binary body)
Docling   : http://docling:5001    POST /v1/convert/file/async, /v1/convert/source
Gotenberg : http://gotenberg:3000  POST /forms/chromium/convert/html, /forms/libreoffice/convert

Status: cd ${BASE_DIR} && docker compose -f docker-compose.docserver.yml ps
Written: $(date '+%Y-%m-%d %H:%M')
EOF
    chmod 640 "${CREDENTIALS_DIR}/docserver-endpoints.txt"
}

set_project_permissions() {
    local admin_user="${SUDO_USER:-}"
    chmod -R g+rwX "${BASE_DIR}"
    chmod 770 "${CREDENTIALS_DIR}"
    if [[ -n "$admin_user" && "$admin_user" != root ]] && id "$admin_user" >/dev/null 2>&1; then
        if ! id -nG "$admin_user" | grep -qw docker; then
            usermod -aG docker "$admin_user"
            log_warn "User '${admin_user}' added to the docker group -- log in again."
        fi
    fi
    log_success "Permissions set."
}

start_stack() {
    log_info "Bringing the stack to the state above (docker compose up -d) ..."
    (cd "${BASE_DIR}" && docker compose -f docker-compose.docserver.yml up -d --remove-orphans)

    log_info "Waiting for the health checks (at most 300 s) ..."
    local elapsed=0 tika_ok docling_ok gotenberg_ok
    while (( elapsed < 300 )); do
        sleep 10
        elapsed=$((elapsed + 10))
        tika_ok=$(docker inspect --format='{{.State.Health.Status}}' tika 2>/dev/null || echo "missing")
        docling_ok=$(docker inspect --format='{{.State.Health.Status}}' docling 2>/dev/null || echo "missing")
        gotenberg_ok=$(docker inspect --format='{{.State.Health.Status}}' gotenberg 2>/dev/null || echo "missing")
        log_info "  [${elapsed}s] tika=${tika_ok} | docling=${docling_ok} | gotenberg=${gotenberg_ok}"
        if [[ "$tika_ok" == healthy && "$docling_ok" == healthy && "$gotenberg_ok" == healthy ]]; then
            log_success "Tika, Docling and Gotenberg ready."
            return 0
        fi
    done
    log_error "Tika, Docling or Gotenberg did not become healthy within 300 s:"
    (cd "${BASE_DIR}" && docker compose -f docker-compose.docserver.yml ps)
    return 1
}

write_backup_script() {
    if [[ -f "${SCRIPT_DIR}/sicherung.sh" ]]; then
        # shellcheck source=sicherung.sh
        . "${SCRIPT_DIR}/sicherung.sh"
        backup_script_write "$BASE_DIR" "backup_run docserver ${BASE_DIR} /opt/backups/docserver/sicherung --exclude volumes"
    else
        log_warn "sicherung.sh missing in ${SCRIPT_DIR} -- no backup script written."
    fi
}

main() {
    log_info "========================================================"
    log_info " Docserver -- Tika / Docling / Gotenberg (internal only)"
    log_info " Domain: ${DOMAIN}"
    log_info "========================================================"
    check_prerequisites
    create_dirs
    backup_compose
    create_compose
    save_endpoints
    set_project_permissions
    start_stack
    ts_catalogue_installed docserver
    write_backup_script
    log_success "========================================================"
    log_success " Docserver ready. Knowledge reads PDF and Office files from now on."
    log_success "========================================================"
}

main
