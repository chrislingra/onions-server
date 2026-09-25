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
for f in "$ROOT"/install.sh "$ROOT"/lib/*.sh "$ROOT"/steps/*.sh "$ROOT"/toolserver/*.sh "$ROOT"/tests/*.sh; do
    check "bash -n ${f#$ROOT/}" bash -n "$f"
    if grep -q $'\r' "$f"; then fail "LF only: ${f#$ROOT/}"; else ok "LF only: ${f#$ROOT/}"; fi
done

echo "== no secrets in the tree"
# No exception any more: since 2026-09-19 the first-login password of the Toolserver is
# generated in phase 4 of its setup (secrets/admin_password), the tree holds no start value.
if grep -rInE '(PASSWORD|PASS|SECRET|TOKEN|API_KEY)[[:space:]]*=[[:space:]]*"?[A-Za-z0-9]{6,}' "$ROOT" --include='*.sh' --include='*.yml' --include='*.md' \
    | grep -vE 'ask_secret|\$\{?[A-Za-z_]+\}?|@[A-Z_]+@|password[[:space:]]+\$pw' >/dev/null; then
    fail "a literal credential-looking assignment exists"
else
    ok "no literal credentials"
fi

# --- load the libraries the way install.sh does, but in a sandbox ---------------------
INSTALL_ROOT="$ROOT"; INSTANCE_DIR="$TMP/instance"; STATE_DIR="$INSTANCE_DIR/state"; LOG_DIR="$INSTANCE_DIR/logs"
RUN_STAMP="test"; LOG_FILE="$LOG_DIR/test.log"; SITE_ENV="$INSTANCE_DIR/site.env"; DOMAIN="example.org"
BOOTSTRAP_USER="manager"; PLATFORM_GROUP="onions"
mkdir -p "$STATE_DIR" "$LOG_DIR"
. "$ROOT/lib/help.sh"; . "$ROOT/lib/common.sh"; . "$ROOT/lib/os.sh"; . "$ROOT/lib/checklist.sh"
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
_t_unproven() { ! os_proven; }
check "unknown dies"       _t_unknown
check "unproven by default" _t_unproven

echo "== the support table answers BEFORE the installation, not in step 6"
# the operator's requirement: Ubuntu, Red Hat, SUSE, Debian -- and a clear word per release
_t_level() { detect "$1" "$2" "$3" "$4" >/dev/null; [ "$(os_support_level)" = "$5" ]; }
check "ubuntu 24.04 full"   _t_level ubuntu 24.04 noble debian full
check "ubuntu 22.04 full"   _t_level ubuntu 22.04 jammy debian full
check "debian 12 full"      _t_level debian 12 bookworm '' full
check "debian 13 full"      _t_level debian 13 trixie '' full
check "rocky 9.4 full"      _t_level rocky 9.4 '' 'rhel centos fedora' full
check "almalinux 10.0 full" _t_level almalinux 10.0 '' 'rhel centos fedora' full
check "rhel 9.4 full"       _t_level rhel 9.4 '' fedora full
check "fedora 42 full"      _t_level fedora 42 '' '' full
check "leap 15.6 partial"   _t_level opensuse-leap 15.6 '' 'suse opensuse' partial
check "sles 15.6 partial"   _t_level sles 15.6 '' '' partial
check "ubuntu 26.04 untested" _t_level ubuntu 26.04 resolute debian untested
check "debian 14 untested"  _t_level debian 14 forky '' untested
# every partial must SAY what is missing -- a verdict without a reason helps nobody
_t_partial_note() { detect opensuse-leap 15.6 '' suse >/dev/null; [ -n "$(os_support_note)" ]; }
check "partial names the gap" _t_partial_note
_t_trixie_note() { detect debian 13 trixie '' >/dev/null; os_support_note | grep -q "bookworm"; }
check "trixie names its substitute" _t_trixie_note
# the blocking tool follows the family, and the menu never hardcodes a name
_t_tool_deb() { detect ubuntu 24.04 noble debian >/dev/null; [ "$(intrusion_tool)" = "crowdsec" ]; }
_t_tool_rhel() { detect rocky 9.4 '' rhel >/dev/null; [ "$(intrusion_tool)" = "crowdsec" ]; }
_t_tool_suse() { detect sles 15.6 '' '' >/dev/null; [ "$(intrusion_tool)" = "fail2ban" ]; }
check "debian blocks with crowdsec" _t_tool_deb
check "rhel blocks with crowdsec"   _t_tool_rhel
check "suse blocks with fail2ban"   _t_tool_suse
_t_no_hardcoded_tool() { ! grep -qE 'pick_option .*(CrowdSec only|CrowdSec, automatic)' "$ROOT/steps/60-hardening.sh"; }
check "menu asks the family for the name" _t_no_hardcoded_tool
# the report must run without a machine and must never refuse
_t_report() { detect sles 15.6 '' '' >/dev/null; LOG_FILE="$TMP/rep.log" os_support_report >/dev/null 2>&1; }
check "report never fails"  _t_report
# the recommended base (operator 2026-09-23) -- named where it helps, silent where it does not
# the report's output is captured, never piped into grep -q: that closes the pipe early and
# "set -o pipefail" would then read the writer's SIGPIPE as a failed check
_t_report_says() {
    local id="$1" ver="$2" code="$3" like="$4" want="$5" out
    detect "$id" "$ver" "$code" "$like" >/dev/null
    out="$(LOG_FILE="$TMP/rep-$id.log" os_support_report 2>&1)"
    [[ "$out" == *"$want"* ]]
}
_t_rec_named()    { _t_report_says sles 15.6 '' '' "$RECOMMENDED_OS"; }
_t_rec_untested() { _t_report_says debian 14 forky '' "$RECOMMENDED_OS"; }
_t_rec_quiet()    { ! _t_report_says debian 12 bookworm '' "$RECOMMENDED_OS"; }
_t_rec_self()     { ! _t_report_says ubuntu 24.04 noble debian "Recommended base"; }
check "partial names the recommendation"  _t_rec_named
check "untested names the recommendation" _t_rec_untested
check "a full release is not nagged"      _t_rec_quiet
check "the recommended one names itself not" _t_rec_self
_t_rec_is_full() { [ "${OS_SUPPORT[$RECOMMENDED_OS_KEY]%%|*}" = "full" ]; }
check "the recommendation is a full row"  _t_rec_is_full
_t_rec_once() { [ "$(grep -c '^RECOMMENDED_OS=' "$ROOT/lib/os.sh")" = "1" ]; }
check "the recommendation stands in one place" _t_rec_once
_t_rec_readme() { grep -q "Ubuntu 24.04 LTS" "$ROOT/README.md"; }
check "the README names it too"           _t_rec_readme
# the help key belongs LAST. Passed in the options slot it built a menu with one nonsense
# entry and no default (2026-09-23). pick_option refuses that now; this finds it before a run.
_t_pick_order() {
    local out
    out="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ta}' "$ROOT"/install.sh "$ROOT"/steps/*.sh 2>/dev/null \
           | grep -nE 'pick_option[^=]*(step[0-9]+\.[a-z_]+)[^=]*=' || true)"
    [[ -z "$out" ]] || { echo "help key before the options string: $out"; return 1; }
}
check "pick_option takes the help key last" _t_pick_order
_t_pick_refuses() {
    local rc=0
    bash -c '. "$0/lib/help.sh"; . "$0/lib/common.sh"; . "$0/lib/checklist.sh"
             LOG_FILE=/dev/null; pick_option v "Q" a "step60.part" </dev/null' "$ROOT" >/dev/null 2>&1 || rc=$?
    (( rc != 0 ))
}
check "pick_option refuses a bad options string" _t_pick_refuses
# every helper the banner calls must exist -- os_measured was renamed and the banner kept
# calling it, which printed "command not found" on every screen of a live installation
_t_banner_calls() {
    local fn missing=""
    for fn in os_support_level os_support_note os_proven os_key; do
        grep -q "^${fn}()\|^${fn}() *{\|^${fn}()" "$ROOT/lib/os.sh" || missing="$missing $fn"
    done
    [[ -z "$missing" ]] || { echo "banner calls what does not exist:$missing"; return 1; }
}
check "the banner only calls helpers that exist" _t_banner_calls
_t_no_dead_names() { ! grep -rn "os_measured\|OS_MEASURED" "$ROOT"/install.sh "$ROOT"/lib "$ROOT"/steps >/dev/null 2>&1; }
check "the renamed os_measured is gone everywhere" _t_no_dead_names
detect ubuntu 24.04 noble debian >/dev/null
check "sshd service debian" [ "$(sshd_service)" = "ssh" ]
check "sudo group debian"   [ "$(sudo_group)" = "sudo" ]
check "pkg_name htpasswd"   [ "$(pkg_name htpasswd)" = "apache2-utils" ]
detect rocky 9.4 '' rhel >/dev/null
check "sshd service rhel"   [ "$(sshd_service)" = "sshd" ]
check "pkg_name cron rhel"  [ "$(pkg_name cron)" = "cronie" ]

echo "== checklist"
printf '# comment\nTIMEZONE=Europe/Berlin\nADMIN_USER="chris"\nSMTP_PORT=587\nrm -rf / # not a key\nBAD KEY=1\n' > "$SITE_ENV"
unset TIMEZONE ADMIN_USER SMTP_PORT
checklist_load
check "loads TIMEZONE"          [ "${TIMEZONE:-}" = "Europe/Berlin" ]
check "strips quotes"           [ "${ADMIN_USER:-}" = "chris" ]
check "ignores non-keys"        [ -z "${BAD:-}" ]
check "is_domain ok"            is_domain onions.one
check "is_domain rejects"       bash -c '. "$0/lib/checklist.sh"; ! is_domain "onions"' "$ROOT"
check "is_email ok"             is_email chris@example.org
check "is_email rejects"        bash -c '. "$0/lib/checklist.sh"; ! is_email "chris@"' "$ROOT"
check "is_pubkey ed25519"       is_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGxxxx comment"
check "is_pubkey_or_dash dash"  is_pubkey_or_dash -
_t_pod() { ! is_pubkey_or_dash "nonsense"; }
check "is_pubkey_or_dash rejects" _t_pod
check "KEY_SOURCE generate valid" _item_valid KEY_SOURCE generate
check "KEY_SOURCE later valid"   _item_valid KEY_SOURCE later
_t_options_wellformed() { local item k p d v o opt; for item in "${CHECKLIST_ITEMS[@]}"; do IFS="|" read -r k p d v o <<< "$item"; [[ -z "$o" ]] && continue; IFS=";" read -ra _o <<< "$o"; for opt in "${_o[@]}"; do [[ "$opt" =~ ^[A-Za-z0-9_-]+=.+$ ]] || { echo "bad option in $k: $opt"; return 1; }; done; done; }
check "every option is code=label"  _t_options_wellformed
_t_ks_none() { ! _item_valid KEY_SOURCE none; }
check "KEY_SOURCE none gone"    _t_ks_none
_t_ks() { ! _item_valid KEY_SOURCE upload; }
check "KEY_SOURCE rejects"      _t_ks
check "is_pubkey path"          bash -c 'echo "ssh-ed25519 AAAA x" > "$1/k.pub"; . "$2/lib/checklist.sh"; is_pubkey "$1/k.pub"' _ "$TMP" "$ROOT"
check "option_valid"            option_valid "a=A;b=B" b
_t_opt_bad() { ! option_valid "a=A;b=B" c; }
check "option_valid rejects"    _t_opt_bad
check "option_label"            [ "$(option_label "a=Alpha;b=Beta" b)" = "Beta" ]
out="$(printf '\n' | { pick_option v "Q" b "a=A;b=B;c=C"; echo "$v"; } | tail -1)"
check "pick_option enter = default" [ "$out" = "b" ]
out="$(printf 'x\n9\n3\n' | { pick_option v "Q" b "a=A;b=B;c=C"; echo "$v"; } | tail -1)"
check "pick_option survives bad input" [ "$out" = "c" ]
LANGUAGE=de COUNTRY=CH checklist_derive
check "derive locale"           [ "$LOCALE" = "de_DE.UTF-8" ]
check "derive timezone"         [ "$TIMEZONE" = "Europe/Zurich" ]
check "derive keymap"           [ "$KEYMAP" = "ch" ]
check "derived saved"           grep -qx "TIMEZONE=Europe/Zurich" "$SITE_ENV"
check "personal user ok"        is_personal_user chris
_t_pu_boot() { ! is_personal_user manager; }
_t_pu_root() { ! is_personal_user root; }
check "personal user not bootstrap" _t_pu_boot
check "personal user not root"  _t_pu_root
check "default expands DOMAIN"  [ "$(_checklist_default 'service@${DOMAIN}')" = "service@example.org" ]
checklist_save_key TIMEZONE Europe/Berlin
checklist_save_key TIMEZONE Europe/Vienna
check "save replaces in place"  [ "$(grep -c '^TIMEZONE=' "$SITE_ENV")" = "1" ]
check "save keeps value"        grep -q '^TIMEZONE=Europe/Vienna$' "$SITE_ENV"
# a required key that is already valid asks nothing (stdin closed would fail otherwise)
_t_req_valid() { checklist_require ADMIN_USER SMTP_PORT < /dev/null; }
check "require valid asks nothing" _t_req_valid
# a missing key is asked, answer comes from stdin
out="$(printf 'admin@example.org\n' | { checklist_require ACME_EMAIL >/dev/null; echo "$ACME_EMAIL"; })"
check "require asks and takes answer" [ "$out" = "admin@example.org" ]
out="$(printf 'nonsense\nadmin@example.org\n' | { checklist_require NOTIFICATION_EMAIL >/dev/null; echo "$NOTIFICATION_EMAIL"; })"
check "require re-asks on invalid" [ "$out" = "admin@example.org" ]

echo "== prompts"
out="$(printf 'x\n9\n2\n' | choose "Pick" a b c 2>/dev/null | tail -1)"
check "choose survives bad input" [ "$out" = "2" ]
out="$(printf "1
" | choose "Pick" a b 2>/dev/null)"
check "choose prints only the answer" [ "$out" = "1" ]
# step 7 probes the Toolserver address without any key handling of its own and without
# ever prompting; both cases run against local repositories, no network needed
git init -q "$TMP/readable" && git -C "$TMP/readable" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
_t_git_ok()  { TOOLSERVER_SOURCE="$TMP/readable" _git_readable; }
_t_git_bad() { ! TOOLSERVER_SOURCE="$TMP/nowhere" _git_readable < /dev/null; }
check "step 7 reads a readable address" _t_git_ok
check "step 7 stops on an unreadable address" _t_git_bad
check "step 7 never prompts" [ "$(TOOLSERVER_SOURCE="$TMP/nowhere" _git_readable >/dev/null 2>&1; echo "$GIT_TERMINAL_PROMPT")" = "0" ]
# the source is fixed, never asked (operator 2026-09-24)
_t_source_fixed() { ! grep -qE '^[[:space:]]*"TOOLSERVER_' "$ROOT/lib/checklist.sh" && grep -q '^TOOLSERVER_SOURCE=' "$ROOT/install.sh"; }
check "Toolserver source is not a question" _t_source_fixed
# every installation gets its own Verwalter (operator 2026-09-25)
_t_verwalter() {
    [[ -s "$ROOT/toolserver/verwalter.py" ]] \
        && sed -n '/^step_70_run()/,/^}/p' "$ROOT/steps/70-toolserver.sh" | grep -q '_verwalter_einrichten' \
        && grep -q 'ExecStart=/usr/bin/python3 \$ziel' "$ROOT/steps/70-toolserver.sh"
}
check "step 7 installs this host's own Verwalter" _t_verwalter
# full operation from the terminal (operator 2026-09-25): Weaviate and Nextcloud in step 7
_t_services() {
    local f
    for f in setup-weaviate.sh setup-nextcloud.sh toolserver-link.sh; do [[ -s "$ROOT/toolserver/$f" ]] || return 1; done
    [[ " ${SERVICE_SCRIPTS[*]} " == *" setup-weaviate.sh "* && " ${SERVICE_SCRIPTS[*]} " == *" setup-nextcloud.sh "* ]] \
        && [[ " ${SETUP_SCRIPTS[*]} " == *" toolserver-link.sh "* ]]
}
check "step 7 sets up Weaviate and Nextcloud" _t_services
# the Verwalter runs setup scripts as root without a terminal: no question, no fixed password,
# no user that only exists on the Onions server
_t_unattended() { ! grep -nE '^[^#]*(read -p|read -r -p|dont4get|SUDO_USER:-chris|chown -R manager)' "$ROOT"/toolserver/setup-*.sh; }
check "setup scripts run unattended, without fixed passwords" _t_unattended
_t_dns_missing() { ! _dns_check "no-record.invalid" >/dev/null 2>&1; }
check "step 7 stops on a name without a DNS record" _t_dns_missing
_t_link_without_ts() { bash -c '. "$0/toolserver/toolserver-link.sh"; docker() { return 1; }; ts_connector_register weaviate W http://w:8080 s && ts_catalogue_installed weaviate' "$ROOT"; }
check "a service without a Toolserver is no error" _t_link_without_ts
_t_no_keys() { ! grep -qE '^[[:space:]]*(run[[:space:]]+)?ssh-keygen|api.github.com|ask_secret|IdentitiesOnly' "$ROOT/steps/70-toolserver.sh"; }
check "step 7 carries no key apparatus" _t_no_keys
# ask prints its question block first (structured, one line per answer), so the value is the
# LAST line -- same as the pick_option checks above
out="$(printf '\n' | { ask v "Q" dflt; echo "$v"; } | tail -1)"
check "ask keeps default"        [ "$out" = "dflt" ]
out="$(printf '\n' | { ask v "Git URL of the Toolserver (public address: no credentials; private: ssh address)" x; } | sed -n '2p')"
check "a long aside gets its own line" [ "$out" = "  (public address: no credentials; private: ssh address)" ]
out="$(printf '\n' | { ask v "SMTP relay port (submission)" 587; } | sed -n '1p')"
check "a short aside stays in the line" [ "$out" = "SMTP relay port (submission)" ]
_t_one_column() {
    # every answer of a question prints in the same column -- numbers and h/b alike
    local out
    out="$(printf '\n' | confirm "Q?" y 2>&1 | sed -n '2p;4p' | sed 's/[^ ].*//' | sort -u)"
    [ "$(printf '%s' "$out" | wc -l)" = "0" ]
}
check "numbers and h/b share a column" _t_one_column
check "confirm default n"        bash -c '. "$0/lib/common.sh"; ! confirm "Q?" n < /dev/null' "$ROOT"
check "confirm 1 = yes"          bash -c '. "$0/lib/common.sh"; printf "1\n" | confirm "Q?" n' "$ROOT"
check "confirm 2 = no"           bash -c '. "$0/lib/common.sh"; ! printf "2\n" | confirm "Q?" y' "$ROOT"
check "confirm enter = default y" bash -c '. "$0/lib/common.sh"; printf "\n" | confirm "Q?" y' "$ROOT"
check "confirm survives bad input" bash -c '. "$0/lib/common.sh"; printf "x\n7\n1\n" | confirm "Q?" n' "$ROOT"

