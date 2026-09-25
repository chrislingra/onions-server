#!/usr/bin/env bash
# install.sh -- onions-server: the menu-driven base installation of a fresh Linux host,
# from the empty machine up to the point where the Toolserver takes over.
#
#   git -C /opt/onions-server pull --ff-only 2>/dev/null \
#       || git clone https://github.com/chrislingra/onions-server.git /opt/onions-server
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
# The one source of the Toolserver, always its current state -- not a question (operator
# 2026-09-24: "es gibt keine anderen optionen"). With release level 1 this becomes the public
# https address of the published base (GAP-PUB-OEFFENTLICHES-REPOSITORY-01).
TOOLSERVER_SOURCE="git@github.com:chrislingra/onions-toolserver.git"

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
        # The one question without h and b: there is no step before it to go back to, and
        # listing two answers that do nothing here only confuses (operator 2026-09-24:
        # "an der stelle nicht durch die zurueck oder Hilfeoption verwirren"). What the value
        # has to look like is said in the question itself instead of behind h.
        echo
        echo "Domain this server serves"
        echo "  (lower case, with at least one dot, e.g. example.org)"
        while true; do
            read -r -p "${PROMPT_INDENT}Domain: " domain
            domain="${domain//[[:space:]]/}"
            [[ -z "$domain" ]] && { echo "  A value is required."; continue; }
            is_domain "$domain" && break
            echo "  '$domain' is not a valid domain: lower case letters, digits, dashes, at least one dot."
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
    # the verdict belongs HERE, above the menu, not only once at start: the banner clears
    # the screen, so a report printed before it is gone before anyone can read it
    # (operator 2026-09-23: "wenn hinter der systemerkennung und empfehlung keine pause
    # kommt, sieht das niemand"). One line, always visible; the detail is behind h.
    case "$(os_support_level)" in
        full)    echo "  Support: fully supported -- nothing has to be substituted." ;;
        partial) echo "  Support: supported, with a named substitution (entry h explains it)." ;;
        *)       echo "  Support: NOT YET MEASURED on $(os_key) -- watch every step." ;;
    esac
    if os_proven; then
        echo "  Proven by a complete run: ${OS_PROVEN[$(os_key)]}"
    else
        echo "  No complete run recorded yet on $(os_key) (README: Proving a run)"
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

# first_open_step -> the number of the first step without a done marker, nothing when all are done.
first_open_step() {
    local n
    for n in "${STEPS[@]}"; do step_is_done "$n" || { echo "$n"; return 0; }; done
    return 1
}

# run_all continues where the last run stopped, wherever that was (operator 2026-09-24: "ich
# moechte, dass setup an der Abbruchstelle fortsetzt (egal wo abgebrochen wird)"). A finished
# step is skipped, not repeated; the step that broke off starts again, and inside it every
# answer already given is read from site.env instead of asked again. Only passwords are asked
# anew -- they are never stored. Repeating a finished step on purpose is its own menu number.
run_all() {
    local n rc
    for n in "${STEPS[@]}"; do
        if step_is_done "$n"; then
            log_info "Step $((n / 10)) done $(step_done_at "$n") -- skipped."
            continue
        fi
        rc=0; run_step "$n" || rc=$?
        (( rc == 0 )) && continue
        if (( rc == PROMPT_RC_BACK )); then
            log_info "Stopped at step $((n / 10)) on request. The next start continues here."
        else
            log_err "Stopped at step $((n / 10)). Fix the cause; the next start continues here."
        fi
        return 1
    done
    # say "done" only when the markers agree -- a step that returned 0 without its marker is open
    if n="$(first_open_step)"; then
        log_warn "Step $((n / 10)) finished without being marked done -- it stays open."
        return 1
    fi
    log_ok "All steps done."
}

main_menu() {
    local reply n open
    while true; do
        banner
        echo "   0) Preparation checklist (review or change every answer)"
        for n in "${STEPS[@]}"; do status_line "$n"; done
        if open="$(first_open_step)"; then
            echo "   a) Continue: every open step, from step $((open / 10)) on"
        else
            echo "   a) All steps are done"
        fi
        echo "   v) Show checklist values"
        echo "   h) Help -- what the steps do and in which order"
        echo "   q) Quit"
        echo
        # Enter continues -- the one answer that is right after every break-off
        if [[ -n "$open" ]]; then read -r -p "${PROMPT_INDENT}Choice [a]: " reply; reply="${reply:-a}"
        else                      read -r -p "${PROMPT_INDENT}Choice: " reply; fi
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
    # What this machine is in for -- said here, before anything is installed, not in step 6.
    # The pause is the point: the menu's banner clears the screen, so without it the report
    # scrolls away unread (operator 2026-09-23: "wenn hinter der systemerkennung und
    # empfehlung keine pause kommt, sieht das niemand"). The banner carries a one-line
    # version of the same verdict afterwards, so it stays visible.
    os_support_report
    # Whether step 7 can work at all is known before step 1 -- say it now, not after six steps.
    step_is_done 70 || toolserver_precheck
    echo
    pause
    # A run that broke off goes on by itself at the break-off point, the menu comes afterwards.
    # "Broke off" = an earlier run left a log here and a step is still open -- also when that
    # was step 1. Only the very first start of a host begins at the menu.
    local open earlier
    earlier="$(find "$LOG_DIR" -maxdepth 1 -name 'install-*.log' ! -path "$LOG_FILE" 2>/dev/null | head -1)"
    if open="$(first_open_step)" && [[ -n "$earlier" ]]; then
        log_info "Continuing at step $((open / 10)), where the last run stopped."
        run_all || true
        pause
    fi
    main_menu
}

main "$@"
