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

**Recommended base: Ubuntu 24.04 LTS.** Both Docker and CrowdSec publish packages for it,
so nothing has to be substituted, and it is maintained until 2029. Debian 12, Debian 13,
RHEL/Rocky/Alma 8-10 and Fedora 41/42 install just as completely; SLES and openSUSE work
with two named substitutions. The full picture is in *Which distributions it runs on*
below, and the installer tells you which case your machine is before the first step runs.

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
apt-get install -y git && { git -C /opt/onions-server pull --ff-only 2>/dev/null || git clone https://github.com/chrislingra/onions-server.git /opt/onions-server; } && cd /opt/onions-server && bash install.sh
```

One line for the first start and every restart alike: an existing checkout is brought to the
current state, a missing one is cloned -- the line never stops at "already exists". On
RHEL/Fedora read `dnf install -y git`, on SUSE `zypper install -y git`.

Menu item `a` runs steps 1-8 in order; every step can also be run alone and repeated.

**Access to the Toolserver's source (step 7).** This installer is a product path for an
unknown user (open core: the Toolserver's base is published under AGPL-3.0-only from
release level 1). The source is fixed (`TOOLSERVER_SOURCE` in `install.sh`, always its
current state) and never asked. From release level 1 on it is a public address and step 7
clones it without credentials -- no deploy key, no token, no password.

**Until then nobody but lingra can install the Toolserver**, and the installer says so at
start, before step 1: steps 1-6 run, step 7 stops. A lingra host gets past it only with its
own key (`/root/.ssh/id_ed25519.pub`) registered as a read-only deploy key of the private
repository. Step 7 has no key handling of its own -- it probes the source the way git will
use it, never prompts, and shows git's reason if it fails.

| Step | Does |
|---|---|
| 1 Base system | update, base packages, snapd off (Ubuntu), locale, time zone, group `onions`, bootstrap user `manager` |
| 2 Firewall | deny in; 22/80/443 in; 587 out; 25/465 out blocked |
| 3 Personal admins | users with password, sudo, SFTP (`internal-sftp`); SSH keys and hardening optional (else later in the Toolserver) |
| 4 Docker | Engine + Compose v2 plugin from the vendor (distribution on SUSE), network `traefik_web` |
| 5 Traefik | `/opt/traefik` from `templates/`, Let's Encrypt staging/production, dashboard auth |
| 6 Hardening | recommended set: mail relay (msmtp), CrowdSec + bouncer, automatic security updates; extras: rkhunter, Docker Scout |
| 7 Toolserver | probes `TOOLSERVER_SOURCE` without prompting, clones it, `toolserver/setup-toolserver.sh` placed into `/opt/<domain>/` and run with `--skip-docker --skip-traefik` (first-login password generated, printed once), then this host's own Verwalter (`toolserver/verwalter.py` to `/opt/<domain>/`, systemd unit `onions-verwalter`) that carries out the interface's jobs, handover |
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

## Which distributions it runs on

Four families, and the installer says which case yours is **before** the first step runs
(`os_support_report`). The table lives in `OS_SUPPORT` in `lib/os.sh`; the entries below
were measured on 2026-09-23 against the vendors' own repositories. The recommended base
for a new machine is `RECOMMENDED_OS` in the same file -- **Ubuntu 24.04 LTS**, the one
combination where nothing at all is substituted. It is a recommendation, not a gate: every
row marked *full* installs just as completely, and the installer only names the
recommendation on a machine that has to substitute something or that nobody has tried.

| Distribution | Docker | Attack blocking | Verdict |
|---|---|---|---|
| Ubuntu 22.04 / 24.04 LTS | vendor | CrowdSec | full |
| Debian 12 (bookworm) | vendor | CrowdSec | full |
| Debian 13 (trixie) | vendor | CrowdSec, **bookworm packages** | full |
| RHEL / Rocky / Alma 8, 9, 10 | vendor | CrowdSec (`el/N`) | full |
| Fedora 41 / 42 | vendor | CrowdSec | full |
| SLES 15 / openSUSE Leap 15.6 | **distribution's own** | **fail2ban** | partial |

The two gaps, and why they are gaps:

- **Debian 13 trixie**: CrowdSec publishes nothing for trixie (its `dists/trixie/Release`
  is a 404). Its bookworm packages are installed instead — the same software, one release
  behind. A vendor follows the distribution's release cycle by months; `apt_repo_dist`
  asks the repository which release it really carries and never takes a newer one.
- **SUSE**: Docker Inc. publishes no SUSE packages at all, so the distribution's own
  `docker` and `docker-compose` are used. CrowdSec's SUSE repository exists but is empty
  (`primary.xml.gz` says `packages="0"`, stamped 2021), and no OBS project carries it
  either — so `fail2ban` from the distribution watches SSH instead. It bans repeated
  failed logins; it has no shared blocklists and no hub, and the installer says so.

A release that is not in the table is **untested**, not refused: the family's commands
run, `pkg_refresh` notices a package source that cannot work and repairs or switches it
off, and the report says plainly that nobody has watched this combination.

## Proving a run

`OS_PROVEN` in `lib/os.sh` lists the distributions this installer ran through completely
on a fresh machine, watched by a person. `OS_SUPPORT` says what *can* work and is measured
against the vendors; `OS_PROVEN` says what *has* worked end to end. It is empty until the
first proof. To add one: fresh VM or snapshot → clone → menu item `a` → every step green →
Toolserver reachable → add the line `[<id>-<version>]="<date> <who/where>"` and commit.
Nothing else counts as proven.
