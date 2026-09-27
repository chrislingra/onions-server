#!/bin/bash
# =============================================================================
# sicherung.sh -- how a service of THIS host is backed up. Sourced (never run) by the
# sichern.sh each setup script writes into its service directory; the Verwalter runs that
# sichern.sh when Environment > Server-Config > Backups or the backup schedule asks for it
# (public.platform_components.backup_script = sichern.sh, relative to service_dir).
#
# Why (GAP-ENV-KUNDE-DIENSTE-SICHERUNG-01, 2026-09-27): the catalogue names sichern.sh for
# Nextcloud, Weaviate, Traefik and the docserver, and the Verwalter runs only a script
# that exists. On the Onions server these came with its own setup scripts; the installer's
# setup scripts wrote none, so "Back up" failed on every new host.
#
#   backup_run <key> <service_dir> <backup_dir> [options]
#       --pg <container> <user> <database>   pg_dump first (consistent), and the raw
#                                            database directory is left out of the files
#       --exclude <path>                     leave out a path relative to <service_dir>
#       --pause <container>                  freeze the container while its files are
#                                            read (docker pause) -- a consistent copy of
#                                            a store that writes all the time
#       --occ <container>                    Nextcloud: maintenance mode on for the run
#       --keep <n>                           how many runs stay (default 7)
#   backup_script_write <service_dir> <line>
#       writes <service_dir>/sichern.sh: sources this file, then runs <line>.
#
# One run = one stamp: <backup_dir>/daily/<key>-files-<stamp>.tar.gz and, with --pg,
# <key>-db-<stamp>.sql.gz. A run writes .part files and renames them only after gzip -t
# has proven them readable; a failed run leaves nothing that looks like a backup. The
# Backups window lists the files under <backup_dir> (two levels).
#
# Lives in the installer repository (toolserver/) and in /opt/<domain>/.
# =============================================================================

_sich_log()  { echo "[$1] $2"; }

