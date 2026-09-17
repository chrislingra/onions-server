# Preparation checklist

Everything to have ready **before** the first command on the new server. The installer
asks for each value (menu item 0) and stores the answers in `site.env`; passwords are
never stored -- have them at hand.

1. **Domain** -- the name the server serves (e.g. `example.org`). The checkout directory
   is `/opt/<domain>`; the installer reads the domain from it.
2. **DNS** -- A records (and AAAA if used) pointing at the server's public IP:
   `traefik.<domain>` (dashboard), `tools.<domain>` (Toolserver), plus one per service
   that will be added later (`gpt.`, `search.`, `cloud.`, ...). Let's Encrypt validates
   over HTTP, so the names must resolve before Traefik starts.
3. **Ports** -- 22, 80 and 443 reachable from the internet (provider firewall / cloud
   security group). The installer's own firewall opens exactly these.
4. **Admin user** -- the Linux user name that will own the platform (default `manager`)
   and its password (asked once, hidden).
5. **SSH key pair** -- generated on the workstation (`ssh-keygen -t ed25519`). The public
   key (`.pub`, one line) goes into the checklist; the private key stays with you. The
   hardening step turns password login off -- only after you proved the key login in a
   second session.
6. **Let's Encrypt** -- the e-mail for expiry notices, and whether to start with
   `staging` (test certificates, no rate limits) or `production`.
7. **GitHub deploy key** -- the Toolserver repository is private. Step 7 generates the
   server's own key and shows it; register it under *repository > Settings > Deploy keys*
   (read-only). Have GitHub access ready when you reach that step.
8. **Mail relay** -- SMTP host, port (587), user name and password of the account the
   server sends from (e.g. an Ionos mailbox), the sender address and the address that
   receives notifications.
9. **Locale, keymap, time zone** -- defaults `de_DE.UTF-8`, `de`, `Europe/Berlin`.
10. **Toolserver secrets** -- nothing to prepare: `setup-toolserver.sh` generates them
    into `/opt/toolserver/secrets/`. The menu password is printed once at the end of
    step 7; write it down.

Order on the machine (README has the commands): install `git` → clone this repository
to `/opt/<domain>` → `sudo bash install.sh` → menu item 8 (all steps), or 1-7 one by one.
