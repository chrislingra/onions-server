#!/usr/bin/env bash
# =============================================================================
# setup-toolserver.sh — Toolserver Fresh Installation
# Sprint 117: G-131 Installation Guide Rebuild
#
# For: Ubuntu 22.04+ / Debian 12+ (x86_64)
# Requires: root or sudo access, internet connection
#
# What this does:
#   Phase 1: Install Docker + Docker Compose (if missing)
#   Phase 2: Create Traefik reverse proxy (if missing)
#   Phase 3: Create /opt/toolserver directory structure
#   Phase 4: Generate all secrets (G-130 compliant)
#   Phase 5: Create .env with domain config and, since v1524, the memory
#            sizes of both containers derived from the host (/proc/meminfo)
#   Phase 6: Create every network the compose file declares external, start
#            PostgreSQL + Toolserver containers (v1503)
#   Phase 7: Structure, tenants, seed (one transaction), platform project and
#            languages, env section, then the pending patches (v1504)
#   Phase 8: Create superadmin user with the standard printed password,
#            retried against a container that may still be starting (v1505, v1507)
#
# Where this script lives (2026-09-19): the Toolserver repository carries no setup
# script any more ("scripts/setup-*.sh darf es nicht geben", operator 2026-09-18);
# every setup script lives in /opt/<domain>. Because this one must run BEFORE a
# Toolserver exists, the base installer onions-server carries it
# (toolserver/setup-toolserver.sh) and its step 7 places it into /opt/<domain>/
# and runs it from there. On a running host the copy in /opt/<domain>/ is the one
# the Toolserver maintains (deploy_write); both must stay identical.
#
# Usage:
#   sudo bash setup-toolserver.sh --domain yourdomain.com
#
# After setup:
#   https://tools.yourdomain.com/menu  (login with menu password)
#   https://tools.yourdomain.com/app   (Knowledge module)
#
# Prerequisites:
#   - DNS A-record: tools.yourdomain.com → server IP
#   - Ports 80 + 443 open (for Let's Encrypt + Traefik)
#   - Toolserver codebase in current directory or specified via --source
# =============================================================================
set -euo pipefail

VERSION="1.0.0"
INSTALL_DIR="/opt/toolserver"
TRAEFIK_DIR="/opt/traefik"
DOMAIN=""
SOURCE_DIR=""
MENU_PASSWORD=""
SKIP_TRAEFIK=false
SKIP_DOCKER=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC}    $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC}  $1"; }
phase(){ echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  Phase $1: $2${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: sudo bash setup-toolserver.sh --domain DOMAIN [options]"
    echo ""
    echo "Required:"
    echo "  --domain DOMAIN        Domain name (e.g. onions.one → tools.onions.one)"
    echo ""
    echo "Optional:"
    echo "  --source DIR           Source directory with Toolserver codebase (default: current dir)"
    echo "  --install-dir DIR      Installation directory (default: /opt/toolserver)"
    echo "  --menu-password PW     Set menu login password (default: auto-generated)"
    echo "  --skip-traefik         Skip Traefik setup (already running)"
    echo "  --skip-docker          Skip Docker installation (already installed)"
    echo "  --dry-run              Show what would be done without executing"
    echo "  --help                 Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)          DOMAIN="$2";         shift 2;;
        --source)          SOURCE_DIR="$2";     shift 2;;
        --install-dir)     INSTALL_DIR="$2";    shift 2;;
        --menu-password)   MENU_PASSWORD="$2";  shift 2;;
        --skip-traefik)    SKIP_TRAEFIK=true;   shift;;
        --skip-docker)     SKIP_DOCKER=true;    shift;;
        --dry-run)         DRY_RUN=true;        shift;;
        --help|-h)         usage;;
        *)                 err "Unknown option: $1"; usage;;
    esac
done

if [ -z "$DOMAIN" ]; then
    err "--domain is required"
    usage
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║       onions.one AI Toolserver — Fresh Installation          ║"
echo "║       Version: $VERSION                                          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
info "Domain:      $DOMAIN"
info "Tools URL:   https://tools.${DOMAIN}"
info "Install dir: $INSTALL_DIR"
info "Source:      ${SOURCE_DIR:-'(current directory)'}"
echo ""

