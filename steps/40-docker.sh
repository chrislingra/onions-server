#!/usr/bin/env bash
# steps/40-docker.sh -- Docker Engine + Compose v2 plugin. Origin: prepare-system.sh step 2.
# Compose v1 (the separate docker-compose binary) is not installed any more: every script
# on the host uses "docker compose". Sourced by install.sh.

STEP_40_TITLE="Docker Engine and Compose plugin"

step_40_run() {
    heading "$STEP_40_TITLE"
    checklist_require ADMIN_USER
    if docker_ok; then
        log_ok "Docker present: $(docker --version) / $(docker compose version)"
    else
        log_info "Installing Docker for $OS_PRETTY..."
        docker_install
        docker_ok || die "Docker is installed but 'docker compose version' fails."
        log_ok "Docker installed: $(docker --version)"
    fi
    run usermod -aG docker "$ADMIN_USER"
    if ! docker network inspect traefik_web >/dev/null 2>&1; then
        run docker network create traefik_web
        log_ok "Network traefik_web created."
    else
        log_ok "Network traefik_web exists."
    fi
    step_done 40
    log_ok "Docker ready. $ADMIN_USER needs a new login for the docker group."
}
