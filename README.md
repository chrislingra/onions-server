# onions-server

The base installation of a fresh Linux host for the onions.one platform -- menu-driven,
from the empty machine up to the point where the **Toolserver** takes over.

Design decisions (recorded in the Toolserver's `GAP-ENV-SYSTEM-NEUAUFBAU-01`, K1-K7):

1. **Own repository**, separate from the Toolserver. The first thing that runs on a new
   server is a `git clone` of this one -- to `/opt/onions-server`, the same on every host.
2. **Code and instance apart**: the domain is individual, the code is not. On first start
   the installer asks the domain once, remembers it in `.instance`, and creates
   `/opt/<domain>` for everything of *this* host: the answers (`site.env`, mode 600), step
   markers, backups, logs. A fresh machine has none of these directories; the installer
   makes them.
3. **Menu-driven**: `install.sh` shows the eight steps with their state; no parameters.
   Every decision on the way is the same simple numbered choice.
4. **Distribution families** debian (Ubuntu, Debian), rhel (RHEL, Rocky, Alma, Fedora),
   suse (SLES, openSUSE Leap) behind `lib/os.sh`. A distribution the installer has not
   been proven on is installed the same way; the banner and the log say so (see *Proving a run*).
5. **Two kinds of users.** The **bootstrap user** `manager` (fixed name, step 1) makes the
   delivered state work: sudo, docker, a generated one-time password shown once on the
   console and expired on purpose. It owns nothing -- platform directories belong to
   `root:onions`, the platform group every admin is in. **Personal admins** (step 3, as
   many as needed) get their SSH key one of three ways: pasted, generated on the server
   (handed out once, deleted after the proven login), or none yet -- then password login
   stays on and the hardening waits. The hardening turns password login off only after a
   key login was proven in a second session. **Step 8 removes the bootstrap user** once a personal admin
   with sudo and key exists, sshd is hardened and the user owns no files.
6. **Handover**: step 7 pulls the Toolserver from Git and runs its own
   `scripts/setup-toolserver.sh`. From then on the Toolserver manages the host
   (Environment > Server-Config > Services). This repository never installs a service.
7. **Checklist as data**: `checklist/PREPARATION.md` lists what to have ready; `site.env`
   holds the answers. **No password lives in this repository or in `site.env`** -- they
   are asked hidden at the moment of use.
8. **Bash, not Ansible**: a fresh server has bash and git before anything else, the raw
   material was Bash, and the Toolserver takes over long before an orchestration tool
   would pay off.

## Quick start on a fresh machine

```bash
# 1. git, then this repository (public -- no key needed for this clone)
apt-get install -y git            # dnf install git / zypper install git
git clone https://github.com/chrislingra/onions-server.git /opt/onions-server

# 2. the menu -- asks the domain, creates /opt/<domain>, shows the steps
cd /opt/onions-server && sudo bash install.sh
```

Menu item `a` runs steps 1-8 in order; every step can also be run alone and repeated.

| Step | Does |
|---|---|
| 1 Base system | update, base packages, snapd off (Ubuntu), locale, time zone, group `onions`, bootstrap user `manager` |
| 2 Firewall | deny in; 22/80/443 in; 587 out; 25/465 out blocked |
| 3 Personal admins | users with SSH keys, sudo, SFTP (`internal-sftp`), sshd hardening behind a proof |
| 4 Docker | Engine + Compose v2 plugin from the vendor (distribution on SUSE), network `traefik_web` |
| 5 Traefik | `/opt/traefik` from `templates/`, Let's Encrypt staging/production, dashboard auth |
| 6 Hardening | mail relay (msmtp), CrowdSec + bouncer, rkhunter daily report, Docker Scout |
| 7 Toolserver | deploy key, clone, `setup-toolserver.sh --skip-docker --skip-traefik`, handover |
| 8 Finish | removes the bootstrap user after the checks |

## Layout

```
install.sh              entry point, menu, instance (domain) handling
lib/common.sh           logging (terminal + log), prompts, backups, config-line editing
lib/os.sh               the distribution layer: packages, services, firewall, Docker, locale
lib/checklist.sh        the checklist items, validation, site.env
steps/NN-name.sh        one step each, idempotent, sourced by install.sh
templates/              Traefik static config and compose file with @PLACEHOLDERS@
checklist/PREPARATION.md what to have ready
tests/selftest.sh       100 checks without root (syntax, detection, checklist, prompts, ...)
.instance               the domain of this host (gitignored)
src/                    Toolserver checkout for step 7 (gitignored)

/opt/<domain>/          the instance: site.env, state/ (markers, backups), logs/
```

## Proving a run

`OS_MEASURED` in `lib/os.sh` lists the distributions this installer ran through
completely on a fresh machine. It is empty until the first proof. To add one: fresh VM
or snapshot → clone → menu item `a` → every step green → Toolserver reachable → add the
line `[<id>-<version>]="<date> <who/where>"` and commit. Nothing else counts as proven.