# Root check
if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = false ]; then
    err "This script must be run as root (sudo)"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════
# Phase 1: Docker + Docker Compose
# ═══════════════════════════════════════════════════════════════
phase 1 "Docker + Docker Compose"

if [ "$SKIP_DOCKER" = true ]; then
    info "Skipped (--skip-docker)"
elif command -v docker &>/dev/null && docker compose version &>/dev/null; then
    log "Docker already installed: $(docker --version)"
    log "Compose: $(docker compose version)"
else
    info "Installing Docker..."
    if [ "$DRY_RUN" = false ]; then
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg lsb-release

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

        systemctl enable docker
        systemctl start docker
        log "Docker installed: $(docker --version)"
    else
        info "[DRY RUN] Would install Docker"
    fi
fi

# ═══════════════════════════════════════════════════════════════
# Phase 2: Traefik Reverse Proxy
# ═══════════════════════════════════════════════════════════════
phase 2 "Traefik Reverse Proxy"

if [ "$SKIP_TRAEFIK" = true ]; then
    info "Skipped (--skip-traefik)"
elif docker network ls | grep -q traefik_web; then
    log "traefik_web network exists"
    if docker ps --format '{{.Names}}' | grep -q traefik; then
        log "Traefik container running"
    else
        warn "traefik_web network exists but no Traefik container running"
        warn "Start Traefik manually or pass --skip-traefik"
    fi
else
    info "Setting up Traefik..."
    if [ "$DRY_RUN" = false ]; then
        docker network create traefik_web || true
        mkdir -p "$TRAEFIK_DIR"

        cat > "$TRAEFIK_DIR/docker-compose.yml" << TRAEFIK_EOF
services:
  traefik:
    image: traefik:v3.1
    container_name: traefik
    restart: unless-stopped
    command:
      - "--api.dashboard=false"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=traefik_web"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.http_resolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.http_resolver.acme.email=admin@${DOMAIN}"
      - "--certificatesresolvers.http_resolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
    networks: [traefik_web]

networks:
  traefik_web:
    external: true
TRAEFIK_EOF

        mkdir -p "$TRAEFIK_DIR/letsencrypt"
        cd "$TRAEFIK_DIR"
        docker compose up -d
        log "Traefik started"
    else
        info "[DRY RUN] Would create Traefik at $TRAEFIK_DIR"
    fi
fi

# ═══════════════════════════════════════════════════════════════
# Phase 3: Directory Structure
# ═══════════════════════════════════════════════════════════════
phase 3 "Directory Structure"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$INSTALL_DIR"/{secrets,volumes/pg-data,db/patches,scripts,static/screens,exports,xdoc}
    mkdir -p "$INSTALL_DIR"/{knowledge,admin,workspace,governance,customers,environment,core,services,routers,skills,installation}
    chmod 700 "$INSTALL_DIR/secrets"
    log "Directory structure created at $INSTALL_DIR"
else
    info "[DRY RUN] Would create directory structure at $INSTALL_DIR"
fi

