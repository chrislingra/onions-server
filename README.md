# onions-server

The base installation of a fresh Linux host for the onions.one platform -- menu-driven,
from the empty machine up to the point where the **Toolserver** takes over. It replaces
the hand-run scripts `prepare-system.sh`, `harden-system.sh`, `user-security.sh` and
`setup-utf8.sh` that grew in `/opt/onions.one` over the years.

Design decisions (recorded in the Toolserver's `GAP-ENV-SYSTEM-NEUAUFBAU-01`, K1-K7):

1. **Own repository**, separate from the Toolserver. The first thing that runs on a new
   server is a `git clone` of this one.
2. **Menu-driven**: `install.sh` shows the steps with their state; no parameters to know.
3. **Distribution families** debian (Ubuntu, Debian), rhel (RHEL, Rocky, Alma, Fedora),
   suse (SLES, openSUSE Leap) behind `lib/os.sh`. A distribution the installer has not
   been proven on says so and asks for a typed `YES` -- the code path exists, the proof
   does not (see *Proving a run*).
4. **Handover**: the last step pulls the Toolserver from Git and runs its own
   `scripts/setup-toolserver.sh`. From then on the Toolserver manages the host
   (Environment > Server-Config > Services). This repository never installs a service.
5. **Checklist as data**: `checklist/PREPARATION.md` lists what to have ready;
   `site.env` (gitignored, mode 600) holds the answers. **No password lives in this
   repository or in `site.env`** -- they are asked hidden at the moment of use.
6. **Bash, not Ansible**: a fresh server has bash and git before anything else, the raw
   material was Bash, and the Toolserver takes over long before an orchestration tool
   would pay off.

## Quick start

```bash
# 1. git, then this repository into the domain directory
apt-get install -y git            # dnf install git / zypper install git
git clone git@github.com:chrislingra/onions-server.git /opt/example.org

# 2. the menu
cd /opt/example.org && sudo bash install.sh
```

Menu item 8 runs steps 1-7 in order; every step can also be run alone and repeated.

| Step | Does | Origin |
|---|---|---|
| 1 Base system | update, base packages, snapd off (Ubuntu), locale, time zone | prepare-system.sh, setup-utf8.sh |
| 2 Firewall | deny in; 22/80/443 in; 587 out; 25/465 out blocked | prepare-system.sh, harden-system.sh |
| 3 Admin user | user, sudo, key, SFTP (`internal-sftp`), sshd hardening behind a proof | prepare-system.sh, user-security.sh |
| 4 Docker | Engine + Compose v2 plugin from the vendor (distribution on SUSE), network `traefik_web` | prepare-system.sh |
| 5 Traefik | `/opt/traefik` from `templates/`, Let's Encrypt staging/production, dashboard auth | prepare-system.sh, live /opt/traefik |
| 6 Hardening | mail relay (msmtp), CrowdSec + bouncer, rkhunter daily report, Docker Scout | harden-system.sh |
| 7 Toolserver | deploy key, clone, `setup-toolserver.sh --skip-docker --skip-traefik`, handover | setup-toolserver.sh (Toolserver repo) |

## Layout

```
install.sh              entry point and menu
lib/common.sh           logging (terminal + logs/), prompts, backups, config-line editing
lib/os.sh               the distribution layer: packages, services, firewall, Docker, locale
lib/checklist.sh        the checklist items, validation, site.env
steps/NN-name.sh        one step each, idempotent, sourced by install.sh
templates/              Traefik static config and compose file with @PLACEHOLDERS@
checklist/PREPARATION.md what to have ready
site.env                answers (gitignored)      state/   step markers, backups (gitignored)
logs/                   one log per run (gitignored)
src/                    Toolserver checkout for step 7 (gitignored)
```

On the live host `/opt/onions.one` also carries the service setup scripts the Toolserver
delivers (`setup-<service>.sh`) and older material (`old/`, `tools/`); `.gitignore` keeps
them out of this repository.

## What changed against the old scripts

1. No plaintext password (prepare-system.sh had one for the admin user and the pipelines
   API; harden-system.sh wrote the SMTP password into ssmtp.conf world-readable by mail).
2. `ssmtp` → `msmtp` (ssmtp is not in Debian 12 / Ubuntu 24.04 any more).
3. No Compose v1 binary; everything uses `docker compose`.
4. sshd: settings land in `/etc/ssh/sshd_config.d/10-onions.conf` when the main file has
   an `Include`, so cloud-init's `PasswordAuthentication yes` no longer wins; the old
   `sed` on the main file never saw that drop-in. `AllowUsers` is not set (it made
   toggle-root.sh ineffective).
5. No `chown -R /opt` (user-security.sh changed the owner of every container volume).
6. Traefik image pinned to `traefik:v3` by default (the host runs `latest`); dashboard
   password hashed with `openssl passwd -apr1`, no apache2-utils needed.

## Proving a run

`OS_MEASURED` in `lib/os.sh` lists the distributions this installer ran through
completely on a fresh machine. It is empty until the first proof. To add one: fresh VM
or snapshot → clone → menu item 8 → every step green → Toolserver reachable → add the
line `[<id>-<version>]="<date> <who/where>"` and commit. Nothing else counts as proven.
