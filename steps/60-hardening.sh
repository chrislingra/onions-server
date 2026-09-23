#!/usr/bin/env bash
# steps/60-hardening.sh -- mail relay, CrowdSec, rkhunter, Docker Scout.
# The SMTP password is asked hidden and written only to /etc/msmtprc (mode 600, root).
# Sourced by install.sh.

STEP_60_TITLE="Hardening (mail relay, CrowdSec, automatic security updates)"

# The recommended set (operator 2026-09-17): mail relay, CrowdSec, automatic security
# updates. rkhunter and Docker Scout stay available as extras, not in the set.
step_60_run() {
    heading "$STEP_60_TITLE"
    local pick
    pick_option pick "Which part" set step60.part \
        "set=Recommended set: mail relay, CrowdSec, automatic security updates;mail=Mail relay only;crowdsec=CrowdSec only;updates=Automatic security updates only;rkhunter=Extra: rkhunter with daily report;scout=Extra: Docker Scout for the admin user;rkhunter_off=Remove rkhunter again;back=Back"
    # Each part reports for itself, and one failing part does not swallow the others: until
    # 2026-09-23 this was an && chain that skipped everything after the first failure -- and
    # marked the step done regardless. Hardening that half ran must not look finished.
    local rc=0
    case "$pick" in
        set)          _hard_mail        || rc=1
                      _hard_crowdsec    || rc=1
                      _hard_autoupdates || rc=1 ;;
        mail)         _hard_mail        || rc=1 ;;
        crowdsec)     _hard_crowdsec    || rc=1 ;;
        updates)      _hard_autoupdates || rc=1 ;;
        rkhunter)     _hard_rkhunter    || rc=1 ;;
        scout)        _hard_scout       || rc=1 ;;
        rkhunter_off) _hard_rkhunter_off || rc=1 ;;
        back)         return 0 ;;
    esac
    if (( rc != 0 )); then
        log_err "Hardening is INCOMPLETE -- the part above did not finish. The step stays open on purpose; fix the cause and run it again."
        return 1
    fi
    step_done 60
}

# Automatic security updates: unattended-upgrades (debian), dnf-automatic (rhel),
# os-update timer (suse). Reports go through the mail relay when it exists.
_hard_autoupdates() {
    heading "Automatic security updates"
    checklist_require NOTIFICATION_EMAIL
    case "$OS_FAMILY" in
        debian)
            pkg_install unattended-upgrades
            cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
            cat > /etc/apt/apt.conf.d/52onions-unattended <<EOF
// onions-server, step 6: security updates apply themselves; a report is mailed on change
Unattended-Upgrade::Mail "$NOTIFICATION_EMAIL";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
            svc_enable_now unattended-upgrades
            unattended-upgrade --dry-run >/dev/null 2>&1 && log_ok "unattended-upgrades active (security origins, no automatic reboot)." \
                || log_warn "unattended-upgrades installed, but the dry run reported a problem -- see /var/log/unattended-upgrades/"
            ;;
        rhel)
            pkg_install dnf-automatic
            backup_file /etc/dnf/automatic.conf
            sed -i -E 's/^upgrade_type *=.*/upgrade_type = security/; s/^apply_updates *=.*/apply_updates = yes/; s/^emit_via *=.*/emit_via = stdio,email/; s/^email_to *=.*/email_to = '"$NOTIFICATION_EMAIL"'/' /etc/dnf/automatic.conf
            svc_enable_now dnf-automatic.timer
            log_ok "dnf-automatic: security updates apply daily, report to $NOTIFICATION_EMAIL."
            ;;
        suse)
            pkg_install os-update
            svc_enable_now os-update.timer
            log_ok "os-update timer active (zypper patch, daily)."
            ;;
    esac
}

_hard_rkhunter_off() {
    heading "Remove rkhunter"
    if pkg_installed rkhunter; then
        pkg_remove rkhunter
        rm -f /etc/cron.daily/rkhunter
        log_ok "rkhunter removed, daily job gone."
    else
        log_ok "rkhunter is not installed."
    fi
}

