#!/usr/bin/env bash
# =============================================================================
# host-task.sh <task> -- one piece of work on THIS host, started from the interface.
#
# The Toolserver's setup page (Environment > Installation > Setup) writes a job
# (public.platform_agent_jobs, action "host", target = the task, params = its values), and this
# host's Verwalter (verwalter.py, root) runs this script. Operator 2026-09-17: "ssh kann
# uebergangen werden und in onions nachgeholt werden"; 2026-09-26: "staging umstellen / email/
# Smtp nachbearbeiten / ssh-Zugriff einrichten / weitere Haertungsschritte".
#
# Nothing here is new work: every task calls the installer's own step functions (steps/30,
# 50, 60), with the answers from site.env and the job instead of a terminal. A question that
# would need a person is refused with its name -- never answered by guessing.
#
#   status            report of the host, one line "ONIONS_HOST_STATUS {json}" at the end
#   ssh_key           HT_USER HT_KEY: add a public key to an existing admin
#   ssh_harden        key login only -- refused unless every personal admin has a key and one
#                     key login is proven in the log
#   user_add          HT_USER HT_KEY: a personal admin with sudo, the key, and a password that
#                     expires at the first login (state/generated-passwords.txt)
#   harden_mail       the mail relay; host, user, sender and password arrive as JSON on stdin
#                     (the Verwalter reads them from the Toolserver's SMTP access)
#   harden_intrusion  CrowdSec with bouncer (fail2ban on SUSE)
#   harden_updates    automatic security updates
#   harden_rkhunter / rkhunter_off / harden_scout   the extras of step 6
#   cert_production   Let's Encrypt production instead of staging
#
# Lives in the installer repository (toolserver/) and in /opt/<domain>/, next to
# verwalter.py. The installer's libraries are read from /opt/onions-server.
# =============================================================================
set -euo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/onions-server}"
TASK="${1:-}"

# the same fixed names as install.sh
BOOTSTRAP_USER="manager"
PLATFORM_GROUP="onions"

[[ -f "$INSTALL_ROOT/lib/common.sh" ]] || {
    echo "[ERROR] $INSTALL_ROOT is missing -- this host was not set up by the installer, nothing to run here."
    exit 1
}

DOMAIN="$(basename "$HIER")"; export DOMAIN
INSTANCE_DIR="$HIER"
SITE_ENV="$INSTANCE_DIR/site.env"
STATE_DIR="$INSTANCE_DIR/state"
LOG_DIR="$INSTANCE_DIR/logs"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/host-task-$RUN_STAMP.log"
mkdir -p "$STATE_DIR" "$LOG_DIR"

# shellcheck source=../lib/help.sh
. "$INSTALL_ROOT/lib/help.sh"
# shellcheck source=../lib/common.sh
. "$INSTALL_ROOT/lib/common.sh"
# shellcheck source=../lib/os.sh
. "$INSTALL_ROOT/lib/os.sh"
# shellcheck source=../lib/checklist.sh
. "$INSTALL_ROOT/lib/checklist.sh"
# shellcheck source=../lib/order.sh
. "$INSTALL_ROOT/lib/order.sh"
for f in 30-users 50-traefik 60-hardening; do
    # shellcheck disable=SC1090
    . "$INSTALL_ROOT/steps/$f.sh"
done

# Nobody sits at a terminal behind the Verwalter. A yes/no takes its default and says so;
# a value or a password that is not there stops the task by name.
confirm() {
    local question="$1" default="${2:-n}"
    echo "$question -> $([[ $default == y ]] && echo yes || echo no) (default; no terminal behind the Verwalter)"
    [[ "$default" == "y" ]]
}
pause() { :; }
ask() { die "No terminal behind the Verwalter to answer: $2 -- set it in $SITE_ENV or in the installer."; }
ask_secret() { die "No terminal behind the Verwalter to answer: $2"; }

os_detect
checklist_load

_json() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))'; }

# --- status --------------------------------------------------------------------------------
_admins() {
    { cat "$STATE_DIR/personal_users" 2>/dev/null || true
      getent group "$(sudo_group)" | cut -d: -f4 | tr ',' '\n'
    } | grep -vxE "root|$BOOTSTRAP_USER|" | sort -u
}

_key_logins() {
    { journalctl -t sshd -t sshd-session --since "-120 days" --no-pager -o short-iso 2>/dev/null || true
      cat /var/log/auth.log /var/log/secure 2>/dev/null || true
    } | grep -F "Accepted publickey for " || true
}

