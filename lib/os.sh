#!/usr/bin/env bash
# lib/os.sh -- the distribution layer. Every step talks to these functions, never to
# apt/dnf/zypper, ufw/firewalld or systemctl directly. Sourced, never executed.
#
# Families: debian (Ubuntu, Debian) | rhel (RHEL, Rocky, Alma, CentOS Stream, Fedora)
#           | suse (SLES, openSUSE Leap)

# --- WHICH DISTRIBUTIONS THIS INSTALLER SUPPORTS, AND WHAT DIFFERS ON EACH -----------------
#
# The requirement (operator, repeated 2026-09-23: "das system sollte auf Ubuntu, Red Hat,
# Suse und debian laufen. Ubuntu ist minimum"). This table is the answer, and it is a
# TABLE on purpose: until 2026-09-23 the installer found out on the operator's machine, in
# step 6, that a vendor repository had nothing for his release -- by then apt was already
# broken and the run was over. What can be known beforehand is written down beforehand.
#
# The verdicts:
#   full      every part has packages from the vendor; nothing is left out.
#   partial   the installation runs, but a named part is not available and is replaced or
#             skipped. Said BEFORE anything is installed, not discovered halfway.
#   untested  this release is not in the table. The family's commands run and the runtime
#             check in pkg_refresh catches a source that does not exist -- but nobody has
#             looked at this combination. It is a warning, not a refusal.
#
# MEASURED 2026-09-23 against the vendors' own repositories (the date matters: a vendor adds
# a release months after the distribution publishes it):
#   Docker    has packages for ubuntu jammy/noble, debian bookworm/trixie, centos+rhel 8/9/10,
#             fedora 41/42 -- and NOTHING for SLES or openSUSE (404).
#   CrowdSec  has packages for ubuntu jammy/noble, debian bookworm, el 8/9/10, fedora 41 --
#             nothing for debian trixie (404), and its SUSE repository exists but is EMPTY
#             (primary.xml.gz says packages="0", stamped 2021). openSUSE itself carries no
#             crowdsec either, in no OBS project -- but it does carry fail2ban 0.11.2.
#
# Keys are looked up in this order: <id>-<version> (ubuntu-24.04), then <id>-<major>
# (rocky-9), then the family. A line with a second field explains what is different here;
# os_support_report prints it before the first step runs.
declare -A OS_SUPPORT=(
    [ubuntu-22.04]="full|"
    [ubuntu-24.04]="full|"
    [debian-12]="full|"
    [debian-13]="full|CrowdSec publishes nothing for trixie. Its bookworm packages are installed instead -- same software, one release behind."
    [rhel-8]="full|"      [rhel-9]="full|"      [rhel-10]="full|"
    [rocky-8]="full|"     [rocky-9]="full|"     [rocky-10]="full|"
    [almalinux-8]="full|" [almalinux-9]="full|" [almalinux-10]="full|"
    [centos-9]="full|"    [centos-10]="full|"
    [fedora-41]="full|"   [fedora-42]="full|"
    [sles-15]="partial|Docker publishes nothing for SUSE -- the distribution's own docker and docker-compose are installed. CrowdSec has no SUSE packages at all (its repository is empty): fail2ban from the distribution protects SSH instead."
    [opensuse-leap-15]="partial|Docker publishes nothing for SUSE -- the distribution's own docker and docker-compose are installed. CrowdSec has no SUSE packages at all (its repository is empty): fail2ban from the distribution protects SSH instead."
)
# The recommended base (operator's decision 2026-09-23). It is a recommendation, never a
# gate: every "full" line above installs just as completely. Ubuntu 24.04 LTS is named
# because it is the only combination where nothing at all is substituted -- both vendors
# publish for it, and it is maintained until 2029. Named in ONE place; the report and the
# README both take it from here.
RECOMMENDED_OS_KEY="ubuntu-24.04"
RECOMMENDED_OS="Ubuntu 24.04 LTS"
RECOMMENDED_OS_WHY="both Docker and CrowdSec publish for it, so nothing has to be substituted; maintained until 2029"

