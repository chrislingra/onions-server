#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# setup-weaviate.sh -- Weaviate vector database stack
# Contains: Weaviate + multi2vec-clip
# Network:  traefik_web (for the INTERNAL route, not for publication)
# Internal: weaviate:8080 (HTTP) | weaviate:50051 (gRPC)
# External: NO access. On purpose.
#
# Call:  sudo /opt/<domain>/setup-weaviate.sh   (the domain is this directory's name)
#        --purge  discards stack AND data volume (the whole vector database)
#
# -----------------------------------------------------------------------------
# 2026-08-13 (v1025) -- two things, both important:
#
# 1. NO TRAEFIK PUBLICATION ANY MORE.
#    Since 2026-04-21 the stack carried labels offering weaviate.<domain> to the outside.
#    No DNS record ever existed for it, so no certificate ever came about -- the route was
#    dead, but Traefik kept trying to get one: 2117 failed attempts in one log alone. In
#    the end Let's Encrypt paused the whole account and took other names down with it.
#    The Toolserver speaks to Weaviate by container name (http://weaviate:8080, as its
#    connector says). A public name is not needed and is a security problem for a vector
#    database. traefik.enable=false now stands there explicitly -- not merely "no labels",
#    so nobody puts them back by accident.
#
# 2. A RE-RUN NO LONGER DELETES DATA.
#    The earlier version ran "docker compose down --remove-orphans --volumes" on every run
#    and then "docker volume rm" on everything called weaviate. That is not idempotence,
#    that is deletion followed by a rebuild: EVERY re-run would have destroyed the whole
#    vector database. Now a run brings the state in line: the compose file is backed up
#    and rewritten, "docker compose up -d" recreates the changed containers, the data
#    volume stays. Whoever really wants to discard everything calls it with --purge.
#
# 2026-09-25 (GAP-ENV-INSTALL-VOLLBETRIEB-01): the installer (onions-server step 7) runs
# this script on every new host, as root and without a terminal -- like the Verwalter does.
#   1. "usermod -aG docker ${SUDO_USER:-chris}" ended the run on any host without a user
#      chris (set -e). Group membership is the installer's business (step 3); here it is
#      only done for a SUDO_USER that exists.
#   2. The Toolserver of this host gets its connector 'Weaviate Local' with the API key
#      when it has none, and the catalogue marks Weaviate installed (toolserver-link.sh).
#      Until now the key had to be typed in by hand.
#   3. Texts in English, like the whole installer.
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOMAIN="$(basename "$SCRIPT_DIR")"
readonly BASE_DIR="/opt/weaviate"
readonly COMPOSE_FILE="${BASE_DIR}/docker-compose.weaviate.yml"
readonly CREDENTIALS_DIR="${BASE_DIR}/credentials"
readonly VOLUMES_DIR="${BASE_DIR}/volumes"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        *) echo "Unknown option: $arg (known: --purge)"; exit 1 ;;
    esac
done

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
    ts_connector_register()  { log_warn "toolserver-link.sh missing in ${SCRIPT_DIR} -- connector not registered."; }
    ts_catalogue_installed() { log_warn "toolserver-link.sh missing in ${SCRIPT_DIR} -- catalogue not updated."; }
fi

# =============================================================================
# API KEY (idempotent: only when there is none yet)
# Runs BEFORE everything else: a new key would make the connector in the Toolserver
# useless.
# =============================================================================
generate_api_key() {
    local keyfile="${CREDENTIALS_DIR}/.weaviate_api_key"
    if [ -f "$keyfile" ]; then
        WEAVIATE_API_KEY=$(cat "$keyfile")
        log_success "Existing API key loaded (unchanged)."
    else
        WEAVIATE_API_KEY=$(openssl rand -hex 32)
        mkdir -p "${CREDENTIALS_DIR}"
        echo "$WEAVIATE_API_KEY" > "$keyfile"
        chmod 600 "$keyfile"
        log_success "New API key generated."
    fi
}

