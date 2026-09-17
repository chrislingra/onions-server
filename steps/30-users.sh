#!/usr/bin/env bash
# steps/30-users.sh -- the administrative user, sudo, SSH key, SFTP access, sshd hardening.
# Origin: prepare-system.sh step 2 (user), user-security.sh (key, sudo, sshd).
# Differences to the origin, on purpose:
#   * no password in the script -- it is asked once, hidden, and goes straight to chpasswd
#   * the hardening refuses to run until the key login was proven in a second session
#   * sshd settings go to a drop-in when the main config includes one (Ubuntu 22.04+ ships
#     50-cloud-init.conf with PasswordAuthentication yes, which the old sed never saw)
#   * no chown -R on /opt (it changed the owner of every container volume)
# Sourced by install.sh.

STEP_30_TITLE="Admin user, SSH key, sshd hardening"

step_30_run() {
    heading "$STEP_30_TITLE"
    checklist_require ADMIN_USER ADMIN_SSH_PUBKEY
    local user="$ADMIN_USER" group_sudo; group_sudo="$(sudo_group)"

    # --- user --------------------------------------------------------------------------
    if id "$user" >/dev/null 2>&1; then
        log_ok "User $user exists."
    else
        run useradd -m -s /bin/bash "$user"
        log_ok "User $user created."
    fi
    if confirm "Set (or reset) the password of $user now?" y; then
        local pw
        ask_secret pw "Password for $user"
        printf '%s:%s\n' "$user" "$pw" | chpasswd
        unset pw
        log_ok "Password set."
    fi
    run usermod -aG "$group_sudo" "$user"
    if getent group docker >/dev/null; then run usermod -aG docker "$user"; fi

    # --- key ---------------------------------------------------------------------------
    local home grp; home="$(getent passwd "$user" | cut -d: -f6)"; grp="$(primary_group "$user")"
    local key; key="$(pubkey_text "$ADMIN_SSH_PUBKEY")"
    install -d -m 700 -o "$user" -g "$grp" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    if ! grep -qF "$key" "$home/.ssh/authorized_keys"; then
        echo "$key" >> "$home/.ssh/authorized_keys"
        log_ok "Public key added to $home/.ssh/authorized_keys."
    else
        log_ok "Public key already present."
    fi
    chmod 600 "$home/.ssh/authorized_keys"; chown "$user:$grp" "$home/.ssh/authorized_keys"

    # --- sftp subsystem (WinSCP): internal-sftp needs no binary path per distribution ---
    local sshd_conf="/etc/ssh/sshd_config"
    backup_file "$sshd_conf"
    if grep -Eq '^[[:space:]]*Subsystem[[:space:]]+sftp' "$sshd_conf"; then
        sed -i -E 's|^[[:space:]]*Subsystem[[:space:]]+sftp.*$|Subsystem sftp internal-sftp|' "$sshd_conf"
    else
        echo "Subsystem sftp internal-sftp" >> "$sshd_conf"
    fi

    # --- hardening, guarded ------------------------------------------------------------
    echo
    log_warn "Next: root login off, password login off, key only."
    log_warn "Before you say yes: open a SECOND terminal and log in as $user with the key."
    if ! confirm "Did the key login of $user work in a second session?" n; then
        log_warn "Hardening skipped -- run this step again once the key login is proven."
        step_done 30
        return 0
    fi
    _sshd_apply_hardening
    step_done 30
    log_ok "sshd hardened. Keep the second session open until you confirmed the new login."
}

_sshd_apply_hardening() {
    local main="/etc/ssh/sshd_config" target
    if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$main"; then
        target="/etc/ssh/sshd_config.d/10-onions.conf"   # sorts before 50-cloud-init.conf: first match wins
        mkdir -p /etc/ssh/sshd_config.d
        backup_file "$target"
        : > "$target"
    else
        target="$main"
    fi
    set_config_line "$target" PermitRootLogin no
    set_config_line "$target" PasswordAuthentication no
    set_config_line "$target" PubkeyAuthentication yes
    set_config_line "$target" ChallengeResponseAuthentication no
    set_config_line "$target" X11Forwarding no
    set_config_line "$target" MaxAuthTries 3
    set_config_line "$target" ClientAliveInterval 60
    set_config_line "$target" ClientAliveCountMax 3
    if ! sshd -t; then
        log_err "sshd rejects the new configuration -- restoring the backup, nothing restarted."
        cp -a "$STATE_DIR/backups/$RUN_STAMP$target" "$target" 2>/dev/null || rm -f "$target"
        return 1
    fi
    svc_restart "$(sshd_service)"
    log_info "Effective: $(sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication) ' | tr '\n' ' ')"
}
