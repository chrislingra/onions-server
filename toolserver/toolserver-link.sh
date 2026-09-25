#!/bin/bash
# =============================================================================
# toolserver-link.sh -- how a setup script tells the Toolserver of THIS host that its
# service exists. Sourced (never run) by setup-<service>.sh from the same directory,
# /opt/<domain>/.
#
# Two things, both only when the Toolserver runs on this host (container toolserver-
# postgres); without it the functions say so and return 0 -- a service set up by hand
# before the Toolserver exists is not an error:
#   ts_connector_register   the connector the Toolserver reads the service by (Fernet-
#                           encrypted with the Toolserver's own key, inside its container
#                           -- one algorithm, one place). Only when there is no active
#                           connector of that type yet: an existing one is the operator's
#                           and is never touched.
#   ts_catalogue_installed  public.platform_components.installed_at for the service, so
#                           Environment > Installation > Updates shows it. The trigger on
#                           that table keeps the menu in step.
#
# 2026-09-25, GAP-ENV-INSTALL-VOLLBETRIEB-01: the installer (onions-server step 7) sets up
# Weaviate and Nextcloud right after the Toolserver. Until then the connectors were typed
# in by hand, and the catalogue of a fresh host was the copy of the Onions server's.
# The same file lives in the installer repository (toolserver/) and in /opt/<domain>/.
# =============================================================================

_ts_psql() { docker exec -i toolserver-postgres psql -U toolserver -d toolserver -v ON_ERROR_STOP=1 -qtA "$@"; }

ts_present() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx toolserver-postgres \
        && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx toolserver
}

# ts_connector_register <type> <name> <base_url> <secret> [config_json]
ts_connector_register() {
    local type="$1" name="$2" url="$3" secret="$4" cfg="${5:-}" n enc
    [ -n "$cfg" ] || cfg='{}'
    if ! ts_present; then
        echo "[INFO] No Toolserver on this host -- connector '$name' not registered."
        return 0
    fi
    n="$(_ts_psql -c "SELECT count(*) FROM public.connectors WHERE type = '$type' AND active")"
    if [ "${n:-0}" != "0" ]; then
        echo "[OK] Toolserver: a connector of type $type is already there -- unchanged."
        return 0
    fi
    enc="$(docker exec -e TS_SECRET="$secret" toolserver python3 -c '
import os
from services.db_credentials import encrypt_credential
print(encrypt_credential(os.environ["TS_SECRET"]))
')" || { echo "[ERROR] Toolserver could not encrypt the secret for '$name'."; return 1; }
    _ts_psql <<SQL
INSERT INTO public.connectors (id, tenant_id, type, name, base_url, api_key_enc, config_json, scope)
VALUES (gen_random_uuid()::text, 'default', '$type', '$name', '$url', '$enc', '$cfg'::jsonb, 'system');
SQL
    echo "[OK] Toolserver: connector '$name' registered ($url)."
}

# ts_catalogue_installed <component key>
ts_catalogue_installed() {
    local key="$1"
    if ! ts_present; then
        echo "[INFO] No Toolserver on this host -- catalogue not updated."
        return 0
    fi
    _ts_psql -c "UPDATE public.platform_components SET installed_at = COALESCE(installed_at, now()), updated_at = now() WHERE key = '$key'" >/dev/null
    echo "[OK] Toolserver: '$key' marked installed (Environment > Installation > Updates)."
}