# Copy codebase if source specified
if [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
    if [ "$DRY_RUN" = false ]; then
        info "Copying codebase from $SOURCE_DIR..."
        rsync -a --exclude='volumes/' --exclude='secrets/' --exclude='.env' \
            --exclude='__pycache__' --exclude='*.pyc' \
            "$SOURCE_DIR/" "$INSTALL_DIR/"
        log "Codebase copied"
    else
        info "[DRY RUN] Would copy codebase from $SOURCE_DIR"
    fi
elif [ -f "./main.py" ] && [ -f "./requirements.txt" ]; then
    if [ "$DRY_RUN" = false ]; then
        if [ "$(pwd)" != "$INSTALL_DIR" ]; then
            info "Copying codebase from current directory..."
            rsync -a --exclude='volumes/' --exclude='secrets/' --exclude='.env' \
                --exclude='__pycache__' --exclude='*.pyc' \
                "./" "$INSTALL_DIR/"
            log "Codebase copied from $(pwd)"
        else
            log "Already in $INSTALL_DIR — skipping copy"
        fi
    fi
else
    warn "No codebase found. Copy Toolserver files to $INSTALL_DIR manually before starting."
fi

# ═══════════════════════════════════════════════════════════════
# Phase 4: Generate Secrets (G-130)
# ═══════════════════════════════════════════════════════════════
phase 4 "Generate Secrets"

SECRETS_DIR="$INSTALL_DIR/secrets"

_create_secret() {
    local name="$1"
    local mode="$2"  # 'random' | 'fernet' | 'password'
    local file="$SECRETS_DIR/$name"

    if [ -f "$file" ] && [ -s "$file" ]; then
        log "$name — already exists"
        return
    fi

    case "$mode" in
        random)
            openssl rand -base64 32 | tr -d '\n' > "$file"
            ;;
        fernet)
            python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode(), end='')" > "$file" 2>/dev/null \
                || openssl rand -base64 32 | tr -d '\n' > "$file"
            ;;
        password)
            if [ -n "$MENU_PASSWORD" ]; then
                echo -n "$MENU_PASSWORD" > "$file"
            else
                # Generate readable password: 16 chars alphanumeric
                openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16 > "$file"
            fi
            ;;
    esac
    chmod 600 "$file"
    log "$name — generated"
}

if [ "$DRY_RUN" = false ]; then
    _create_secret "postgres_password"  "random"
    _create_secret "session_secret"     "random"
    _create_secret "menu_password"      "password"
    _create_secret "api_key"            "random"
    _create_secret "connector_enc.key"  "fernet"
    log "All secrets in $SECRETS_DIR (chmod 600)"
else
    info "[DRY RUN] Would generate 5 secret files in $SECRETS_DIR"
fi

# ═══════════════════════════════════════════════════════════════
# Phase 5: Configuration (.env)
# ═══════════════════════════════════════════════════════════════
phase 5 "Configuration"

ENV_FILE="$INSTALL_DIR/.env"

# v1524 -- the memory sizes follow THIS host, not onions.one. Until v1524 the
# compose file carried shared_buffers=6GB, effective_cache_size=14GB and the
# limits 6g (PostgreSQL) and 2g (Toolserver) as fixed numbers, sized for the
# live host. PostgreSQL maps shared_buffers as ONE shared-memory segment at
# start; on a host with less memory than that the kernel refuses the mapping
# ("could not map anonymous shared memory", PostgreSQL manual, Shared Memory
# and Semaphores), the container never turns healthy and phase 6 ends in
# "did not become healthy within 600s". The compose file now reads
# PG_SHARED_BUFFERS, PG_EFFECTIVE_CACHE_SIZE, PG_MEM_LIMIT and
# TOOLSERVER_MEM_LIMIT from .env (missing = the onions.one numbers); this is
# where they are derived, once, from MemTotal: 25 % / 50 % / 40 % / 15 %
# (the PostgreSQL rule of thumb for a host that runs other services next to
# the database), the Toolserver never below 2048 MB -- rasterising one large
# drawing in Extrusion needs that (measured 2026-09-03). They are plain lines
# in .env: the operator changes them there and restarts the stack.
MEM_TOTAL_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${MEM_TOTAL_KB:-0}" -lt 1048576 ]; then
    err "Host memory could not be read from /proc/meminfo or is below 1 GB (MemTotal=${MEM_TOTAL_KB} kB)"
    exit 1
fi
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
PG_SHARED_BUFFERS="$(( MEM_TOTAL_MB * 25 / 100 ))MB"
PG_EFFECTIVE_CACHE_SIZE="$(( MEM_TOTAL_MB * 50 / 100 ))MB"
PG_MEM_LIMIT="$(( MEM_TOTAL_MB * 40 / 100 ))m"
TOOLSERVER_MEM_MB=$(( MEM_TOTAL_MB * 15 / 100 ))
if [ "$TOOLSERVER_MEM_MB" -lt 2048 ]; then TOOLSERVER_MEM_MB=2048; fi
TOOLSERVER_MEM_LIMIT="${TOOLSERVER_MEM_MB}m"
info "Host memory ${MEM_TOTAL_MB} MB -> PostgreSQL shared_buffers=${PG_SHARED_BUFFERS} effective_cache_size=${PG_EFFECTIVE_CACHE_SIZE} limit=${PG_MEM_LIMIT}; Toolserver limit=${TOOLSERVER_MEM_LIMIT}"