declare -A OS_SUPPORT_FAMILY=(
    [debian]="untested|This Debian or Ubuntu release is newer than the table. Everything is tried; a vendor repository that does not carry it yet is noticed and an older release of it is used."
    [rhel]="untested|This Red Hat family release is not in the table. Everything is tried; a vendor repository that does not carry it yet is noticed."
    [suse]="partial|Docker publishes nothing for SUSE -- the distribution's own docker is installed. CrowdSec has no SUSE packages at all: fail2ban from the distribution protects SSH instead."
)

# PROVEN: a full run on a fresh machine, watched by a person. The table above says what
# CAN work and is measured against the vendors; this says what HAS worked end to end.
# Add a line only after such a run (README, section "Proving a run").
declare -A OS_PROVEN=(
    # [ubuntu-24.04]="2026-09-xx install.sh full run, VM xyz"
)

OS_ID=""; OS_FAMILY=""; OS_VERSION=""; OS_CODENAME=""; OS_PRETTY=""

os_detect() {
    local release="${OS_RELEASE_FILE:-/etc/os-release}"
    [[ -r "$release" ]] || die "Cannot read $release -- unsupported system."
    # shellcheck disable=SC1090
    . "$release"
    OS_ID="${ID:-}"; OS_VERSION="${VERSION_ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    case "$OS_ID" in
        ubuntu|debian)                      OS_FAMILY="debian" ;;
        rhel|rocky|almalinux|centos|fedora) OS_FAMILY="rhel" ;;
        sles|opensuse-leap|opensuse)        OS_FAMILY="suse" ;;
        *)
            case " ${ID_LIKE:-} " in
                *" debian "*|*" ubuntu "*) OS_FAMILY="debian" ;;
                *" rhel "*|*" fedora "*)   OS_FAMILY="rhel" ;;
                *" suse "*)                OS_FAMILY="suse" ;;
                *) die "Unknown distribution '$OS_ID' (ID_LIKE='${ID_LIKE:-}'). Supported families: debian, rhel, suse." ;;
            esac ;;
    esac
}

os_key()       { echo "${OS_ID}-${OS_VERSION}"; }
os_key_major() { echo "${OS_ID}-${OS_VERSION%%.*}"; }
os_proven()    { [[ -n "${OS_PROVEN[$(os_key)]:-}" ]]; }

# _os_support_entry -> the table line for this machine: "<verdict>|<what differs>".
# Exact release first, then the major version, then the family.
_os_support_entry() {
    local entry="${OS_SUPPORT[$(os_key)]:-}"
    [[ -n "$entry" ]] || entry="${OS_SUPPORT[$(os_key_major)]:-}"
    [[ -n "$entry" ]] || entry="${OS_SUPPORT_FAMILY[$OS_FAMILY]:-}"
    [[ -n "$entry" ]] || entry="untested|This distribution is not in the table."
    printf '%s' "$entry"
}

os_support_level() { local e; e="$(_os_support_entry)"; printf '%s' "${e%%|*}"; }
os_support_note()  { local e; e="$(_os_support_entry)"; printf '%s' "${e#*|}"; }

# _os_recommendation -> names the recommended base, but only where it helps: on a machine
# that has to substitute something or that nobody has looked at. A fully supported Debian 12
# is not nagged at -- a recommendation repeated where it changes nothing is noise.
_os_recommendation() {
    [[ "$(os_key)" == "$RECOMMENDED_OS_KEY" ]] && return 0
    log_info "  Recommended base for a NEW machine: $RECOMMENDED_OS -- $RECOMMENDED_OS_WHY."
    log_info "  This installation continues here; the recommendation is for the next fresh host."
}

# os_support_report -> says what this machine is in for, BEFORE the first step runs.
# Never refuses: an untested release is a warning, and the operator decides.
os_support_report() {
    local level note
    level="$(os_support_level)"; note="$(os_support_note)"
    case "$level" in
        full)
            log_ok "$OS_PRETTY is fully supported: every part of the installation has packages."
            [[ -n "$note" ]] && log_info "  $note"
            ;;
        partial)
            log_warn "$OS_PRETTY is supported with one part missing:"
            log_warn "  $note"
            _os_recommendation
            ;;
        *)
            log_warn "$OS_PRETTY is not in the table of measured distributions."
            log_warn "  $note"
            log_warn "  The commands of the $OS_FAMILY family run. Watch the log, and tell us how it went."
            _os_recommendation
            ;;
    esac
    os_proven && log_ok "  A complete run on this release has been watched: ${OS_PROVEN[$(os_key)]}" \
              || log_info "  No complete run on this exact release has been recorded yet."
    return 0
}