backup_run() {
    local key="$1" dir="$2" dest="$3"; shift 3
    local pg_container="" pg_user="" pg_db="" pause="" occ="" keep=7
    local excludes=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pg)      pg_container="$2"; pg_user="$3"; pg_db="$4"; shift 4 ;;
            --exclude) excludes+=("$2"); shift 2 ;;
            --pause)   pause="$2"; shift 2 ;;
            --occ)     occ="$2"; shift 2 ;;
            --keep)    keep="$2"; shift 2 ;;
            *) _sich_log ERROR "backup_run: unknown option $1"; return 2 ;;
        esac
    done
    [[ "$key" =~ ^[a-z][a-z0-9_-]{0,39}$ ]] || { _sich_log ERROR "backup_run: invalid key '$key'"; return 2; }
    [[ -d "$dir" ]] || { _sich_log ERROR "$dir does not exist -- nothing to back up."; return 1; }
    [[ "$keep" =~ ^[1-9][0-9]*$ ]] || { _sich_log ERROR "backup_run: --keep needs a number"; return 2; }

    local target="$dest/daily" stamp
    stamp="$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$target"
    chmod 700 "$dest" "$target"
    rm -f "$target"/*.part 2>/dev/null || true

    local tar_ex=(--exclude='*.bak' --exclude='__pycache__') du_ex=(--exclude='*.bak')
    local e
    for e in "${excludes[@]}"; do
        tar_ex+=(--exclude="./$e")
        du_ex+=(--exclude="$dir/$e")
    done

    # room: the files of the service once more, plus a tenth
    local need avail
    need="$(du -sb "${du_ex[@]}" "$dir" 2>/dev/null | cut -f1)" || true
    avail="$(df -B1 --output=avail "$target" 2>/dev/null | tail -1 | tr -d ' ')" || true
    if [[ "$need" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] && (( need + need / 10 > avail )); then
        _sich_log ERROR "Not enough space in $target: $(( need / 1048576 )) MB needed, $(( avail / 1048576 )) MB free. Nothing written."
        return 1
    fi

    local rc=0 fehler="" occ_an=0 pausiert=0

    if [[ -n "$occ" ]]; then
        if docker exec -u www-data "$occ" php occ maintenance:mode --on >/dev/null 2>&1; then
            occ_an=1
            _sich_log INFO "$occ: maintenance mode on for the backup."
        else
            _sich_log WARN "$occ: maintenance mode could not be switched on -- backing up while it runs."
        fi
    fi

    if [[ -n "$pg_container" ]]; then
        local dump="$target/${key}-db-${stamp}.sql.gz"
        _sich_log INFO "Database $pg_db ($pg_container) ..."
        if docker exec "$pg_container" pg_dump -U "$pg_user" -d "$pg_db" --no-owner | gzip > "$dump.part" \
           && gzip -t "$dump.part"; then
            mv "$dump.part" "$dump"
            _sich_log OK "Database: $(basename "$dump") ($(du -h "$dump" | cut -f1))."
        else
            rm -f "$dump.part"
            fehler="database dump of $pg_db failed"
        fi
    fi

    if [[ -z "$fehler" ]]; then
        local arch="$target/${key}-files-${stamp}.tar.gz"
        if [[ -n "$pause" ]] && docker pause "$pause" >/dev/null 2>&1; then
            pausiert=1
            _sich_log INFO "$pause paused while its files are read."
        fi
        _sich_log INFO "Files of $dir ..."
        set +e
        tar --warning=no-file-changed "${tar_ex[@]}" -czf "$arch.part" -C "$dir" .
        rc=$?
        set -e
        if (( pausiert )); then docker unpause "$pause" >/dev/null 2>&1 || true; pausiert=0; fi
        # tar: 1 = a file changed while it was read -- the archive is complete otherwise
        if (( rc <= 1 )) && gzip -t "$arch.part"; then
            mv "$arch.part" "$arch"
            (( rc == 1 )) && _sich_log WARN "Some files changed while they were read."
            _sich_log OK "Files: $(basename "$arch") ($(du -h "$arch" | cut -f1))."
        else
            rm -f "$arch.part"
            fehler="archive of $dir failed (tar exit $rc)"
        fi
    fi

    if (( occ_an )); then
        docker exec -u www-data "$occ" php occ maintenance:mode --off >/dev/null 2>&1 \
            || _sich_log ERROR "$occ: maintenance mode could not be switched off -- do it by hand: occ maintenance:mode --off"
        _sich_log INFO "$occ: maintenance mode off."
    fi

    if [[ -n "$fehler" ]]; then
        # a half run is no run: what this stamp wrote goes
        rm -f "$target/${key}-"*"-${stamp}".*
        _sich_log ERROR "Backup of $key failed: $fehler. Older backups are untouched."
        return 1
    fi

    # keep the newest <keep> runs; a run = one stamp
    local stamps alt
    stamps="$(find "$target" -maxdepth 1 -type f -name "${key}-*-*.gz" -printf '%f\n' \
              | sed -E 's/.*-([0-9]{8}-[0-9]{6})\..*/\1/' | sort -ur)"
    alt="$(printf '%s\n' "$stamps" | tail -n +"$(( keep + 1 ))")"
    local s n=0
    for s in $alt; do
        rm -f "$target/${key}-"*"-${s}".*
        n=$(( n + 1 ))
    done
    (( n )) && _sich_log INFO "$n older run(s) removed, $keep kept."
    _sich_log OK "Backup of $key complete: $target ($stamp)."
    return 0
}

# backup_script_write <service_dir> <line> -- <service_dir>/sichern.sh, the file the
# catalogue names. The line is the backup_run call of this service.
backup_script_write() {
    local dir="$1" line="$2" lib
    lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sicherung.sh"
    cat > "$dir/sichern.sh" <<EOF
#!/bin/bash
# $dir/sichern.sh -- written by the setup script of this service; do not edit, the next
# setup run writes it again. Run by the Verwalter (Environment > Server-Config > Backups).
set -euo pipefail
. "$lib"
$line
EOF
    chmod 750 "$dir/sichern.sh"
    echo "[OK] Backup script written: $dir/sichern.sh"
}
