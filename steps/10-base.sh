#!/usr/bin/env bash
# steps/10-base.sh -- system update, base packages, locale and time zone.
# Origin: prepare-system.sh step 1 + setup-utf8.sh. Sourced by install.sh.

STEP_10_TITLE="Base system (updates, packages, locale, time zone)"

step_10_run() {
    heading "$STEP_10_TITLE"
    checklist_require TIMEZONE LOCALE KEYMAP

    log_info "Refreshing package lists and upgrading the system ($OS_PRETTY)..."
    pkg_refresh
    pkg_upgrade_all

    log_info "Installing base packages..."
    pkg_install curl ca-certificates gnupg git openssl acl jq rsync "$(pkg_name cron)"

    if [[ "$OS_ID" == "ubuntu" ]] && pkg_installed snapd; then
        if confirm "Remove snapd (saves memory; prepare-system.sh always did this)?" y; then
            systemctl disable --now snapd.service snapd.socket snapd.seeded.service >/dev/null 2>&1 || true
            pkg_remove snapd
            rm -rf /root/snap /var/cache/snapd /var/lib/snapd
            log_ok "snapd removed."
        fi
    fi

    log_info "Locale $LOCALE, keymap $KEYMAP, time zone $TIMEZONE..."
    locale_set "$LOCALE" "$TIMEZONE" "$KEYMAP"

    log_info "Security framework: $(security_framework)"
    step_done 10
    log_ok "Base system done. A reboot applies the new locale to every session."
}