# --- third-party apt repositories: which codename do they really carry? ---------------------
# apt_repo_dist BASE_URL -> prints the codename to use for that repository on this host, and
# fails (exit 1, nothing printed) when it carries none we could use.
#
# Why this exists (operator 2026-09-23, on a freshly installed Debian trixie: "es kommt zu
# fehlern"): a vendor repository follows the distribution's release cycle by months. On the
# day trixie was installed, CrowdSec's packagecloud repository had no trixie directory at
# all. The installer wrote the source anyway, "apt-get update" answered 404 for it, and the
# step ran on into "Unable to locate package ..." -- ending in a hardening that blocked
# nothing. One HTTP request per candidate turns that into a named, older but working source.
#
# The chain is the release order of the distribution, newest first. Only codenames OLDER than
# this host's are tried: an older repository is a compromise, a newer one is wrong. A codename
# this list does not know yet counts as the newest, so everything below it is fair game --
# which is exactly what should happen the day the next release appears and this list is stale.
apt_repo_dist() {
    local base="$1" chain c past candidates=""
    case "$OS_ID" in
        debian) chain="forky trixie bookworm bullseye" ;;
        ubuntu) chain="questing plucky oracular noble jammy focal" ;;
        *)      chain="" ;;
    esac
    case " $chain " in
        *" ${OS_CODENAME} "*) past="" ;;   # known release: start at it
        *)                    past="yes" ;; # unknown (newer than this list): everything is older
    esac
    [[ -n "$OS_CODENAME" ]] && candidates="$OS_CODENAME"
    for c in $chain; do
        if [[ -z "$past" ]]; then
            [[ "$c" == "$OS_CODENAME" ]] && past="yes"
            continue
        fi
        candidates="$candidates $c"
    done
    for c in $candidates; do
        if curl -fsS --max-time 20 -o /dev/null "${base%/}/dists/${c}/Release" 2>/dev/null; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# _url_ok URL -> 0 when the address answers without an error status. Uses whatever is on the
# machine; if neither curl nor wget is there, it says "unknown" (2) and nothing is repaired
# on a guess.
_url_ok() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 20 -o /dev/null "$url" 2>/dev/null
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=20 --tries=1 -O /dev/null "$url" 2>/dev/null
        return $?
    fi
    return 2
}

