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
# Every question offers the same two extra answers besides its own (operator 2026-09-23:
# "jede Auswahl muss 2 weitere Optionen erhalten: hilfe und einen schritt zurueck"):
#
#   h  help       the explanation of this question, from lib/help.sh
#   b  back       leave this question without answering it
#
# What "back" does depends on where the question is asked, and that is not a special case but
# the structure of this installer: a step runs in its own process (see run_step in
# install.sh), so leaving a question inside a step means leaving the step -- the main menu
# comes back and nothing of the step was marked done. In the menu process itself (the
# checklist) the helper returns PROMPT_RC_BACK and the asking loop goes to the previous
# question. Nothing is ever saved on the way out: back means back, not "cancel and keep".
#
# The last argument of every helper is the optional help key (see lib/help.sh). A question
# without one still offers h and gets the general text.
PROMPT_RC_BACK=10

_prompt_back() {
    _log_line "INFO" "one step back at: ${1:-<question>}"
    if [[ -n "${ONIONS_STEP:-}" ]]; then
        echo "  Back to the main menu. Nothing of this step was saved."
        exit "$PROMPT_RC_BACK"
    fi
    return "$PROMPT_RC_BACK"
}

# One column for every answer of every question: the numbered choices of pick_option print
# with "  %2d)", so these print with "  %2s)" and land under them instead of two characters
# to the left. A list that is almost aligned reads worse than one that is not aligned at all.
_prompt_extras() {
    printf '  %2s) %s\n' "h" "Help -- what this question means"
    printf '  %2s) %s\n' "b" "One step back"
}

# The input line starts in the same column as the answers above it ("   h)"), and it names
# what is typed instead of a bare "Value:" (operator 2026-09-24: "statt value: haette ich
# gerne den benannten Wert nach dem gefragt wird. zB email: und das buendig unter der Auswahl
# help oder zurueck"). The name is the question without its explaining parenthesis.
PROMPT_INDENT="   "
_prompt_label() {
    local text="$1"
    [[ "$text" =~ ^(.*[^[:space:]])[[:space:]]\(.+\)$ ]] && text="${BASH_REMATCH[1]}"
    printf '%s' "${text%\?}"
}

# _prompt_headline "Question (long aside)" -> the question on one line, a long aside
# indented on the next. Many questions here end in a parenthesis that explains the value;
# left in the same line it is what turns a readable question into a wrapped block. A short
# aside ("SMTP relay port (submission)") stays where it is -- splitting that would be noise.
_prompt_headline() {
    local text="$1"
    if [[ "$text" =~ ^(.*[^[:space:]])[[:space:]]\((.+)\)$ ]] && (( ${#BASH_REMATCH[2]} > 24 )); then
        printf '%s\n  (%s)\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf '%s\n' "$text"
    fi
}

# confirm "Question?" [y|n] [helpkey] -> 0 for yes, 1 for no, and it never returns on "back"
# inside a step: _prompt_back leaves the step there. This matters because confirm is nearly
# always used in an "if", where a return code would be read as "no" -- a silent wrong answer.
#
# With an installation order (lib/order.sh) nobody sits at the terminal: the answer is the
# order's under the help key, and a question the order does not answer takes its default --
# both said on the screen and in the log, so the run reads like a dialogue afterwards.
confirm() {
    local question="$1" default="${2:-n}" helpkey="${3:-}" reply dflt=2
    [[ "$default" == "y" ]] && dflt=1
    if declare -F order_active >/dev/null && order_active; then
        reply="$(order_answer "$helpkey" || true)"
        case "$reply" in
            y|n) echo "$question -> $([[ $reply == y ]] && echo yes || echo no) (installation order)" ;;
            *)   reply="$default"
                 echo "$question -> $([[ $reply == y ]] && echo yes || echo no) (default; the order does not answer it)" ;;
        esac
        _log_line "INFO" "order: $question -> $reply"
        [[ "$reply" == "y" ]]
        return
    fi
    _prompt_headline "$question"
    printf '  %2d) %s\n' 1 "Yes"
    printf '  %2d) %s\n' 2 "No"
    _prompt_extras
    while true; do
        read -r -p "${PROMPT_INDENT}Choice [$dflt]: " reply
        reply="${reply:-$dflt}"
        case "$reply" in
            1|y|Y|j|J) return 0 ;;
            2|n|N)     return 1 ;;
            h|H|\?)    help_show "$helpkey" "$question"; continue ;;
            b|B)       _prompt_back "$question"; return "$PROMPT_RC_BACK" ;;
        esac
        echo "  Enter 1, 2, h or b."
    done
}