if [ "$DRY_RUN" = false ]; then
    if [ -f "$ENV_FILE" ]; then
        warn ".env already exists — not overwriting"
    else
        # v1524: AUDIT_BASE_DIR is a WebDAV folder named after the domain --
        # "/onions.one/..." stood here fixed and would have sent every other
        # domain's audit trail into a folder of that name.
        cat > "$ENV_FILE" << ENV_EOF
# Toolserver .env — non-sensitive config only (G-130)
# All secrets in /opt/toolserver/secrets/
DOMAIN=${DOMAIN}
TOOLSERVER_EXTERNAL_URL=https://tools.${DOMAIN}
EMBEDDINGS_ROOT_PATH=/embeddings
EXPORT_DIR=/app/exports
TOOLSERVER_ICONS_DIR=/app/static/icons/tabler
AUDIT_BASE_DIR=/${DOMAIN}/ai-projects/audit
# Memory sizes, derived from this host's ${MEM_TOTAL_MB} MB at installation
# (setup-toolserver.sh phase 5, v1524) -- edit here, then
# docker compose -f docker-compose.toolserver.yml up -d --force-recreate
PG_SHARED_BUFFERS=${PG_SHARED_BUFFERS}
PG_EFFECTIVE_CACHE_SIZE=${PG_EFFECTIVE_CACHE_SIZE}
PG_MEM_LIMIT=${PG_MEM_LIMIT}
TOOLSERVER_MEM_LIMIT=${TOOLSERVER_MEM_LIMIT}
ENV_EOF
        log ".env created (non-sensitive config only)"
    fi
else
    info "[DRY RUN] Would create .env with DOMAIN=$DOMAIN and the memory sizes above"
fi

# ═══════════════════════════════════════════════════════════════
# Phase 6: Start Containers
# ═══════════════════════════════════════════════════════════════
phase 6 "Start Containers"

COMPOSE_FILE="$INSTALL_DIR/docker-compose.toolserver.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
    err "docker-compose.toolserver.yml not found at $COMPOSE_FILE"
    err "Copy the Toolserver codebase to $INSTALL_DIR first."
    exit 1
fi

if [ "$DRY_RUN" = false ]; then
    cd "$INSTALL_DIR"
    # Every network the compose file declares "external" must exist before `up`, or
    # compose refuses with "declared as external, but could not be found". Measured
    # 2026-09-17 on a fresh Ubuntu 24.04 host (first run of onions-server, step 7):
    # browser_net was missing, because until now only setup-chromium.sh created it.
    # An empty network hurts nothing; the service that owns it later finds it in place.
    for net in $(awk '/^networks:/{s=1;next} s&&/^[^ ]/{s=0} s&&/^  [A-Za-z0-9_-]+:/{n=$1;sub(/:$/,"",n)} s&&/^    external: *true/{print n}' docker-compose.toolserver.yml); do
        if docker network inspect "$net" &>/dev/null; then
            log "Network $net exists"
        else
            docker network create "$net" >/dev/null
            log "Network $net created (declared external in the compose file, was missing)"
        fi
    done
    docker compose -f docker-compose.toolserver.yml up -d
    info "Waiting for containers to become healthy..."
    for i in $(seq 1 60); do
        if docker exec toolserver-postgres pg_isready -U toolserver -d toolserver &>/dev/null; then
            log "PostgreSQL healthy after ${i}0s"
            break
        fi
        sleep 10
        if [ "$i" -eq 60 ]; then
            err "PostgreSQL did not become healthy within 600s"
            exit 1
        fi
    done

    # Wait for Toolserver
    for i in $(seq 1 30); do
        if docker exec toolserver python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" &>/dev/null 2>&1; then
            log "Toolserver healthy"
            break
        fi
        sleep 10
        if [ "$i" -eq 30 ]; then
            warn "Toolserver not yet healthy — may still be installing pip packages"
            warn "Check: docker logs toolserver"
        fi
    done