# apt_sources_repair -> looks at every extra package source, repairs the ones whose repository
# does not carry the release they name, and switches off the ones that cannot be repaired.
# Returns 0 when it changed something, 1 when it found nothing to change.
#
# Why this exists (operator 2026-09-23, on the host of the trixie run): a single broken source
# stops apt-get update with exit 100 -- and with it EVERY step of this installer, including
# the first one, which only wants to install curl and git. The source that broke it had been
# written by an earlier run of step 6 for a release CrowdSec does not publish. Repairing
# CrowdSec alone was not enough: the file was still lying there, and step 1 never got far
# enough to reach step 6. A leftover source of a third party must not be able to block the
# installation of the machine.
apt_sources_repair() {
    [[ "$OS_FAMILY" == "debian" ]] || return 1
    local file changed=1
    shopt -s nullglob
    for file in /etc/apt/sources.list.d/*.list; do
        _apt_list_repair "$file" && changed=0
    done
    for file in /etc/apt/sources.list.d/*.sources; do
        _apt_deb822_repair "$file" && changed=0
    done
    shopt -u nullglob
    return "$changed"
}

# _apt_list_repair FILE -> 0 when the file was rewritten or switched off.
_apt_list_repair() {
    local file="$1" line url suite i rc new_suite touched=1
    local -a parts
    local tmp; tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ ! "$line" =~ ^[[:space:]]*deb(-src)?[[:space:]] ]]; then
            printf '%s\n' "$line" >> "$tmp"; continue
        fi
        read -ra parts <<< "$line"
        i=1
        # an option block [arch=... signed-by=...] may span several words
        if [[ "${parts[1]:-}" == \[* ]]; then
            while (( i < ${#parts[@]} )) && [[ "${parts[$i]}" != *\] ]]; do i=$((i + 1)); done
            i=$((i + 1))
        fi
        url="${parts[$i]:-}"; suite="${parts[$((i + 1))]:-}"
        # only repositories with the usual dists/ layout can be asked; a flat repo ends in /
        if [[ "$url" != http* || -z "$suite" || "$suite" == */ ]]; then
            printf '%s\n' "$line" >> "$tmp"; continue
        fi
        _url_ok "${url%/}/dists/${suite}/Release"; rc=$?
        if (( rc == 0 )); then printf '%s\n' "$line" >> "$tmp"; continue; fi
        if (( rc == 2 )); then
            log_warn "Cannot check $url (neither curl nor wget here) -- leaving ${file##*/} alone."
            printf '%s\n' "$line" >> "$tmp"; continue
        fi
        new_suite="$(apt_repo_dist "$url")" || new_suite=""
        if [[ -n "$new_suite" ]]; then
            log_warn "${file##*/}: $url has nothing for '$suite' -- using '$new_suite' instead."
            printf '%s\n' "${line/ $suite / $new_suite }" >> "$tmp"
            touched=0
        else
            rm -f "$tmp"
            backup_file "$file"
            mv "$file" "$file.disabled"
            log_err "${file##*/}: $url publishes nothing for $OS_ID $OS_CODENAME nor for any earlier release."
            log_err "  The source is switched off (now ${file##*/}.disabled) so the rest of the installation can run."
            log_err "  Whatever it was meant to deliver is NOT installed -- the step that needs it will say so."
            return 0
        fi
    done < "$file"
    if (( touched == 0 )); then
        backup_file "$file"
        cat "$tmp" > "$file"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# _apt_deb822_repair FILE -> the same for the newer deb822 form (URIs:/Suites:).
# A file with several suites or several URIs is not rewritten -- it is reported and left
# alone. Guessing which combination was meant would be worse than saying so.
_apt_deb822_repair() {
    local file="$1" uris suites rc new_suite
    uris="$(sed -n 's/^[Uu][Rr][Ii][Ss]:[[:space:]]*//p' "$file" | head -1)"
    suites="$(sed -n 's/^[Ss][Uu][Ii][Tt][Ee][Ss]:[[:space:]]*//p' "$file" | head -1)"
    [[ "$uris" == http* && -n "$suites" ]] || return 1
    [[ "$uris" != *" "* && "$suites" != *" "* ]] || { log_warn "${file##*/}: several URIs or suites -- not touched."; return 1; }
    _url_ok "${uris%/}/dists/${suites}/Release"; rc=$?
    (( rc == 0 )) && return 1
    if (( rc == 2 )); then
        log_warn "Cannot check $uris (neither curl nor wget here) -- leaving ${file##*/} alone."
        return 1
    fi
    new_suite="$(apt_repo_dist "$uris")" || new_suite=""
    backup_file "$file"
    if [[ -n "$new_suite" ]]; then
        sed -i "s/^\([Ss][Uu][Ii][Tt][Ee][Ss]:[[:space:]]*\).*$/\1${new_suite}/" "$file"
        log_warn "${file##*/}: $uris has nothing for '$suites' -- using '$new_suite' instead."
    else
        mv "$file" "$file.disabled"
        log_err "${file##*/}: $uris publishes nothing for $OS_ID $OS_CODENAME nor for any earlier release -- source switched off."
    fi
    return 0
}