_hard_mail() {
    heading "Mail relay"
    checklist_require NOTIFICATION_EMAIL SENDER_EMAIL SMTP_SERVER SMTP_PORT SMTP_USER
    pkg_install msmtp msmtp-mta
    local pw
    ask_secret pw "Password of $SMTP_USER at $SMTP_SERVER" SMTP_USER
    backup_file /etc/msmtprc
    umask 077
    cat > /etc/msmtprc <<EOF
# Mail relay for $DOMAIN -- written by onions-server, step 60
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        relay
host           $SMTP_SERVER
port           $SMTP_PORT
from           $SENDER_EMAIL
user           $SMTP_USER
password       $pw

account default : relay
EOF
    unset pw; umask 022
    chmod 600 /etc/msmtprc; chown root:root /etc/msmtprc
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || sed -i 's|/etc/ssl/certs/ca-certificates.crt|/etc/pki/tls/certs/ca-bundle.crt|' /etc/msmtprc
    cat > /usr/local/bin/system-mail <<'EOF'
#!/usr/bin/env bash
# system-mail -s "Subject" recipient  <  body   -- sends through the msmtp relay
subject=""; to=""
while [[ $# -gt 0 ]]; do case "$1" in -s|--subject) subject="$2"; shift 2 ;; *) to="$1"; shift ;; esac; done
[[ -n "$to" ]] || { echo "system-mail: recipient missing" >&2; exit 2; }
prefix="[$(hostname -f 2>/dev/null || hostname)]"
[[ "$subject" == "$prefix"* ]] || subject="$prefix $subject"
{ printf 'To: %s\nSubject: %s\n\n' "$to" "$subject"; cat; } | /usr/bin/msmtp -a default "$to"
EOF
    chmod 755 /usr/local/bin/system-mail
    log_ok "Relay configured; wrapper /usr/local/bin/system-mail."
    if confirm "Send a test mail to $NOTIFICATION_EMAIL?" y step60.testmail; then
        if printf 'Test mail from %s (onions-server step 60).\n' "$(hostname)" | system-mail -s "Relay test" "$NOTIFICATION_EMAIL"; then
            log_ok "Test mail handed to the relay -- check the mailbox."
        else
            log_warn "Sending failed -- see /var/log/msmtp.log"
        fi
    fi
}

# CrowdSec = the detector (crowdsec) PLUS the bouncer that turns its decisions into firewall
# rules. Without the bouncer nothing is blocked, so this function fails closed: no running
# bouncer, no "done". Until 2026-09-23 it only warned, and a Debian trixie install ended with
# "[WARN] Bouncer NOT running -- nothing is blocked yet" in a step that called itself finished.
_hard_crowdsec() {
    heading "CrowdSec"
    _crowdsec_repo || return 1
    pkg_refresh
    pkg_install crowdsec || { log_err "crowdsec is not installable -- see the messages above."; return 1; }
    svc_enable_now crowdsec

    # The bouncer's package name differs by source: the vendor repository splits it by firewall
    # backend, the distribution's own ships one package for both. Take the first that installs.
    local bouncer="" candidate
    for candidate in crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables crowdsec-firewall-bouncer; do
        if pkg_install "$candidate"; then bouncer="$candidate"; break; fi
        log_info "$candidate is not available from the configured sources, trying the next name."
    done
    if [[ -z "$bouncer" ]]; then
        log_err "No firewall bouncer could be installed -- CrowdSec would detect attacks and block nothing."
        log_err "  Sources in use: $(ls /etc/apt/sources.list.d/ 2>/dev/null | tr '\n' ' ')"
        log_err "  Install one by hand (docs.crowdsec.net, 'Firewall Bouncer') and run this step again."
        return 1
    fi
    log_ok "Bouncer package: $bouncer"

    # A registration is only worth something when the key it produced is in the bouncer's
    # config. A repaired install lands exactly between the two: the bouncer was registered in
    # an earlier run, the package that reads the key was installed only now, and its config
    # still carries the packaged placeholder. Asking only "is it registered?" would leave it
    # there for good, with a bouncer that starts and authenticates against nothing. So the
    # config decides, and a name that is registered without a usable key is registered again.
    local name="firewall-bouncer-$(hostname)" key conf
    if _bouncer_key_present; then
        log_ok "Bouncer $name is registered and its key is in the configuration."
    else
        cscli bouncers delete "$name" >/dev/null 2>&1 \
            && log_info "Bouncer $name was registered without a usable key -- registering again."
        key="$(cscli bouncers add "$name" -o raw)"
        for conf in /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml /etc/crowdsec/bouncers/crowdsec-firewall-bouncer-nftables.yaml; do
            [[ -f "$conf" ]] || continue
            backup_file "$conf"
            sed -i "s|^api_key:.*|api_key: $key|" "$conf"
        done
        unset key
        _bouncer_key_present || { log_err "The bouncer's configuration still has no api_key -- look into /etc/crowdsec/bouncers/."; return 1; }
        svc_enable_now crowdsec-firewall-bouncer
        svc_restart crowdsec-firewall-bouncer
    fi
    svc_reload crowdsec
    if ! svc_active crowdsec-firewall-bouncer; then
        log_err "The bouncer is installed but NOT running -- nothing is blocked. Its own words:"
        journalctl -u crowdsec-firewall-bouncer -n 20 --no-pager 2>&1 | tee -a "$LOG_FILE" || true
        return 1
    fi
    log_ok "Bouncer active -- CrowdSec's decisions reach the firewall."
    cscli bouncers list | tee -a "$LOG_FILE"
}

# _bouncer_key_present [DIR] -> 0 when one of the bouncer configs in DIR carries a real
# api_key. The packaged default is the literal ${API_KEY}; an empty value, "none" and "null"
# count as missing too. DIR is a parameter so the self-test can measure the real function
# instead of a copy of it. Nothing of the key itself is printed or logged.
_bouncer_key_present() {
    local dir="${1:-/etc/crowdsec/bouncers}" conf value
    for conf in "$dir"/crowdsec-firewall-bouncer.yaml "$dir"/crowdsec-firewall-bouncer-nftables.yaml; do
        [[ -f "$conf" ]] || continue
        value="$(sed -n 's/^api_key:[[:space:]]*//p' "$conf" | head -1 | tr -d "\"' ")"
        case "$value" in
            ''|'${API_KEY}'|none|null) continue ;;
            *) return 0 ;;
        esac
    done
    return 1
}

