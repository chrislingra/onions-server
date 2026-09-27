#!/bin/bash
# tests/test_sicherung.sh -- toolserver/sicherung.sh without Docker: archive, exclusion,
# retention, the written sichern.sh, refusals. Called by tests/selftest.sh.
set -euo pipefail
HIER="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/svc/volumes/postgres-data" "$T/svc/conf"
echo "config" > "$T/svc/conf/a.yml"
echo "rohdaten" > "$T/svc/volumes/postgres-data/big"
echo "alt" > "$T/svc/x.yml.bak"
. "$HIER/../toolserver/sicherung.sh"
for i in 1 2 3 4 5; do
    backup_run testsvc "$T/svc" "$T/backup" --exclude volumes/postgres-data --keep 3 >/dev/null
    sleep 1.1
done
n=$(ls "$T/backup/daily" | wc -l)
echo "Dateien nach 5 Laeufen mit --keep 3: $n (erwartet 3)"
[[ "$n" == 3 ]] || { echo "FAIL keep"; exit 1; }
a=$(ls "$T/backup/daily" | tail -1)
inhalt=$(tar -tzf "$T/backup/daily/$a")
echo "$inhalt" | grep -q "conf/a.yml" || { echo "FAIL inhalt"; exit 1; }
if echo "$inhalt" | grep -q "postgres-data/big"; then echo "FAIL ausschluss"; exit 1; fi
if echo "$inhalt" | grep -q "x.yml.bak"; then echo "FAIL bak"; exit 1; fi
echo "Archiv enthaelt conf/a.yml, nicht postgres-data und nicht *.bak"
ls "$T/backup/daily"/*.part >/dev/null 2>&1 && { echo "FAIL part"; exit 1; }
backup_script_write "$T/svc" "backup_run testsvc $T/svc $T/backup --keep 3"
bash -n "$T/svc/sichern.sh"
bash "$T/svc/sichern.sh" | tail -1
backup_run testsvc "$T/fehlt" "$T/backup" >/dev/null 2>&1 && { echo "FAIL fehlendes Verzeichnis"; exit 1; }
echo "Fehlendes Verzeichnis: abgelehnt"
backup_run "BAD KEY" "$T/svc" "$T/backup" >/dev/null 2>&1 && { echo "FAIL key"; exit 1; }
echo "Ungueltiger Schluessel: abgelehnt"
echo "ALLES OK"
