#!/usr/bin/env bash
# steps/60-hardening.sh -- mail relay, CrowdSec, rkhunter, Docker Scout.
# The SMTP password is asked hidden and written only to /etc/msmtprc (mode 600, root).
# Sourced by install.sh.

STEP_60_TITLE="Hardening (mail relay, CrowdSec, rkhunter, Docker Scout)"

step_60_run() {
    heading "$STEP_60_TITLE"
    local parts=("Mail relay (msmtp)" "CrowdSec + firewall bouncer" "rkhunter with daily report" "Docker Scout for the admin user" "All four")
    local pick; pick="$(choose "Which part" "${parts[@]}")"
    case "$pick" in
        0) return 0 ;;
        1) _hard_mail ;;
        2) _hard_crowdsec ;;
        3) _hard_rkhunter ;;
        4) _hard_scout ;;
        5) _hard_mail && _hard_crowdsec && _hard_rkhunter && _hard_scout ;;
    esac
    step_done 60
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
