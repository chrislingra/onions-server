#!/usr/bin/env bash
# steps/30-users.sh -- personal admins, their SSH keys, SFTP, sshd hardening.
# The bootstrap user is step 1's; this step is about the people. Rules:
#   * SSH keys and hardening are optional here (operator 2026-09-17: "ssh kann uebergangen
#     werden und in onions nachgeholt werden"): the default is a password now and the SSH
#     part later in the Toolserver. A key can still be pasted or generated here (the
#     private key is handed out once and deleted after the proven login).
#   * the hardening refuses to run until a key login was proven in a second session
#   * sshd settings go to a drop-in when the main config includes one (Ubuntu 22.04+ ships
#     50-cloud-init.conf with PasswordAuthentication yes, which a sed on the main file
#     never sees)
#   * no chown -R on /opt (it changes the owner of every container volume); admins reach
#     the platform directories through the group $PLATFORM_GROUP instead
# Sourced by install.sh.

STEP_30_TITLE="Personal admins (SSH keys), SFTP, sshd hardening"

step_30_run() {
    heading "$STEP_30_TITLE"
    checklist_require ADMIN_USER KEY_SOURCE
    [[ "$KEY_SOURCE" == "paste" ]] && _require_pasted_key
    _personal_user "$ADMIN_USER" "$KEY_SOURCE" "${ADMIN_SSH_PUBKEY:--}" y
    while confirm "Add another personal admin?" n; do
        local name source pubkey="-"
        while true; do
            ask name "Linux user name"
            is_personal_user "$name" && break
            echo "  '$name' is not allowed (reserved: $BOOTSTRAP_USER, root)."
        done
        pick_option source "SSH access of $name" later "later=Password now, SSH later in the Toolserver;paste=I have a public key;generate=Generate a key pair on this server"
        if [[ "$source" == "paste" ]]; then
            while true; do
                ask pubkey "Public SSH key of $name (one line, or a path to a .pub file)"
                is_pubkey "$pubkey" && break
                echo "  That is not a public key."
            done
        fi
        local sudo_flag=n; confirm "Give $name sudo?" y && sudo_flag=y
        _personal_user "$name" "$source" "$pubkey" "$sudo_flag"
    done
    _sftp_subsystem

    if ! _any_admin_with_key; then
        log_ok "SSH keys and hardening: later, in the Toolserver (Environment > Server-Config). Password login stays on."
        step_done 30
        return 0
    fi
    echo
    log_warn "Next: root login off, password login off, key only -- for everyone, including $BOOTSTRAP_USER."
    log_warn "Before you say yes: open a SECOND terminal and log in as a personal admin with the key."
    if ! confirm "Did a key login of a personal admin work in a second session?" n; then
        log_warn "Hardening skipped -- run this step again once the key login is proven."
        step_done 30
        return 0
    fi
    _sshd_apply_hardening
    _remove_handed_out_keys
    step_done 30
    log_ok "sshd hardened. Keep the second session open until you confirmed the new login."
}

_require_pasted_key() {
    while ! is_pubkey "${ADMIN_SSH_PUBKEY:-}"; do
        ask ADMIN_SSH_PUBKEY "Public SSH key of $ADMIN_USER (one line, or a path to a .pub file)"
        is_pubkey "$ADMIN_SSH_PUBKEY" || echo "  That is not a public key."
    done
    export ADMIN_SSH_PUBKEY; checklist_save_key ADMIN_SSH_PUBKEY "$ADMIN_SSH_PUBKEY"
}

_any_admin_with_key() {
    local u
    for u in $(cat "$STATE_DIR/personal_users" 2>/dev/null); do
        [[ -s "$(getent passwd "$u" 2>/dev/null | cut -d: -f6)/.ssh/authorized_keys" ]] && return 0
    done
    return 1
}

