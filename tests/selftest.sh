#!/usr/bin/env bash
# tests/selftest.sh -- runs WITHOUT root and without touching the system: syntax of every
# script, the distribution detection against sample os-release files, the checklist
# parser and validators, the config-line editor, the menu rendering. Anything that needs
# a real machine is out of scope here (README: Proving a run).
#   bash tests/selftest.sh        -> exit 0 = all green, 1 = at least one FAIL
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }

echo "== syntax"
for f in "$ROOT"/install.sh "$ROOT"/lib/*.sh "$ROOT"/steps/*.sh "$ROOT"/tests/*.sh; do
    check "bash -n ${f#$ROOT/}" bash -n "$f"
    if grep -q $'\r' "$f"; then fail "LF only: ${f#$ROOT/}"; else ok "LF only: ${f#$ROOT/}"; fi
done

echo "== no secrets in the tree"
if grep -rInE '(PASSWORD|PASS|SECRET|TOKEN|API_KEY)[[:space:]]*=[[:space:]]*"?[A-Za-z0-9]{6,}' "$ROOT" --include='*.sh' --include='*.yml' --include='*.md' \
    | grep -vE 'ask_secret|\$\{?[A-Za-z_]+\}?|@[A-Z_]+@|password[[:space:]]+\$pw' >/dev/null; then
    fail "a literal credential-looking assignment exists"
else
    ok "no literal credentials"
fi

# --- load the libraries the way install.sh does, but in a sandbox ---------------------
INSTALL_ROOT="$ROOT"; STATE_DIR="$TMP/state"; LOG_DIR="$TMP/logs"; RUN_STAMP="test"
LOG_FILE="$LOG_DIR/test.log"; SITE_ENV="$TMP/site.env"; DOMAIN_GUESS="example.org"
mkdir -p "$STATE_DIR" "$LOG_DIR"
. "$ROOT/lib/common.sh"; . "$ROOT/lib/os.sh"; . "$ROOT/lib/checklist.sh"
for f in "$ROOT"/steps/*.sh; do . "$f"; done

echo "== distribution detection"
detect() { printf 'ID=%s\nVERSION_ID="%s"\nVERSION_CODENAME=%s\nID_LIKE="%s"\nPRETTY_NAME="x"\n' "$1" "$2" "$3" "$4" > "$TMP/os-release"
           OS_RELEASE_FILE="$TMP/os-release" os_detect 2>/dev/null; echo "$OS_FAMILY $(os_key)"; }
check "ubuntu -> debian"   [ "$(detect ubuntu 24.04 noble debian)" = "debian ubuntu-24.04" ]
check "debian -> debian"   [ "$(detect debian 12 bookworm '')" = "debian debian-12" ]
check "rocky -> rhel"      [ "$(detect rocky 9.4 '' 'rhel centos fedora')" = "rhel rocky-9.4" ]
check "rhel -> rhel"       [ "$(detect rhel 9.4 '' fedora)" = "rhel rhel-9.4" ]
check "leap -> suse"       [ "$(detect opensuse-leap 15.6 '' 'suse opensuse')" = "suse opensuse-leap-15.6" ]
check "sles -> suse"       [ "$(detect sles 15.6 '' '')" = "suse sles-15.6" ]
check "linuxmint via ID_LIKE" [ "$(detect linuxmint 22 wilma 'ubuntu debian')" = "debian linuxmint-22" ]
printf 'ID=plan9\nVERSION_ID=1\n' > "$TMP/os9"
_t_unknown()  { ! ( OS_RELEASE_FILE="$TMP/os9" os_detect ); }
_t_unproven() { ! os_measured; }
check "unknown dies"       _t_unknown
check "unproven by default" _t_unproven
detect ubuntu 24.04 noble debian >/dev/null
check "sshd service debian" [ "$(sshd_service)" = "ssh" ]
check "sudo group debian"   [ "$(sudo_group)" = "sudo" ]
check "pkg_name htpasswd"   [ "$(pkg_name htpasswd)" = "apache2-utils" ]
detect rocky 9.4 '' rhel >/dev/null
check "sshd service rhel"   [ "$(sshd_service)" = "sshd" ]
check "pkg_name cron rhel"  [ "$(pkg_name cron)" = "cronie" ]

echo "== checklist"
printf '# comment\nDOMAIN=example.org\nADMIN_USER="chris"\nSMTP_PORT=587\nrm -rf / # not a key\nBAD KEY=1\n' > "$SITE_ENV"
unset DOMAIN ADMIN_USER SMTP_PORT
checklist_load
check "loads DOMAIN"            [ "${DOMAIN:-}" = "example.org" ]
check "strips quotes"           [ "${ADMIN_USER:-}" = "chris" ]
check "ignores non-keys"        [ -z "${BAD:-}" ]
check "is_domain ok"            is_domain onions.one
check "is_domain rejects"       bash -c '. "$0/lib/checklist.sh"; ! is_domain "onions"' "$ROOT"
check "is_email ok"             is_email chris@example.org
check "is_email rejects"        bash -c '. "$0/lib/checklist.sh"; ! is_email "chris@"' "$ROOT"
check "is_pubkey ed25519"       is_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGxxxx comment"
check "is_pubkey path"          bash -c 'echo "ssh-ed25519 AAAA x" > "$1/k.pub"; . "$2/lib/checklist.sh"; is_pubkey "$1/k.pub"' _ "$TMP" "$ROOT"
check "is_acme_mode"            is_acme_mode staging
check "default expands DOMAIN"  [ "$(_checklist_default 'service@${DOMAIN}')" = "service@example.org" ]
checklist_save_key TIMEZONE Europe/Berlin
checklist_save_key TIMEZONE Europe/Vienna
check "save replaces in place"  [ "$(grep -c '^TIMEZONE=' "$SITE_ENV")" = "1" ]
check "save keeps value"        grep -q '^TIMEZONE=Europe/Vienna$' "$SITE_ENV"
# a required key that is already valid asks nothing (stdin closed would fail otherwise)
_t_req_valid() { checklist_require DOMAIN < /dev/null; }
check "require valid asks nothing" _t_req_valid
# a missing key is asked, answer comes from stdin
out="$(printf 'admin@example.org\n' | { checklist_require ACME_EMAIL >/dev/null; echo "$ACME_EMAIL"; })"
check "require asks and takes answer" [ "$out" = "admin@example.org" ]
out="$(printf 'nonsense\nadmin@example.org\n' | { checklist_require NOTIFICATION_EMAIL >/dev/null; echo "$NOTIFICATION_EMAIL"; })"
check "require re-asks on invalid" [ "$out" = "admin@example.org" ]

echo "== prompts"
out="$(printf 'x\n9\n2\n' | choose "Pick" a b c 2>/dev/null | tail -1)"
check "choose survives bad input" [ "$out" = "2" ]
out="$(printf '\n' | { ask v "Q" dflt; echo "$v"; })"
check "ask keeps default"        [ "$out" = "dflt" ]
check "confirm default n"        bash -c '. "$0/lib/common.sh"; ! confirm "Q?" n < /dev/null' "$ROOT"
check "confirm_word exact"       bash -c '. "$0/lib/common.sh"; printf "YES\n" | confirm_word "Q?" YES' "$ROOT"
check "confirm_word rejects"     bash -c '. "$0/lib/common.sh"; ! printf "yes\n" | confirm_word "Q?" YES' "$ROOT"

echo "== config editing"
printf '# PermitRootLogin prohibit-password\nPasswordAuthentication yes\nSubsystem sftp /usr/lib/openssh/sftp-server\n' > "$TMP/sshd"
set_config_line "$TMP/sshd" PermitRootLogin no
set_config_line "$TMP/sshd" PasswordAuthentication no
set_config_line "$TMP/sshd" MaxAuthTries 3
check "uncomments and sets"      grep -qx 'PermitRootLogin no' "$TMP/sshd"
check "replaces active"          grep -qx 'PasswordAuthentication no' "$TMP/sshd"
check "appends new"              grep -qx 'MaxAuthTries 3' "$TMP/sshd"
check "one line per key"         [ "$(grep -c 'PermitRootLogin' "$TMP/sshd")" = "1" ]
check "untouched line stays"     grep -q 'Subsystem sftp' "$TMP/sshd"
printf 'A=1\n#B=2\n' > "$TMP/env"; set_env_line "$TMP/env" A 9; set_env_line "$TMP/env" B 3; set_env_line "$TMP/env" C 4
check "env replace"              grep -qx 'A=9' "$TMP/env"
check "env uncomment"            grep -qx 'B=3' "$TMP/env"
check "env append"               grep -qx 'C=4' "$TMP/env"
backup_file "$TMP/env" >/dev/null
check "backup_file copies"       [ -f "$STATE_DIR/backups/test$TMP/env" ]

echo "== templates"
out="$(sed -e 's|@ACME_EMAIL@|a@b.de|' -e 's|@CA_SERVER@||' "$ROOT/templates/traefik.yml")"
check "traefik.yml no placeholder left" bash -c '! grep -q "@[A-Z_]*@" <<< "$1"' _ "$out"
hash='$$apr1$$x$$y'
out="$(sed -e 's|@DOMAIN@|example.org|g' -e 's|@TRAEFIK_IMAGE@|traefik:v3|' -e 's|@ADMIN_USER@|manager|' -e "s|@DASHBOARD_HASH@|$hash|" "$ROOT/templates/traefik-compose.yml")"
check "compose no placeholder left" bash -c '! grep -q "@[A-Z_]*@" <<< "$1"' _ "$out"
check "compose keeps \$\$ hash"     grep -q 'manager:\$\$apr1\$\$x\$\$y' <<< "$out"
check "compose host rule"           grep -q 'Host(`traefik.example.org`)' <<< "$out"

echo "== menu rendering"
STEPS=(10 20 30 40 50 60 70); OS_PRETTY="Test OS"; OS_FAMILY="debian"; OS_ID=ubuntu; OS_VERSION=24.04
banner()      { :; }
status_line() { local n="$1" title_var="STEP_${1}_TITLE"; printf '%s|%s\n' "$((n / 10))" "${!title_var}"; }
out="$(for n in "${STEPS[@]}"; do status_line "$n"; done)"
check "seven steps have titles"  [ "$(grep -c '|.\+' <<< "$out")" = "7" ]
_t_steps() { local n; for n in 10 20 30 40 50 60 70; do declare -F "step_${n}_run" >/dev/null || return 1; done; }
check "step functions exist"     _t_steps
step_done 10; check "step marker"  step_is_done 10
check "unmarked step open"       bash -c '! step_is_done 20'

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