# --- packages -----------------------------------------------------------------------------
# A failing refresh is not passed on blindly: apt stops on ONE unusable source, and that one
# is usually a leftover of an earlier run. Repair it, then ask again -- and if there was
# nothing to repair, the cause is elsewhere and the failure stands.
pkg_refresh() {
    case "$OS_FAMILY" in
        debian)
            if run apt-get update -qq; then return 0; fi
            log_warn "apt-get update failed. Looking for a package source that cannot work..."
            if apt_sources_repair; then
                log_info "Asking again with the repaired sources."
                run apt-get update -qq
            else
                log_err "No unusable package source found -- the cause is elsewhere (network, disk, or a mirror of the distribution). The lines above say which source complained."
                return 1
            fi
            ;;
        rhel)   run dnf -q makecache ;;
        suse)   run zypper --non-interactive refresh ;;
    esac
}

pkg_upgrade_all() {
    case "$OS_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive run apt-get upgrade -y -qq ;;
        rhel)   run dnf -y -q upgrade ;;
        suse)   run zypper --non-interactive update ;;
    esac
}

pkg_install() {
    [[ $# -gt 0 ]] || return 0
    case "$OS_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive run apt-get install -y -qq "$@" ;;
        rhel)   run dnf -y -q install "$@" ;;
        suse)   run zypper --non-interactive install -y "$@" ;;
    esac
}

pkg_remove() {
    [[ $# -gt 0 ]] || return 0
    case "$OS_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive run apt-get remove --purge -y -qq "$@" ;;
        rhel)   run dnf -y -q remove "$@" ;;
        suse)   run zypper --non-interactive remove -y "$@" ;;
    esac
}

pkg_installed() {
    case "$OS_FAMILY" in
        debian) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
        rhel|suse) rpm -q "$1" >/dev/null 2>&1 ;;
    esac
}

# pkg_name <generic> -> the distribution's package name for a few things that differ.
pkg_name() {
    case "$1" in
        htpasswd)  case "$OS_FAMILY" in debian) echo apache2-utils ;; rhel) echo httpd-tools ;; suse) echo apache2-utils ;; esac ;;
        cron)      case "$OS_FAMILY" in debian) echo cron ;; rhel) echo cronie ;; suse) echo cron ;; esac ;;
        mailer)    echo msmtp ;;   # ssmtp is gone from Debian 12 / Ubuntu 24.04; msmtp is its successor
        *)         echo "$1" ;;
    esac
}

# --- services -----------------------------------------------------------------------------
svc_enable_now() { run systemctl enable --now "$1"; }
svc_restart()    { run systemctl restart "$1"; }
svc_reload()     { run systemctl reload "$1"; }
svc_active()     { systemctl is-active --quiet "$1"; }

# Which tool blocks attackers on this family. CrowdSec everywhere it exists -- on SUSE it
# does not (its repository is empty, measured 2026-09-23), and fail2ban from the
# distribution takes the job. One name, decided here, so no step has to ask again.
intrusion_tool() { case "$OS_FAMILY" in suse) echo fail2ban ;; *) echo crowdsec ;; esac; }
# ... and how it is written for a person to read. The package name is lower case because
# packages are; a menu entry is not a package name.
intrusion_tool_name() { case "$OS_FAMILY" in suse) echo "fail2ban" ;; *) echo "CrowdSec" ;; esac; }

sshd_service() { case "$OS_FAMILY" in debian) echo ssh ;; *) echo sshd ;; esac; }
sudo_group()   { case "$OS_FAMILY" in debian) echo sudo ;; *) echo wheel ;; esac; }

# --- firewall: ufw on the debian family, firewalld elsewhere -------------------------------
fw_install() {
    case "$OS_FAMILY" in
        debian) pkg_installed ufw || pkg_install ufw ;;
        rhel|suse) pkg_installed firewalld || pkg_install firewalld; svc_enable_now firewalld ;;
    esac
}

