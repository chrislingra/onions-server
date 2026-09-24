#!/usr/bin/env bash
# lib/help.sh -- the explanation behind every question the installer asks.
# Sourced, never executed. Needs nothing but bash 4 (associative arrays).
#
# Why the texts live HERE and not next to each question (operator 2026-09-23: "jede Auswahl
# muss 2 weitere Optionen erhalten: hilfe und einen schritt zurueck"): an installation is a
# long chain of questions, several of them about things a person meets once a year. An
# explanation that sits in the code of the step is written for whoever edits the step; one
# that sits in a table is written for whoever is answering. One place also means one place to
# correct when an answer's meaning changes.
#
# A key is the checklist key (LANGUAGE, SMTP_PORT, ...) or step.<thing> for a question that
# belongs to one step. Missing key = the prompt still offers help, and says honestly that this
# particular question has none yet.

declare -A HELP_TEXTS=(

[menu]="The eight steps build the host from the empty machine up to the point where the
Toolserver takes over. They are meant to run in order, and each one is idempotent: running it
again repairs rather than breaks, so a step you are unsure about can simply be repeated.
  0  Checklist   every answer this installation needs, changeable at any time
  1  Base        updates, packages, locale, the platform group, the bootstrap user
  2  Firewall    only what has to be reachable stays open
  3  Users       your personal admins, their SSH keys, then password login off
  4  Docker      the engine every service of the platform runs in
  5  Traefik     one address in front of everything, with certificates
  6  Hardening   mail relay, CrowdSec, automatic security updates
  7  Toolserver  the platform itself, from its repository
  8  Finish      checks that you can get in without the bootstrap user, then removes it
'a' (or Enter) continues: it skips every finished step, runs the open ones in order and stops
at the first one that does not finish. After a break-off -- wherever it happened -- the next
start continues there by itself; answers already given are not asked again, only passwords.
A number 1-8 runs that one step, also a finished one, on purpose. The state
lives in /opt/<domain>, the log of this run in the path named at the bottom of every help
text -- a step that went wrong can always be read up there afterwards."

[domain]="The domain decides where everything of this host lives: /opt/<domain> holds the
answers, the state, the logs and the backups. It is also the name the certificates are issued
for later. Enter the domain this server serves, not the machine's host name -- e.g.
example.org. It is asked once and remembered in .instance next to the installer."

[LANGUAGE]="The language of the SYSTEM: it sets the locale (messages, sorting, date format)
for every session on this host. It does not change this installer, which is English
throughout. Unsure? German or English (US) are the two that are used the most here."

[COUNTRY]="The country sets two things at once: the time zone (every log line and every cron
job depends on it) and the console keyboard layout. Pick where the server stands, not where
you sit -- a server in a Frankfurt data centre is Germany even when you administer it from
abroad."

[ADMIN_USER]="Your own Linux login on this machine -- a person, not a service. It gets sudo
and, in step 3, an SSH key. It is NOT the bootstrap user 'manager': that one only exists to
get the machine to this point and is removed again in step 8. Use a short lower-case name,
the same one you use on your other machines if you can."

[KEY_SOURCE]="How that admin gets in over SSH.
  Password now: you log in with a password for the time being, and the Toolserver sets up
    keys and switches password login off later. The simplest road when nothing is prepared.
  I have a public key: you paste the .pub line (or a path to the file). The private half
    stays on your workstation and never touches this server. This is the right answer if you
    already work with SSH keys.
  Generate here: the server makes a key pair and hands the private key out ONCE. You copy it
    to your workstation, and step 3 offers to delete the server's copy. Convenient, but the
    private key does exist on the server for a moment -- which the other two avoid."

[ADMIN_SSH_PUBKEY]="One line, starting with ssh-ed25519 or ssh-rsa, ending in a comment --
that is the PUBLIC half, and it is safe to paste anywhere. You may also give a path to a .pub
file that already lies on this host. A single - means: no key now (then choose 'Password now'
above). Never paste a private key here; a private key starts with -----BEGIN."

[ACME_EMAIL]="Let's Encrypt writes to this address when a certificate is about to expire and
was not renewed -- which is the one warning you really want to arrive. It is not published
anywhere. A mailbox somebody actually reads."

[ACME_MODE]="Production issues real certificates that every browser trusts, but Let's Encrypt
counts the attempts: about five per domain per week, and a broken setup burns them fast.
Staging issues certificates nobody trusts, with practically no limit -- the right choice while
you are still testing whether the domain points here at all. You can switch to production
later and get real ones."

[TRAEFIK_IMAGE]="The container image of the reverse proxy that terminates HTTPS and puts every
service behind one address. traefik:v3 follows the version-3 line and updates with it. Pin a
narrower tag (traefik:v3.1) only if you have a reason to."

[NOTIFICATION_EMAIL]="Where the machine writes when something is wrong: the security-update
report, the rkhunter finding, a failing cron job. This is the address the server talks TO you
with -- give it a mailbox that is read, not a no-reply."

[SENDER_EMAIL]="The address the server's mail comes FROM. It has to be one the relay below
accepts as a sender, otherwise the relay refuses everything -- with most providers that means
an address of the same domain as the relay account."