# _personal_user NAME SOURCE(later|paste|generate) PUBKEY SUDO(y|n)
_personal_user() {
    local user="$1" source="$2" pubkey="$3" want_sudo="$4"
    if id "$user" >/dev/null 2>&1; then
        log_ok "User $user exists."
    else
        run useradd -m -s /bin/bash "$user"
        log_ok "User $user created."
        if [[ "$source" == "later" ]] || confirm "Set a password for $user (sudo asks for it; login itself is by key)?" y; then
            local pw; ask_secret pw "Password for $user"
            printf '%s:%s\n' "$user" "$pw" | chpasswd; unset pw
        fi
    fi
    [[ "$want_sudo" == "y" ]] && run usermod -aG "$(sudo_group)" "$user"
    run usermod -aG "$PLATFORM_GROUP" "$user"
    getent group docker >/dev/null && run usermod -aG docker "$user"
    printf '%s\n' "$user" >> "$STATE_DIR/personal_users"
    sort -u -o "$STATE_DIR/personal_users" "$STATE_DIR/personal_users"

    case "$source" in
        paste)    _install_pubkey "$user" "$(pubkey_text "$pubkey")" ;;
        generate) _generate_key "$user" ;;
        later)    log_ok "$user logs in with the password; SSH key and hardening follow in the Toolserver." ;;
    esac
}

_install_pubkey() {
    local user="$1" key="$2" home grp
    home="$(getent passwd "$user" | cut -d: -f6)"; grp="$(primary_group "$user")"
    install -d -m 700 -o "$user" -g "$grp" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    if ! grep -qF "$key" "$home/.ssh/authorized_keys"; then
        echo "$key" >> "$home/.ssh/authorized_keys"
        log_ok "Public key added for $user."
    else
        log_ok "Public key of $user already present."
    fi
    chmod 600 "$home/.ssh/authorized_keys"; chown "$user:$grp" "$home/.ssh/authorized_keys"
}

# The key pair is made here because the person has none. The private half is written to
# $INSTANCE_DIR/keys/<user> (root:$PLATFORM_GROUP, 640 -- the bootstrap user can fetch it
# with SFTP/WinSCP before the hardening) and shown once; after the proven login it is
# deleted from the server (_remove_handed_out_keys).
_generate_key() {
    local user="$1" dir="$INSTANCE_DIR/keys" file
    mkdir -p "$dir"; chown "root:$PLATFORM_GROUP" "$dir"; chmod 750 "$dir"
    file="$dir/$user"
    if [[ -f "$file" ]]; then
        log_ok "Key pair for $user already exists in $dir."
    else
        ssh-keygen -q -t ed25519 -N "" -C "$user@$DOMAIN" -f "$file"
        chown "root:$PLATFORM_GROUP" "$file" "$file.pub"; chmod 640 "$file"; chmod 644 "$file.pub"
        _log_line "INFO" "key pair generated for $user in $dir (private key handed out on the console)"
    fi
    _install_pubkey "$user" "$(cat "$file.pub")"
    echo
    echo "  ==========================================================="
    echo "  Private key of $user -- copy it NOW to the workstation:"
    echo "    file on this server: $file  (fetch with WinSCP/SFTP as $BOOTSTRAP_USER)"
    echo "    or copy the text below into ~/.ssh/$user (mode 600); WinSCP/PuTTY: import in PuTTYgen"
    echo "  -----------------------------------------------------------"
    cat "$file"
    echo "  ==========================================================="
    echo "  It is deleted from this server once the key login was proven."
    echo
    pause
}

_remove_handed_out_keys() {
    local dir="$INSTANCE_DIR/keys" f
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*; do
        [[ -f "$f" && "$f" != *.pub ]] || continue
        if confirm "Delete the server copy of the private key $(basename "$f") (you have it on the workstation)?" y; then
            shred -u "$f" 2>/dev/null || rm -f "$f"
            log_ok "Private key $(basename "$f") removed from the server."
        else
            log_warn "Private key $(basename "$f") stays in $dir -- delete it yourself once it is safe."
        fi
    done
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