# fw_baseline: deny incoming, allow outgoing, open 22/80/443, submission (587) out,
# block direct SMTP out (25, 465).
fw_baseline() {
    case "$OS_FAMILY" in
        debian)
            run ufw default deny incoming
            run ufw default allow outgoing
            run ufw allow 22/tcp comment 'SSH'
            run ufw allow 80/tcp comment 'HTTP'
            run ufw allow 443/tcp comment 'HTTPS'
            run ufw allow out 587/tcp comment 'SMTP submission'
            run ufw deny out 25/tcp comment 'Block direct SMTP'
            run ufw deny out 465/tcp comment 'Block SMTPS'
            run ufw --force enable
            ;;
        rhel|suse)
            run firewall-cmd --permanent --set-default-zone=public
            run firewall-cmd --permanent --zone=public --add-service=ssh
            run firewall-cmd --permanent --zone=public --add-service=http
            run firewall-cmd --permanent --zone=public --add-service=https
            run firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --dport 25 -j REJECT
            run firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --dport 465 -j REJECT
            run firewall-cmd --reload
            ;;
    esac
}

fw_status() {
    case "$OS_FAMILY" in
        debian)    ufw status verbose ;;
        rhel|suse) firewall-cmd --list-all; firewall-cmd --direct --get-all-rules ;;
    esac
}

# --- Docker: the vendor's repositories on debian/rhel, the distribution's on suse ---------
docker_install() {
    case "$OS_FAMILY" in
        debian)
            pkg_install ca-certificates curl gnupg
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            # not blindly $OS_CODENAME: the day a new release appears, Docker's repository does
            # not have it yet and apt would fail on a source that cannot exist (see apt_repo_dist)
            local docker_dist
            docker_dist="$(apt_repo_dist "https://download.docker.com/linux/${OS_ID}")" \
                || die "Docker publishes nothing for ${OS_ID} ${OS_CODENAME} nor for any earlier release. Install docker and the compose plugin by hand, then run this step again."
            [[ "$docker_dist" == "$OS_CODENAME" ]] \
                || log_warn "Docker has no packages for ${OS_ID} ${OS_CODENAME} yet -- using the ${docker_dist} ones, which is what Docker itself recommends in that situation."
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${docker_dist} stable" \
                > /etc/apt/sources.list.d/docker.list
            pkg_refresh
            pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        rhel)
            pkg_install dnf-plugins-core
            local repo_os="centos"; [[ "$OS_ID" == "fedora" ]] && repo_os="fedora"
            run dnf -y config-manager --add-repo "https://download.docker.com/linux/${repo_os}/docker-ce.repo"
            pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        suse)
            # Docker Inc. publishes no x86_64 packages for SUSE; the distribution's own are current.
            pkg_install docker docker-compose docker-buildx
            ;;
    esac
    svc_enable_now docker
}

docker_ok() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }

# --- locale / time ------------------------------------------------------------------------
locale_set() {
    local locale="$1" timezone="$2" keymap="$3"
    case "$OS_FAMILY" in
        debian)
            pkg_install locales
            sed -i -E "s|^#?[[:space:]]*(${locale}[[:space:]]+UTF-8)|\1|" /etc/locale.gen
            grep -q "^${locale} UTF-8" /etc/locale.gen || echo "${locale} UTF-8" >> /etc/locale.gen
            run locale-gen
            ;;
        rhel) pkg_install glibc-langpack-"${locale%%_*}" ;;
        suse) pkg_install glibc-locale ;;
    esac
    run localectl set-locale "LANG=${locale}"
    case "$OS_FAMILY" in
        debian)
            # localectl set-keymap is refused on Debian/Ubuntu ("not supported in Debian");
            # the keymap lives in /etc/default/keyboard and console-setup applies it
            pkg_install console-setup keyboard-configuration
            set_env_line /etc/default/keyboard XKBLAYOUT "\"$keymap\""
            DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive keyboard-configuration >/dev/null 2>&1 || true
            command -v setupcon >/dev/null && setupcon --save-only >/dev/null 2>&1 || true
            ;;
        *) run localectl set-keymap "$keymap" ;;
    esac
    run timedatectl set-timezone "$timezone"
}

# --- security framework note (informational; SELinux changes how bind mounts behave) ----
security_framework() {
    if command -v getenforce >/dev/null 2>&1; then echo "SELinux: $(getenforce)"
    elif command -v aa-status >/dev/null 2>&1; then echo "AppArmor: $(aa-status --enabled 2>/dev/null && echo enabled || echo disabled)"
    else echo "no MAC framework detected"; fi
}
