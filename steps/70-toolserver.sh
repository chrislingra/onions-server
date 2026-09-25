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
# AGPL-3.0-only from release level 1, so TOOLSERVER_SOURCE is then a public address and the
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
    docker_ok || die "Docker is missing -- run the Docker step first."
    docker ps --format '{{.Names}}' | grep -qx traefik || die "Traefik is not running -- run the Traefik step first."
    command -v git >/dev/null || pkg_install git

    local src="$INSTALL_ROOT/src/onions-toolserver"
    mkdir -p "$INSTALL_ROOT/src"
    _git_readable || return 1
    if [[ -d "$src/.git" ]]; then
        log_info "Updating $src to the current state..."
        (cd "$src" && run git fetch --tags origin && run git pull -q --ff-only)
    else
        log_info "Cloning $TOOLSERVER_SOURCE to $src..."
        run git clone "$TOOLSERVER_SOURCE" "$src"
    fi
    log_ok "Toolserver source at $(cd "$src" && git describe --tags --always)."

    local setup="$INSTANCE_DIR/setup-toolserver.sh"
    [[ -f "$INSTALL_ROOT/toolserver/setup-toolserver.sh" ]] || die "toolserver/setup-toolserver.sh is missing in $INSTALL_ROOT."
    run install -m 755 "$INSTALL_ROOT/toolserver/setup-toolserver.sh" "$setup"
    log_ok "Setup script placed at $setup (the Toolserver lists and maintains it there)."
    log_info "Handing over to the Toolserver's setup (Docker and Traefik are done here)."
    (cd "$src" && run bash "$setup" --domain "$DOMAIN" --source "$src" --skip-docker --skip-traefik)
    _verwalter_einrichten
    step_done 70
    echo
    log_ok "Handover complete. The Toolserver now owns the host: https://tools.$DOMAIN"
    log_info "Everything beyond this point (services, backups, updates) is managed there:"
    log_info "  Environment > Server-Config > Services"
}

# _verwalter_einrichten -- every installation gets its own Verwalter (operator 2026-09-25:
# "jede neuinstallation braucht einen eigenen Verwalter"; GAP-ENV-VERWALTER-JE-INSTALLATION-01).
# The Toolserver only WRITES jobs into public.platform_agent_jobs; this root service on the
# host carries them out (update, restart, backup, setup). Without it no button of the
# interface has an effect on this host. It lives next to the setup scripts in /opt/<domain>
# -- it finds them in its own directory. The unit names this domain's path; on the Onions
# server the same file sits in /opt/onions.one. Re-running rewrites both and restarts.
_verwalter_einrichten() {
    local quelle="$INSTALL_ROOT/toolserver/verwalter.py"
    local ziel="$INSTANCE_DIR/verwalter.py"
    local unit="/etc/systemd/system/onions-verwalter.service"
    [[ -f "$quelle" ]] || die "toolserver/verwalter.py is missing in $INSTALL_ROOT."
    command -v python3 >/dev/null || pkg_install python3
    run install -m 750 "$quelle" "$ziel"
    cat > "$unit" <<EOF
[Unit]
Description=onions.one Verwalter for $DOMAIN (GAP-ENV-LEITSTELLE-01)
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $ziel
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable onions-verwalter.service
    run systemctl restart onions-verwalter.service
    sleep 2
    if systemctl is-active --quiet onions-verwalter.service; then
        log_ok "Verwalter running ($ziel) -- the buttons under Environment > Installation act on this host."
    else
        log_err "Verwalter did not start -- see: journalctl -u onions-verwalter -n 30"
        return 1
    fi
}

# _git_probe -- can this host read TOOLSERVER_SOURCE the way git will use it, without asking
# anything? GIT_TERMINAL_PROMPT=0 makes an https address that wants a login fail at once
# instead of prompting for a user name; BatchMode does the same for ssh; the host key of the
# Git server is accepted on first contact. Both settings stay exported, so the clone and
# every later pull behave the same way. Prints git's own error on failure, nothing else.
_git_probe() {
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    git ls-remote --exit-code -h "$TOOLSERVER_SOURCE" 2>&1 >/dev/null
}

# toolserver_not_published -- the plain statement, said before step 1 AND when step 7 stops
# (operator 2026-09-24: "es muss offensichtlich sein, dass das nicht geht"). Until release
# level 1 (D-OPENCORE-08) the Toolserver's source is closed: nobody but lingra can install it,
# and this installer must say so up front instead of letting six steps run first.
toolserver_not_published() {
    log_warn "The Toolserver cannot be installed on this host: its source is not published yet."
    log_warn "  It becomes public with release level 1. Until then steps 1-6 run, step 7 stops."
    log_info "  Only a lingra host gets past step 7 now: this host's key registered as a read-only"
    log_info "  deploy key of $TOOLSERVER_SOURCE."
    if [[ -f /root/.ssh/id_ed25519.pub ]]; then
        log_info "  This host's key:"; cat /root/.ssh/id_ed25519.pub
    else
        log_info "  This host has no key yet: ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519"
    fi
}

# toolserver_precheck -- at start, before step 1: says it only when access is refused. No git
# yet, or no network, is not a verdict about publication; step 7 names those itself.
toolserver_precheck() {
    local err
    command -v git >/dev/null || return 0
    err="$(_git_probe)" && return 0
    case "$err" in
        *"could not read Username"*|*"Authentication failed"*|*"Permission denied"*|*"Repository not found"*|*"not found"*|*"does not appear to be a git repository"*)
            echo; toolserver_not_published ;;
    esac
    return 0
}

# _git_readable -- the probe with its explanation, for step 7.
_git_readable() {
    local err
    if err="$(_git_probe)"; then
        log_ok "Git access to $TOOLSERVER_SOURCE works."
        return 0
    fi
    log_err "This host cannot read $TOOLSERVER_SOURCE. Git says:"
    printf '%s\n' "$err" | grep -v '^$' | tail -n 4 | sed 's/^/    /' | tee -a "$LOG_FILE"
    case "$err" in
        *"could not read Username"*|*"Authentication failed"*|*"Permission denied"*|*"Repository not found"*|*"not found"*|*"does not appear to be a git repository"*)
            toolserver_not_published ;;
        *)  log_warn "That is not an access problem -- check the network first (DNS, https or port 22 to the Git server)." ;;
    esac
    return 1
}
