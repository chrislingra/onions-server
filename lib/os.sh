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

# --- packages -----------------------------------------------------------------------------
pkg_refresh() {
    case "$OS_FAMILY" in
        debian) run apt-get update -qq ;;
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
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
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
