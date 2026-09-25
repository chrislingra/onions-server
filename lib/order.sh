#!/usr/bin/env bash
# lib/order.sh -- the installation order: "bash install.sh <code>" fetches every answer from
# the Toolserver that served the start script, and the run goes through without a question
# (operator 2026-09-24: "wenn ich alle noetigen parameter ... hier bereits vorgeben kann (in
# der gui) und die Installation dann durchlaeuft"; GAP-ENV-NEUER-SERVER-VORGABEN-01). The
# order is made in the Toolserver under Environment > Installation > New server; saving it
# shows the code once. Sourced, never executed.
#
# Where things live:
#   $INSTANCE_DIR/order.env   the answers exactly as the Toolserver sent them (KEY=value,
#                             mode 600). The checklist keys go on into site.env, so every step
#                             finds them where it always looks; the rest -- further admins,
#                             the hardening parts, the answer of a single question under its
#                             help key (step10.snapd, step80.remove, ...) -- is read from here.
#   $STATE_DIR/order.code     the code and the address it belongs to (mode 600). Removed once
#                             the Toolserver was told "done" -- the code is dead from then on.
#   $STATE_DIR/order.done     the order is finished; this host is interactive again, and a
#                             later "bash install.sh" shows the menu and asks as before.
#   $STATE_DIR/generated-passwords.txt
#                             every password the run made up (root only, mode 600), shown at
#                             the very end ("das kennwort muss angezeigt werden wenn es
#                             gebraucht wird. zum schluss", operator 2026-09-25).
# No password travels in order.env. The one password an order carries -- the mail relay's --
# is fetched in step 6 exactly once and goes straight into /etc/msmtprc.
#
# Nothing of the answer is executed: every line is checked against KEY=value and read into
# an array, never sourced.

declare -A ORDER=()
ORDER_ALPHABET='abcdefghjkmnpqrstuvwx23456789'
ORDER_CODE_LEN=24

# order_code_norm CODE -> the code without dashes and spaces, lower case
order_code_norm() { local c="${1,,}"; c="${c//-/}"; printf '%s' "${c//[[:space:]]/}"; }

