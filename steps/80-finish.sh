#!/usr/bin/env bash
# steps/80-finish.sh -- the last step: the bootstrap user leaves. It was the delivered
# state's working login; once personal admins exist, are proven and sshd is hardened, it
# is only an extra door. The step refuses to remove it while any of that is missing, and
# refuses while the user still owns files (it should own nothing, see steps/10).
# Sourced by install.sh.

STEP_80_TITLE="Finish (remove the bootstrap user after the checks)"

step_80_run() {
    heading "$STEP_80_TITLE"
    local user="$BOOTSTRAP_USER" ok=1 u sudo_ok=0

    if ! id "$user" >/dev/null 2>&1; then
        log_ok "Bootstrap user $user is already gone."
        step_done 80; return 0
    fi

    # 1. at least one personal admin with sudo and an authorized key
    for u in $(cat "$STATE_DIR/personal_users" 2>/dev/null); do
        id "$u" >/dev/null 2>&1 || continue
        id -nG "$u" | tr ' ' '\n' | grep -qx "$(sudo_group)" || continue
        [[ -s "$(getent passwd "$u" | cut -d: -f6)/.ssh/authorized_keys" ]] || continue
        sudo_ok=1; log_ok "Personal admin with sudo and key: $u"
    done
    (( sudo_ok )) || { log_err "No personal admin with sudo and an SSH key -- step 3 first."; ok=0; }

    # 2. sshd hardened (key only) -- otherwise the bootstrap password is still the easy door
    if [[ -f "$STATE_DIR/sshd_hardened" ]]; then log_ok "sshd hardened."
    else log_err "sshd is not hardened yet (step 3, second half)."; ok=0; fi

    # 3. the user owns nothing outside its home
    local owned; owned="$(find / -xdev \( -path /proc -o -path /sys -o -path "/home/$user" \) -prune -o -user "$user" -print 2>/dev/null | head -20)"
    if [[ -n "$owned" ]]; then
        log_err "$user still owns files outside its home -- removing it would orphan them:"
        echo "$owned" | sed 's/^/    /'
        log_info "Give them to root:$PLATFORM_GROUP (chown) or to the admin who needs them, then run this step again."
        ok=0
    else
        log_ok "$user owns nothing outside /home/$user."
    fi

    # 4. not the user running this
    if [[ "${SUDO_USER:-}" == "$user" ]]; then
        log_err "You are logged in as $user -- log in as a personal admin and run this step from there."; ok=0
    fi

    (( ok )) || { log_err "Not removed. Fix the points above."; return 1; }

    log_warn "Removing $user with its home directory. Its sessions end now."
    confirm_word "Remove bootstrap user $user?" YES || return 1
    pkill -KILL -u "$user" 2>/dev/null || true
    run userdel -r "$user"
    rm -f "/etc/sudoers.d/$user"
    step_done 80
    log_ok "Bootstrap user removed. Logins: personal admins by key only. The Toolserver runs the host from here."
}
