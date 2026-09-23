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
   many as needed) log in with a password; SSH keys and the sshd hardening are optional
   here and otherwise follow in the Toolserver. A key can be pasted or generated on the
   server (handed out once, deleted after the proven login); the hardening turns password
   login off only after a key login was proven in a second session. **Step 8 removes the bootstrap user** once another
   admin with sudo can log in (key or password -- the installer's first user counts), the
   user owns no files outside its home, and the step is not run from that very login.
   Every reason for a refusal is printed, numbered; declining the final question keeps the
   user and leaves the step open.
6. **Handover**: step 7 pulls the Toolserver from Git, places `toolserver/setup-toolserver.sh`
   into `/opt/<domain>/` and runs it from there. The Toolserver repository carries no setup
   script (operator 2026-09-18: `scripts/setup-*.sh` must not exist there -- every setup script
   lives in `/opt/<domain>`); this one travels here because it runs before a Toolserver exists.
   From then on the Toolserver manages the host (Environment > Server-Config > Services) and
   maintains that copy. This repository never installs a service.
7. **Checklist as data**: `checklist/PREPARATION.md` lists what to have ready; `site.env`
   holds the answers. **No password lives in this repository or in `site.env`** -- they
   are asked hidden at the moment of use.
8. **Bash, not Ansible**: a fresh server has bash and git before anything else, the raw
   material was Bash, and the Toolserver takes over long before an orchestration tool
   would pay off.

## Quick start on a fresh machine

One address, one command, as root:

```bash
bash <(curl -fsSL https://tools.onions.one/install)
```

That address is served by a running Toolserver (`environment/envi_install_bootstrap.sh`,
GET `/install`). The script installs git if it is missing, clones this repository into
`/opt/onions-server` -- or fast-forwards an existing checkout -- and hands over to
`install.sh`. Nothing else: no login, no token, no call home.

Two details that look like typos and are not. **Not** `curl ... | bash`: the installer is a
menu and reads its answers from the terminal, and through a pipe those reads would swallow
the script itself; the first guard refuses that form. And **not** `sudo bash <(curl ...)`:
sudo closes the descriptor the process substitution hands over. Become root first
(`sudo -i`), then run the line above.

Without a reachable Toolserver -- the very first host of an installation -- the same thing
by hand:

```bash
apt-get install -y git            # dnf install git / zypper install git
git clone https://github.com/chrislingra/onions-server.git /opt/onions-server
cd /opt/onions-server && sudo bash install.sh
```

Menu item `a` runs steps 1-8 in order; every step can also be run alone and repeated.

**Access to the Toolserver's source (step 7).** This installer is a product path for an
unknown user (open core: the Toolserver's base is published under AGPL-3.0-only from
release level 1). From then on `TOOLSERVER_GIT` is a public address and step 7 clones it
without credentials -- no deploy key, no token, no password, nothing registered anywhere.
Until that release the base is closed and only lingra installs: the operator registers this
host's own key (`/root/.ssh/id_ed25519.pub`) as a read-only deploy key of the private
repository and enters its ssh address. Step 7 has no key handling of its own -- it probes
the address the way git will use it, never prompts, and shows git's reason if it fails.

| Step | Does |
|---|---|
| 1 Base system | update, base packages, snapd off (Ubuntu), locale, time zone, group `onions`, bootstrap user `manager` |
| 2 Firewall | deny in; 22/80/443 in; 587 out; 25/465 out blocked |
| 3 Personal admins | users with password, sudo, SFTP (`internal-sftp`); SSH keys and hardening optional (else later in the Toolserver) |
| 4 Docker | Engine + Compose v2 plugin from the vendor (distribution on SUSE), network `traefik_web` |
| 5 Traefik | `/opt/traefik` from `templates/`, Let's Encrypt staging/production, dashboard auth |
| 6 Hardening | recommended set: mail relay (msmtp), CrowdSec + bouncer, automatic security updates; extras: rkhunter, Docker Scout |
| 7 Toolserver | probes `TOOLSERVER_GIT` without prompting, clones it, `toolserver/setup-toolserver.sh` placed into `/opt/<domain>/` and run with `--skip-docker --skip-traefik` (first-login password generated, printed once), handover |
| 8 Finish | removes the bootstrap user after the checks |

## Layout

```
install.sh              entry point, menu, instance (domain) handling
lib/common.sh           logging (terminal + log), prompts, backups, config-line editing
lib/os.sh               the distribution layer: packages, services, firewall, Docker, locale
lib/checklist.sh        the checklist items, validation, site.env
steps/NN-name.sh        one step each, idempotent, sourced by install.sh
templates/              Traefik static config and compose file with @PLACEHOLDERS@
toolserver/             setup-toolserver.sh -- the Toolserver's setup, placed into /opt/<domain>/ by step 7
checklist/PREPARATION.md what to have ready
tests/selftest.sh       checks without root (syntax, detection, checklist, prompts, ...)
.instance               the domain of this host (gitignored)
src/                    Toolserver checkout for step 7 (gitignored)

/opt/<domain>/          the instance: site.env, state/ (markers, backups), logs/
```

## Proving a run

`OS_MEASURED` in `lib/os.sh` lists the distributions this installer ran through
completely on a fresh machine. It is empty until the first proof. To add one: fresh VM
or snapshot → clone → menu item `a` → every step green → Toolserver reachable → add the
line `[<id>-<version>]="<date> <who/where>"` and commit. Nothing else counts as proven.