# is_order_code CODE -> 24 characters of the code alphabet, dashes allowed anywhere
is_order_code() {
    local c; c="$(order_code_norm "$1")"
    [[ ${#c} -eq $ORDER_CODE_LEN && "$c" =~ ^[$ORDER_ALPHABET]+$ ]]
}

# is_order_origin URL -> https://host[:port], nothing behind it
is_order_origin() { [[ "$1" =~ ^https://[a-z0-9.-]+(:[0-9]+)?$ ]]; }

# order_parse FILE -> 0 when FILE is an order: DOMAIN=<domain> first, then KEY=value lines.
# Prints the reason on stderr otherwise. Checked before anything of it is used.
order_parse() {
    local file="$1" line n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ -z "$line" ]] && continue
        if [[ ! "$line" =~ ^[A-Za-z0-9_.]+= ]]; then
            echo "  line $n is not KEY=value." >&2; return 1
        fi
        if [[ "$line" == *[[:cntrl:]]* ]]; then
            echo "  line $n carries a control character." >&2; return 1
        fi
        if (( n == 1 )); then
            [[ "$line" == DOMAIN=* ]] || { echo "  the first line is not DOMAIN=." >&2; return 1; }
            is_domain "${line#DOMAIN=}" || { echo "  '${line#DOMAIN=}' is not a domain." >&2; return 1; }
        fi
    done < "$file"
    (( n > 0 )) || { echo "  the answer is empty." >&2; return 1; }
}

# order_start ARGS... -- in install.sh before instance_open. Without arguments nothing
# happens. With a code: fetch the order from ONIONS_ORIGIN (set by the start script the
# Toolserver serves), check it, and fix the domain of this host. Logging does not exist yet
# at this point (the instance names the log file), so this talks to the terminal only.
order_start() {
    (( $# == 0 )) && return 0
    (( $# == 1 )) || { echo "Usage: bash install.sh [installation code]" >&2; exit 2; }
    local code="$1" origin="${ONIONS_ORIGIN:-}" out http domain known=""
    if ! is_order_code "$code"; then
        echo "'$code' is not an installation code (24 letters and digits, shown in groups of four)." >&2
        echo "Usage: bash install.sh [installation code]" >&2
        exit 2
    fi
    code="$(order_code_norm "$code")"
    if ! is_order_origin "$origin"; then
        echo "An installation code belongs to the Toolserver that showed it, and this run does not know which." >&2
        echo "Start with the two lines from Environment > Installation > New server:" >&2
        echo "  curl -fsSL https://tools.<domain>/install -o install.sh" >&2
        echo "  bash install.sh <code>" >&2
        echo "(or name it yourself: ONIONS_ORIGIN=https://tools.<domain> bash install.sh <code>)" >&2
        exit 2
    fi
    echo "Fetching the installation order from $origin ..."
    out="$(mktemp)"; chmod 600 "$out"
    if ! http="$(curl -sS --max-time 30 -o "$out" -w '%{http_code}' "$origin/api/install-order/$code")"; then
        rm -f "$out"
        echo "The Toolserver at $origin cannot be reached (network, DNS or https). Nothing was changed." >&2
        exit 1
    fi
    if [[ "$http" != "200" ]]; then
        echo "The Toolserver refused the order (HTTP $http): $(head -c 200 "$out" | head -1)" >&2
        echo "A code is shown once, is valid for seven days and ends when an installation reports done." >&2
        echo "\"New code\" in the mask issues another one." >&2
        rm -f "$out"; exit 1
    fi
    if ! order_parse "$out"; then
        echo "What $origin sent is not an installation order -- nothing was used." >&2
        rm -f "$out"; exit 1
    fi
    domain="$(head -1 "$out")"; domain="${domain#DOMAIN=}"
    [[ -f "$INSTANCE_FILE" ]] && known="$(tr -d '[:space:]' < "$INSTANCE_FILE")"
    if [[ -n "$known" && "$known" != "$domain" ]]; then
        echo "This host is already the instance $known; the order is for $domain. Nothing was changed." >&2
        echo "One host serves one domain -- use the order on the server it was made for." >&2
        rm -f "$out"; exit 1
    fi
    printf '%s\n' "$domain" > "$INSTANCE_FILE"
    _ORDER_PENDING="$out"; _ORDER_PENDING_CODE="$code"; _ORDER_PENDING_ORIGIN="$origin"
    echo "Order for $domain received."
}

# order_active -> this run works from an order that is not finished yet
order_active() { [[ -f "${INSTANCE_DIR:-/nonexistent}/order.env" && ! -f "${STATE_DIR:-/nonexistent}/order.done" ]]; }

# order_answer KEY -> prints the order's answer for KEY; 1 when there is none or it is empty
order_answer() {
    [[ -n "${1:-}" ]] || return 1
    order_active || return 1
    [[ -n "${ORDER[$1]:-}" ]] || return 1
    printf '%s' "${ORDER[$1]}"
}

# The keys that are items of the preparation checklist -- these go on into site.env.
_order_checklist_keys() {
    local item; for item in "${CHECKLIST_ITEMS[@]}"; do printf '%s\n' "${item%%|*}"; done
}

# order_load -- in install.sh after instance_open, before checklist_load; in the menu process
# and in every step process. Takes over a freshly fetched order (files, checklist answers),
# then reads order.env into ORDER.
order_load() {
    local line key value
    if [[ -n "${_ORDER_PENDING:-}" ]]; then
        install -m 600 "$_ORDER_PENDING" "$INSTANCE_DIR/order.env"; rm -f "$_ORDER_PENDING"
        ( umask 077; printf 'CODE=%s\nORIGIN=%s\n' "$_ORDER_PENDING_CODE" "$_ORDER_PENDING_ORIGIN" > "$STATE_DIR/order.code" )
        rm -f "$STATE_DIR/order.done"
        _ORDER_PENDING=""
        _order_fill_checklist=1
    fi
    ORDER=()
    order_active || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[A-Za-z0-9_.]+= ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        ORDER["$key"]="$value"
    done < "$INSTANCE_DIR/order.env"
    if [[ -n "${_order_fill_checklist:-}" ]]; then
        _order_fill_checklist=""
        for key in $(_order_checklist_keys); do
            value="${ORDER[$key]:-}"
            [[ "$key" == "ADMIN_SSH_PUBKEY" && -z "$value" ]] && value="-"
            [[ -n "$value" ]] && checklist_save_key "$key" "$value"
        done
        log_info "Installation order taken over: $(wc -l < "$INSTANCE_DIR/order.env") answers, from ${_ORDER_PENDING_ORIGIN}."
    fi
}

# _order_meta KEY -> CODE or ORIGIN from order.code
_order_meta() { sed -n "s/^$1=//p" "$STATE_DIR/order.code" 2>/dev/null | head -1; }

# order_smtp_password -> prints the relay password of the order, fetched from the Toolserver.
# Exactly once: the Toolserver deletes it on the way out. 1 when there is none to fetch.
order_smtp_password() {
    local code origin pw
    [[ "${ORDER[SMTP_PASSWORD_SET]:-n}" == "y" ]] || return 1
    code="$(_order_meta CODE)"; origin="$(_order_meta ORIGIN)"
    [[ -n "$code" && -n "$origin" ]] || return 1
    pw="$(curl -fsS --max-time 30 "$origin/api/install-order/$code/smtp-password" 2>/dev/null)" || return 1
    [[ -n "$pw" ]] || return 1
    printf '%s' "$pw"
}

# order_new_password -> 16 random letters and digits (the same recipe as the bootstrap user's)
order_new_password() { openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16; }

# order_password_note WHAT USER PASSWORD -- keeps a generated password for the end of the run
order_password_note() {
    local file="$STATE_DIR/generated-passwords.txt"
    ( umask 077; printf '%-40s user %-14s password %s\n' "$1" "$2" "$3" >> "$file" )
    chmod 600 "$file"; chown root:root "$file" 2>/dev/null || true
    _log_line "INFO" "password generated for $1 (user $2) -- shown at the end, never in this log"
}

# order_passwords_show -- at the very end: every password this run made up
order_passwords_show() {
    local file="$STATE_DIR/generated-passwords.txt"
    [[ -s "$file" ]] || return 0
    echo "  Passwords this run generated (each expires at the first login where it says so):"
    sed 's/^/    /' "$file"
    echo "  Also in $file (root only). Delete it once they are safe: rm $file"
    echo
}

# order_finish -- tell the Toolserver the order is done: once the handover (step 7) is done
# and step 8 either ran or the order said to keep the bootstrap user. From then on the code is
# dead, and this host is interactive again.
order_finish() {
    order_active || return 0
    step_is_done 70 || return 0
    if ! step_is_done 80 && [[ "${ORDER[step80.remove]:-y}" != "n" ]]; then return 0; fi
    local code origin
    code="$(_order_meta CODE)"; origin="$(_order_meta ORIGIN)"
    if [[ -n "$code" && -n "$origin" ]] && curl -fsS --max-time 30 -X POST "$origin/api/install-order/$code/done" >/dev/null 2>&1; then
        log_ok "Order reported done to $origin -- its code is no longer valid."
    else
        log_warn "Could not report the order done to ${origin:-the Toolserver} -- it expires by itself after seven days."
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/order.done"
    rm -f "$STATE_DIR/order.code"
}