else
    info "[DRY RUN] Would start containers via docker compose"
fi

# ═══════════════════════════════════════════════════════════════
# Phase 7: Database Schema
# ═══════════════════════════════════════════════════════════════
phase 7 "Database Schema"

# v1504 -- measured on the operator's first fresh run (Ubuntu 24.04, lingra.eu,
# 2026-09-17): the seed's menu_nodes reference tenant 'default', which until now
# was created in phase 8 -- AFTER the seed -- so the seed died on its first table.
# The same run showed the second trap: "schema already initialised" looked at the
# table count, so a re-run after that abort skipped the seed for good. Now the
# structure and the seed are decided separately, the rows every seed and every
# patch assume come first, and the seed loads in ONE transaction -- an abort
# leaves nothing half-loaded.
_psql()   { docker exec -i toolserver-postgres psql -U toolserver -d toolserver -v ON_ERROR_STOP=1 -q "$@"; }
_psql_q() { docker exec toolserver-postgres psql -U toolserver -d toolserver -tAc "$1"; }

if [ "$DRY_RUN" = false ]; then
    cd "$INSTALL_DIR"

    # 7a. Structure -- once.
    TABLE_COUNT=$(_psql_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('public','governance','i18n')" 2>/dev/null || echo "0")
    if [ "$TABLE_COUNT" -gt 10 ]; then
        log "Structure present ($TABLE_COUNT tables)"
    else
        if [ ! -f "db/schema_current.sql" ]; then
            err "db/schema_current.sql not found -- the baseline travels with the repository (scripts/patch_cleanup.sh writes it after every deploy)."
            exit 1
        fi
        info "Loading the structure from db/schema_current.sql..."
        _psql < db/schema_current.sql
        log "Structure applied ($(_psql_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('public','governance','i18n')") tables)"
    fi

    # 7b. Tenants -- instance data, never in the seed, but the seed's menu_nodes
    #     point at 'default' and the connector code at the sentinel 'system'.
    _psql <<SQL
INSERT INTO public.tenants (id, name, active, domain)
VALUES ('default', '${DOMAIN}', true, '${DOMAIN}')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.tenants (id, name, active)
VALUES ('system', 'System (platform sentinel)', true)
ON CONFLICT (id) DO NOTHING;
SQL
    log "Tenants 'default' (${DOMAIN}) and 'system' present"

    # 7c. Seed -- once, decided by the version marker, not by the table count.
    SEED_ROWS=$(_psql_q "SELECT COUNT(*) FROM public.schema_version")
    if [ "${SEED_ROWS:-0}" -gt 0 ]; then
        log "Seed data present (schema_version at $(_psql_q 'SELECT MAX(version) FROM public.schema_version'))"
    else
        if [ ! -f "db/schema_seed.sql" ]; then
            err "db/schema_seed.sql not found -- without it a fresh database has no menus and no version marker."
            exit 1
        fi
        info "Loading the seed from db/schema_seed.sql (one transaction)..."
        _psql --single-transaction < db/schema_seed.sql
        log "Seed applied (schema_version at $(_psql_q 'SELECT MAX(version) FROM public.schema_version'))"
    fi

    # 7d. Rows every patch assumes: the platform's own project (every changelog
    #     entry points at it) and the two languages (every translation does).
    #     No-ops once the seed carries them (scripts/dump_schema.sh, v1504).
    _psql <<'SQL'
INSERT INTO governance.projects (id, project_code, name, tenant_id, status, language, created_by)
VALUES (1, 'DEV-TSAI-2026-0001', 'Toolserver AI — onions.one Platform', 'default', 'active', 'en', 'system')
ON CONFLICT (id) DO NOTHING;
SELECT setval('governance.projects_id_seq', GREATEST((SELECT MAX(id) FROM governance.projects), 1));
INSERT INTO i18n.languages (code, label, is_source, active)
VALUES ('en', 'English', true, true), ('de', 'Deutsch', false, true)
ON CONFLICT (code) DO NOTHING;
SQL
    log "Platform project and languages en/de present"

    # 7e. system_config section 'env' from the .env written in phase 5. The seed
    #     never carries this section (it is the copy of ONE instance's .env, with
    #     its domain and URLs); the same admin action exists in the Toolserver
    #     (POST /api/admin/migrate-env-to-db), with the same secret filter.
    ENV_LINES="$(grep -E '^[A-Z_]+=' "$ENV_FILE" || true)"
    _psql <<SQL