echo "== help and one step back (every question offers both)"
# outside a step _prompt_back returns PROMPT_RC_BACK; inside one it leaves the step (exit 10)
_t_rc() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" = "10" ]; }
check "confirm: b = back"        _t_rc bash -c '. "$0/lib/help.sh"; . "$0/lib/common.sh"; printf "b\n" | confirm "Q?" n' "$ROOT"
check "ask: b = back"            _t_rc bash -c '. "$0/lib/help.sh"; . "$0/lib/common.sh"; printf "b\n" | ask v "Q" d' "$ROOT"
check "ask_secret: b = back"     _t_rc bash -c '. "$0/lib/help.sh"; . "$0/lib/common.sh"; printf "b\n" | ask_secret v "Q"' "$ROOT"
check "pick_option: b = back"    _t_rc bash -c '. "$0/lib/help.sh"; . "$0/lib/common.sh"; . "$0/lib/checklist.sh"; printf "b\n" | pick_option v "Q" a "a=A;b=B"' "$ROOT"
check "choose: b = back"         _t_rc bash -c '. "$0/lib/help.sh"; . "$0/lib/common.sh"; printf "b\n" | choose "Q" one two' "$ROOT"
# help does not answer the question: h prints the text and asks again
out="$(printf 'h\n2\n' | bash -c '. "$0/lib/help.sh"; . "$0/lib/common.sh"; confirm "Q?" y; echo "rc=$?"' "$ROOT" | tail -1)"
check "confirm: h asks again"    [ "$out" = "rc=1" ]
out="$(printf 'h\nwert\n' | bash -c '. "$0/lib/help.sh"; . "$0/lib/common.sh"; ask v "Q"; echo "$v"' "$ROOT" | tail -1)"
check "ask: h asks again"        [ "$out" = "wert" ]
check "help_show names the log"  bash -c '. "$0/lib/help.sh"; LOG_FILE=/x/y.log help_show LANGUAGE Q | grep -q "/x/y.log"' "$ROOT"
check "help_show without a key"  bash -c '. "$0/lib/help.sh"; help_show "" "Frage" | grep -q "no written explanation"' "$ROOT"
# the drift guard: every help key a prompt names must have a text. A key that is only
# mistyped would silently fall back to the general text and nobody would notice.
_t_help_keys() {
    local key missing=""
    while read -r key; do
        [[ -n "$key" ]] || continue
        [[ -n "${HELP_TEXTS[$key]:-}" ]] || missing="$missing $key"
    done < <(grep -rhoE '\b(confirm|ask|ask_secret|pick_option|help_show)\b[^|&;]*\b(step[0-9]{2}\.[a-z]+|menu)\b' \
                 "$ROOT/install.sh" "$ROOT/steps" 2>/dev/null \
             | grep -oE '(step[0-9]{2}\.[a-z]+|\bmenu\b)' | sort -u)
    [[ -z "$missing" ]] || { echo "help keys without a text:$missing"; return 1; }
}
check "every help key has a text" _t_help_keys
# and every checklist item, whose key IS its help key
_t_help_items() {
    local item k rest missing=""
    for item in "${CHECKLIST_ITEMS[@]}"; do
        IFS='|' read -r k rest <<< "$item"
        [[ -n "${HELP_TEXTS[$k]:-}" ]] || missing="$missing $k"
    done
    [[ -z "$missing" ]] || { echo "checklist items without help:$missing"; return 1; }
}
check "every checklist item has help" _t_help_items