_status() {
    local sshd_t logins
    sshd_t="$(sshd -T 2>/dev/null || true)"
    logins="$(_key_logins)"
    local tool; tool="$(intrusion_tool)"
    ADMINS="$(_admins | tr '\n' ' ')" SSHD_T="$sshd_t" LOGINS="$logins" TOOL="$tool" \
    SUDO_GROUP="$(sudo_group)" OSKEY="$(os_key)" OS_FAMILY="$OS_FAMILY" \
    python3 - <<'PY'
import json, os, pwd, re, subprocess, grp

def aktiv(einheit):
    return subprocess.run(["systemctl", "is-active", "--quiet", einheit]).returncode == 0

sshd = {}
for z in os.environ.get("SSHD_T", "").splitlines():
    teile = z.split(None, 1)
    if len(teile) == 2 and teile[0] in ("passwordauthentication", "permitrootlogin", "pubkeyauthentication",
                                         "kbdinteractiveauthentication"):
        sshd[teile[0]] = teile[1].strip()
try:
    sudo_mitglieder = set(grp.getgrnam(os.environ["SUDO_GROUP"]).gr_mem)
except KeyError:
    sudo_mitglieder = set()
admins, scout = [], False
for user in os.environ.get("ADMINS", "").split():
    try:
        home = pwd.getpwnam(user).pw_dir
    except KeyError:
        continue
    keys = 0
    try:
        with open(os.path.join(home, ".ssh", "authorized_keys")) as f:
            keys = sum(1 for z in f if z.strip() and not z.lstrip().startswith("#"))
    except OSError:
        pass
    zuletzt = None
    for z in os.environ.get("LOGINS", "").splitlines():
        if re.search(r"Accepted publickey for %s from " % re.escape(user), z):
            zuletzt = z.split()[0] if z.split() else "yes"
    admins.append({"user": user, "sudo": user in sudo_mitglieder, "keys": keys, "key_login": zuletzt})
    if os.path.exists(os.path.join(home, ".docker", "cli-plugins", "docker-scout")):
        scout = True

tool = os.environ.get("TOOL", "crowdsec")
intrusion = {"tool": tool, "active": aktiv(tool), "bouncer": aktiv("crowdsec-firewall-bouncer") if tool == "crowdsec" else None}
fam = os.environ.get("OS_FAMILY", "")
if fam == "debian":
    conf = ""
    try:
        conf = open("/etc/apt/apt.conf.d/20auto-upgrades").read()
    except OSError:
        pass
    updates = {"kind": "unattended-upgrades",
               "active": bool(re.search(r'Unattended-Upgrade\s+"1"', conf)) and aktiv("unattended-upgrades")}
elif fam == "rhel":
    updates = {"kind": "dnf-automatic", "active": aktiv("dnf-automatic.timer")}
else:
    updates = {"kind": "os-update", "active": aktiv("os-update.timer")}

relay = {"configured": False}
try:
    felder = {}
    for z in open("/etc/msmtprc"):
        t = z.split(None, 1)
        if len(t) == 2 and t[0] in ("host", "user", "from", "password") and t[0] not in felder:
            felder[t[0]] = t[1].strip()
    relay = {"configured": bool(felder.get("host") and felder.get("password")),
             "host": felder.get("host", ""), "user": felder.get("user", ""), "from": felder.get("from", "")}
except OSError:
    pass

acme = "unknown"
try:
    acme = "staging" if "acme-staging" in open("/opt/traefik/traefik.yml").read() else "production"
except OSError:
    pass

firewall = aktiv("ufw") or aktiv("firewalld")
try:
    ufw = subprocess.run(["ufw", "status"], capture_output=True, text=True).stdout
    firewall = firewall or ufw.startswith("Status: active")
except OSError:
    pass

try:
    pwd.getpwnam("manager")
    bootstrap = True
except KeyError:
    bootstrap = False

bericht = {"os": os.environ.get("OSKEY", ""), "sshd": sshd, "admins": admins, "bootstrap_user": bootstrap,
           "intrusion": intrusion, "updates": updates, "rkhunter": subprocess.run(
               ["sh", "-c", "command -v rkhunter"], capture_output=True).returncode == 0,
           "scout": scout, "relay": relay, "acme_mode": acme, "firewall": firewall}
print("ONIONS_HOST_STATUS " + json.dumps(bericht, separators=(",", ":")))
PY
}

# --- values from the job --------------------------------------------------------------------
_job_user() {
    [[ -n "${HT_USER:-}" ]] && is_personal_user "$HT_USER" || die "Not a usable admin name: '${HT_USER:-}'."
}
_job_key() {
    [[ -n "${HT_KEY:-}" ]] && is_pubkey "$HT_KEY" || die "Not a public SSH key."
}

_ssh_key() {
    _job_user; _job_key
    id "$HT_USER" >/dev/null 2>&1 || die "There is no user $HT_USER on this host -- add the admin first."
    _install_pubkey "$HT_USER" "$HT_KEY"
    log_ok "Log in once as $HT_USER with this key, then press 'Measure now' on the setup page."
}

