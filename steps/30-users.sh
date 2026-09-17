#!/usr/bin/env bash
# steps/30-users.sh -- personal admins (each with their own SSH key), SFTP, sshd hardening.
# The bootstrap user is step 1's; this step is about the people. Rules:
#   * every personal user brings a public key -- no key, no user (the hardening below turns
#     password login off, and a user without a key would be locked out with it)
#   * the hardening refuses to run until a key login was proven in a second session
#   * sshd settings go to a drop-in when the main config includes one (Ubuntu 22.04+ ships
#     50-cloud-init.conf with PasswordAuthentication yes, which the old sed never saw)
#   * no chown -R on /opt (it changed the owner of every container volume); admins reach
#     the platform directories through the group $PLATFORM_GROUP instead
# Sourced by install.sh.

STEP_30_TITLE="Personal admins (SSH keys), SFTP, sshd hardening"

step_30_run() {
    heading "$STEP_30_TITLE"
    checklist_require ADMIN_USER ADMIN_SSH_PUBKEY
    _personal_user "$ADMIN_USER" "$ADMIN_SSH_PUBKEY" y
    while confirm "Add another personal admin?" n; do
        local name key
        while true; do
            ask name "Linux user name"
            is_personal_user "$name" && break
            echo "  '$name' is not allowed (reserved: $BOOTSTRAP_USER, root)."
        done
        while true; do
            ask key "Public SSH key of $name (one line, or a path to a .pub file)"
            is_pubkey "$key" && break
            echo "  That is not a public key."
        done
        local sudo_flag=n; confirm "Give $name sudo?" y && sudo_flag=y
        _personal_user "$name" "$key" "$sudo_flag"
    done
    _sftp_subsystem
    echo
    log_warn "Next: root login off, password login off, key only -- for everyone, including $BOOTSTRAP_USER."
    log_warn "Before you say yes: open a SECOND terminal and log in as a personal admin with the key."
    if ! confirm "Did a key login of a personal admin work in a second session?" n; then
        log_warn "Hardening skipped -- run this step again once the key login is proven."
        step_done 30
        return 0
    fi
    _sshd_apply_hardening
    step_done 30
    log_ok "sshd hardened. Keep the second session open until you confirmed the new login."
}

# _personal_user NAME PUBKEY SUDO(y|n)
_personal_user() {
    local user="$1" pubkey="$2" want_sudo="$3"
    if id "$user" >/dev/null 2>&1; then
        log_ok "User $user exists."
    else
        run useradd -m -s /bin/bash "$user"
        log_ok "User $user created."
        if confirm "Set a password for $user (sudo asks for it; login itself is by key)?" y; then
            local pw; ask_secret pw "Password for $user"
            printf '%s:%s\n' "$user" "$pw" | chpasswd; unset pw
        fi
    fi
    [[ "$want_sudo" == "y" ]] && run usermod -aG "$(sudo_group)" "$user"
    run usermod -aG "$PLATFORM_GROUP" "$user"
    getent group docker >/dev/null && run usermod -aG docker "$user"

    local home grp key
    home="$(getent passwd "$user" | cut -d: -f6)"; grp="$(primary_group "$user")"
    key="$(pubkey_text "$pubkey")"
    install -d -m 700 -o "$user" -g "$grp" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    if ! grep -qF "$key" "$home/.ssh/authorized_keys"; then
        echo "$key" >> "$home/.ssh/authorized_keys"
        log_ok "Public key added for $user."
    else
        log_ok "Public key of $user already present."
    fi
    chmod 600 "$home/.ssh/authorized_keys"; chown "$user:$grp" "$home/.ssh/authorized_keys"
    printf '%s\n' "$user" >> "$STATE_DIR/personal_users"
    sort -u -o "$STATE_DIR/personal_users" "$STATE_DIR/personal_users"
}

# internal-sftp needs no sftp-server binary path per distribution (WinSCP works with it)
_sftp_subsystem() {
    local sshd_conf="/etc/ssh/sshd_config"
    backup_file "$sshd_conf"
    if grep -Eq '^[[:space:]]*Subsystem[[:space:]]+sftp' "$sshd_conf"; then
        sed -i -E 's|^[[:space:]]*Subsystem[[:space:]]+sftp.*$|Subsystem sftp internal-sftp|' "$sshd_conf"
    else
        echo "Subsystem sftp internal-sftp" >> "$sshd_conf"
    fi
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
    touch "$STATE_DIR/sshd_hardened"
    log_info "Effective: $(sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication) ' | tr '\n' ' ')"
}
