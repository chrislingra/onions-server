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
    pick_option pick "Which part" set \
        "set=Recommended set: mail relay, CrowdSec, automatic security updates;mail=Mail relay only;crowdsec=CrowdSec only;updates=Automatic security updates only;rkhunter=Extra: rkhunter with daily report;scout=Extra: Docker Scout for the admin user;rkhunter_off=Remove rkhunter again;back=Back"
    case "$pick" in
        set)         _hard_mail && _hard_crowdsec && _hard_autoupdates ;;
        mail)        _hard_mail ;;
        crowdsec)    _hard_crowdsec ;;
        updates)     _hard_autoupdates ;;
        rkhunter)    _hard_rkhunter ;;
        scout)       _hard_scout ;;
        rkhunter_off) _hard_rkhunter_off ;;
        back)        return 0 ;;
    esac
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
    ask_secret pw "Password of $SMTP_USER at $SMTP_SERVER"
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
    if confirm "Send a test mail to $NOTIFICATION_EMAIL?" y; then
        if printf 'Test mail from %s (onions-server step 60).\n' "$(hostname)" | system-mail -s "Relay test" "$NOTIFICATION_EMAIL"; then
            log_ok "Test mail handed to the relay -- check the mailbox."
        else
            log_warn "Sending failed -- see /var/log/msmtp.log"
        fi
    fi
}

_hard_crowdsec() {
    heading "CrowdSec"
    case "$OS_FAMILY" in
        debian) curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash ;;
        rhel)   curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.rpm.sh | bash ;;
        suse)   log_err "CrowdSec has no packagecloud repository for SUSE -- install it by hand (docs.crowdsec.net) and rerun."; return 1 ;;
    esac
    pkg_refresh
    pkg_install crowdsec
    svc_enable_now crowdsec
    if ! pkg_install crowdsec-firewall-bouncer-nftables; then
        log_warn "nftables bouncer not installable, trying the iptables one."
        pkg_install crowdsec-firewall-bouncer-iptables
    fi
    local name="firewall-bouncer-$(hostname)" key conf
    if cscli bouncers list -o raw 2>/dev/null | grep -q "^$name,"; then
        log_ok "Bouncer $name already registered."
    else
        key="$(cscli bouncers add "$name" -o raw)"
        for conf in /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml /etc/crowdsec/bouncers/crowdsec-firewall-bouncer-nftables.yaml; do
            [[ -f "$conf" ]] || continue
            backup_file "$conf"
            sed -i "s|^api_key:.*|api_key: $key|" "$conf"
        done
        unset key
        svc_restart crowdsec-firewall-bouncer
    fi
    svc_reload crowdsec
    svc_active crowdsec-firewall-bouncer && log_ok "Bouncer active." || log_warn "Bouncer NOT running -- nothing is blocked yet."
    cscli bouncers list | tee -a "$LOG_FILE"
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
    confirm "Run the first scan now (several minutes)?" n && rkhunter --check --skip-keypress --report-warnings-only || true
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
