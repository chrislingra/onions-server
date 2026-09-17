#!/usr/bin/env bash
# install.sh -- onions-server: the menu-driven base installation of a fresh Linux host,
# from the empty machine up to the point where the Toolserver takes over.
#
#   git clone git@github.com:chrislingra/onions-server.git /opt/<domain>
#   cd /opt/<domain> && sudo bash install.sh
#
# The directory name is the domain (convention /opt/<domain>). Answers live in site.env
# next to this file (gitignored); passwords are asked when needed and never written by
# this installer except into the config file that needs them (msmtprc, chpasswd).
# Steps are idempotent: running one twice repairs rather than breaks.
set -euo pipefail

INSTALL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_ENV="$INSTALL_ROOT/site.env"
STATE_DIR="$INSTALL_ROOT/state"
LOG_DIR="$INSTALL_ROOT/logs"
# a step runs as its own bash process (see run_step); it inherits stamp and log from the menu
RUN_STAMP="${RUN_STAMP:-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/install-$RUN_STAMP.log}"
DOMAIN_GUESS="$(basename "$INSTALL_ROOT")"
[[ "$DOMAIN_GUESS" == *.* ]] || DOMAIN_GUESS=""

mkdir -p "$STATE_DIR" "$LOG_DIR"
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

STEPS=(10 20 30 40 50 60 70)

banner() {
    clear
    echo "================================================================"
    echo "  onions-server -- base installation"
    echo "  Host: $(hostname)   Domain: ${DOMAIN:-<not set>}"
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
    (( rc == 0 )) || { log_err "Step $((n / 10)) failed -- see $LOG_FILE"; return 1; }
}

run_all() {
    local n
    for n in "${STEPS[@]}"; do
        run_step "$n" || { log_err "Stopped at step $((n / 10)). Fix the cause and run 'All steps' again -- finished steps repeat harmlessly."; return 1; }
    done
    log_ok "All steps done."
}

main_menu() {
    local reply n
    while true; do
        banner
        echo "   0) Preparation checklist (review or change every answer)"
        for n in "${STEPS[@]}"; do status_line "$n"; done
        echo "   8) All steps in order (1-7)"
        echo "   9) Show checklist values"
        echo "   q) Quit"
        echo
        read -r -p "Choice: " reply
        case "$reply" in
            0) checklist_review; pause ;;
            [1-7]) run_step "$((reply * 10))" || true; pause ;;
            8) run_all || true; pause ;;
            9) checklist_show; pause ;;
            q|Q) exit 0 ;;
            *) echo "  Enter 0-9 or q." ; sleep 1 ;;
        esac
    done
}

main() {
    require_root
    os_detect
    checklist_load
    if [[ -n "${ONIONS_STEP:-}" ]]; then
        # child process for one step: set -e is honoured here, failure = exit code
        "step_${ONIONS_STEP}_run"
        exit $?
    fi
    log_info "onions-server started on $OS_PRETTY, root $INSTALL_ROOT"
    if ! os_measured; then
        banner
        log_warn "This installer has never run through on $(os_key)."
        log_warn "The commands for the $OS_FAMILY family exist, but nobody has watched them succeed."
        confirm_word "Continue anyway?" YES || exit 0
    fi
    main_menu
}

main "$@"
