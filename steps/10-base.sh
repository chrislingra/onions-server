#!/usr/bin/env bash
# steps/10-base.sh -- system update, base packages, locale and time zone, the platform
# group and the bootstrap user.
# Sourced by install.sh.
#
# The bootstrap user ($BOOTSTRAP_USER, fixed name) is what makes the delivered state work:
# sudo, docker, member of the platform group, and a password that is expired on purpose (the
# first login must change it). You either set that password yourself or let it be generated
# into a root-only file -- see _bootstrap_user below for why there is no fixed default one.
# It owns nothing -- platform files belong to root:$PLATFORM_GROUP -- so step 8 can remove it
# without leaving orphans.

STEP_10_TITLE="Base system (updates, packages, locale, platform group, bootstrap user)"

step_10_run() {
    heading "$STEP_10_TITLE"
    checklist_require LANGUAGE COUNTRY

    log_info "Refreshing package lists and upgrading the system ($OS_PRETTY)..."
    pkg_refresh
    pkg_upgrade_all

    log_info "Installing base packages..."
    pkg_install curl ca-certificates gnupg git openssl acl jq rsync "$(pkg_name cron)"

    if [[ "$OS_ID" == "ubuntu" ]] && pkg_installed snapd; then
        if confirm "Remove snapd?" y step10.snapd; then
            systemctl disable --now snapd.service snapd.socket snapd.seeded.service >/dev/null 2>&1 || true
            pkg_remove snapd
            rm -rf /root/snap /var/cache/snapd /var/lib/snapd
            log_ok "snapd removed."
        fi
    fi

    log_info "Locale $LOCALE, keymap $KEYMAP, time zone $TIMEZONE..."
    locale_set "$LOCALE" "$TIMEZONE" "$KEYMAP"

    _platform_group
    _bootstrap_user

    log_info "Security framework: $(security_framework)"
    step_done 10
    log_ok "Base system done. A reboot applies the new locale to every session."
}

_platform_group() {
    if getent group "$PLATFORM_GROUP" >/dev/null; then
        log_ok "Group $PLATFORM_GROUP exists."
    else
        run groupadd "$PLATFORM_GROUP"
        log_ok "Group $PLATFORM_GROUP created (owner group of the platform directories)."
    fi
    # the instance directory belongs to the platform, not to a person
    chgrp -R "$PLATFORM_GROUP" "$INSTANCE_DIR"
    chmod 2750 "$INSTANCE_DIR"
    _backup_root
}

# /opt/backups -- where every service puts its backups, and where the copies of
# deploy_write and deploy_delete land. It is created HERE, with the platform
# group, and not later by whoever happens to write into it first.
#
# Why this is its own line in the installer (operator 2026-09-23: "chris braucht
# zugriff auf die volle backupstruktur. das ist nicht gegeben und muss auch fuer
# kuenftige installationen beruecksichtigt werden"): on the host that grew
# before this installer existed, the backup library created everything with
# mode 700 and 600 -- readable by root alone. Nobody noticed until an admin
# tried to reach his own backups over SFTP and found nothing. The rule is the
# same one as for every other platform directory, and it belongs where the
# group is created, not in nine service scripts.
#
# The 2 in 2750 is the point: setgid passes the group on to everything created
# inside later, so a service that makes its own subdirectory does the right
# thing without knowing about any of this.
_backup_root() {
    local dir="/opt/backups"
    mkdir -p "$dir"
    chgrp "$PLATFORM_GROUP" "$dir"
    chmod 2750 "$dir"
    log_ok "$dir belongs to root:$PLATFORM_GROUP, mode 2750 (setgid -- new subdirectories inherit the group)."
    log_info "Everyone in $PLATFORM_GROUP can read the backups -- including database dumps."
}

