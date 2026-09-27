#!/bin/bash
# ==============================================================================
# setup-chromium.sh -- headless Chromium as the third stage of page fetching
#
#   sudo /opt/<domain>/setup-chromium.sh           (the domain is this directory's name)
#   sudo /opt/<domain>/setup-chromium.sh --purge
#
# Repeatable. Internal: toolserver-chromium:8080 in the network browser_net.
# No outside access, no Traefik labels.
#
# What uses it: the price and source research of the Toolserver (AI Sources) fetches a
# page directly first; only when that is not enough does it ask this browser
# (services/svc_browser_client.py, connector kind "browser"). Without it the research
# still runs and names the stage "not set up".
#
# The script is complete: it writes service, package list and compose file itself. From
# the Toolserver it needs exactly one file -- services/svc_urlguard.py, the address guard,
# mounted read-only.
#
# WHY ITS OWN CONTAINER AND NETWORK: the service EXECUTES foreign pages. An executed page
# makes requests of its own; svc_urlguard otherwise checks only what WE fetch. In the
# network traefik_web a browser could reach every other container; in browser_net only
# the Toolserver is there. On top, every sub-request of the page goes through the same
# check_url.
#
# SANDBOX: Chromium runs WITH its sandbox (no --no-sandbox). For that the container needs
# CAP_SYS_ADMIN; exploitable only as root, and the service runs as pwuser with
# no-new-privileges and without every other capability.
#
# 2026-09-27 (GAP-ENV-KUNDE-WEITERE-DIENSTE-01): taken over from the setup script of the
# Onions server into the installer. Changed against the original: the access key goes
# into the Toolserver as connector "Page fetch (browser)" by itself (toolserver-link.sh)
# instead of being printed for typing in; the catalogue marks Chromium installed; a
# sichern.sh is written (sicherung.sh); texts in English.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_DIR="/opt/chromium"
readonly COMPOSE_FILE="${BASE_DIR}/docker-compose.chromium.yml"
readonly KEYFILE="${BASE_DIR}/credentials/.chromium_access_key"
readonly SERVICE_FILE="${BASE_DIR}/browser_service.py"
readonly REQ_FILE="${BASE_DIR}/requirements.txt"
readonly NETWORK="browser_net"
readonly TOOLSERVER_DIR="/opt/toolserver"
readonly GUARD="${TOOLSERVER_DIR}/services/svc_urlguard.py"

# Image and pip version of playwright must match: the browsers are in the image, the
# Python package comes by pip. Both 1.49.0.
readonly PW_VERSION="1.49.0"
readonly IMAGE="mcr.microsoft.com/playwright/python:v${PW_VERSION}-noble"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        *) echo "Unknown option: $arg (known: --purge)"; exit 1 ;;
    esac
done

