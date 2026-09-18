#!/usr/bin/env bash
# steps/80-finish.sh -- the last step: the bootstrap user leaves. It was the delivered
# state's working login; once a personal admin with sudo can log in, it is only an extra
# door. The step refuses to remove it while nobody else could administer the host, while
# the user still owns files outside its home (it should own nothing, see steps/10), and
# while the person running this step IS that user. sshd hardening is not required here --
# it may follow in the Toolserver (operator 2026-09-17).
#
# Every reason is printed, numbered, before the step gives up (operator's run of
# 2026-09-18: "Step 8 failed" was all he saw). A declined confirmation is not a failure:
# the user stays, the step stays open. Sourced by install.sh.

STEP_80_TITLE="Finish (remove the bootstrap user after the checks)"

# _admin_candidates -> every human user except the bootstrap user: uid >= 1000, a real
# shell, plus whatever step 3 recorded. The Ubuntu installer's first user counts too --
# it is a sudo login the operator already has, whether step 3 created it or not.
_admin_candidates() {
    { getent passwd | awk -F: -v boot="$BOOTSTRAP_USER" '$3 >= 1000 && $3 < 60000 && $1 != boot && $7 !~ /(nologin|false)$/ {print $1}'
      cat "$STATE_DIR/personal_users" 2>/dev/null || true
    } | sort -u
}

# _can_login USER -> 0 when an SSH key or a usable password exists
_can_login() {
    local u="$1" home
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -s "$home/.ssh/authorized_keys" ]] && return 0
    [[ "$(passwd -S "$u" 2>/dev/null | awk '{print $2}')" == "P" ]]
}

step_80_run() {
    heading "$STEP_80_TITLE"
    local user="$BOOTSTRAP_USER" u how sudo_ok=0
    local -a reasons=() owned=()

    if ! id "$user" >/dev/null 2>&1; then
        log_ok "Bootstrap user $user is already gone."
        step_done 80; return 0
    fi

    # 1. someone else with sudo can log in (key or password)
    for u in $(_admin_candidates); do
        id "$u" >/dev/null 2>&1 || continue
        if ! id -nG "$u" | tr ' ' '\n' | grep -qx "$(sudo_group)"; then
            log_info "$u: no sudo -- does not count."; continue
        fi
        if [[ -s "$(getent passwd "$u" | cut -d: -f6)/.ssh/authorized_keys" ]]; then how="SSH key"
        elif _can_login "$u"; then how="password"
        else log_warn "$u: sudo, but neither an SSH key nor a password -- cannot log in."; continue; fi
        sudo_ok=1; log_ok "Admin with sudo who can log in ($how): $u"
    done
    (( sudo_ok )) || reasons+=("No admin besides $user has sudo AND a way to log in (SSH key or password) -- run step 3, or give an existing user sudo and a password.")

    # 2. sshd hardening: not required -- it may follow in the Toolserver
    if [[ -f "$STATE_DIR/sshd_hardened" ]]; then log_ok "sshd hardened (key only)."
    else log_warn "sshd is not hardened: password login stays on until the Toolserver does it."; fi

    # 3. the user owns nothing outside its home (first 20 hits; the pipe may not kill the step)
    mapfile -t owned < <(find / -xdev \( -path /proc -o -path /sys -o -path "/home/$user" \) -prune -o -user "$user" -print 2>/dev/null | head -20 || true)
    if (( ${#owned[@]} )); then
        log_err "$user still owns files outside /home/$user -- removing it would orphan them:"
        printf '    %s\n' "${owned[@]}"
        reasons+=("$user owns files outside its home (see the list above) -- chown them to root:$PLATFORM_GROUP or to the admin who needs them.")
    else
        log_ok "$user owns nothing outside /home/$user."
    fi

    # 4. not the user running this
    if [[ "${SUDO_USER:-}" == "$user" ]]; then
        reasons+=("You are logged in as $user. Log in as one of the admins above and run: sudo bash /opt/onions-server/install.sh -> 8.")
    fi

    if (( ${#reasons[@]} )); then
        log_err "$user is NOT removed. Reason(s):"
        local i=1; for u in "${reasons[@]}"; do echo "  $i) $u"; i=$((i + 1)); done
        return 1
    fi

    log_warn "Removing $user with its home directory. Its sessions end now."
    if ! confirm "Remove bootstrap user $user now?" n; then
        log_info "$user stays. Step 8 remains open -- run it again when ready."
        return 0
    fi
    pkill -KILL -u "$user" 2>/dev/null || true
    run userdel -r "$user"
    rm -f "/etc/sudoers.d/$user"
    step_done 80
    log_ok "Bootstrap user removed. The Toolserver runs the host from here."
}