echo "== a broken package source must not block the installation"
# one unusable source stops apt-get update with exit 100 -- and with it every step. The
# repair either rewrites the release it names or switches the file off; it never guesses.
detect debian 13 trixie '' >/dev/null
_t_src() {
    local carries="$1" content="$2" want="$3" dir="$TMP/aptsrc" rc=0 out
    rm -rf "$dir"; mkdir -p "$dir"
    printf '%s\n' "$content" > "$dir/probe.list"
    _url_ok() { case "$1" in *"/dists/${carries}/Release") return 0 ;; *) return 22 ;; esac; }
    _apt_list_repair "$dir/probe.list" >/dev/null 2>&1 || rc=1
    unset -f _url_ok
    if [[ -f "$dir/probe.list" ]]; then out="changed:$(sed -n '1p' "$dir/probe.list")"; else out="disabled"; fi
    (( rc == 0 )) || out="untouched"
    [ "$out" = "$want" ]
}
check "broken suite is rewritten" _t_src bookworm \
    'deb [signed-by=/x.gpg] https://packagecloud.io/crowdsec/crowdsec/debian/ trixie main' \
    'changed:deb [signed-by=/x.gpg] https://packagecloud.io/crowdsec/crowdsec/debian/ bookworm main'
check "a working source stays" _t_src trixie \
    'deb https://download.docker.com/linux/debian trixie stable' 'untouched'