ok()   { echo -e "\033[1;32m[OK]\033[0m $1"; }
info() { echo -e "\033[1;36m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

# shellcheck source=toolserver-link.sh
if [[ -f "${SCRIPT_DIR}/toolserver-link.sh" ]]; then
    . "${SCRIPT_DIR}/toolserver-link.sh"
else
    ts_connector_register()  { warn "toolserver-link.sh missing in ${SCRIPT_DIR} -- connector not registered."; }
    ts_catalogue_installed() { warn "toolserver-link.sh missing in ${SCRIPT_DIR} -- catalogue not updated."; }
fi

# ------------------------------------------------------------------ service ---
create_service() {
    cat >"$SERVICE_FILE" <<'PYEOF'
"""browser_service.py -- headless Chromium as the third fetch stage.

Written by setup-chromium.sh. Lines changed by hand are lost on the next run.

One job: open an address, wait until the page has built its content, return the
finished HTML.

EVERY request the page makes by itself goes through the same check_url as the
Toolserver's direct fetch. What does not pass is aborted and counted; the count
is in the answer.

No login, no session, no persistent profile, no downloads: every call gets a
fresh context that is closed afterwards.
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys
import time
from typing import Optional

# Mounted read-only. Exactly one file comes from there: the address guard.
sys.path.insert(0, "/toolserver")

from fastapi import FastAPI, Header, HTTPException          # noqa: E402
from pydantic import BaseModel                              # noqa: E402

from services.svc_urlguard import check_url, UrlBlocked     # noqa: E402

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("chromium")

ACCESS_KEY = os.environ.get("CHROMIUM_ACCESS_KEY", "").strip()
NAV_TIMEOUT_MS = int(os.environ.get("CHROMIUM_NAV_TIMEOUT_MS", "45000"))
IDLE_TIMEOUT_MS = int(os.environ.get("CHROMIUM_IDLE_TIMEOUT_MS", "8000"))
MAX_HTML_BYTES = int(os.environ.get("CHROMIUM_MAX_HTML_BYTES", "5000000"))
MAX_PARALLEL = int(os.environ.get("CHROMIUM_MAX_PARALLEL", "1"))
MAX_SUBREQUESTS = int(os.environ.get("CHROMIUM_MAX_SUBREQUESTS", "300"))

#: Adds nothing to a price table -- saves memory, time, attack surface.
BLOCKED_TYPES = {"image", "media", "font"}

app = FastAPI(title="onions chromium", docs_url=None, redoc_url=None)

_browser = None
_playwright = None
_lock = asyncio.Semaphore(MAX_PARALLEL)
_dns_cache: dict = {}


class RenderIn(BaseModel):
    url: str
    wait_selector: Optional[str] = None
    wait_ms: Optional[int] = None


async def _check(url: str) -> Optional[str]:
    """The reason when the address must NOT be fetched, otherwise None."""
    host = ""
    try:
        if "://" in url:
            host = url.split("/", 3)[2]
    except IndexError:
        host = ""
    if host and host in _dns_cache:
        return _dns_cache[host]
    try:
        await asyncio.wait_for(asyncio.to_thread(check_url, url), timeout=5.0)
        reason = None
    except UrlBlocked as exc:
        reason = str(exc)
    except asyncio.TimeoutError:
        reason = "name resolution took too long: %s" % (host or url)
    except Exception as exc:                                  # noqa: BLE001
        reason = "address not checkable: %s" % str(exc)[:120]
    if host:
        _dns_cache[host] = reason
    return reason


async def _start():
    global _browser, _playwright
    if _browser is not None:
        return _browser
    from playwright.async_api import async_playwright
    _playwright = await async_playwright().start()
    _browser = await _playwright.chromium.launch(
        headless=True,
        # NO --no-sandbox.
        args=["--disable-dev-shm-usage", "--disable-gpu",
              "--disable-background-networking", "--no-first-run",
              "--disable-extensions", "--mute-audio"],
    )
    logger.info("Chromium started")
    return _browser


@app.on_event("shutdown")
async def _stop():
    global _browser, _playwright
    try:
        if _browser is not None:
            await _browser.close()
        if _playwright is not None:
            await _playwright.stop()
    except Exception:                                          # noqa: BLE001
        pass
    _browser, _playwright = None, None


@app.get("/health")
async def health():
    """Answers only when playwright is REALLY there -- otherwise the service would
    report healthy and fail at its first fetch."""
    try:
        import playwright                                      # noqa: F401
        ready, error = True, None
    except Exception as exc:                                   # noqa: BLE001
        ready, error = False, str(exc)
    if not ready:
        raise HTTPException(503, "playwright missing: %s" % error)
    return {"status": "ok", "browser": _browser is not None,
            "key_configured": bool(ACCESS_KEY)}


@app.post("/render")
async def render(body: RenderIn, x_browser_key: str = Header(default="")):
    if not ACCESS_KEY:
        raise HTTPException(503, "No access key configured.")
    if x_browser_key != ACCESS_KEY:
        raise HTTPException(401, "Wrong access key")

    reason = await _check(body.url)
    if reason:
        raise HTTPException(400, "Address not fetchable: %s" % reason)

    started = time.monotonic()
    counts = {"gestellt": 0, "gesperrt_adresse": 0, "gesperrt_art": 0,
              "gesperrt_menge": 0}
    blocked: list = []
    async with _lock:
        browser = await _start()
        context = await browser.new_context(
            accept_downloads=False, java_script_enabled=True, locale="de-DE",
            viewport={"width": 1280, "height": 1600},
            user_agent=("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                        "AppleWebKit/537.36 (KHTML, like Gecko) "
                        "Chrome/126.0.0.0 Safari/537.36"))

        async def _route(route, request):
            counts["gestellt"] += 1
            if counts["gestellt"] > MAX_SUBREQUESTS:
                counts["gesperrt_menge"] += 1
                await route.abort(); return
            if request.resource_type in BLOCKED_TYPES:
                counts["gesperrt_art"] += 1
                await route.abort(); return
            why = await _check(request.url)
            if why:
                counts["gesperrt_adresse"] += 1
                if len(blocked) < 10:
                    blocked.append({"url": request.url[:200], "grund": why})
                logger.warning("blocked: %s (%s)", request.url[:200], why)
                await route.abort(); return
            await route.continue_()

        await context.route("**/*", _route)
        page = await context.new_page()
        try:
            answer = await page.goto(body.url, wait_until="domcontentloaded",
                                     timeout=NAV_TIMEOUT_MS)
            status = answer.status if answer else None
            try:
                await page.wait_for_load_state("networkidle", timeout=IDLE_TIMEOUT_MS)
            except Exception:                                  # noqa: BLE001
                pass
            if body.wait_selector:
                try:
                    await page.wait_for_selector(body.wait_selector, timeout=IDLE_TIMEOUT_MS)
                except Exception:                              # noqa: BLE001
                    pass
            if body.wait_ms:
                await page.wait_for_timeout(min(int(body.wait_ms), 15000))
            html = await page.content()
            final_url = page.url
        except Exception as exc:                               # noqa: BLE001
            raise HTTPException(
                502, "The page could not be opened: %s" % str(exc)[:300]) from exc
        finally:
            try:
                await context.close()
            except Exception:                                  # noqa: BLE001
                pass

    if len(html) > MAX_HTML_BYTES:
        html = html[:MAX_HTML_BYTES]
    took = int((time.monotonic() - started) * 1000)
    logger.info("rendered: %s -> %d chars, %d requests, %d blocked, %d ms",
                body.url[:120], len(html), counts["gestellt"],
                counts["gesperrt_adresse"], took)
    # The keys of the answer are what svc_browser_client.py reads -- unchanged.
    return {"url": final_url, "status": status, "html": html,
            "chars": len(html), "requests": counts,
            "blocked_examples": blocked, "took_ms": took}
PYEOF
    ok "Service written: ${SERVICE_FILE}"
}

# ------------------------------------------------------------ package list ---
# playwright IS in here: the image brings the browsers, but the Python package was not
# importable for the Python that starts the service. With a fixed version it matches the
# browser in the image; the browsers are NOT downloaded again.
create_requirements() {
    cat >"$REQ_FILE" <<EOF
fastapi>=0.115.0
uvicorn[standard]>=0.30.0
pydantic>=2.5.0
playwright==${PW_VERSION}
EOF
    ok "Package list written: ${REQ_FILE}"
}

# ----------------------------------------------------------------- compose ---
# The start command stays on ONE line (YAML folding once left pip without a package).
# PATH is NOT set: the image brings its own.
create_compose() {
    cat >"$COMPOSE_FILE" <<EOF
# Written by setup-chromium.sh -- changes belong into the script.
services:

  toolserver-chromium:
    image: ${IMAGE}
    container_name: toolserver-chromium
    restart: unless-stopped
    user: pwuser
    working_dir: /srv
    volumes:
      - ${SERVICE_FILE}:/srv/browser_service.py:ro
      - ${REQ_FILE}:/srv/requirements.txt:ro
      - ${TOOLSERVER_DIR}:/toolserver:ro
    command: bash -c "pip install --no-cache-dir --user --break-system-packages -r /srv/requirements.txt && python -m uvicorn browser_service:app --host 0.0.0.0 --port 8080 --log-level info"
    environment:
      CHROMIUM_ACCESS_KEY: "${CHROMIUM_ACCESS_KEY}"
      CHROMIUM_NAV_TIMEOUT_MS: "45000"
      CHROMIUM_IDLE_TIMEOUT_MS: "8000"
      CHROMIUM_MAX_HTML_BYTES: "5000000"
      CHROMIUM_MAX_PARALLEL: "1"
      CHROMIUM_MAX_SUBREQUESTS: "300"
      PYTHONDONTWRITEBYTECODE: "1"
      PYTHONPATH: "/srv"
    networks: [${NETWORK}]
    mem_limit: 2g
    pids_limit: 512
    shm_size: 1gb
    cap_drop: [ALL]
    cap_add: [SYS_ADMIN]
    security_opt:
      - no-new-privileges:true
    labels:
      - "traefik.enable=false"
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:8080/health')\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s

networks:
  ${NETWORK}:
    external: true
EOF
    chmod 640 "$COMPOSE_FILE"
    ok "Compose file written: ${COMPOSE_FILE}"
}

# ------------------------------------------------------------------- start ---
start_stack() {
    (cd "${BASE_DIR}" && docker compose -f docker-compose.chromium.yml up -d)
    info "Waiting for the service (the first start loads packages, up to 300 s) ..."
    local waited=0 restarts=0
    while [ "$waited" -lt 300 ]; do
        if docker exec toolserver-chromium python3 -c \
             "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" \
             >/dev/null 2>&1; then
            ok "The service answers (after ${waited} s)."
            return 0
        fi
        restarts="$(docker inspect -f '{{.RestartCount}}' toolserver-chromium 2>/dev/null || echo 0)"
        if [ "${restarts:-0}" -ge 3 ]; then
            err "The container keeps restarting (${restarts}x). Log:"
            docker logs --tail 30 toolserver-chromium || true
            exit 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    err "No answer after 300 s. Log:"
    docker logs --tail 40 toolserver-chromium || true
    exit 1
}

# ------------------------------------------------------------------- probe ---
smoke_test() {
    info "Test fetch (example.com) ..."
    if docker exec -i toolserver-chromium python3 - <<'PYEOF'
import json, os, sys, urllib.request
req = urllib.request.Request(
    "http://localhost:8080/render",
    data=json.dumps({"url": "https://example.com"}).encode(),
    headers={"Content-Type": "application/json",
             "X-Browser-Key": os.environ.get("CHROMIUM_ACCESS_KEY", "")})
try:
    with urllib.request.urlopen(req, timeout=120) as r:
        d = json.load(r)
    print("  chars:", d.get("chars"), "| took (ms):", d.get("took_ms"),
          "| requests:", (d.get("requests") or {}).get("gestellt"))
    sys.exit(0 if (d.get("chars") or 0) > 200 else 1)
except Exception as exc:
    print("  ERROR:", exc)
    sys.exit(1)
PYEOF
    then
        ok "Test fetch succeeded -- Chromium runs with its sandbox."
    else
        err "Test fetch failed. Last log lines:"
        docker logs --tail 25 toolserver-chromium || true
        exit 1
    fi
}

# -------------------------------------------------------------------- rest ---
purge_stack() {
    warn "--purge: the browser service is removed."
    if [ -f "$COMPOSE_FILE" ]; then
        (cd "${BASE_DIR}" && docker compose -f docker-compose.chromium.yml down --remove-orphans) || true
    fi
    rm -f "$COMPOSE_FILE" "$SERVICE_FILE" "$REQ_FILE"
    warn "Network ${NETWORK} and the key stay -- the Toolserver is attached to the network."
    ok "Removed."
}

write_backup_script() {
    if [[ -f "${SCRIPT_DIR}/sicherung.sh" ]]; then
        # shellcheck source=sicherung.sh
        . "${SCRIPT_DIR}/sicherung.sh"
        backup_script_write "$BASE_DIR" "backup_run chromium ${BASE_DIR} /opt/backups/chromium/sicherung"
    else
        warn "sicherung.sh missing in ${SCRIPT_DIR} -- no backup script written."
    fi
}

main() {
    [ "$EUID" -ne 0 ] && { err "Run it with sudo."; exit 1; }
    mkdir -p "${BASE_DIR}/credentials"
    chmod 700 "${BASE_DIR}/credentials"
    if [ "$PURGE" -eq 1 ]; then purge_stack; exit 0; fi

    [ -f "$GUARD" ] || { err "${GUARD} is missing -- the Toolserver comes first."; exit 1; }
    ok "Address guard found."

    if [ -s "$KEYFILE" ]; then
        CHROMIUM_ACCESS_KEY="$(cat "$KEYFILE")"
        ok "Access key kept."
    else
        CHROMIUM_ACCESS_KEY="$(openssl rand -hex 32)"
        (umask 077; echo "$CHROMIUM_ACCESS_KEY" > "$KEYFILE")
        ok "Access key generated."
    fi

    docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
    ok "Network ${NETWORK} present."

    create_service
    python3 -m py_compile "$SERVICE_FILE" || { err "Service does not compile."; exit 1; }
    rm -rf "${BASE_DIR}/__pycache__"
    create_requirements
    create_compose
    start_stack
    smoke_test
    ts_connector_register browser "Page fetch (browser)" "http://toolserver-chromium:8080" "$CHROMIUM_ACCESS_KEY"
    ts_catalogue_installed chromium
    write_backup_script

    echo ""
    ok "Chromium runs: toolserver-chromium:8080 (network ${NETWORK})."
    ok "The research of the Toolserver uses it as its third fetch stage from now on."
}

main "$@"
