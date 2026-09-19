#!/usr/bin/env bash
# steps/70-toolserver.sh -- the handover (K4/K7): pull the Toolserver from Git and run its
# setup-toolserver.sh. From here on the Toolserver manages the host (its Environment
# module, GAP-ENV-LEITSTELLE-01); this installer's job ends. Sourced by install.sh.
#
# Since 2026-09-19 the setup script travels with THIS repository (toolserver/
# setup-toolserver.sh), not with the Toolserver's: its repository carries no setup script
# any more ("scripts/setup-*.sh darf es nicht geben", operator 2026-09-18, Toolserver
# v1524) -- every setup script lives in /opt/<domain>, and the Toolserver's Environment
# module lists them there. This step places the script into /opt/<domain>/ and runs it
# from there; on the running host the Toolserver maintains that copy (deploy_write).
#
# Access (operator 2026-09-19, open-core decisions D-OPENCORE-01/05/08/12): this installer
# is a product path for an unknown user. The Toolserver's open base is published under
# AGPL-3.0-only from release level 1, so TOOLSERVER_GIT is then a public address and the
# clone needs no credentials -- no deploy key, no token, no password, nothing registered
# anywhere. Until that release the base is closed and only lingra installs: for such a
# host the operator registers the host's own SSH key (/root/.ssh/id_ed25519.pub) as a
# read-only deploy key of the private repository and enters its ssh address. This step
# carries NO key handling of its own: it probes the address the way git will use it and,
# if that fails, shows git's reason and stops. The deploy-key apparatus of 2026-09-17
# (one key per repository, registration through the GitHub API with a token) is gone --
# it was a crutch of the closed phase, not a product path.

STEP_70_TITLE="Toolserver (pull from Git, run its setup, hand over)"

step_70_run() {
    heading "$STEP_70_TITLE"
    checklist_require TOOLSERVER_GIT TOOLSERVER_REF
    docker_ok || die "Docker is missing -- run the Docker step first."
    docker ps --format '{{.Names}}' | grep -qx traefik || die "Traefik is not running -- run the Traefik step first."
    command -v git >/dev/null || pkg_install git

    local src="$INSTALL_ROOT/src/onions-toolserver"
    mkdir -p "$INSTALL_ROOT/src"
    _git_readable || return 1
    if [[ -d "$src/.git" ]]; then
        log_info "Updating $src to $TOOLSERVER_REF..."
        (cd "$src" && run git fetch --tags origin && run git checkout -q "$TOOLSERVER_REF" && (git symbolic-ref -q HEAD >/dev/null && run git pull -q --ff-only || true))
    else
        log_info "Cloning $TOOLSERVER_GIT ($TOOLSERVER_REF) to $src..."
        run git clone --branch "$TOOLSERVER_REF" "$TOOLSERVER_GIT" "$src"
    fi
    log_ok "Toolserver source at $(cd "$src" && git describe --tags --always) ($TOOLSERVER_REF)."

    local setup="$INSTANCE_DIR/setup-toolserver.sh"
    [[ -f "$INSTALL_ROOT/toolserver/setup-toolserver.sh" ]] || die "toolserver/setup-toolserver.sh is missing in $INSTALL_ROOT."
    run install -m 755 "$INSTALL_ROOT/toolserver/setup-toolserver.sh" "$setup"
    log_ok "Setup script placed at $setup (the Toolserver lists and maintains it there)."
    log_info "Handing over to the Toolserver's setup (Docker and Traefik are done here)."
    (cd "$src" && run bash "$setup" --domain "$DOMAIN" --source "$src" --skip-docker --skip-traefik)
    step_done 70
    echo
    log_ok "Handover complete. The Toolserver now owns the host: https://tools.$DOMAIN"
    log_info "Everything beyond this point (services, backups, updates) is managed there:"
    log_info "  Environment > Server-Config > Services"
}

# _git_readable -- can this host read TOOLSERVER_GIT the way git will use it, without
# asking anything? GIT_TERMINAL_PROMPT=0 makes an https address that wants a login fail at
# once instead of prompting for a user name; BatchMode does the same for ssh; the host key
# of the Git server is accepted on first contact. Both settings stay exported, so the clone
# and every later pull behave the same way. Git's own reason is always shown.
_git_readable() {
    local err
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    if err="$(git ls-remote --exit-code -h "$TOOLSERVER_GIT" 2>&1 >/dev/null)"; then
        log_ok "Git access to $TOOLSERVER_GIT works."
        return 0
    fi
    log_err "This host cannot read $TOOLSERVER_GIT. Git says:"
    printf '%s\n' "$err" | grep -v '^$' | tail -n 4 | sed 's/^/    /' | tee -a "$LOG_FILE"
    case "$err" in
        *"could not read Username"*|*"Authentication failed"*|*"Permission denied"*|*"Repository not found"*|*"not found"*|*"does not appear to be a git repository"*)
            log_info "The address must be readable without credentials: a published repository over https needs nothing."
            log_info "A private repository (lingra's closed phase): register this host's key as a read-only deploy key there and enter its ssh address."
            if [[ -f /root/.ssh/id_ed25519.pub ]]; then
                log_info "This host's key:"; cat /root/.ssh/id_ed25519.pub
            else
                log_info "This host has no key yet: ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519"
            fi
            log_info "Then run this step again." ;;
        *)  log_warn "That is not an access problem -- check the network first (DNS, https or port 22 to the Git server)." ;;
    esac
    return 1
}
