#!/usr/bin/env bash
# steps/10-base.sh -- system update, base packages, locale and time zone, the platform
# group and the bootstrap user.
# Sourced by install.sh.
#
# The bootstrap user ($BOOTSTRAP_USER, fixed name) is what makes the delivered state work:
# sudo, docker, member of the platform group, a generated password shown ONCE on the console
# and expired on purpose (must be changed at first login). It owns nothing -- platform files
# belong to root:$PLATFORM_GROUP -- so step 8 can remove it without leaving orphans.

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
        if confirm "Remove snapd?" y; then
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
}

_bootstrap_user() {
    local user="$BOOTSTRAP_USER"
    if id "$user" >/dev/null 2>&1; then
        log_ok "Bootstrap user $user exists (password unchanged)."
    else
        run useradd -m -s /bin/bash "$user"
        local pw; pw="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
        printf '%s:%s\n' "$user" "$pw" | chpasswd
        chage -d 0 "$user"    # expired: must be changed at the first login
        # shown once, on purpose not through the logger -- the log must never carry it
        echo
        echo "  ==========================================================="
        echo "  Bootstrap user  : $user"
        echo "  One-time password: $pw"
        echo "  Changes at first login. Step 8 removes this user again."
        echo "  ==========================================================="
        echo
        unset pw
        _log_line "INFO" "bootstrap user $user created, one-time password shown on the console"
        pause
    fi
    run usermod -aG "$(sudo_group)" "$user"
    run usermod -aG "$PLATFORM_GROUP" "$user"
    getent group docker >/dev/null && run usermod -aG docker "$user"
    log_ok "$user: sudo, $PLATFORM_GROUP$(getent group docker >/dev/null && echo ', docker')."
}