INSERT INTO public.system_config (tenant_id, section, data, updated_at)
SELECT 'default', 'env',
       jsonb_object_agg(split_part(l, '=', 1), substr(l, position('=' in l) + 1)), now()
  FROM unnest(string_to_array(\$env\$${ENV_LINES}\$env\$, E'\n')) AS l
 WHERE l ~ '^[A-Z_]+='
   AND l !~* '(DATABASE_URL|PASSWORD|SECRET|API_KEY|ENCRYPTION|TOKEN)'
HAVING count(*) > 0
ON CONFLICT ON CONSTRAINT uq_system_config_tenant_section DO NOTHING;
SQL
    log "system_config 'env' section present"

    # Apply incremental patches beyond the baseline (idempotent, version-tracked).
    # Brings a fresh install (or an existing one) up to the latest schema_version.
    # v1486: `--to alle` sagt wissentlich "alles, was hier liegt" -- beim
    # Neuaufbau ist jede Patchdatei im Ordner gewollt. Im Bedienerblock einer
    # Lieferung heisst es dagegen `--to <Patchnummer>`, und ohne Nummer weist
    # dbmigrate.sh ab (R-06).
    if [ -f "dbmigrate.sh" ]; then
        info "Applying schema patches via dbmigrate.sh ..."
        bash dbmigrate.sh apply --to alle
    else
        warn "dbmigrate.sh not found — DB left at baseline only."
        warn "Run 'bash dbmigrate.sh apply --to alle' once the runner is present."
    fi
else
    info "[DRY RUN] Would initialise database schema and apply pending patches"
fi

# ═══════════════════════════════════════════════════════════════
# Phase 8: Superadmin User
# ═══════════════════════════════════════════════════════════════
phase 8 "Superadmin User"

# v1505 (operator 2026-09-18, verbatim: "Admin und ein standardPW wuerde
# einwandfrei gehen! Admin / dont4get"): v1504 left 'admin' without a personal
# password and relied on the menu-password fallback (services/config_ui_router
# .py, POST /menu with an empty login name) -- a second, differently-named
# secret in a different file, never printed as "this is your login". The
# operator's own first attempt was admin + the Linux root password, which was
# never going to match either. A working login beats a secret nobody can find:
# 'admin' now gets this fixed, printed password directly.
#
# Idempotent and safe to re-run: a personal password already set -- this one
# from an earlier run, or one the operator changed it to -- is never
# overwritten (password_hash IS NULL is the only case this touches).
#
# v1507 (operator 2026-09-18: "admin und das angezeigte PW funktionieren
# nicht!" -- on the same fresh lingra.eu run v1505 was meant to fix): phase 6
# only WARNS and moves on if the toolserver app container isn't healthy
# within its own 300s, e.g. still installing pip packages. The hashing below
# runs `docker exec` against that same container -- if it wasn't ready yet,
# the hash failed, admin got created with NO password, and yet the summary
# below still printed the standard password as working, because it only
# checked whether a password existed BEFORE this run, never whether hashing
# succeeded NOW. Fixed two ways: retry the hash here too (phase 7's DB work
# already buys it time; this adds up to two more minutes), and track this
# run's real result in ADMIN_LOGIN_SET so the summary never claims a password
# that was not actually set.
ADMIN_STANDARD_PASSWORD="dont4get"
HAD_PW=""             # set below when not a dry run; `set -u` needs it bound for the summary
ADMIN_LOGIN_SET=false # true only once the hash below actually lands in the database

