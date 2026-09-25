#!/bin/bash
# =============================================================================
# toolserver-quelle.sh -- which files of the Toolserver lie on THIS host. Sourced (never
# run) by the installer's step 7 and by setup-module.sh. The same file lives in the
# installer repository (toolserver/) and in /opt/<domain>/.
#
#   tsq_setzen <src> <stufen.py> <tier or module>...
#       The working copy <src> (a partial git clone) holds exactly the registered files of
#       what is named -- lib/stufen.py reads them from the start dump -- plus db/patches/.
#       The pending patches are pieces of a delivery, not rows of the registry, and
#       dbmigrate.sh applies every one lying there. A file outside the named tiers and
#       modules is neither in the working copy nor, with a partial clone, even downloaded.
#   tsq_erweiterungen
#       The extensions the Toolserver on this host found installed at its last start
#       (public.platform_modules: tier addon, installed). Fails when the database does
#       not answer -- a caller that went on without them would drop them silently.
#
# Operator 2026-09-25: open core first; "die Erweiterungen werden selectiv ueber die
# oberflaeche nach Terminalinstallation geholt"; "lingra darf niemals auftauchen".
# =============================================================================

tsq_setzen() {
    local src="$1" stufen="$2"; shift 2
    local liste zweig n
    liste="$(mktemp)" || return 1
    if ! git -C "$src" show HEAD:db/schema_seed.sql | python3 "$stufen" "$@" > "$liste"; then
        rm -f "$liste"
        echo "[ERROR] Which file belongs where could not be read from the start dump (db/schema_seed.sql) -- see above." >&2
        return 1
    fi
    n="$(wc -l < "$liste")"
    echo "/db/patches/" >> "$liste"
    if ! git -C "$src" sparse-checkout set --no-cone --stdin < "$liste"; then
        rm -f "$liste"
        return 1
    fi
    rm -f "$liste"
    zweig="$(git -C "$src" symbolic-ref --short HEAD)" || return 1
    git -C "$src" checkout -q "$zweig" || return 1
    echo "[OK] Working copy holds the $n registered files of: $*"
}

tsq_erweiterungen() {
    docker exec toolserver-postgres psql -U toolserver -d toolserver -tAc \
        "SELECT key FROM public.platform_modules WHERE installed AND tier = 'addon' ORDER BY sort_order, key"
}
