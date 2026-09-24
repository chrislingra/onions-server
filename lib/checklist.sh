#!/usr/bin/env bash
# lib/checklist.sh -- the preparation checklist as data: site.env in the instance directory.
# Everything the installer needs to know is asked here, never assumed and never hardcoded.
# Passwords and keys are NOT part of it: they are asked at the moment of use (ask_secret)
# and exist only in memory. site.env is gitignored. Sourced, never executed.

# key | prompt | default (empty = required) | validator | options (optional)
#   options = "code=Label;code=Label;..."  -> the item is a numbered choice, the stored
#   value is the code. Without options the item is a typed value with a default.
# DOMAIN is not an item: the instance fixes it (install.sh, instance_open) before this loads.
CHECKLIST_ITEMS=(
    "LANGUAGE|Language of the system|de|is_nonempty|de=German;en=English (US);gb=English (UK);fr=French;it=Italian;es=Spanish;nl=Dutch;pl=Polish;pt=Portuguese"
    "COUNTRY|Country (sets time zone and keyboard)|DE|is_nonempty|DE=Germany;AT=Austria;CH=Switzerland;NL=Netherlands;BE=Belgium;FR=France;IT=Italy;ES=Spain;PL=Poland;PT=Portugal;GB=United Kingdom;US=United States"
    "ADMIN_USER|First personal admin (Linux user name; not the bootstrap user)||is_personal_user"
    "KEY_SOURCE|SSH access of that admin|later|is_nonempty|later=Password now -- SSH keys and hardening later in the Toolserver;paste=I have a public key (pasted, or a path to a .pub file);generate=Generate a key pair on this server (the private key is handed out once)"
    "ADMIN_SSH_PUBKEY|Public SSH key of that admin (one line, or a path to a .pub file; - = none)|-|is_pubkey_or_dash"
    "ACME_EMAIL|E-mail for Let's Encrypt (expiry notices)||is_email"
    "ACME_MODE|Let's Encrypt certificates|production|is_nonempty|production=Production (real certificates);staging=Staging (test certificates, no rate limits)"
    "TRAEFIK_IMAGE|Traefik image|traefik:v3|is_nonempty"
    "NOTIFICATION_EMAIL|E-mail that receives system notifications (rkhunter, cron)||is_email"
    "SENDER_EMAIL|Sender address the server mails from|service@\${DOMAIN}|is_email"
    "SMTP_SERVER|SMTP relay host|smtp.ionos.de|is_nonempty"
    "SMTP_PORT|SMTP relay port (submission)|587|is_number"
    "SMTP_USER|SMTP relay user name (the password is asked when the relay is set up)||is_nonempty"
    "TOOLSERVER_GIT|Git URL of the Toolserver (public address: no credentials; private: this host's key as deploy key, ssh address)|git@github.com:chrislingra/onions-toolserver.git|is_nonempty"
    "TOOLSERVER_REF|Toolserver branch or tag to install|master|is_nonempty"
)

# What a language and a country mean for the system: locale | time zone + keymap.
declare -A LANGUAGE_LOCALE=(
    [de]="de_DE.UTF-8" [en]="en_US.UTF-8" [gb]="en_GB.UTF-8" [fr]="fr_FR.UTF-8" [it]="it_IT.UTF-8"
    [es]="es_ES.UTF-8" [nl]="nl_NL.UTF-8" [pl]="pl_PL.UTF-8" [pt]="pt_PT.UTF-8"
)
declare -A COUNTRY_TIMEZONE=(
    [DE]="Europe/Berlin" [AT]="Europe/Vienna" [CH]="Europe/Zurich" [NL]="Europe/Amsterdam" [BE]="Europe/Brussels"
    [FR]="Europe/Paris" [IT]="Europe/Rome" [ES]="Europe/Madrid" [PL]="Europe/Warsaw" [PT]="Europe/Lisbon"
    [GB]="Europe/London" [US]="America/New_York"
)
declare -A COUNTRY_KEYMAP=(
    [DE]="de" [AT]="de" [CH]="ch" [NL]="us" [BE]="be" [FR]="fr" [IT]="it" [ES]="es" [PL]="pl" [PT]="pt" [GB]="gb" [US]="us"
)

