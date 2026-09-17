#!/usr/bin/env bash
# lib/checklist.sh -- the preparation checklist as data: site.env next to install.sh.
# Everything the installer needs to know is asked here, never assumed and never hardcoded.
# Passwords and keys are NOT part of it: they are asked at the moment of use (ask_secret)
# and exist only in memory. site.env is gitignored. Sourced, never executed.

# key | prompt | default (empty = required) | validator
CHECKLIST_ITEMS=(
    "DOMAIN|Domain the server serves (the directory name under /opt)|${DOMAIN_GUESS:-}|is_domain"
    "ADMIN_USER|Administrative Linux user to create|manager|is_username"
    "ADMIN_SSH_PUBKEY|Public SSH key of the admin (one line, or a path to a .pub file)||is_pubkey"
    "ACME_EMAIL|E-mail for Let's Encrypt (expiry notices)||is_email"
    "ACME_MODE|Let's Encrypt mode: staging (test certificates) or production|production|is_acme_mode"
    "TRAEFIK_IMAGE|Traefik image|traefik:v3|is_nonempty"
    "TIMEZONE|System time zone|Europe/Berlin|is_nonempty"
    "LOCALE|System locale|de_DE.UTF-8|is_nonempty"
    "KEYMAP|Console keymap|de|is_nonempty"
    "NOTIFICATION_EMAIL|E-mail that receives system notifications (rkhunter, cron)||is_email"
    "SENDER_EMAIL|Sender address the server mails from|service@\${DOMAIN}|is_email"
    "SMTP_SERVER|SMTP relay host|smtp.ionos.de|is_nonempty"
    "SMTP_PORT|SMTP relay port (submission)|587|is_number"
    "SMTP_USER|SMTP relay user name (the password is asked when the relay is set up)||is_nonempty"
    "TOOLSERVER_GIT|Git URL of the Toolserver|git@github.com:chrislingra/onions-toolserver.git|is_nonempty"
    "TOOLSERVER_REF|Toolserver branch or tag to install|master|is_nonempty"
)

is_nonempty()  { [[ -n "$1" ]]; }
is_number()    { [[ "$1" =~ ^[0-9]+$ ]]; }
is_domain()    { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }
is_username()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_email()     { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
is_acme_mode() { [[ "$1" == "staging" || "$1" == "production" ]]; }
is_pubkey()    { [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/=]+ ]] || [[ -r "$1" && "$1" == *.pub ]]; }

# checklist_load: read KEY=VALUE lines only (no code is executed from site.env).
checklist_load() {
    [[ -f "$SITE_ENV" ]] || return 0
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"; value="${line#*=}"
        key="${key//[[:space:]]/}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        value="${value%\"}"; value="${value#\"}"
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$SITE_ENV"
}

checklist_save_key() {
    local key="$1" value="$2"
    touch "$SITE_ENV"; chmod 600 "$SITE_ENV"
    set_env_line "$SITE_ENV" "$key" "$value"
}

_checklist_default() {
    # defaults may reference other keys (service@${DOMAIN}); expand them safely
    local raw="$1"
    raw="${raw//\$\{DOMAIN\}/${DOMAIN:-}}"
    echo "$raw"
}

# checklist_require KEY... -> every named key must have a valid value; asks for the rest.
checklist_require() {
    local want item key prompt default validator value
    for want in "$@"; do
        for item in "${CHECKLIST_ITEMS[@]}"; do
            IFS='|' read -r key prompt default validator <<< "$item"
            [[ "$key" == "$want" ]] || continue
            value="${!key:-}"
            if [[ -n "$value" ]] && "$validator" "$value"; then continue; fi
            [[ -n "$value" ]] && log_warn "$key='$value' is not valid, asking again."
            default="$(_checklist_default "$default")"
            while true; do
                ask value "$prompt" "$default"
                "$validator" "$value" && break
                echo "  '$value' is not a valid value for $key."
            done
            printf -v "$key" '%s' "$value"; export "$key"
            checklist_save_key "$key" "$value"
        done
    done
}

# checklist_review: walk through every item, show the current value, allow changes.
checklist_review() {
    local item key prompt default validator value new
    heading "Preparation checklist ($SITE_ENV)"
    for item in "${CHECKLIST_ITEMS[@]}"; do
        IFS='|' read -r key prompt default validator <<< "$item"
        value="${!key:-}"
        default="$(_checklist_default "$default")"
        [[ -z "$value" ]] && value="$default"
        while true; do
            ask new "$prompt" "$value"
            "$validator" "$new" && break
            echo "  '$new' is not a valid value for $key."
        done
        printf -v "$key" '%s' "$new"; export "$key"
        checklist_save_key "$key" "$new"
    done
    log_ok "Checklist saved to $SITE_ENV (mode 600)."
}

checklist_show() {
    local item key prompt default validator value state
    echo
    printf '  %-20s %-40s %s\n' "KEY" "VALUE" "STATE"
    for item in "${CHECKLIST_ITEMS[@]}"; do
        IFS='|' read -r key prompt default validator <<< "$item"
        value="${!key:-}"
        if [[ -z "$value" ]]; then state="missing"
        elif "$validator" "$value"; then state="ok"
        else state="INVALID"; fi
        [[ "$key" == "ADMIN_SSH_PUBKEY" && ${#value} -gt 40 ]] && value="${value:0:37}..."
        printf '  %-20s %-40s %s\n' "$key" "$value" "$state"
    done
    echo
}

# pubkey_text KEY_OR_PATH -> the key line itself (reads the file when a path was given).
pubkey_text() {
    if [[ -r "$1" && "$1" == *.pub ]]; then cat "$1"; else echo "$1"; fi
}
