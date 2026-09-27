#!/usr/bin/env bash
# =============================================================================
# remove-module.sh <module> -- one extension of the Toolserver off THIS host again.
#
# Started from the interface, never typed: Environment > Server-Config > Modules writes a
# job (public.platform_agent_jobs, action "module_remove", target = the module's key), and
# this host's Verwalter (verwalter.py, root, v12) runs this script with the key as its one
# argument. The counterpart of setup-module.sh.
#
# Why (GAP-ENV-ERWEITERUNG-ENTFERNEN-01, 2026-09-27): a fetched extension could not be
# removed. After its demo and grace period it stayed on the host and answered 403, with no
# way to get rid of it.
#
# What it does:
#   1. checks the key: a module the Toolserver knows, of the tier addon, installed. The open
#      core is never removed here, and lingra's internal tier never was on this host;
#   2. refuses while another installed extension requires it (platform_modules.requires --
#      Governance and Ramson need Workspace, every extension needs Licence): remove those
#      first;
#   3. takes its files out of the working copy (toolserver-quelle.sh: the open core, the
#      other installed extensions and what they require stay) and deletes from
#      /opt/toolserver exactly the registered files that belong to this module and to
#      nothing that stays;
#   4. restarts through deploy.sh, which first proves that the application builds from the
#      files on disk, and asks the Toolserver whether it now finds the module absent.
#
# THE DATA STAYS. Tables, rows, uploaded files and settings of the extension are not
# touched: removing is reversible -- fetching it again under Modules brings back the
# function with its data. Deleting data cannot be undone, and nothing here asks for it.
#
# Lives in the installer repository (toolserver/) and in /opt/<domain>/, next to
# setup-module.sh and toolserver-quelle.sh.
# =============================================================================
set -euo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/onions-server}"
SRC="${TOOLSERVER_SRC:-$INSTALL_ROOT/src/onions-toolserver}"
STUFEN="$INSTALL_ROOT/lib/stufen.py"
TOOLSERVER_DIR="${TOOLSERVER_DIR:-/opt/toolserver}"
# shellcheck source=toolserver-quelle.sh
. "$HIER/toolserver-quelle.sh"

export GIT_TERMINAL_PROMPT=0

_psql() { docker exec toolserver-postgres psql -U toolserver -d toolserver -tA -F '|' -c "$1"; }

MODUL="${1:-}"
if [[ ! "$MODUL" =~ ^[a-z][a-z0-9_]{1,39}$ ]]; then
    echo "[ERROR] usage: remove-module.sh <module key> -- got '${MODUL}'"
    exit 1
fi
[[ -d "$SRC/.git" ]] || { echo "[ERROR] No Toolserver working copy at $SRC -- this host was not set up by the installer."; exit 1; }
[[ -f "$STUFEN" ]] || { echo "[ERROR] $STUFEN is missing -- the installer checkout is incomplete."; exit 1; }

zeile="$(_psql "SELECT tier, installed FROM public.platform_modules WHERE key = '$MODUL'")"
if [[ -z "$zeile" ]]; then
    echo "[ERROR] The Toolserver does not know a module '$MODUL'."
    exit 1
fi
IFS='|' read -r stufe da <<< "$zeile"
if [[ "$stufe" != addon ]]; then
    echo "[ERROR] '$MODUL' is no extension (tier ${stufe:-none}) -- only extensions are removed here."
    exit 1
fi
if [[ "$da" != t ]]; then
    echo "[OK] '$MODUL' is not installed -- nothing to do."
    exit 0
fi
abhaengig="$(_psql "SELECT string_agg(key, ' ' ORDER BY key) FROM public.platform_modules WHERE installed AND tier = 'addon' AND key <> '$MODUL' AND '$MODUL' = ANY(requires)")"
if [[ -n "$abhaengig" ]]; then
    echo "[ERROR] '$MODUL' is required by: $abhaengig -- remove those first. Nothing was changed."
    exit 1
fi

schon="$(tsq_erweiterungen)" || { echo "[ERROR] The Toolserver's database did not say which extensions are installed -- nothing removed."; exit 1; }
bleiben=""
for k in $schon; do
    [[ "$k" == "$MODUL" ]] || bleiben="$bleiben $k"
done
bleiben="${bleiben# }"
braucht=""
if [[ -n "$bleiben" ]]; then
    braucht="$(_psql "SELECT string_agg(DISTINCT r, ' ') FROM public.platform_modules m, unnest(m.requires) AS r WHERE m.key = ANY(string_to_array('$bleiben', ' '))")"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2086 -- one module key per word
if ! git -C "$SRC" show HEAD:db/schema_seed.sql | python3 "$STUFEN" "$MODUL" | sort -u > "$tmp/modul"; then
    echo "[ERROR] The files of '$MODUL' could not be read from the start dump -- nothing removed."
    exit 1
fi
# shellcheck disable=SC2086
if ! git -C "$SRC" show HEAD:db/schema_seed.sql | python3 "$STUFEN" base $bleiben $braucht | sort -u > "$tmp/rest"; then
    echo "[ERROR] The files of what stays could not be read from the start dump -- nothing removed."
    exit 1
fi
comm -23 "$tmp/modul" "$tmp/rest" > "$tmp/weg"
echo "[INFO] Removing '$MODUL': $(wc -l < "$tmp/weg") file(s) of its own; its data stays."

# shellcheck disable=SC2086 -- word splitting of the lists is intended
tsq_setzen "$SRC" "$STUFEN" base $bleiben $braucht

n=0
while IFS= read -r muster; do
    pfad="${muster#/}"
    case "$pfad" in ''|*..*|/*) continue ;; esac
    if [[ -f "$TOOLSERVER_DIR/$pfad" || -L "$TOOLSERVER_DIR/$pfad" ]]; then
        rm -f "$TOOLSERVER_DIR/$pfad"
        n=$((n + 1))
    fi
done < "$tmp/weg"
# directories the module leaves empty (its package, its screens) go as well; a directory
# without a .py file left loses its __pycache__ first
while IFS= read -r muster; do
    d="$(dirname "${muster#/}")"
    while [[ "$d" != "." && "$d" != "/" && -n "$d" ]]; do
        if [[ -d "$TOOLSERVER_DIR/$d/__pycache__" ]] && ! compgen -G "$TOOLSERVER_DIR/$d/*.py" >/dev/null; then
            rm -rf "${TOOLSERVER_DIR:?}/$d/__pycache__"
        fi
        rmdir "$TOOLSERVER_DIR/$d" 2>/dev/null || break
        d="$(dirname "$d")"
    done
done < "$tmp/weg"
echo "[OK] $n file(s) removed from $TOOLSERVER_DIR."

bash "$TOOLSERVER_DIR/deploy.sh"

da="$(_psql "SELECT installed FROM public.platform_modules WHERE key = '$MODUL'")"
if [[ "$da" == t ]]; then
    echo "[ERROR] After the restart the Toolserver still finds '$MODUL' installed -- see the start log above."
    exit 1
fi
echo "[OK] '$MODUL' removed -- its tile is gone after reloading the page. Its data stays; Install brings it back."