check "hopeless source is switched off" _t_src nirgends \
    'deb https://example.invalid/repo trixie main' 'disabled'
check "a comment is no source" _t_src nirgends \
    '# deb https://example.invalid/repo trixie main' 'untouched'
_t_flat() { _t_src nirgends 'deb https://example.invalid/repo ./' 'untouched'; }
check "flat repo is left alone" _t_flat

echo "== CrowdSec: a registration without a key in the config is not a registration"
. "$ROOT/steps/60-hardening.sh"
_t_key() {
    local content="$1" want="$2" dir="$TMP/bouncers" rc=0
    rm -rf "$dir"; mkdir -p "$dir"
    printf '%s\n' "$content" > "$dir/crowdsec-firewall-bouncer.yaml"
    _bouncer_key_present "$dir" || rc=1
    [ "$rc" = "$want" ]
}
check "placeholder counts as missing" _t_key 'api_key: ${API_KEY}' 1
check "empty counts as missing"       _t_key 'api_key:' 1
check "a real key counts"             _t_key 'api_key: abc123XYZ' 0
check "a quoted key counts"           _t_key 'api_key: "abc123XYZ"' 0
_t_key_nodir() { local rc=0; _bouncer_key_present "$TMP/gibtesnicht" || rc=1; [ "$rc" = "1" ]; }
check "no config at all = missing"    _t_key_nodir