is_nonempty()  { [[ -n "$1" ]]; }
is_number()    { [[ "$1" =~ ^[0-9]+$ ]]; }
is_domain()    { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }
is_username()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_personal_user() { is_username "$1" && [[ "$1" != "${BOOTSTRAP_USER:-manager}" && "$1" != "root" ]]; }
is_email()     { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
is_pubkey()    { [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/=]+ ]] || [[ -r "$1" && "$1" == *.pub ]]; }
is_pubkey_or_dash() { [[ "$1" == "-" ]] || is_pubkey "$1"; }

# option_valid "options" code -> the code is one of the options
option_valid() { [[ ";$1;" == *";$2="* ]]; }
# option_label "options" code -> its label
option_label() {
    local opt; IFS=';' read -ra _opts <<< "$1"
    for opt in "${_opts[@]}"; do [[ "${opt%%=*}" == "$2" ]] && { echo "${opt#*=}"; return; }; done
    echo "$2"
}

# _item_valid KEY VALUE -> validator, and membership for choice items
_item_valid() {
    local key="$1" value="$2" item k p d v o
    [[ -n "$value" ]] || return 1
    for item in "${CHECKLIST_ITEMS[@]}"; do
        IFS='|' read -r k p d v o <<< "$item"
        [[ "$k" == "$key" ]] || continue
        "$v" "$value" || return 1
        [[ -z "$o" ]] || option_valid "$o" "$value"
        return
    done
    return 1
}

# pick_option VAR "Prompt" DEFAULT "options" -> numbered choice, Enter takes the default
pick_option() {
    local -n _target="$1"
    local prompt="$2" default="$3" options="$4" helpkey="${5:-}" i reply dflt=0
    # Fail closed on a wrong call instead of drawing a nonsense menu. On 2026-09-23 the help
    # key was passed in the options slot in two places; the menu then offered the single
    # entry "step60.part", the default was not among the entries, and the operator saw a bare
    # "Choice:" with no default. A menu built from garbage must not be shown -- it looks like
    # a decision and is a bug.
    if [[ "$options" != *=* ]]; then
        log_err "pick_option called wrongly: the options argument is '$options' and carries no 'code=Label'."
        log_err "  Order: pick_option VAR \"Prompt\" DEFAULT \"code=Label;code=Label\" [helpkey]"
        return 1
    fi
    IFS=';' read -ra _opts <<< "$options"
    _prompt_headline "$prompt"
    for i in "${!_opts[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${_opts[$i]#*=}"
        [[ "${_opts[$i]%%=*}" == "$default" ]] && dflt=$((i + 1))
    done
    _prompt_extras
    while true; do
        if (( dflt > 0 )); then read -r -p "${PROMPT_INDENT}Choice [$dflt]: " reply; reply="${reply:-$dflt}"
        else read -r -p "${PROMPT_INDENT}Choice: " reply; fi
        case "$reply" in
            h|H|\?) help_show "$helpkey" "$prompt"; continue ;;
            b|B)    _prompt_back "$prompt"; return "$PROMPT_RC_BACK" ;;
        esac
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#_opts[@]} )); then
            _target="${_opts[$((reply - 1))]%%=*}"
            return 0
        fi
        echo "  Enter a number between 1 and ${#_opts[@]}, h or b."
    done
}

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

# _checklist_ask KEY PROMPT DEFAULT VALIDATOR OPTIONS CURRENT -> asks, validates, saves.
# Returns PROMPT_RC_BACK when the answer was "one step back" -- nothing is saved then, and the
# caller decides what "back" means in its context (the review walks to the previous item).
# The item's KEY is its help key, so every checklist question explains itself for free.
_checklist_ask() {
    local key="$1" prompt="$2" default="$3" validator="$4" options="$5" current="$6" value rc
    default="$(_checklist_default "$default")"
    [[ -n "$current" ]] && default="$current"
    while true; do
        rc=0
        if [[ -n "$options" ]]; then pick_option value "$prompt" "$default" "$options" "$key" || rc=$?
        else ask value "$prompt" "$default" "$key" || rc=$?; fi
        (( rc == PROMPT_RC_BACK )) && return "$PROMPT_RC_BACK"
        _item_valid "$key" "$value" && break
        echo "  '$value' is not a valid value for $key."
    done
    printf -v "$key" '%s' "$value"; export "$key"
    checklist_save_key "$key" "$value"
}

