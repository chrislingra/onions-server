#!/usr/bin/env bash
# install.sh -- onions-server: the menu-driven base installation of a fresh Linux host,
# from the empty machine up to the point where the Toolserver takes over.
#
#   git clone git@github.com:chrislingra/onions-server.git /opt/onions-server
#   cd /opt/onions-server && sudo bash install.sh
#
# Two places, kept apart on purpose:
#   /opt/onions-server   this checkout -- generic code, the same on every host
#   /opt/<domain>        the instance -- created by the installer on first start; holds the
#                        answers (site.env, mode 600), step markers, backups and logs.
#                        The domain is asked once and remembered in .instance (gitignored).
# Passwords are asked when needed and never written by this installer except into the one
# config file that needs them (msmtprc) or straight into chpasswd.
# Steps are idempotent: running one twice repairs rather than breaks.
set -euo pipefail

INSTALL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_FILE="$INSTALL_ROOT/.instance"

# Fixed names of the platform -- the same on every host, so every script can rely on them.
BOOTSTRAP_USER="manager"   # exists from step 1 on, works in the delivered state, removed by step 8
PLATFORM_GROUP="onions"    # owns the platform directories; every admin is a member

# shellcheck source=lib/help.sh
. "$INSTALL_ROOT/lib/help.sh"
# shellcheck source=lib/common.sh
. "$INSTALL_ROOT/lib/common.sh"
# shellcheck source=lib/os.sh
. "$INSTALL_ROOT/lib/os.sh"
# shellcheck source=lib/checklist.sh
. "$INSTALL_ROOT/lib/checklist.sh"
for f in "$INSTALL_ROOT"/steps/*.sh; do
    # shellcheck disable=SC1090
    . "$f"
done

STEPS=(10 20 30 40 50 60 70 80)

# instance_open: the domain decides where everything of this host lives (/opt/<domain>).
instance_open() {
    local domain=""
    [[ -f "$INSTANCE_FILE" ]] && domain="$(tr -d '[:space:]' < "$INSTANCE_FILE")"
    if [[ -z "$domain" ]] || ! is_domain "$domain"; then
        echo
        echo "This host has no instance yet. The domain names it: everything of this host"
        echo "goes to /opt/<domain> (answers, state, logs); the code stays in $INSTALL_ROOT."
        while true; do
            # no "back" behind this one: without a domain there is no instance and nothing to
            # go back to -- the installer would have nowhere to put its answers.
            ask domain "Domain this server serves (e.g. example.org)" "" domain \
                || { echo "  The domain is the one question that has no step before it."; continue; }
            is_domain "$domain" && break
            echo "  '$domain' is not a valid domain."
        done
        printf '%s\n' "$domain" > "$INSTANCE_FILE"
    fi
    DOMAIN="$domain"; export DOMAIN
    INSTANCE_DIR="/opt/$DOMAIN"
    SITE_ENV="$INSTANCE_DIR/site.env"
    STATE_DIR="$INSTANCE_DIR/state"
    LOG_DIR="$INSTANCE_DIR/logs"
    # a step runs as its own bash process (see run_step); it inherits stamp and log from the menu
    RUN_STAMP="${RUN_STAMP:-$(date +%Y%m%d-%H%M%S)}"
    LOG_FILE="${LOG_FILE:-$LOG_DIR/install-$RUN_STAMP.log}"
    mkdir -p "$INSTANCE_DIR" "$STATE_DIR" "$LOG_DIR"
    chmod 750 "$INSTANCE_DIR"
}

banner() {
    clear
    echo "================================================================"
    echo "  onions-server -- base installation"
    echo "  Host: $(hostname)   Domain: $DOMAIN   Instance: $INSTANCE_DIR"
    echo "  System: $OS_PRETTY ($OS_FAMILY family)"
    if os_measured; then
        echo "  Proven on this distribution: ${OS_MEASURED[$(os_key)]}"
    else
        echo "  NOT YET PROVEN on $(os_key) -- watch every step (README: Proving a run)"
    fi
    echo "  Log: $LOG_FILE"
    echo "================================================================"
    echo
}

status_line() {
    local n="$1" title_var="STEP_${1}_TITLE" mark
    if step_is_done "$n"; then mark="done $(step_done_at "$n")"; else mark="open"; fi
    printf '  %2d) %-58s %s\n' "$((n / 10))" "${!title_var}" "$mark"
}

# Why a child process: bash ignores "set -e" inside anything called from an || or && list,
# and the menu must survive a failed step. In its own process the step really stops at the
# first failing command instead of carrying on with half-done work.
run_step() {
    local n="$1"
    ONIONS_STEP="$n" RUN_STAMP="$RUN_STAMP" LOG_FILE="$LOG_FILE" bash "$INSTALL_ROOT/install.sh"
    local rc=$?
    checklist_load   # the step may have saved new answers
    # PROMPT_RC_BACK is not a failure: somebody answered "b" at a question and the step left
    # on purpose. Saying "failed" there would teach people to distrust the word.
    (( rc == PROMPT_RC_BACK )) && { log_info "Step $((n / 10)) left on request -- it stays open."; return "$PROMPT_RC_BACK"; }
    (( rc == 0 )) || { log_err "Step $((n / 10)) failed -- see $LOG_FILE"; return 1; }
}

run_all() {
    local n rc
    for n in "${STEPS[@]}"; do
        rc=0; run_step "$n" || rc=$?
        (( rc == 0 )) && continue
        if (( rc == PROMPT_RC_BACK )); then
            log_info "Stopped at step $((n / 10)) on request. 'All steps' takes it up again -- finished steps repeat harmlessly."
        else
            log_err "Stopped at step $((n / 10)). Fix the cause and run 'All steps' again -- finished steps repeat harmlessly."
        fi
        return 1
    done
    log_ok "All steps done."
}

main_menu() {
    local reply n
    while true; do
        banner
        echo "   0) Preparation checklist (review or change every answer)"
        for n in "${STEPS[@]}"; do status_line "$n"; done
        echo "   a) All steps in order (1-8)"
        echo "   v) Show checklist values"
        echo "   h) Help -- what the steps do and in which order"
        echo "   q) Quit"
        echo
        read -r -p "Choice: " reply
        case "$reply" in
            0) checklist_review; pause ;;
            [1-8]) run_step "$((reply * 10))" || true; pause ;;
            a|A) run_all || true; pause ;;
            v|V) checklist_show; pause ;;
            h|H|\?) help_show menu "Main menu"; pause ;;
            q|Q) exit 0 ;;
            *) echo "  Enter 0-8, a, v, h or q." ; sleep 1 ;;
        esac
    done
}

main() {
    require_root
    os_detect
    instance_open
    checklist_load
    DOMAIN="$(tr -d '[:space:]' < "$INSTANCE_FILE")"   # .instance decides, not a hand-edited site.env
    checklist_save_key DOMAIN "$DOMAIN"
    if [[ -n "${ONIONS_STEP:-}" ]]; then
        # child process for one step: set -e is honoured here, failure = exit code
        "step_${ONIONS_STEP}_run"
        exit $?
    fi
    log_info "onions-server started on $OS_PRETTY ($OS_FAMILY family), code $INSTALL_ROOT, instance $INSTANCE_DIR"
    # what this machine is in for -- said here, before anything is installed, not in step 6
    os_support_report
    main_menu
}

main "$@"