echo "== third-party apt repositories follow the release cycle late"
# apt_repo_dist must never propose a codename NEWER than this host's, and must fall back to
# the newest older one the repository actually carries (the trixie/CrowdSec case, 2026-09-23).
_t_repo() {
    local carries="$1" expect="$2" got
    curl() { case "$*" in *"/dists/${carries}/Release"*) return 0 ;; *) return 22 ;; esac; }
    got="$(apt_repo_dist https://example.invalid/repo 2>/dev/null)" || got="<none>"
    unset -f curl
    [ "$got" = "$expect" ]
}
detect debian 13 trixie '' >/dev/null
check "trixie, repo has trixie"   _t_repo trixie trixie
check "trixie, repo only bookworm" _t_repo bookworm bookworm
check "trixie, repo only bullseye" _t_repo bullseye bullseye
check "trixie, repo has nothing"  _t_repo nothing '<none>'
detect debian 12 bookworm '' >/dev/null
_t_repo_no_newer() { _t_repo trixie '<none>'; }
check "bookworm never takes trixie" _t_repo_no_newer
detect ubuntu 24.04 noble debian >/dev/null
check "noble falls back to jammy"  _t_repo jammy jammy

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
STEPS=(10 20 30 40 50 60 70 80); OS_PRETTY="Test OS"; OS_FAMILY="debian"; OS_ID=ubuntu; OS_VERSION=24.04
banner()      { :; }
status_line() { local n="$1" title_var="STEP_${1}_TITLE"; printf '%s|%s\n' "$((n / 10))" "${!title_var}"; }
out="$(for n in "${STEPS[@]}"; do status_line "$n"; done)"
check "eight steps have titles"  [ "$(grep -c '|.\+' <<< "$out")" = "8" ]
_t_steps() { local n; for n in 10 20 30 40 50 60 70 80; do declare -F "step_${n}_run" >/dev/null || return 1; done; }
check "step functions exist"     _t_steps
step_done 10; check "step marker"  step_is_done 10
check "unmarked step open"       bash -c '! step_is_done 20'

