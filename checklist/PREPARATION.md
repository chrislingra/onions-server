# Preparation checklist

Everything to have ready **before** the first command on the new server. The installer
asks for each value (menu item 0) and stores the answers in `/opt/<domain>/site.env`;
passwords are never stored -- have them at hand.

1. **Domain** -- the name the server serves (e.g. `example.org`). Asked once at the first
   start; the instance directory `/opt/<domain>` is created from it.
2. **DNS** -- A records (and AAAA if used) pointing at the server's public IP:
   `traefik.<domain>` (dashboard), `tools.<domain>` (Toolserver), `nextcloud.<domain>` and
   `office.<domain>` (Nextcloud and Collabora, set up by step 7), plus one per service
   that will be added later (`gpt.`, `search.`, ...). Let's Encrypt validates over HTTP,
   so the names must resolve before Traefik asks for them; step 7 checks its three names
   first and stops, before installing anything, while one has no record.
3. **Ports** -- 22, 80 and 443 reachable from the internet (provider firewall / cloud
   security group). The installer's own firewall opens exactly these.
4. **A password for the bootstrap user, or nothing at all** -- `manager` is created by
   step 1, and the step asks how you want its first password: type it yourself (at least
   10 characters), or let it be generated. A generated one is never only on the screen --
   it is also written to `<state>/bootstrap-password.txt`, readable by root alone, and
   can be sent by mail. On a KVM console or a serial line there is nothing to copy with,
   so do not rely on reading it off the screen. It must be changed at the first login,
   and the user disappears in step 8.
5. **Personal admins** -- for every person who will administer the host: the Linux user
   name and a password. SSH keys and the sshd hardening are **not** needed for the base
   installation: the default is "password now, SSH later in the Toolserver". Who has a
   key pair (`ssh-keygen -t ed25519`, or PuTTYgen) can paste the public half; who wants
   one can let step 3 generate it (shown once, fetchable with WinSCP as `manager`,
   deleted from the server after the proven login).
6. **Let's Encrypt** -- the e-mail for expiry notices, and whether to start with
   `staging` (test certificates, no rate limits) or `production`.
7. **Access to the Toolserver's source (step 7)** -- nothing to prepare once the source is
   published (release level 1): step 7 clones it without credentials. Until then only a
   lingra host gets past step 7, with its own key (`/root/.ssh/id_ed25519.pub`) registered
   as a read-only deploy key of the private repository; the installer says so at start,
   before step 1, and shows the key.
8. **Mail relay** -- SMTP host, port (587), user name and password of the account the
   server sends from (e.g. an Ionos mailbox), the sender address and the address that
   receives notifications.
9. **Language and country** -- two choices from a list; they set locale, time zone and keyboard.
10. **Toolserver secrets** -- nothing to prepare: `setup-toolserver.sh` generates them
    into `/opt/toolserver/secrets/`. The platform has one superadmin, `admin`, the same in
    the Toolserver and in Nextcloud; the installer shows its password at the end of every
    run (menu item `n` repeats it).

Order on the machine (README has the commands): install `git` → clone this
repository to `/opt/onions-server` → `sudo bash install.sh` → domain → menu item `a`
(all steps), or 1-8 one by one.