# checklist_derive: LANGUAGE -> LOCALE, COUNTRY -> TIMEZONE + KEYMAP (saved, so steps and
# the values view see them; changing language or country changes them again)
checklist_derive() {
    if [[ -n "${LANGUAGE:-}" && -n "${LANGUAGE_LOCALE[$LANGUAGE]:-}" ]]; then
        LOCALE="${LANGUAGE_LOCALE[$LANGUAGE]}"; export LOCALE; checklist_save_key LOCALE "$LOCALE"
    fi
    if [[ -n "${COUNTRY:-}" && -n "${COUNTRY_TIMEZONE[$COUNTRY]:-}" ]]; then
        TIMEZONE="${COUNTRY_TIMEZONE[$COUNTRY]}"; KEYMAP="${COUNTRY_KEYMAP[$COUNTRY]}"; export TIMEZONE KEYMAP
        checklist_save_key TIMEZONE "$TIMEZONE"; checklist_save_key KEYMAP "$KEYMAP"
    fi
}

# checklist_require KEY... -> every named key must have a valid value; asks for the rest.
checklist_require() {
    local want item key prompt default validator options value
    for want in "$@"; do
        for item in "${CHECKLIST_ITEMS[@]}"; do
            IFS='|' read -r key prompt default validator options <<< "$item"
            [[ "$key" == "$want" ]] || continue
            value="${!key:-}"
            _item_valid "$key" "$value" && continue
            [[ -n "$value" ]] && log_warn "$key='$value' is not valid, asking again."
            _checklist_ask "$key" "$prompt" "$default" "$validator" "$options" ""
        done
    done
    checklist_derive
}

# checklist_review: walk through every item, show the current value, allow changes.
# "One step back" here means the PREVIOUS question, not "out of the checklist": this is the
# long chain of questions where a typo used to cost the whole walk. At the first item there is
# nothing before it, so back leaves the checklist; everything answered until then is saved --
# each answer is written the moment it is given, not at the end.
checklist_review() {
    local item key prompt default validator options i=0 rc
    heading "Preparation checklist ($SITE_ENV)"
    while (( i < ${#CHECKLIST_ITEMS[@]} )); do
        IFS='|' read -r key prompt default validator options <<< "${CHECKLIST_ITEMS[$i]}"
        rc=0
        _checklist_ask "$key" "$prompt" "$default" "$validator" "$options" "${!key:-}" || rc=$?
        if (( rc == PROMPT_RC_BACK )); then
            if (( i == 0 )); then
                log_info "Checklist left at the first question. Everything answered before is saved."
                return 0
            fi
            i=$((i - 1))
            continue
        fi
        (( rc == 0 )) || return "$rc"
        i=$((i + 1))
    done
    checklist_derive
    log_ok "Checklist saved to $SITE_ENV (mode 600)."
}

checklist_show() {
    local item key prompt default validator options value state shown
    echo
    printf '  %-20s %-44s %s\n' "KEY" "VALUE" "STATE"
    printf '  %-20s %-44s %s\n' "DOMAIN" "${DOMAIN:-}" "instance"
    for item in "${CHECKLIST_ITEMS[@]}"; do
        IFS='|' read -r key prompt default validator options <<< "$item"
        value="${!key:-}"
        if [[ -z "$value" ]]; then state="missing"
        elif _item_valid "$key" "$value"; then state="ok"
        else state="INVALID"; fi
        shown="$value"
        [[ -n "$options" && -n "$value" ]] && shown="$(option_label "$options" "$value")"
        [[ "$key" == "ADMIN_SSH_PUBKEY" && ${#shown} -gt 44 ]] && shown="${shown:0:41}..."
        printf '  %-20s %-44s %s\n' "$key" "$shown" "$state"
    done
    for key in LOCALE TIMEZONE KEYMAP; do
        printf '  %-20s %-44s %s\n' "$key" "${!key:-}" "derived"
    done
    echo
}

# pubkey_text KEY_OR_PATH -> the key line itself (reads the file when a path was given).
pubkey_text() {
    if [[ -r "$1" && "$1" == *.pub ]]; then cat "$1"; else echo "$1"; fi
}