echo "== backups: created right, never repaired afterwards"
# The directory is created HERE, with the group and the setgid bit, so nothing
# under it ever needs fixing up later. A repair path would only be reachable on
# a host that was installed before this installer existed -- and the answer for
# such a host is a fresh installation, not a script (operator 2026-09-23).
check "backup root created in 10-base" grep -q '^_backup_root()' "$ROOT/steps/10-base.sh"
check "setgid mode on it"              bash -c 'sed -n "/^_backup_root()/,/^}/p" "$1" | grep -q "chmod 2750"' _ "$ROOT/steps/10-base.sh"
check "no ACL repair tool"             bash -c '! [ -e "$1/tools/backup-access.sh" ]' _ "$ROOT"
check "no setfacl anywhere"            bash -c '! grep -rqE "^[^#]*\bsetfacl\b" "$1/steps" "$1/lib" "$1/install.sh"' _ "$ROOT"

echo "== phase 7 of setup-toolserver.sh"
_st="$ROOT/toolserver/setup-toolserver.sh"
# The seed loads in ONE transaction. That is what lets the two self-referencing
# keys be deferred to COMMIT -- and they carry that from db/schema_current.sql
# (v1732), so phase 7 must NOT repeat it here: a second source would drift.
check "seed loads in one transaction"  grep -q 'single-transaction' "$_st"
check "no constraint surgery in 7"     bash -c '! grep -q "INITIALLY DEFERRED" "$1"' _ "$_st"
check "tenants exist before the seed"  bash -c '
    t=$(grep -n "INSERT INTO public.tenants" "$1" | head -1 | cut -d: -f1)
    s=$(grep -n "schema_seed.sql (one transaction)" "$1" | head -1 | cut -d: -f1)
    [ -n "$t" ] && [ -n "$s" ] && [ "$t" -lt "$s" ]' _ "$_st"
# 7f measures the catalogue on this host: a compose file present = installed, absent = not
# (the seed carried the Onions server's installed_at to every fresh host)
_t_catalogue() {
    local d="$TMP/cat"; mkdir -p "$d/a"; : > "$d/a/c.yml"
    sed -n '/# 7f\. The catalogue/,/log "Catalogue measured/p' "$_st" > "$d/7f.sh"
    [[ -s "$d/7f.sh" ]] || return 1
    D="$d" bash -c '_psql_q() { printf "a|%s/a|c.yml\nb|%s/b|c.yml\n" "$D" "$D"; }
                    _psql() { cat > "$D/sql"; }; log() { :; }; . "$D/7f.sh"' || return 1
    grep -q "key IN ('a') AND installed_at IS NULL" "$d/sql" && grep -q "key IN ('b') AND installed_at IS NOT NULL" "$d/sql"
}
check "7f marks what is on the host, and only that" _t_catalogue

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