# =============================================================================
# DISCARD EVERYTHING -- only when explicitly asked for
# =============================================================================
purge_stack() {
    log_warn "--purge: stack AND data volume are removed."
    log_warn "The whole vector database is gone afterwards. 10 seconds to cancel."
    sleep 10
    if [ -f "$COMPOSE_FILE" ]; then
        (cd "${BASE_DIR}" && \
            docker compose -f docker-compose.weaviate.yml down --remove-orphans --volumes) || true
    fi
    docker volume ls -q --filter "name=weaviate" | xargs -r docker volume rm 2>/dev/null || true
    rm -f "$COMPOSE_FILE"
    log_success "Removed completely."
}

# =============================================================================
# BACK UP THE COMPOSE FILE before it is overwritten
# =============================================================================
backup_compose() {
    if [ -f "$COMPOSE_FILE" ]; then
        local stamp
        stamp="$(date '+%Y%m%d-%H%M%S')"
        cp -p "$COMPOSE_FILE" "${COMPOSE_FILE}.${stamp}.bak"
        log_success "Previous compose file kept: $(basename "${COMPOSE_FILE}").${stamp}.bak"
    fi
}

create_dirs() {
    mkdir -p "${VOLUMES_DIR}/weaviate-data"
    mkdir -p "${CREDENTIALS_DIR}"
    log_success "Directory structure present."
}

# Container UIDs are fixed (project standard).
set_perms() {
    chown -R 1000:1000 "${VOLUMES_DIR}/weaviate-data"
    log_success "Container permissions set."
}