[SMTP_SERVER]="The mail relay that carries the server's mail out. A server that sends directly
lands in spam folders or is blocked outright, so it hands its mail to a provider instead. The
host name of your provider's submission service, e.g. smtp.ionos.de."

[SMTP_PORT]="587 is submission with STARTTLS and is what the installer configures. 465 is the
older implicit-TLS port -- use it only if your provider requires it. Never 25: that is
server-to-server and blocked on most networks."

[SMTP_USER]="The login name at the relay, usually the full mailbox address. The PASSWORD is
not asked here: it is asked in step 6 at the moment the relay is written, and it goes straight
into /etc/msmtprc (root only, mode 600). It is never stored in the checklist."

[TOOLSERVER_GIT]="Where the Toolserver itself is cloned from in step 7. A public https address
needs nothing -- no token, no key. A private repository needs an ssh address (git@github.com:
...) and this host's key registered there as a deploy key; step 7 tells you the key to
register when that is the case."

[TOOLSERVER_REF]="The branch or tag of the Toolserver to install. master is the current state.
Name a tag instead when you want a fixed, known version that does not move under you."

[step10.password]="The first password of the bootstrap user. It expires immediately -- the
first login has to change it -- but it has to reach you in the first place.
  I type it myself: you choose it, so there is nothing to copy off the screen. This is the
    answer when you are on a console that cannot copy (KVM, rescue, serial).
  Generate one: the installer makes a random one, shows it, and writes it to a root-only file
    under the instance directory. You can read that file later, fetch it with scp, or have it
    mailed once the relay of step 6 exists.
There is deliberately no fixed default password: this installer is public, so a password
written into it would be a published password on every host installed from it."

[step10.snapd]="snapd is Ubuntu's second package system. Nothing the platform installs uses
it, and it keeps a daemon and several mounts alive for nothing. Removing it is the tidy
answer on a server; keep it only if you know something of yours needs a snap."

[step10.mailpw]="Send the generated password to the notification address as well. Useful
exactly when you cannot copy from this screen. Mail is not confidential in transit -- but this
password expires at the first login, and the alternative is typing 16 random characters off a
console by hand."

[step30.another]="Add a further personal admin. Every person who works on this machine gets
their own login -- shared accounts make it impossible to tell later who did what. Answer no
when you are the only one."

[step30.sudo]="sudo lets this user become root. Give it to people who administer the machine.
A user without sudo can still log in and read what their groups allow."

[step30.keylogin]="Answered honestly, this is the safety catch before step 3 switches password
login off. Open a SECOND terminal now, log in with the key, and only then answer yes. If you
answer yes without having tried, and the key is wrong, the next disconnect locks you out of
your own server."

[step30.password]="A password for this user even though the login is by key: sudo asks for it,
and without one sudo cannot be used at all. It is not a way in -- SSH password login gets
switched off."

[step30.delkey]="The private key was generated on this server and you have copied it to your
workstation. Deleting the server's copy is what makes it a private key again. Say no only if
you have not actually copied it yet."

[step50.rewrite]="Traefik is already configured here. Rewriting replaces traefik.yml and
docker-compose.yml with freshly generated ones -- any change you made in them by hand is
gone (the old files are copied to the instance's backup directory first). Say no to keep what
is there."

[step60.part]="Which part of the hardening to run.
  Recommended set: the three that belong on every host -- mail relay (so the machine can
    report), CrowdSec (detects and blocks attacks), automatic security updates.
  The single entries do exactly one of them, for repairing or for adding later.
  rkhunter and Docker Scout are extras: useful, but they mail findings you have to read.
Each part is idempotent -- running it again repairs rather than breaks."

[step60.testmail]="Sends one mail through the freshly written relay. It is the only way to
learn whether the credentials are right, and it costs nothing. If it never arrives, look at
/var/log/msmtp.log."

[step60.rkhunter]="The first rkhunter scan takes several minutes and holds the installation
while it runs. It changes nothing -- it only looks. Skipping it is fine: the daily cron job
runs it anyway and mails what it finds."

[step80.remove]="Removes the bootstrap user 'manager' and its home directory. It is the point
of no return of the installation: from here on your personal admin is the only way in, which
is why step 8 refuses unless it has checked that this actually works. Sessions of that user
end immediately."
)

# help_show KEY PROMPT -- prints the explanation for a question, then the two standing lines
# every question shares. Never fails: a missing text says so instead of pretending.
help_show() {
    local key="${1:-}" prompt="${2:-}" text="${HELP_TEXTS[${key:-__none__}]:-}"
    echo
    echo "  ------------------------------------------------------------------"
    if [[ -n "$text" ]]; then
        printf '%s\n' "$text" | sed 's/^/  /'
    else
        echo "  ${prompt}"
        echo
        echo "  There is no written explanation for this question yet. What you enter"
        echo "  is saved and can be changed afterwards: the checklist (entry 0 in the"
        echo "  main menu) shows every answer and lets you correct it, and every step"
        echo "  can be run again."
    fi
    echo
    echo "  h = this help    b = one step back    the log of this run: ${LOG_FILE:-<not open yet>}"
    echo "  ------------------------------------------------------------------"
    echo
}
