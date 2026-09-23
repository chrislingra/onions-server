#!/usr/bin/env bash
# lib/os.sh -- the distribution layer. Every step talks to these functions, never to
# apt/dnf/zypper, ufw/firewalld or systemctl directly. Sourced, never executed.
#
# Families: debian (Ubuntu, Debian) | rhel (RHEL, Rocky, Alma, CentOS Stream, Fedora)
#           | suse (SLES, openSUSE Leap)

# MEASURED: distributions this installer has run through completely, with the date and
# the version it was proven on. Anything not listed here asks the operator to confirm
# before it starts -- the code path exists, but nobody has watched it succeed yet.
# Add a line only after a full run on a fresh machine (README, section "Proving a run").
declare -A OS_MEASURED=(
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

os_key()      { echo "${OS_ID}-${OS_VERSION}"; }
os_measured() { [[ -n "${OS_MEASURED[$(os_key)]:-}" ]]; }

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