# The package source for CrowdSec. The vendor repository carries current versions but lags the
# distribution's release cycle; the distribution's own is always there but can be years old.
# Prefer the vendor's for a codename it actually serves -- and say plainly which one it is.
_crowdsec_repo() {
    local dist
    case "$OS_FAMILY" in
        debian)
            if dist="$(apt_repo_dist "https://packagecloud.io/crowdsec/crowdsec/${OS_ID}")"; then
                [[ "$dist" == "$OS_CODENAME" ]] \
                    || log_warn "CrowdSec publishes nothing for ${OS_ID} ${OS_CODENAME} yet -- taking its ${dist} packages, which run here."
                # os/dist are the packagecloud script's own override variables: without them it
                # asks lsb_release, writes a source for a codename the repository does not have,
                # and every later apt-get update fails with 404.
                curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh \
                    | os="$OS_ID" dist="$dist" bash
                log_ok "CrowdSec repository: packagecloud, ${OS_ID}/${dist}."
                return 0
            fi
            log_warn "CrowdSec's own repository carries nothing usable for ${OS_ID} ${OS_CODENAME}."
            rm -f /etc/apt/sources.list.d/crowdsec_crowdsec.list
            if apt-cache policy crowdsec 2>/dev/null | grep -q 'Candidate: [0-9]'; then
                log_warn "Using the packages of ${OS_PRETTY} instead -- these are older and their"
                log_warn "  hub content may no longer update. Watch 'cscli hub list' afterwards."
                return 0
            fi
            log_err "Neither CrowdSec's repository nor ${OS_PRETTY} offers a crowdsec package."
            return 1
            ;;
        rhel)
            curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.rpm.sh | bash
            return 0
            ;;
        suse)
            log_err "CrowdSec has no packagecloud repository for SUSE -- install it by hand (docs.crowdsec.net) and rerun."
            return 1
            ;;
    esac
}

_hard_rkhunter() {
    heading "rkhunter"
    checklist_require NOTIFICATION_EMAIL
    [[ -x /usr/local/bin/system-mail ]] || { log_err "system-mail is missing -- set up the mail relay first (the daily report needs it)."; return 1; }
    [[ "$OS_FAMILY" == "rhel" ]] && pkg_install epel-release
    pkg_install rkhunter
    backup_file /etc/rkhunter.conf
    sed -i -E "s/^(#\s*)?MAIL-ON-WARNING=.*/MAIL-ON-WARNING=\"$NOTIFICATION_EMAIL\"/" /etc/rkhunter.conf
    sed -i -E "s/^(#\s*)?UPDATE_MIRRORS=.*/UPDATE_MIRRORS=1/" /etc/rkhunter.conf
    sed -i -E "s/^(#\s*)?MIRRORS_MODE=.*/MIRRORS_MODE=0/" /etc/rkhunter.conf
    rkhunter --update >/dev/null || true
    rkhunter --propupd >/dev/null
    cat > /etc/cron.daily/rkhunter <<EOF
#!/bin/sh
rkhunter --check --cron --skip-keypress --report-warnings-only | /usr/local/bin/system-mail -s "rkhunter daily scan" "$NOTIFICATION_EMAIL"
EOF
    chmod 755 /etc/cron.daily/rkhunter
    log_ok "rkhunter installed, daily report to $NOTIFICATION_EMAIL."
    confirm "Run the first scan now (several minutes)?" n step60.rkhunter && rkhunter --check --skip-keypress --report-warnings-only || true
}

_hard_scout() {
    heading "Docker Scout"
    checklist_require ADMIN_USER
    local version="1.14.0" home dir
    home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"; dir="$home/.docker/cli-plugins"
    sudo -u "$ADMIN_USER" mkdir -p "$dir"
    curl -fsSL "https://github.com/docker/scout-cli/releases/download/v${version}/docker-scout_${version}_linux_amd64.tar.gz" -o /tmp/docker-scout.tgz
    sudo -u "$ADMIN_USER" tar xzf /tmp/docker-scout.tgz -C "$dir" docker-scout
    rm -f /tmp/docker-scout.tgz
    chmod 755 "$dir/docker-scout"
    sudo -u "$ADMIN_USER" "$dir/docker-scout" version >/dev/null && log_ok "Docker Scout $version for $ADMIN_USER (docker scout cves --image <name>)."
}
