# Preparation checklist

Everything to have ready **before** the first command on the new server. The installer
asks for each value (menu item 0) and stores the answers in `/opt/<domain>/site.env`;
passwords are never stored -- have them at hand.

1. **Domain** -- the name the server serves (e.g. `example.org`). Asked once at the first
   start; the instance directory `/opt/<domain>` is created from it.
2. **DNS** -- A records (and AAAA if used) pointing at the server's public IP:
   `traefik.<domain>` (dashboard), `tools.<domain>` (Toolserver), plus one per service
   that will be added later (`gpt.`, `search.`, `cloud.`, ...). Let's Encrypt validates
   over HTTP, so the names must resolve before Traefik starts.
3. **Ports** -- 22, 80 and 443 reachable from the internet (provider firewall / cloud
   security group). The installer's own firewall opens exactly these.
4. **Nothing for the bootstrap user** -- `manager` is created by step 1 with a one-time
   password shown on the console (write it down, it must be changed at first login).
   It is the working login of the delivered state and disappears in step 8.
5. **Personal admins** -- for every person who will administer the host: the Linux user
   name and an **SSH key pair generated on their workstation** (`ssh-keygen -t ed25519`).
   The public key (`.pub`, one line) is what the installer asks for; the private key
   stays with the person. **No key, no user**: step 3 turns password login off, so a
   user without a key would be locked out. Optional: a password, so `sudo` can ask for it.
6. **Let's Encrypt** -- the e-mail for expiry notices, and whether to start with
   `staging` (test certificates, no rate limits) or `production`.
7. **GitHub deploy key** -- `onions-server` is public and clones without a key. The
   Toolserver repository is private: step 7 generates the machine's key, shows it, and
   waits until it is registered under *onions-toolserver > Settings > Deploy keys*
   (read-only). Have GitHub access ready when you reach that step.
8. **Mail relay** -- SMTP host, port (587), user name and password of the account the
   server sends from (e.g. an Ionos mailbox), the sender address and the address that
   receives notifications.
9. **Locale, keymap, time zone** -- defaults `de_DE.UTF-8`, `de`, `Europe/Berlin`.
10. **Toolserver secrets** -- nothing to prepare: `setup-toolserver.sh` generates them
    into `/opt/toolserver/secrets/`. The menu password is printed once at the end of
    step 7; write it down.

Order on the machine (README has the commands): install `git` → clone this
repository to `/opt/onions-server` → `sudo bash install.sh` → domain → menu item `a`
(all steps), or 1-8 one by one.