if [ "$DRY_RUN" = false ]; then
    HAD_PW="$(_psql_q "SELECT COALESCE((SELECT password_hash IS NOT NULL FROM public.users WHERE username = 'admin'), false)")"

    # Hash inside the running container with the project's own function
    # (services/auth_gate.hash_password) -- one algorithm, one place (R-129),
    # never re-implemented here. Retried: the container can still be
    # installing pip packages this long after phase 6's own wait (warn, not
    # abort, there).
    ADMIN_HASH=""
    for i in $(seq 1 12); do
        if ADMIN_HASH="$(docker exec -e ADMIN_PW="$ADMIN_STANDARD_PASSWORD" toolserver python3 -c '
from services.auth_gate import hash_password
import os
print(hash_password(os.environ["ADMIN_PW"]))
' 2>/dev/null)" && [ -n "$ADMIN_HASH" ]; then
            break
        fi
        ADMIN_HASH=""
        [ "$i" -eq 12 ] || sleep 10
    done

    if [ -n "$ADMIN_HASH" ]; then
        _psql <<SQL
INSERT INTO public.users (username, tenant_id, name, email, access_role, active, password_hash)
VALUES ('admin', 'default', 'Administrator', 'admin@${DOMAIN}', 'superadmin', true, '${ADMIN_HASH}')
ON CONFLICT (username) DO UPDATE
   SET password_hash = COALESCE(public.users.password_hash, EXCLUDED.password_hash)
 WHERE public.users.password_hash IS NULL;
SQL
        ADMIN_LOGIN_SET=true
        if [ "$HAD_PW" = "t" ]; then
            log "Superadmin 'admin' already has a personal password (this one, or one you set) -- unchanged."
        else
            log "Superadmin 'admin' ready -- login name admin, password ${ADMIN_STANDARD_PASSWORD}. Change it under Admin > Users."
        fi
    else
        warn "Could not hash the standard password inside the container after 2 minutes of retries -- 'admin' has no personal password yet."
        warn "Check: docker logs toolserver -- once it answers /health, re-run this script (idempotent: it never overwrites an existing password)."
        _psql <<SQL
INSERT INTO public.users (username, tenant_id, name, email, access_role, active)
VALUES ('admin', 'default', 'Administrator', 'admin@${DOMAIN}', 'superadmin', true)
ON CONFLICT (username) DO NOTHING;
SQL
        warn "Fallback for now: leave the login name empty and use the menu password (see the summary below)."
    fi
else
    info "[DRY RUN] Would create superadmin user with the standard password"
fi

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
echo "  URL:           https://tools.${DOMAIN}/menu"
if [ "$DRY_RUN" = true ]; then
    echo "  Login:         [DRY RUN] would be admin / ${ADMIN_STANDARD_PASSWORD}, unless a personal password already exists"
elif [ "$HAD_PW" = "t" ]; then
    echo "  Login:         admin, with the password already set on this instance"
elif [ "$ADMIN_LOGIN_SET" = true ]; then
    echo "  Login:         admin / ${ADMIN_STANDARD_PASSWORD}   (change it under Admin > Users)"
else
    echo "  Login:         admin has NO password yet -- the standard password could not be set (see warning above)"
fi
echo "  Fallback door: leave the login name empty, password = $(cat "$SECRETS_DIR/menu_password" 2>/dev/null || echo '(see secrets/menu_password)')"
echo "                 -- open only until a superadmin has a personal password; still open above if the warning fired"
echo ""
echo "  Secrets dir:   $SECRETS_DIR/"
echo "  Config:        $INSTALL_DIR/.env"
echo "  Compose:       $INSTALL_DIR/docker-compose.toolserver.yml"
echo ""
echo "  Next steps:"
echo "    1. Verify: curl -s https://tools.${DOMAIN}/health"
echo "    2. Login:  https://tools.${DOMAIN}/menu"
echo "    3. Configure connectors (IONOS, Nextcloud) in Admin → Connectors"
echo "    4. Create your first Directory Pipe in Knowledge → Pipes"
echo ""
echo "  Logs:    docker logs toolserver"
echo "  Restart: cd $INSTALL_DIR && docker compose -f docker-compose.toolserver.yml up -d --force-recreate"
echo ""
