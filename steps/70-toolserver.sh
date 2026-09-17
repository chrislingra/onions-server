#!/usr/bin/env bash
# steps/70-toolserver.sh -- the handover (K4/K7): pull the Toolserver from Git and run its
# own setup-toolserver.sh. From here on the Toolserver manages the host (its Environment
# module, GAP-ENV-LEITSTELLE-01); this installer's job ends. Sourced by install.sh.

STEP_70_TITLE="Toolserver (pull from Git, run its setup, hand over)"

step_70_run() {
    heading "$STEP_70_TITLE"
    checklist_require DOMAIN TOOLSERVER_GIT TOOLSERVER_REF
    docker_ok || die "Docker is missing -- run the Docker step first."
    docker ps --format '{{.Names}}' | grep -qx traefik || die "Traefik is not running -- run the Traefik step first."
    command -v git >/dev/null || pkg_install git

    local src="$INSTALL_ROOT/src/onions-toolserver"
    mkdir -p "$INSTALL_ROOT/src"
    _git_access_ready || return 1
    if [[ -d "$src/.git" ]]; then
        log_info "Updating $src to $TOOLSERVER_REF..."
        (cd "$src" && run git fetch --tags origin && run git checkout -q "$TOOLSERVER_REF" && (git symbolic-ref -q HEAD >/dev/null && run git pull -q --ff-only || true))
    else
        log_info "Cloning $TOOLSERVER_GIT ($TOOLSERVER_REF) to $src..."
        run git clone --branch "$TOOLSERVER_REF" "$TOOLSERVER_GIT" "$src"
    fi
    log_ok "Toolserver source at $(cd "$src" && git describe --tags --always) ($TOOLSERVER_REF)."

    [[ -f "$src/scripts/setup-toolserver.sh" ]] || die "scripts/setup-toolserver.sh is missing in the Toolserver checkout."
    log_info "Handing over to the Toolserver's own setup (Docker and Traefik are done here)."
    (cd "$src" && run bash scripts/setup-toolserver.sh --domain "$DOMAIN" --source "$src" --skip-docker --skip-traefik)
    step_done 70
    echo
    log_ok "Handover complete. The Toolserver now owns the host: https://tools.$DOMAIN"
    log_info "Everything beyond this point (services, backups, updates) is managed there:"
    log_info "  Environment > Server-Config > Services"
}

# The Toolserver repository is private. A fresh server authenticates with a deploy key:
# its own ed25519 key, registered read-only on GitHub (checklist/PREPARATION.md, item 7).
_git_access_ready() {
    [[ "$TOOLSERVER_GIT" == git@* || "$TOOLSERVER_GIT" == ssh://* ]] || return 0
    local key="/root/.ssh/id_ed25519"
    if [[ ! -f "$key" ]]; then
        install -d -m 700 /root/.ssh
        run ssh-keygen -t ed25519 -N "" -C "deploy@$(hostname)" -f "$key"
    fi
    ssh-keygen -F github.com -f /root/.ssh/known_hosts >/dev/null 2>&1 || ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null
    if git ls-remote --exit-code -h "$TOOLSERVER_GIT" >/dev/null 2>&1; then
        log_ok "Git access to $TOOLSERVER_GIT works."
        return 0
    fi
    log_warn "No access to $TOOLSERVER_GIT yet. Register this public key as a read-only deploy key:"
    echo; cat "$key.pub"; echo
    log_info "GitHub: repository > Settings > Deploy keys > Add deploy key (no write access)."
    pause
    if git ls-remote --exit-code -h "$TOOLSERVER_GIT" >/dev/null 2>&1; then
        log_ok "Git access works now."; return 0
    fi
    log_err "Still no access -- add the deploy key and run this step again."
    return 1
}
