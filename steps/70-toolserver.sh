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
    log_warn "No access to $TOOLSERVER_GIT yet -- the machine's key is not registered as a deploy key."
    local how; how="$(choose "How to register it" "Automatically through the GitHub API (asks for a token once, never stored)" "By hand (the key is shown, register it in the browser)")"
    case "$how" in
        1) _github_register_key "$key.pub" || return 1 ;;
        2) echo; cat "$key.pub"; echo
           log_info "GitHub: repository > Settings > Deploy keys > Add deploy key (no write access)."
           pause ;;
        *) return 1 ;;
    esac
    if git ls-remote --exit-code -h "$TOOLSERVER_GIT" >/dev/null 2>&1; then
        log_ok "Git access works now."; return 0
    fi
    log_err "Still no access -- register the deploy key and run this step again."
    return 1
}

# _github_register_key PUBFILE -- POST /repos/<owner>/<repo>/keys with a token the operator
# types once (fine-grained token: this repository, "Administration: read and write"; or a
# classic token with scope repo). The token lives in this function's memory only.
_github_register_key() {
    local pub="$1" repo token body code
    repo="$(github_repo_of "$TOOLSERVER_GIT")" || { log_err "Not a GitHub URL: $TOOLSERVER_GIT"; return 1; }
    log_info "Token: GitHub > Settings > Developer settings > Fine-grained tokens > repository $repo, permission Administration (write)."
    local tok; ask_secret tok "GitHub token"
    body="$(printf '{"title":"deploy@%s (onions-server)","key":"%s","read_only":true}' "$(hostname)" "$(cut -d' ' -f1,2 < "$pub")")"
    code="$(curl -sS -o /tmp/gh-key.json -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$repo/keys" -d "$body")"
    unset tok
    case "$code" in
        201) log_ok "Deploy key registered on $repo (read-only)."; rm -f /tmp/gh-key.json; return 0 ;;
        422) if grep -q "key is already in use" /tmp/gh-key.json 2>/dev/null; then
                 log_ok "This key is already registered on GitHub."; rm -f /tmp/gh-key.json; return 0; fi
             log_err "GitHub refused the key: $(tr -d '\n' < /tmp/gh-key.json | head -c 300)"; rm -f /tmp/gh-key.json; return 1 ;;
        401|403) log_err "Token rejected (HTTP $code) -- it needs Administration (write) on $repo."; rm -f /tmp/gh-key.json; return 1 ;;
        *) log_err "GitHub answered HTTP $code: $(tr -d '\n' < /tmp/gh-key.json 2>/dev/null | head -c 300)"; rm -f /tmp/gh-key.json; return 1 ;;
    esac
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
