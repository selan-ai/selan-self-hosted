---
name: self-host-server
description: Use when someone wants Selan's self-hosted stack (Own proxy: the proxy, the MCP gateway, selan-keys and their vault) on a server of theirs, such as a Hostinger VPS, from nothing to a request served by it. Checks the host over SSH, sets up their VPN (theirs, Tailscale, WireGuard, or an SSH tunnel for a trial), the DNS names and TLS (DNS-01, Let's Encrypt by hand, or their CA), shows the tag, compose.yaml and install.sh, has the person run Add server's line, moves the keys Selan holds, turns it on and ends with one real request.
allowed-tools: Bash Read WebFetch mcp__hostinger__authenticate mcp__hostinger__complete_authentication
---

# Selan's Own proxy on a server, over SSH

The server runs `install.sh` from a clone of github.com/selan-ai/selan-self-hosted at a release tag,
nothing rewritten and nothing served by Selan. Installing and every upgrade run code Selan wrote: say so
plainly, and that the protection is that they choose the tag and can read it first. Inputs: the host (or
a Hostinger VPS to find), an SSH user with sudo, and the company's domain. The names are `gw.<domain>`
(proxy), `mcp.<domain>` (gateway) and `keys.<domain>` (selan-keys) unless the person says otherwise.
The same steps for people are https://selan.ai/docs/self-hosted; the full detail is the repository's README.

**Claude never sees a registration token, the DNS token or the vault's material.** Never `cat`, `grep` or
copy `/opt/selan/.env`, `/opt/selan/openbao-init.json` or a TLS private key, never run a command that
carries a token, and never ask the person to paste one into the chat. Checking a file is `stat` and `wc -c`.

1. **Find the server.** Given a host, use it. For a Hostinger VPS with the Hostinger MCP server
   connected (authenticate it if it asks), list the virtual machines and show each one's id, hostname,
   plan, state and IP. Without it, `GET https://developers.hostinger.com/api/vps/v1/virtual-machines`
   with `Authorization: Bearer <API token from hPanel>`, which the person exports as `HOSTINGER_API_TOKEN`
   themselves. If it is stopped, start it and wait; never reinstall or recreate it.
2. **Check the host** over `ssh USER@HOST`: `sudo -n true` works; `/etc/os-release` is Debian or Ubuntu
   (other systems need Docker with the compose plugin already); 1 GB of memory or more; `git --version`
   (else `sudo apt-get install -y git`); nothing listens on port 443 (`sudo ss -ltnp 'sport = :443'`).
3. **The VPN.** The proxy listens on a private address only; `install.sh` refuses a public one. Look for
   one on a `tailscale*`, `wg*`, `tun*`, `zt*` or `nebula*` interface (`ip -4 -o addr show`), in 10/8,
   172.16/12, 192.168/16 or 100.64/10. Found: that is `SELAN_BIND_ADDR`. None: ask which of these.
   - **Tailscale**, for a team. After a yes, `curl -fsSL https://tailscale.com/install.sh | sh` on the
     server; `sudo tailscale up --hostname selan-gw` prints a login link and waits: pass it on, and the
     person opens it signed in to their tailnet. `tailscale ip -4` is the address. In Tailscale's admin
     console they turn off key expiry for this machine, or it drops off in 180 days. Each person installs
     Tailscale and signs in to the same tailnet.
   - **WireGuard**, with no outside service: `wg0` on the server with an address in 10/8, one peer per
     person's machine, and UDP 51820 open in the firewall. More hands-on; the person keeps the peer keys.
   - **An SSH tunnel**, for one person trying it: `SELAN_BIND_ADDR=127.0.0.1`. Once the stack is up, a
     tunnel from their machine carries 443; binding it needs root, so on macOS run it through `osascript`
     (the person types their password in the dialog), and never with `nohup`, which fails there with
     "can't detach from console". On Linux, `sudo ssh -N -L …` in a terminal of its own.
     ```sh
     osascript -e 'do shell script "ssh -N -L 127.0.0.1:443:127.0.0.1:443 -i /Users/ME/.ssh/id_ed25519 -o UserKnownHostsFile=/Users/ME/.ssh/known_hosts USER@HOST >/dev/null 2>&1 &" with administrator privileges'
     ```
     Nobody else reaches it. For a team later: Tailscale, the A records at its address, and `install.sh`
     again with that `SELAN_BIND_ADDR`.
