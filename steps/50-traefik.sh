#!/usr/bin/env bash
# steps/50-traefik.sh -- the reverse proxy in /opt/traefik, from the templates in
# templates/. Origin: prepare-system.sh step 3, compared against the live /opt/traefik
# (2026-09-17: production Let's Encrypt, dashboard behind basic auth). Sourced by install.sh.

STEP_50_TITLE="Traefik reverse proxy (/opt/traefik)"

step_50_run() {
    heading "$STEP_50_TITLE"
    checklist_require DOMAIN ADMIN_USER ACME_EMAIL ACME_MODE TRAEFIK_IMAGE
    docker_ok || die "Docker is missing -- run the Docker step first."
    local dir="/opt/traefik"
    mkdir -p "$dir"
    [[ -f "$dir/acme.json" ]] || touch "$dir/acme.json"
    chmod 600 "$dir/acme.json"
    docker network inspect traefik_web >/dev/null 2>&1 || run docker network create traefik_web

    local ca_server=""
    if [[ "$ACME_MODE" == "staging" ]]; then
        ca_server='      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"'
        log_warn "Staging certificates: browsers will warn. Switch ACME_MODE to production later."
    fi

    # dashboard credentials: asked now, hashed with openssl (no apache2-utils needed),
    # never stored in clear text anywhere
    local pw hash
    if [[ -f "$dir/docker-compose.yml" ]] && grep -q 'basicauth.users=' "$dir/docker-compose.yml" \
        && ! confirm "Traefik is already configured. Rewrite traefik.yml and docker-compose.yml?" n; then
        log_ok "Kept the existing configuration."
    else
        ask_secret pw "Password for the Traefik dashboard (user $ADMIN_USER)"
        hash="$(openssl passwd -apr1 "$pw")"; unset pw
        hash="${hash//\$/\$\$}"   # compose interpolation: literal $ is $$
        backup_file "$dir/traefik.yml"; backup_file "$dir/docker-compose.yml"
        sed -e "s|@ACME_EMAIL@|$ACME_EMAIL|" -e "s|@CA_SERVER@|$ca_server|" \
            "$INSTALL_ROOT/templates/traefik.yml" > "$dir/traefik.yml"
        sed -e "s|@DOMAIN@|$DOMAIN|g" -e "s|@TRAEFIK_IMAGE@|$TRAEFIK_IMAGE|" \
            -e "s|@ADMIN_USER@|$ADMIN_USER|" -e "s|@DASHBOARD_HASH@|$hash|" \
            "$INSTALL_ROOT/templates/traefik-compose.yml" > "$dir/docker-compose.yml"
        log_ok "Wrote $dir/traefik.yml and $dir/docker-compose.yml."
    fi

    (cd "$dir" && run docker compose up -d)
    chown -R "$ADMIN_USER:$(primary_group "$ADMIN_USER")" "$dir"; chmod 600 "$dir/acme.json"
    step_done 50
    log_ok "Traefik running. Dashboard: https://traefik.$DOMAIN (DNS record required)."
}
