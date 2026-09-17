#!/usr/bin/env bash
# lib/common.sh -- logging, prompts, file helpers shared by install.sh and every step.
# Sourced, never executed. Needs: LOG_FILE, STATE_DIR (set by install.sh).

C_INFO='\033[1;36m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_OFF='\033[0m'

# --- logging: coloured on the terminal, plain (no ANSI) in the log file ----------------
_log_line() {
    local level="$1"; shift
    local text="$*"
    printf '%s %-6s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$text" >> "$LOG_FILE"
}
log_info()  { echo -e "${C_INFO}[INFO]${C_OFF}  $*"; _log_line "INFO" "$*"; }
log_ok()    { echo -e "${C_OK}[OK]${C_OFF}    $*";   _log_line "OK" "$*"; }
log_warn()  { echo -e "${C_WARN}[WARN]${C_OFF}  $*"; _log_line "WARN" "$*"; }
log_err()   { echo -e "${C_ERR}[ERROR]${C_OFF} $*" >&2; _log_line "ERROR" "$*"; }
die()       { log_err "$*"; exit 1; }
heading()   { echo; echo -e "${C_INFO}=== $* ===${C_OFF}"; _log_line "STEP" "=== $* ==="; }

# --- run: log the command, then execute it (stdout/stderr also go to the log) ----------
run() {
    _log_line "RUN" "$*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc="${PIPESTATUS[0]}"
    (( rc == 0 )) || log_err "failed (exit $rc): $*"
    return "$rc"
}

# primary_group USER -> the login group (Debian/RHEL: a group named like the user; SUSE: users)
primary_group() { id -gn "$1"; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run this as root: sudo bash $0"
}

# --- prompts: every decision is the same simple numbered choice ---------------------------
# confirm "Question?" [y|n]  -> returns 0 for yes. Enter takes the default.
confirm() {
    local question="$1" default="${2:-n}" reply dflt=2
    [[ "$default" == "y" ]] && dflt=1
    echo "$question"
    echo "  1) Yes"
    echo "  2) No"
    while true; do
        read -r -p "Choice [$dflt]: " reply
        reply="${reply:-$dflt}"
        case "$reply" in
            1|y|Y|j|J) return 0 ;;
            2|n|N)     return 1 ;;
        esac
        echo "  Enter 1 or 2."
    done
}

# ask VAR "Prompt" [default] -> reads into VAR, keeps default on empty input.
ask() {
    local -n _target="$1"
    local prompt="$2" default="${3:-}" reply
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply
        _target="${reply:-$default}"
    else
        while true; do
            read -r -p "$prompt: " reply
            [[ -n "$reply" ]] && break
            echo "  A value is required."
        done
        _target="$reply"
    fi
}

# ask_secret VAR "Prompt" -> hidden input, asked twice, never logged, never written to disk.
ask_secret() {
    local -n _target="$1"
    local prompt="$2" first second
    while true; do
        read -r -s -p "$prompt: " first; echo
        [[ -n "$first" ]] || { echo "  A value is required."; continue; }
        read -r -s -p "Repeat: " second; echo
        [[ "$first" == "$second" ]] && break
        echo "  The two entries differ, try again."
    done
    _target="$first"
}

# choose "Prompt" item1 item2 ... -> prints the chosen 1-based index, 0 for cancel.
# Never crashes on non-numeric input.
choose() {
    local prompt="$1"; shift
    local items=("$@") i reply
    # the list goes to the terminal (stderr), only the answer to stdout -- callers capture it
    for i in "${!items[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${items[$i]}" >&2
    done
    printf '   0) Cancel\n' >&2
    while true; do
        read -r -p "$prompt [0-${#items[@]}]: " reply
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 0 && reply <= ${#items[@]} )); then
            echo "$reply"
            return 0
        fi
        echo "  Enter a number between 0 and ${#items[@]}." >&2
    done
}

pause() { read -r -p "Press [Enter] to continue... " _; }

# --- files ---------------------------------------------------------------------------------
# backup_file /etc/x -> copies it to $STATE_DIR/backups/<stamp>/etc/x before we touch it.
backup_file() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    local dest="$STATE_DIR/backups/$RUN_STAMP$src"
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
    log_info "Backup: $src -> $dest"
}

# set_config_line FILE KEY VALUE -> "KEY VALUE" style files (sshd_config). Replaces an
# existing active or commented line, appends when absent. Whole-line, anchored.
set_config_line() {
    local file="$1" key="$2" value="$3"
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}([[:space:]]|$)" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}([[:space:]].*)?$|${key} ${value}|" "$file"
    else
        printf '%s %s\n' "$key" "$value" >> "$file"
    fi
}

# set_env_line FILE KEY VALUE -> "KEY=VALUE" style files.
set_env_line() {
    local file="$1" key="$2" value="$3"
    touch "$file"
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*$|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# --- step bookkeeping ---------------------------------------------------------------------
step_done()    { date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/$1.done"; }
step_is_done() { [[ -f "$STATE_DIR/$1.done" ]]; }
step_done_at() { cat "$STATE_DIR/$1.done" 2>/dev/null || echo "-"; }
