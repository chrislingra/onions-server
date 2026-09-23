#!/usr/bin/env bash
# =============================================================================
# tools/backup-access.sh -- give the platform group read access to /opt/backups
#                           WITHOUT changing a single owner.
#
# WHY THIS EXISTS
#   On a host that grew before this installer, the backup library created
#   everything under /opt/backups with mode 700 and 600: readable by root and
#   nobody else. Nobody noticed until an admin looked for his own backups over
#   SFTP and found an empty directory. The installer creates /opt/backups
#   correctly today (root:<group>, mode 2750, setgid), but that only helps what
#   is created AFTERWARDS -- the directories and dumps that are already there
#   keep the owner, the group and the mode they were born with.
#
#   Operator, 2026-09-23: "fuer 4 bitte ein script, das sicher ist und keinen
#   owner aendert. fuer die Neuinstallation ist dies nicht moeglich und muss
#   automatisch laufen bei der Installation."
#
# WHY IT USES ACLs AND NOT chgrp
#   A backup is evidence. Rewriting who owns it changes the very thing it is
#   supposed to preserve, and `chgrp -R` over a tree of database dumps is
#   exactly the kind of sweeping change that is easy to start and impossible to
#   undo -- the previous owners are not written down anywhere.
#   An access control entry adds a permission beside the owner instead of
#   replacing it. Owner and group stay byte for byte what they were; only the
#   named group gains read access, and the default entry passes that on to
#   whatever is created later. Nothing here can take an existing permission
#   away: every call is `-m` (add or modify one entry), never `-b` (wipe) or
#   `--set` (replace all).
#
# WHAT IT REFUSES TO DO -- fail closed, every one of them
#   * work on any path other than /opt/backups (no argument, no switch: the
#     directory is the job, and a tool that can be pointed elsewhere will be)
#   * follow a symbolic link that stands where the directory should be
#   * run without setfacl, or on a filesystem mounted without ACL support --
#     there is no second way to do this without touching owners, so it says so
#     and stops rather than reporting success it did not achieve
#   * change an owner, a group, or a mode. Not once, anywhere.
#
# Run automatically by steps/10-base.sh; safe to run again at any time.
#   sudo bash tools/backup-access.sh <group>
# =============================================================================
set -euo pipefail

DIR="/opt/backups"
GROUP="${1:-}"

say()  { printf '[backup-access] %s\n' "$1"; }
fail() { printf '[backup-access] FAILED: %s\n' "$1" >&2; exit 1; }

[[ -n "$GROUP" ]] || fail "no group given. Usage: bash tools/backup-access.sh <group>"
getent group "$GROUP" >/dev/null || fail "group '$GROUP' does not exist -- create it first."

# The directory itself, before anything else.
[[ ! -L "$DIR" ]] || fail "$DIR is a symbolic link. Refusing -- a link can point anywhere."
if [[ ! -d "$DIR" ]]; then
    say "$DIR does not exist yet; nothing to open up."
    exit 0
fi

command -v setfacl >/dev/null 2>&1 || fail \
    "setfacl is missing (package 'acl'). Install it and run this again. Without it the
    only way to grant this access would be to rewrite the owner of every backup, and
    this script does not do that."

# Does the filesystem carry ACLs at all? Ask it instead of assuming: a tmpfs or a
# mount without the acl option accepts the command and keeps nothing.
probe="$DIR/.acl-probe.$$"
cleanup() { rm -f "$probe" 2>/dev/null || true; }
trap cleanup EXIT
: > "$probe" || fail "cannot write in $DIR -- run this as root."
if ! setfacl -m "g:${GROUP}:r" "$probe" 2>/dev/null; then
    fail "the filesystem under $DIR does not accept ACLs (mounted without the 'acl' option?).
    Nothing was changed."
fi
getfacl -c "$probe" 2>/dev/null | grep -q "^group:${GROUP}:" || fail \
    "the ACL was accepted but not kept -- the filesystem under $DIR does not store them.
    Nothing was changed."
cleanup
trap - EXIT

# rX, deliberately: read everywhere, execute ONLY where it is already executable.
# A capital X gives the search bit on directories and leaves plain files alone --
# a database dump does not become runnable because someone may read it.
say "granting group '$GROUP' read access under $DIR (owners untouched)..."
setfacl -R -m "g:${GROUP}:rX" "$DIR"
setfacl -R -d -m "g:${GROUP}:rX" "$DIR"

dirs=$(find "$DIR" -type d | wc -l)
files=$(find "$DIR" -type f | wc -l)
say "done: $dirs directory/ies and $files file(s) readable for '$GROUP'."
say "New files inherit it -- the default entry is set."
say "Owner, group and mode are unchanged everywhere; run 'getfacl $DIR' to see the entries."