4. **DNS.** `gw.`, `mcp.` and `keys.<domain>` are A records at that address (`127.0.0.1` for the tunnel),
   added by whoever holds the zone. A private address in public DNS is fine; a public one is said plainly
   before going on. Check with
   `curl -s -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=gw.<domain>&type=A'`.
5. **Show before running.** The tag is the one Add server's line names, which Selan moves only once a
   release passes its own test (pressing it again later gives a fresh token); the newest release otherwise:
   `git ls-remote --tags --refs https://github.com/selan-ai/selan-self-hosted | sort -t/ -k3 -V | tail -n 1`.
   Print it, the full `compose.yaml`, `install.sh` and `signers.txt` at that tag
   (`https://raw.githubusercontent.com/selan-ai/selan-self-hosted/<tag>/<file>`), and what it writes:
   `/opt/selan` (root only), Docker volumes `selan_*`, `/usr/local/bin/selan-keys` from v0.2.5, and Docker
   itself if missing. If `compose.yaml` still has `${SELAN_PROXY_IMAGE:?…}` (or the gateway's or Caddy's),
   that image has no release pinned yet: say so and stop. Wait for a yes.
6. **TLS: ask which.** The names are private, so Let's Encrypt's HTTP-01 and TLS-ALPN cannot work:
   - `SELAN_TLS=dns`: Caddy gets Let's Encrypt certificates over DNS-01 itself, renewing them too. Ask for
     the provider (bunny, cloudflare, digitalocean, duckdns, gandi, hetzner, ionos, linode or vultr) and
     tell them to make a token limited to that zone's TXT records; they give it to `install.sh` when it asks
     without showing it, never in this chat. A token that edits the whole zone is too much to leave on a
     server (Cloudflare's cannot be narrowed to TXT records): then use Let's Encrypt by hand.
   - `SELAN_TLS=files` with **Let's Encrypt by hand**: acme.sh on the server in manual DNS mode, so no DNS
     token is ever on it. As root (`sudo -i`), after a yes:
     ```sh
     curl -fsSL https://get.acme.sh | sh -s email=EMAIL
     ~/.acme.sh/acme.sh --issue --dns --server letsencrypt -d gw.DOMAIN -d mcp.DOMAIN -d keys.DOMAIN \
       --yes-I-know-dns-manual-mode-enough-go-ahead-please
     ```
     It prints one `_acme-challenge` TXT record per name; whoever holds DNS adds them (check with the query
     above, `type=TXT`), then the same command with `--renew` in place of `--issue` gets the certificate.
     `SELAN_TLS_CERT` and `SELAN_TLS_KEY` are the full chain and key paths it prints
     (`/root/.acme.sh/gw.DOMAIN_ecc/fullchain.cer` and `gw.DOMAIN.key`). It lasts 90 days and does not
     renew itself: see step 11.
   - `SELAN_TLS=files` with **their own CA**: a certificate for the three names, copied onto the server.
     Their people's machines must trust that CA.
7. **The person runs the install.** The line is in Selan under Settings › General › Own proxy, Configure,
   then Add server, for owners; a new company can press "Skip: I'll run Selan on my own servers" at the
   bottom of onboarding, which goes straight there. Its token lasts an hour, so they press it only now. In
   their own terminal and SSH session, the settings first, then the line as copied, with every exported
   setting added to `--preserve-env`, or sudo drops it:
   ```sh
   ssh -t USER@HOST
   export SELAN_PROXY_HOST=gw.DOMAIN SELAN_BIND_ADDR=ADDRESS SELAN_TLS=files SELAN_TLS_CERT=PATH SELAN_TLS_KEY=PATH SELAN_VAULT=openbao
   export SELAN_REGISTRATION_TOKEN=selanreg_…; { [ -d /opt/selan ] || sudo git clone --depth 1 --branch TAG https://github.com/selan-ai/selan-self-hosted /opt/selan; } && sudo git -C /opt/selan fetch -q --depth 1 origin tag TAG && sudo git -C /opt/selan checkout -q TAG && sudo --preserve-env=SELAN_REGISTRATION_TOKEN,SELAN_PROXY_HOST,SELAN_BIND_ADDR,SELAN_TLS,SELAN_TLS_CERT,SELAN_TLS_KEY,SELAN_VAULT /opt/selan/install.sh
   ```
   With `dns`, `SELAN_DNS_PROVIDER` in place of the two paths. Without a terminal `install.sh` asks
   nothing, and a missing setting stops it naming the variable; `SELAN_VAULT` is the one people miss:
   `openbao`, or `own` with `VAULT_ADDR` and selan-keys' AppRole (README, "Your own Vault"). With OpenBao it
   prints the file holding the unseal key and root token: they copy it off the server and keep it; Claude
   has not read it. Wait until they say it finished and ask for its last lines (never a token). A
   `signed:` line per image means each cosign signature was checked.
8. **Check it** over SSH: `sudo docker compose --project-directory /opt/selan ps` shows proxy, gateway,
   keys, postgres, caddy (and openbao, unseal) running; `stat -c '%U %a' /opt/selan/.env
   /opt/selan/openbao-init.json` is `root 600`; `curl -sk --resolve gw.DOMAIN:443:ADDRESS
   https://gw.DOMAIN/readyz` on the server answers 200. From this machine, off the VPN, a TCP connect to
   the server's public IP on 443, 8080 and 8200 must fail. If anything answers publicly, say it first and
   help close it (on Hostinger: hPanel › VPS › Firewall, or the API's firewall rules). Start the tunnel now
   if that is the VPN.
9. **Turn it on.** Settings › General › Own proxy shows the proxy, the keys service and the gateway Healthy. Keys
   Selan already holds (a Claude account added at onboarding, say) keep "Use my own proxy" off until they
   move: after a yes, `sudo selan-keys import` on the server (before v0.2.5,
   `sudo docker compose --project-directory /opt/selan exec -T keys selan-keys import`), which opens ten
   minutes for Selan to hand each key over, sealed to that server. A key it cannot move, such as Google
   Workspace or Vertex, is removed first, as the dialog says; afterwards the person changes each moved key
   at its provider. Then they turn on "Use my own proxy".
10. **One real request**, from a machine on the VPN (or through the tunnel), run by the person with a
    company API token from Settings › API tokens (`-k` only with `SELAN_TLS=internal`):
    ```sh
    read -rs T && printf 'Authorization: Bearer %s\n' "$T" | curl -sS https://gw.DOMAIN/v1/messages \
      -H @- -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"claude-haiku-5-5","max_tokens":20,"messages":[{"role":"user","content":"Reply with ok"}]}'; unset T
    ```
    An answer with `"content"` is the proof. Then Logs and Usage in Selan show the request, and
    `sudo docker compose --project-directory /opt/selan logs --since 10m keys` shows `outcome: served` with
    the key's name. An error names the failing part; fix that part, never by reading the vault's files.
11. **Day to day.** People on the VPN use Selan as before: `selan login` into that company, or an API token
    as `SELAN_TOKEN=… selan claude`. A certificate by hand is renewed before its 90 days: `--renew` prints
    new TXT values, they go into DNS, `--renew` again, then
    `sudo install -m 0644 FULLCHAIN /opt/selan/certs/fullchain.pem && sudo install -m 0600 KEY
    /opt/selan/certs/privkey.pem && sudo docker compose --project-directory /opt/selan restart caddy`.
    Suggest a reminder at 60 days.
12. **Upgrade.** New code Selan wrote again, from a tag they choose: say so.
    - Where it is: `sudo git -C /opt/selan describe --tags`, and each part's version in Settings › General ›
      Own proxy. Where to go: the tag Add server's line names now (step 5).
    - Show what changes and wait for a yes: `sudo git -C /opt/selan fetch -q --depth 1 origin tag NEW &&
      sudo git -C /opt/selan diff HEAD NEW -- compose.yaml install.sh signers.txt`.
    - The person runs Add server's line again: it checks out the new tag in `/opt/selan`, and `install.sh`
      keeps `.env`, checks each image's signature again and starts the new images; parts already
      registered ignore the new token. Or, with no token: `sudo git -C /opt/selan checkout -q NEW &&
      sudo /opt/selan/install.sh`. Either way the settings come from `.env`; none is exported again.
    - Then step 8's checks, the three parts Healthy on the new version, and step 10's request and
      `outcome: served`. A certificate by hand still needs step 11's renewal.
    - Back: the same with the old tag, fetched first (the clone is shallow).
13. **Remove it.** `sudo docker compose --project-directory /opt/selan --profile openbao down -v` deletes
    the vault's data with every key in it: say so and wait for a yes. Then delete `/opt/selan` and
    `/usr/local/bin/selan-keys`, stop a tunnel (`sudo pkill -f 443:127.0.0.1:443`), and remove the server
    under Settings › General › Own proxy. Deleting the VPS is the person's decision, in hPanel.