# The first password of a fresh host has to ARRIVE somewhere. Printing it on the console is
# not enough (operator 2026-09-23: "herauskopieren kann ich es nicht aus dem laufenden
# installationsscreen") -- on a KVM console, a rescue viewer or a serial line there is nothing
# to copy with, and a 16-character random string typed off a screen is a source of errors.
#
# There is no fixed default password in this repository, and there will not be one: the
# repository is public, so a password written in it is a published password, and every host
# installed from it would answer to it before anybody logs in the first time. What replaces it
# gives the same thing -- a password that is known without copying:
#   1. you set it yourself (then nothing needs copying: you already know it),
#   2. or it is generated and put into a root-only file, which can be read later, fetched by
#      scp, or mailed by the relay from step 6.
# It stays expired either way: the first login must change it.
_bootstrap_user() {
    local user="$BOOTSTRAP_USER"
    if id "$user" >/dev/null 2>&1; then
        log_ok "Bootstrap user $user exists (password unchanged)."
    else
        run useradd -m -s /bin/bash "$user"
        local pw="" mode
        echo
        echo "The first password of $user. It expires immediately: the first login changes it."
        pick_option mode "How do you want to get it?" self step10.password \
            "self=I type it myself now (nothing to copy afterwards);generate=Generate one and put it into a root-only file"
        if [[ "$mode" == "self" ]]; then
            while true; do
                ask_secret pw "Password for $user" step10.password
                (( ${#pw} >= 10 )) && break
                pw=""
                echo "  At least 10 characters -- this user may log in over SSH and use sudo."
            done
        else
            pw="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
        fi
        printf '%s:%s\n' "$user" "$pw" | chpasswd
        chage -d 0 "$user"    # expired: must be changed at the first login
        [[ "$mode" == "generate" ]] && _bootstrap_password_out "$user" "$pw"
        unset pw
        _log_line "INFO" "bootstrap user $user created ($mode), password never written to this log"
        pause
    fi
    run usermod -aG "$(sudo_group)" "$user"
    run usermod -aG "$PLATFORM_GROUP" "$user"
    getent group docker >/dev/null && run usermod -aG docker "$user"
    log_ok "$user: sudo, $PLATFORM_GROUP$(getent group docker >/dev/null && echo ', docker')."
}

# Hand a generated password over: on the console, in a root-only file, and by mail when the
# relay of step 6 already exists. The log file never sees it -- only the fact that it was made.
_bootstrap_password_out() {
    local user="$1" pw="$2"
    local file="$STATE_DIR/bootstrap-password.txt"
    mkdir -p "$STATE_DIR"
    ( umask 077; printf 'user: %s\npassword: %s\nwritten: %s\n\nThis password expires at the first login. Step 8 removes the user and this file.\n' \
        "$user" "$pw" "$(date '+%Y-%m-%d %H:%M:%S')" > "$file" )
    chmod 600 "$file"; chown root:root "$file"
    # shown once, on purpose not through the logger -- the log must never carry it
    echo
    echo "  ==========================================================="
    echo "  Bootstrap user   : $user"
    echo "  One-time password: $pw"
    echo "  Also in          : $file  (root only, mode 600)"
    echo "  Changes at first login. Step 8 removes this user again."
    echo "  ==========================================================="
    echo
    echo "  Nothing to copy off this screen: read the file later with"
    echo "    sudo cat $file"
    echo
    if [[ -x /usr/local/bin/system-mail && -n "${NOTIFICATION_EMAIL:-}" ]]; then
        if confirm "Mail it to $NOTIFICATION_EMAIL as well?" y step10.mailpw; then
            if printf 'Host %s, bootstrap user %s\nOne-time password: %s\n\nIt expires at the first login. Step 8 removes this user.\n' \
                 "$(hostname -f 2>/dev/null || hostname)" "$user" "$pw" \
                 | system-mail -s "Bootstrap password" "$NOTIFICATION_EMAIL"; then
                log_ok "Password handed to the mail relay."
            else
                log_warn "Sending failed -- see /var/log/msmtp.log. The file above still has it."
            fi
        fi
    else
        log_info "No mail relay yet (step 6 sets it up). Until then the file above is the way to it."
    fi
}
