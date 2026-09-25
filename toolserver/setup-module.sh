#!/usr/bin/env bash
# =============================================================================
# setup-module.sh <module> -- one extension of the Toolserver onto THIS host, as demo.
#
# Started from the interface, never typed: Environment > Server-Config > Modules writes a
# job (public.platform_agent_jobs, action "module", target = the module's key), and this
# host's Verwalter (verwalter.py, root) runs this script with the key as its one argument.
# Operator 2026-09-25: "die Erweiterungen werden selectiv ueber die oberflaeche nach
# Terminalinstallation geholt" -- the terminal installs the open core only.
#
# What it does:
#   1. checks the key: a module the Toolserver knows, of the tier addon (extension).
#      Nothing else is fetched here -- the open core is there already, and lingra's
#      internal tier is never installed (lib/stufen.py refuses it by name as well);
#   2. adds its files -- and those of the modules it requires (platform_modules.requires,
#      written by the Toolserver at start: Governance and Ramson need Workspace) -- to the
#      working copy (toolserver-quelle.sh), at the SAME state as the open core that runs:
#      the working copy is not updated here;
#   3. copies them into /opt/toolserver and restarts through deploy.sh, which first proves
#      that the application builds from the files on disk;
#   4. asks the Toolserver whether it found the module installed at its start.
# Every extension ships in full function as a demo (D-OPENCORE-12). The demo period is
# checked by the extension itself (D-OPENCORE-13), not here.
#
# Lives in the installer repository (toolserver/) and in /opt/<domain>/, next to
# toolserver-quelle.sh. The working copy and lib/stufen.py are the installer's, under
# /opt/onions-server -- the same path on every host.
# =============================================================================
set -euo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/onions-server}"
SRC="${TOOLSERVER_SRC:-$INSTALL_ROOT/src/onions-toolserver}"
STUFEN="$INSTALL_ROOT/lib/stufen.py"
TOOLSERVER_DIR="${TOOLSERVER_DIR:-/opt/toolserver}"
# shellcheck source=toolserver-quelle.sh
. "$HIER/toolserver-quelle.sh"

# no terminal behind the Verwalter: git must fail instead of asking
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

_psql() { docker exec toolserver-postgres psql -U toolserver -d toolserver -tA -F '|' -c "$1"; }

MODUL="${1:-}"
if [[ ! "$MODUL" =~ ^[a-z][a-z0-9_]{1,39}$ ]]; then
    echo "[ERROR] usage: setup-module.sh <module key> -- got '${MODUL}'"
    exit 1
fi
[[ -d "$SRC/.git" ]] || { echo "[ERROR] No Toolserver working copy at $SRC -- this host was not set up by the installer."; exit 1; }
[[ -f "$STUFEN" ]] || { echo "[ERROR] $STUFEN is missing -- the installer checkout is incomplete."; exit 1; }

zeile="$(_psql "SELECT tier, installed, array_to_string(requires, ' ') FROM public.platform_modules WHERE key = '$MODUL'")"
if [[ -z "$zeile" ]]; then
    echo "[ERROR] The Toolserver does not know a module '$MODUL'."
    exit 1
fi
IFS='|' read -r stufe da braucht <<< "$zeile"
if [[ "$stufe" != addon ]]; then
    echo "[ERROR] '$MODUL' is no extension (tier ${stufe:-none}) -- only extensions are fetched here."
    exit 1
fi
if [[ "$da" == t ]]; then
    echo "[OK] '$MODUL' is installed already -- nothing to do."
    exit 0
fi
schon="$(tsq_erweiterungen)" || { echo "[ERROR] The Toolserver's database did not say which extensions are installed -- nothing fetched."; exit 1; }

echo "[INFO] Fetching '$MODUL'${braucht:+ with what it requires: $braucht} (demo)..."
# shellcheck disable=SC2086 -- word splitting of the lists is intended
tsq_setzen "$SRC" "$STUFEN" base $schon $braucht "$MODUL"
rsync -a --exclude='.git' --exclude='volumes/' --exclude='secrets/' --exclude='.env' \
    --exclude='__pycache__' --exclude='*.pyc' "$SRC/" "$TOOLSERVER_DIR/"
bash "$TOOLSERVER_DIR/deploy.sh"

da="$(_psql "SELECT installed FROM public.platform_modules WHERE key = '$MODUL'")"
if [[ "$da" != t ]]; then
    echo "[ERROR] After the restart the Toolserver does not find '$MODUL' installed -- see the start log above."
    exit 1
fi
echo "[OK] '$MODUL' installed as demo -- its tile is live after reloading the page."