# ask VAR "Prompt" [default] [helpkey] -> reads into VAR, keeps default on empty input.
# A lone h or b is the help / back answer here too. None of the values this installer asks
# for -- domain, user name, e-mail, key, URL -- is a single letter, so nothing is shadowed.
#
# The layout is the same as every menu: question on its own line, then one indented line per
# thing you can do, then a short input line (operator 2026-09-23: "es aendert sich von
# strukturiert und zeilenweise in brei den keiner lesen kann"). Question, default and the two
# extra answers used to be crammed into the read prompt, which wrapped into a wall of text as
# soon as the question or the default was long -- and both are long here: a git URL, an SSH
# key, a sentence explaining what the value means.
ask() {
    local -n _target="$1"
    local prompt="$2" default="${3:-}" helpkey="${4:-}" reply show=1
    while true; do
        if (( show )); then
            _prompt_headline "$prompt"
            [[ -n "$default" ]] && echo "  Default: $default"
            _prompt_extras
            show=0
        fi
        if [[ -n "$default" ]]; then read -r -p "${PROMPT_INDENT}$(_prompt_label "$prompt") [Enter = default]: " reply
        else                          read -r -p "${PROMPT_INDENT}$(_prompt_label "$prompt"): " reply; fi
        case "$reply" in
            h|H|\?) help_show "$helpkey" "$prompt"; show=1; continue ;;
            b|B)    _prompt_back "$prompt"; return "$PROMPT_RC_BACK" ;;
        esac
        if [[ -z "$reply" ]]; then
            [[ -n "$default" ]] && { _target="$default"; return 0; }
            echo "  A value is required."
            continue
        fi
        _target="$reply"
        return 0
    done
}

# ask_secret VAR "Prompt" [helpkey] -> hidden input, asked twice, never logged, never written
# to disk. Same layout as ask; the input line says that nothing will appear while you type,
# because a hidden field that gives no sign of itself looks like a hung terminal.
ask_secret() {
    local -n _target="$1"
    local prompt="$2" helpkey="${3:-}" first second show=1
    while true; do
        if (( show )); then
            _prompt_headline "$prompt"
            _prompt_extras
            echo "${PROMPT_INDENT}(hidden: nothing appears as you type)"
            show=0
        fi
        read -r -s -p "${PROMPT_INDENT}$(_prompt_label "$prompt"): " first; echo
        case "$first" in
            h|H|\?) help_show "$helpkey" "$prompt"; show=1; continue ;;
            b|B)    _prompt_back "$prompt"; return "$PROMPT_RC_BACK" ;;
        esac
        [[ -n "$first" ]] || { echo "  A value is required."; continue; }
        read -r -s -p "${PROMPT_INDENT}Repeat: " second; echo
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
    _prompt_extras >&2
    while true; do
        read -r -p "${PROMPT_INDENT}$prompt [0-${#items[@]}]: " reply
        case "$reply" in
            h|H|\?) help_show "" "$prompt" >&2; continue ;;
            b|B)    _prompt_back "$prompt"; return "$PROMPT_RC_BACK" ;;
        esac
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 0 && reply <= ${#items[@]} )); then
            echo "$reply"
            return 0
        fi
        echo "  Enter a number between 0 and ${#items[@]}, h or b." >&2
    done
}

# With an installation order nobody is there to press Enter -- the run goes on.
pause() {
    if declare -F order_active >/dev/null && order_active; then echo; return 0; fi
    read -r -p "Press [Enter] to continue... " _
}

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

# set_env_line FILE KEY VALUE -> "KEY=VALUE" style files. Every active or commented line of
# KEY becomes KEY=VALUE, appended when there is none. Written line by line in bash, not with
# sed: a \, & or | in the value (an image tag, a mailbox name from an installation order)
# is sed syntax in a replacement and would have written something else than was given. The
# file keeps its mode and owner -- it is rewritten in place, not replaced.
set_env_line() {
    local file="$1" key="$2" value="$3" line found=0 tmp
    touch "$file"
    tmp="$(mktemp "$file.XXXXXX")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*${key}= ]]; then
            printf '%s=%s\n' "$key" "$value"; found=1
        else
            printf '%s\n' "$line"
        fi
    done < "$file" > "$tmp"
    (( found )) || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# --- step bookkeeping ---------------------------------------------------------------------
step_done()    { date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/$1.done"; }
step_is_done() { [[ -f "$STATE_DIR/$1.done" ]]; }
step_done_at() { cat "$STATE_DIR/$1.done" 2>/dev/null || echo "-"; }