# Group access for the admins. The docker group is added only for a SUDO_USER that
# exists -- as root without sudo (installer, Verwalter) there is nobody to add.
set_project_permissions() {
    chmod -R g+rwX "${BASE_DIR}"
    if [ -d "${CREDENTIALS_DIR}" ]; then
        chmod 770 "${CREDENTIALS_DIR}"
        chmod 660 "${CREDENTIALS_DIR}"/* 2>/dev/null || true
        chmod 600 "${CREDENTIALS_DIR}/.weaviate_api_key" 2>/dev/null || true
    fi
    find "${BASE_DIR}" -maxdepth 1 -name "docker-compose*.yml" -exec chmod 664 {} \;
    local admin_user="${SUDO_USER:-}"
    if [ -n "$admin_user" ] && id "$admin_user" >/dev/null 2>&1 \
       && ! id -nG "$admin_user" | tr ' ' '\n' | grep -qx docker; then
        usermod -aG docker "$admin_user"
        log_warn "User '${admin_user}' added to the docker group -- log in again for it to apply."
    fi
    log_success "Permissions set."
}

# =============================================================================
# COMPOSE FILE
# =============================================================================
create_compose() {
    cat >"$COMPOSE_FILE" <<EOF
# =============================================================================
# Weaviate stack -- vector database with the CLIP multimodal module
# Internal: weaviate:8080 (HTTP) | weaviate:50051 (gRPC)
# CLIP:     multi2vec-clip:8080 (internal)
# External: NO access -- see traefik.enable=false below.
# =============================================================================
services:

  # ---------------------------------------------------------------------------
  # Weaviate -- vector database with hybrid search + multimodal
  # Reached only by container name in the network traefik_web:
  # http://weaviate:8080/v1/
  # Docs: https://weaviate.io/developers/weaviate
  # ---------------------------------------------------------------------------
  weaviate:
    image: cr.weaviate.io/semitechnologies/weaviate:1.36.5
    container_name: weaviate
    restart: always
    expose: ["8080", "50051"]
    volumes:
      - weaviate-data:/var/lib/weaviate
    # The network STAYS. Not for Traefik, but because the Toolserver reaches Weaviate
    # through it as "weaviate:8080". Without it the vector database is gone for the
    # Toolserver.
    networks: [traefik_web]
    environment:
      # Memory limit: Go runtime capped at 4 GB
      GOMEMLIMIT: "4GiB"
      LIMIT_RESOURCES: "false"
      PERSISTENCE_DATA_PATH: "/var/lib/weaviate"
      # Authentication: API key
      AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED: "false"
      AUTHENTICATION_APIKEY_ENABLED: "true"
      AUTHENTICATION_APIKEY_ALLOWED_KEYS: "${WEAVIATE_API_KEY}"
      AUTHENTICATION_APIKEY_USERS: "admin"
      AUTHORIZATION_ADMINLIST_ENABLED: "true"
      AUTHORIZATION_ADMINLIST_USERS: "admin"
      ENABLE_MODULES: "multi2vec-clip"
      # 2026-08-18 -- THE VARIABLE'S NAME CHANGED, AND WEAVIATE DOES NOT START WITHOUT IT.
      # Measured on 1.36.5: the container looped, logging every minute "init modules:
      # init module N (multi2vec-clip): init vectorizer: required variable
      # CLIP_INFERENCE_API is not set", then "modules didn't initialize" (fatal). Only
      # MULTI2VEC_CLIP_INFERENCE_API stood here; 1.36.5 wants CLIP_INFERENCE_API. BOTH
      # are set: one version reads one, the other the other, and neither minds the
      # extra. Cheaper than guessing at every version change -- and the outage was
      # expensive: without Weaviate the Toolserver's vector search is gone, silently.
      CLIP_INFERENCE_API: "http://multi2vec-clip:8080"
      MULTI2VEC_CLIP_INFERENCE_API: "http://multi2vec-clip:8080"
      CLUSTER_HOSTNAME: "node1"
      QUERY_DEFAULTS_LIMIT: "25"
      DISK_USE_WARNING_PERCENTAGE: "80"
      DISK_USE_READONLY_PERCENTAGE: "90"
    # NO PUBLICATION. Switched off explicitly instead of merely left out: an empty label
    # block invites filling it again. The former router labels requested certificates in
    # vain from April to August 2026 and finally got the Let's Encrypt account paused.
    labels:
      - "traefik.enable=false"
    healthcheck:
      # 2026-08-18 -- MEASURED, NOT GUESSED. "curl -sf ..." stood here. This image has
      # no curl: the tools found in the running container were wget (busybox) and nc;
      # curl and python3 are missing. The check could never succeed -- Weaviate ran,
      # answered the Toolserver with 200 on /v1/.well-known/ready and still stood on
      # "unhealthy" for good. A permanent warning hides the real one.
      # CMD instead of CMD-SHELL: no shell needed, and no nested quotes that writing
      # this file through the script could lose.
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/v1/.well-known/ready"]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 60s

  # ---------------------------------------------------------------------------
  # multi2vec-clip -- CLIP model for image and text embeddings
  # Internal: http://multi2vec-clip:8080
  # Model: ViT-B-32 (512 dimensions, CPU)
  # ---------------------------------------------------------------------------
  multi2vec-clip:
    image: cr.weaviate.io/semitechnologies/multi2vec-clip:sentence-transformers-clip-ViT-B-32
    container_name: multi2vec-clip
    restart: always
    expose: ["8080"]
    networks: [traefik_web]
    environment:
      ENABLE_CUDA: "0"
    labels:
      - "traefik.enable=false"
    healthcheck:
      # 2026-08-18 -- see Weaviate above. In THIS image it is the other way round:
      # python3 is there (the service runs on it), wget, curl, nc and busybox are not.
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/.well-known/ready')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

networks:
  traefik_web:
    external: true

volumes:
  weaviate-data: {}
EOF
    # BOM and CRLF out (project standard)
    sed -i 's/\r$//' "$COMPOSE_FILE"
    sed -i '1s/^\xEF\xBB\xBF//' "$COMPOSE_FILE"
    log_success "Compose file written (no publication)."
}

save_creds() {
    local credfile="${CREDENTIALS_DIR}/weaviate-endpoints.txt"
    cat >"$credfile" <<EOF
Weaviate -- endpoints
=====================
NO EXTERNAL ACCESS. Weaviate is deliberately not published; there is no host name and
no certificate for it.

Internal (Docker network traefik_web):
  HTTP:    http://weaviate:8080/v1/
  gRPC:    weaviate:50051
  Auth:    X-Weaviate-Api-Key -- the key is in ${CREDENTIALS_DIR}/.weaviate_api_key

CLIP module (internal):
  URL:     http://multi2vec-clip:8080
  Model:   ViT-B-32 (512 dimensions, CPU)

Check from a container in the same network:
  docker exec toolserver python3 -c "import urllib.request; \\
    print(urllib.request.urlopen('http://weaviate:8080/v1/.well-known/ready').status)"

In the Toolserver as connector 'Weaviate Local'
(Admin > Masterdata > Connectors > All Connectors).

Written: $(date '+%Y-%m-%d %H:%M')
EOF
    chmod 640 "$credfile"
    log_success "Endpoints written: ${credfile}"
}

# =============================================================================
# BRING THE STACK IN LINE + HEALTH CHECK
# No "down": "up -d" recreates exactly the containers whose configuration changed.
# Named volumes survive that.
# =============================================================================
start_stack() {
    log_info "Bringing the stack to the state above..."
    (cd "${BASE_DIR}" && docker compose -f docker-compose.weaviate.yml up -d)

    log_info "Waiting for the health check (max. 180s)..."
    local elapsed=0
    local interval=10
    while [ $elapsed -lt 180 ]; do
        sleep $interval
        elapsed=$((elapsed + interval))

        local weaviate_ok clip_status
        weaviate_ok=$(docker inspect --format='{{.State.Health.Status}}' weaviate 2>/dev/null || echo "missing")
        clip_status=$(docker inspect --format='{{.State.Health.Status}}' multi2vec-clip 2>/dev/null || echo "starting")

        log_info "  [${elapsed}s] weaviate=${weaviate_ok} | multi2vec-clip=${clip_status}"

        if [ "$weaviate_ok" = "healthy" ]; then
            log_success "Weaviate ready."
            if [ "$clip_status" = "healthy" ]; then
                log_success "multi2vec-clip ready."
            else
                log_warn "multi2vec-clip not healthy yet (start_period 120s) -- keeps starting."
            fi
            return 0
        fi
    done

    log_warn "Time exceeded -- container state:"
    docker compose -f "${COMPOSE_FILE}" ps
}

# =============================================================================
# PROOF: is the publication really gone and the internal route intact?
# Without this check the run would be a claim.
# =============================================================================
verify() {
    log_info "Proof..."
    if docker inspect weaviate 2>/dev/null | grep -q '"traefik.enable": "false"'; then
        log_success "Traefik: publication switched off."
    else
        log_error "Traefik label is NOT false -- please check."
    fi
    if docker inspect weaviate --format '{{range $n,$v := .NetworkSettings.Networks}}{{$n}} {{end}}' 2>/dev/null | grep -q traefik_web; then
        log_success "Network traefik_web: present (internal route intact)."
    else
        log_error "Network traefik_web MISSING -- the Toolserver no longer reaches Weaviate."
    fi
    if docker exec toolserver python3 -c \
        "import urllib.request; urllib.request.urlopen('http://weaviate:8080/v1/.well-known/ready', timeout=5)" 2>/dev/null; then
        log_success "The Toolserver reaches Weaviate at weaviate:8080."
    else
        log_warn "The Toolserver could not reach Weaviate -- is it running? In the same network?"
    fi
}

link_toolserver() {
    ts_connector_register weaviate "Weaviate Local" "http://weaviate:8080" "$WEAVIATE_API_KEY"
    ts_catalogue_installed weaviate
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        log_warn "This script must run as root: sudo $0"
        exit 1
    fi

    log_info "========================================================"
    log_info " Weaviate -- vector DB + CLIP"
    log_info " Domain: ${DOMAIN}   (internal only, no publication)"
    log_info "========================================================"

    generate_api_key
    if [ "$PURGE" -eq 1 ]; then
        purge_stack
    fi
    create_dirs
    set_perms
    backup_compose
    create_compose
    save_creds
    set_project_permissions
    start_stack
    verify
    link_toolserver

    log_success "========================================================"
    log_success " Weaviate ready -- internal only."
    log_success " Internal:  http://weaviate:8080/v1/"
    log_success " Endpoints: ${CREDENTIALS_DIR}/weaviate-endpoints.txt"
    log_success "========================================================"
}

main