_ssh_harden() {
    local u proven=0 logins
    [[ -s "$STATE_DIR/personal_users" ]] || die "No personal admin is recorded on this host -- add one first."
    _every_admin_with_key || die "Not every personal admin has a public key -- hardening refused, nobody is locked out."
    # read once into a variable: "producer | grep -q" ends in SIGPIPE under pipefail and would
    # read as "not found" exactly when it was found
    logins="$(_key_logins)"
    for u in $(cat "$STATE_DIR/personal_users"); do
        grep -qF "Accepted publickey for $u from " <<< "$logins" && proven=1
    done
    (( proven )) || die "No key login of a personal admin is in the log yet -- log in once with a key, then try again."
    _sshd_apply_hardening
    _remove_handed_out_keys
    step_done 30
    log_ok "sshd hardened: key login only."
}

_user_add() {
    _job_user; _job_key
    if ! id "$HT_USER" >/dev/null 2>&1; then
        run useradd -m -s /bin/bash "$HT_USER"
        local gpw; gpw="$(order_new_password)"
        printf '%s:%s\n' "$HT_USER" "$gpw" | chpasswd
        chage -d 0 "$HT_USER"
        order_password_note "Admin (sudo), from the setup page" "$HT_USER" "$gpw  (expires at first login)"
        unset gpw
        log_ok "User $HT_USER created; the password (expires at first login) is in $STATE_DIR/generated-passwords.txt (root only)."
    fi
    _personal_user "$HT_USER" paste "$HT_KEY" y
}

_harden_mail() {
    local zugang
    zugang="$(cat)"
    [[ -n "$zugang" ]] || die "No relay access arrived from the Verwalter."
    eval "$(printf '%s' "$zugang" | python3 -c '
import json, shlex, sys
d = json.load(sys.stdin)
if d.get("error"):
    print("die %s" % shlex.quote(d["error"])); sys.exit(0)
for k, v in (("SMTP_SERVER", d["host"]), ("SMTP_PORT", d["port"]), ("SMTP_USER", d["user"]),
             ("SENDER_EMAIL", d.get("sender") or d["user"]), ("RELAY_PASSWORD", d["password"])):
    print("%s=%s" % (k, shlex.quote(str(v))))
')"
    [[ -n "${NOTIFICATION_EMAIL:-}" ]] || NOTIFICATION_EMAIL="$SENDER_EMAIL"
    export SMTP_SERVER SMTP_PORT SMTP_USER SENDER_EMAIL NOTIFICATION_EMAIL RELAY_PASSWORD
    local k
    for k in SMTP_SERVER SMTP_PORT SMTP_USER SENDER_EMAIL NOTIFICATION_EMAIL; do
        set_env_line "$SITE_ENV" "$k" "${!k}"
    done
    _hard_mail
    unset RELAY_PASSWORD
}

_cert_production() {
    local dir="/opt/traefik" f="/opt/traefik/traefik.yml"
    [[ -f "$f" ]] || die "$f is missing -- Traefik was not set up by the installer."
    if grep -q 'acme-staging' "$f"; then
        backup_file "$f"
        sed -i '/caServer:.*acme-staging/d' "$f"
        log_ok "Staging server removed from $f -- Let's Encrypt production from now on."
    else
        log_ok "$f asks Let's Encrypt production already."
    fi
    if [[ -s "$dir/acme.json" ]] && grep -q 'STAGING\|acme-staging' "$dir/acme.json"; then
        backup_file "$dir/acme.json"
        : > "$dir/acme.json"
        log_ok "The staging certificates are set aside (backup in $STATE_DIR/backups/$RUN_STAMP)."
    fi
    chown root:root "$dir/acme.json"; chmod 600 "$dir/acme.json"
    set_env_line "$SITE_ENV" ACME_MODE production
    (cd "$dir" && run docker compose up -d --force-recreate)
    log_ok "Traefik restarted; the first call of each address requests its certificate."
}

case "$TASK" in
    status)           _status ;;
    ssh_key)          _ssh_key ;;
    ssh_harden)       _ssh_harden ;;
    user_add)         _user_add ;;
    harden_mail)      _harden_mail ;;
    harden_intrusion) _hard_intrusion ;;
    harden_updates)   _hard_autoupdates ;;
    harden_rkhunter)  _hard_rkhunter ;;
    rkhunter_off)     _hard_rkhunter_off ;;
    harden_scout)     _hard_scout ;;
    cert_production)  _cert_production ;;
    *) echo "[ERROR] usage: host-task.sh <task> -- unknown task '$TASK'"; exit 1 ;;
esac
