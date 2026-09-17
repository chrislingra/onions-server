#!/usr/bin/env bash
# steps/70-toolserver.sh -- the handover (K4/K7): pull the Toolserver from Git and run its
# own setup-toolserver.sh. From here on the Toolserver manages the host (its Environment
# module, GAP-ENV-LEITSTELLE-01); this installer's job ends. Sourced by install.sh.

STEP_70_TITLE="Toolserver (pull from Git, run its setup, hand over)"

step_70_run() {
    heading "$STEP_70_TITLE"
    checklist_require TOOLSERVER_GIT TOOLSERVER_REF
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
    # later pulls (by hand or by the Toolserver) use the same deploy key without any environment
    [[ -n "${DEPLOY_KEY:-}" ]] && git -C "$src" config core.sshCommand "ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes"
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

# The Toolserver repository is private. A fresh server authenticates with a deploy key --
# and GitHub binds a deploy key to exactly ONE repository. So this step uses its own key
# per repository (/root/.ssh/deploy-<repository>), never the machine's default id_ed25519.
# Measured 2026-09-17: that default key was already the deploy key of onions-server, GitHub
# refused it for onions-toolserver ("key is already in use"), and the step said "not
# registered" without showing Git's own reason. Now the reason is always shown.

# _deploy_key_for URL -> /root/.ssh/deploy-<repository name>
_deploy_key_for() {
    local repo; repo="$(github_repo_of "$1")" || repo="${1##*/}"
    repo="${repo##*/}"; repo="${repo%.git}"
    echo "/root/.ssh/deploy-${repo:-toolserver}"
}

# _git_probe -- can this key read the repository? Git's stderr lands in GIT_PROBE_ERR.
_git_probe() {
    GIT_PROBE_ERR="$(git ls-remote --exit-code -h "$TOOLSERVER_GIT" 2>&1 >/dev/null)"
}

_git_probe_reason() {
    printf '%s\n' "$GIT_PROBE_ERR" | grep -v '^$' | tail -n 4 | sed 's/^/    /' | tee -a "$LOG_FILE"
    case "$GIT_PROBE_ERR" in
        *"Permission denied"*|*"Repository not found"*|*"not found"*)
            log_info "GitHub does not accept this key for $TOOLSERVER_GIT -- it is not a deploy key of that repository." ;;
        *)  log_warn "That is not a key problem -- check the network first (DNS, port 22 to github.com)." ;;
    esac
}

_git_access_ready() {
    [[ "$TOOLSERVER_GIT" == git@* || "$TOOLSERVER_GIT" == ssh://* ]] || return 0
    DEPLOY_KEY="$(_deploy_key_for "$TOOLSERVER_GIT")"
    if [[ ! -f "$DEPLOY_KEY" ]]; then
        install -d -m 700 /root/.ssh
        run ssh-keygen -t ed25519 -N "" -C "$(basename "$DEPLOY_KEY")@$(hostname)" -f "$DEPLOY_KEY"
    fi
    ssh-keygen -F github.com -f /root/.ssh/known_hosts >/dev/null 2>&1 || ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null
    export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    if _git_probe; then
        log_ok "Git access to $TOOLSERVER_GIT works (deploy key $DEPLOY_KEY.pub)."
        return 0
    fi
    log_warn "No access to $TOOLSERVER_GIT with $DEPLOY_KEY.pub. Git says:"
    _git_probe_reason
    local how repo
    how="$(choose "How to register the key" "Automatically through the GitHub API (asks for a token once, never stored)" "By hand (the key is shown, register it in the browser)")"
    case "$how" in
        1) _github_register_key "$DEPLOY_KEY.pub" || return 1 ;;
        2) echo; cat "$DEPLOY_KEY.pub"; echo
           if repo="$(github_repo_of "$TOOLSERVER_GIT")"; then
               log_info "Register it at https://github.com/$repo/settings/keys (Add deploy key, no write access)."
           else
               log_info "Register it as a read-only deploy key of that repository."
           fi
           log_info "A deploy key belongs to exactly one repository -- GitHub refuses a key another repository already uses."
           pause ;;
        *) return 1 ;;
    esac
    if _git_probe; then
        log_ok "Git access works now."; return 0
    fi
    log_err "Still no access. Git says:"
    _git_probe_reason
    log_err "Register $DEPLOY_KEY.pub as a deploy key of $TOOLSERVER_GIT and run this step again."
    return 1
}

# _github_register_key PUBFILE -- POST /repos/<owner>/<repo>/keys with a token the operator
# types once (fine-grained token: this repository, "Administration: read and write"; or a
# classic token with scope repo). The token lives in this function's memory only.
# "key is already in use" (422) is only good news when the key sits on THIS repository;
# the function looks that up before it says so.
_github_register_key() {
    local pub="$1" repo body code tok blob rc=1
    repo="$(github_repo_of "$TOOLSERVER_GIT")" || { log_err "Not a GitHub URL: $TOOLSERVER_GIT"; return 1; }
    blob="$(cut -d' ' -f2 < "$pub")"
    log_info "Token: GitHub > Settings > Developer settings > Fine-grained tokens > repository $repo, permission Administration (write)."
    ask_secret tok "GitHub token"
    body="$(printf '{"title":"%s@%s (onions-server)","key":"%s","read_only":true}' "$(basename "$pub" .pub)" "$(hostname)" "$(cut -d' ' -f1,2 < "$pub")")"
    code="$(curl -sS -o /tmp/gh-key.json -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$repo/keys" -d "$body")"
    case "$code" in
        201) log_ok "Deploy key registered on $repo (read-only)."; rc=0 ;;
        422) if grep -q "key is already in use" /tmp/gh-key.json 2>/dev/null; then
                 if curl -sS -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
                        "https://api.github.com/repos/$repo/keys" 2>/dev/null | grep -qF "$blob"; then
                     log_ok "This key is already a deploy key of $repo."; rc=0
                 else
                     log_err "GitHub knows this key already -- as the deploy key of ANOTHER repository, and a deploy key belongs to exactly one."
                     log_err "Remove it there (Settings > Deploy keys), or delete $pub and its private half so this step generates a fresh pair."
                 fi
             else
                 log_err "GitHub refused the key: $(tr -d '\n' < /tmp/gh-key.json | head -c 300)"
             fi ;;
        401|403) log_err "Token rejected (HTTP $code) -- it needs Administration (write) on $repo." ;;
        404) log_err "GitHub answered 404 for $repo -- the token cannot see that repository (wrong repository in the token, or wrong URL)." ;;
        *) log_err "GitHub answered HTTP $code: $(tr -d '\n' < /tmp/gh-key.json 2>/dev/null | head -c 300)" ;;
    esac
    unset tok; rm -f /tmp/gh-key.json
    return $rc
}

# github_repo_of URL -> owner/repo for git@github.com:o/r.git, ssh://git@github.com/o/r.git,
# https://github.com/o/r(.git); fails for anything else
github_repo_of() {
    local url="$1" rest
    case "$url" in
        git@github.com:*)          rest="${url#git@github.com:}" ;;
        ssh://git@github.com/*)    rest="${url#ssh://git@github.com/}" ;;
        https://github.com/*)      rest="${url#https://github.com/}" ;;
        *) return 1 ;;
    esac
    rest="${rest%.git}"; rest="${rest%/}"
    [[ "$rest" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    echo "$rest"
}
