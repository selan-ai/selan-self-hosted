---
name: self-host-server
description: Use when someone wants Selan's self-hosted stack (Own servers: the proxy, the MCP gateway and their vault) on a server of theirs, such as a Hostinger VPS, given a host, an SSH user and their domain. Checks the host over SSH, shows the release tag, compose.yaml and install.sh, asks how TLS is done (DNS-01 or their own CA), has the person run Add server's install line, checks nothing answers from the internet, and ends with one real request through the proxy.
allowed-tools: Bash Read WebFetch mcp__hostinger__authenticate mcp__hostinger__complete_authentication
---

# Selan's own-server stack on a server, over SSH

The server runs `install.sh` from a clone of github.com/selan-ai/selan-self-hosted at a release tag,
nothing rewritten and nothing served by Selan. Installing and every upgrade run code Selan wrote: say so
plainly, and that the protection is that they choose the tag and can read it first. Inputs: the host (or a Hostinger VPS to find), an SSH user with sudo,
and the company's domain. The proxy is `gw.<domain>` and the gateway `mcp.<domain>` unless the
person says otherwise.

**Claude never sees the registration token, the DNS token or the vault's material.** Never `cat`, `grep` or copy
`/opt/selan/.env` or `/opt/selan/openbao-init.json`, never run a command that carries the token, and
never ask the person to paste it into the chat. Checking a file is `stat` and `wc -c` only.

1. **Find the server.** Given a host, use it. For a Hostinger VPS with the Hostinger MCP server
   connected (authenticate it if it asks), list the virtual machines and show each one's id,
   hostname, plan, state and IP. Without it, `GET https://developers.hostinger.com/api/vps/v1/virtual-machines`
   with `Authorization: Bearer <API token from hPanel>`, which the person exports as
   `HOSTINGER_API_TOKEN` themselves. If it is stopped, start it and wait; never reinstall or recreate it.
2. **Check the host** over `ssh USER@HOST`:
   - `sudo -n true` works, and `/etc/os-release` is Debian or Ubuntu (other systems need Docker with
     the compose plugin already installed), with 1 GB of memory or more;
   - the VPN: an address on a `tailscale*`, `wg*`, `tun*`, `zt*` or `nebula*` interface
     (`ip -4 -o addr show`), in 10/8, 172.16/12, 192.168/16 or 100.64/10. No VPN, no install: their
     VPN is theirs to set up (README, "VPN required"); say so and stop;
   - DNS: `gw.<domain>` and `mcp.<domain>` should resolve to that VPN address for the people who use
     them, and not to a public address in public DNS
     (`curl -s -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=gw.<domain>&type=A'`).
     A public answer is said plainly before going on;
   - port 443 on the VPN address is free.
3. **Show before running.** The tag is the one in Add server's line (the newest release otherwise:
   `git ls-remote --tags --refs https://github.com/selan-ai/selan-self-hosted | sort -t/ -k3 -V | tail -n 1`).
   Print it, the full `compose.yaml`, `install.sh` and `signers.txt` at that tag
   (`https://raw.githubusercontent.com/selan-ai/selan-self-hosted/<tag>/<file>`), and what it
   writes: `/opt/selan` (root only), Docker volumes `selan_*`, `selan-unseal.service`, and Docker
   itself if missing. If `compose.yaml` still has `${SELAN_PROXY_IMAGE:?…}` (or the gateway's or
   Caddy's), that image has no release pinned yet: say so and stop. Wait for a yes.
4. **TLS: ask which.** The names are private, so Let's Encrypt's HTTP-01 and TLS-ALPN cannot work:
   - `SELAN_TLS=dns`: Let's Encrypt over DNS-01. Ask for the DNS provider (bunny, cloudflare,
     digitalocean, duckdns, gandi, hetzner, ionos, linode or vultr) and tell them to make an API token
     limited to editing that zone's TXT records. They give it to `install.sh` themselves, when it asks
     without showing it, never in this chat. The zone must be in public DNS; the A records need not be.
   - `SELAN_TLS=files`: their own CA's certificate for both names. They copy the chain and key onto
     the server and give their paths when `install.sh` asks (or as `SELAN_TLS_CERT`, `SELAN_TLS_KEY`).
     Their people's machines must trust that CA.
   Any other DNS provider means `files`.
5. **The person runs the install.** Their own terminal, their own SSH session, Add server's line with
   the token pasted in by them, and the settings before it:
   ```sh
   ssh -t USER@HOST
   export SELAN_PROXY_HOST=gw.DOMAIN SELAN_BIND_ADDR=VPN_ADDRESS SELAN_TLS=dns SELAN_DNS_PROVIDER=PROVIDER
   export SELAN_REGISTRATION_TOKEN=selanreg_…; git clone --depth 1 --branch TAG https://github.com/selan-ai/selan-self-hosted /opt/selan && sudo --preserve-env=SELAN_REGISTRATION_TOKEN,SELAN_PROXY_HOST,SELAN_BIND_ADDR,SELAN_TLS,SELAN_DNS_PROVIDER /opt/selan/install.sh
   ```
   As a user that cannot write `/opt`, `sudo install -d -o "$USER" /opt/selan` first. Add `VAULT_ADDR`
   (and its AppRole ids in `/opt/selan/.env`, README "Your own Vault") when they have a Vault. Without
   one, OpenBao is initialised and the line prints the file holding its unseal key and root token; tell
   them to copy it off the server and keep it, and that Claude has not read it. Wait until they say it
   finished, and ask for the last lines it printed (never a token). A `signed:` line per image means
   each cosign signature was checked.
6. **Check it** over SSH: `sudo docker compose --project-directory /opt/selan ps` shows proxy,
   gateway, caddy (and openbao) running; `stat -c '%U %a' /opt/selan/.env /opt/selan/openbao-init.json`
   is `root 600`; `curl -sk --resolve gw.DOMAIN:443:VPN_ADDRESS https://gw.DOMAIN/readyz` on the
   server answers 200. Then the check from outside, from this machine as well when it is off the VPN:
   `curl -sk --max-time 5 https://gw.DOMAIN/readyz` and a TCP connect to the server's public IP on
   443, 8080 and 8200 must fail. If anything answers publicly, say it plainly, first, and help close
   it (on Hostinger: hPanel › VPS › Firewall, or the API's firewall rules) before anything else.
7. **One real request through the proxy**, from a machine on the VPN, run by the person since it
   needs their token (`-k` only with `SELAN_TLS=internal`):
   ```sh
   read -rs T && printf 'Authorization: Bearer %s\n' "$T" | curl -sS https://gw.DOMAIN/anthropic/v1/messages \
     -H @- -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
     -d '{"model":"claude-haiku-5-5","max_tokens":20,"messages":[{"role":"user","content":"Reply with ok"}]}'; unset T
   ```
   An answer with `"content"` is the proof; the request shows in control's usage for the company.
   An error names the failing part; fix that part.
8. **Remove it.** `sudo docker compose --project-directory /opt/selan --profile openbao down -v` deletes the
   vault's data with every key in it: say so and wait for a yes. Then
   `sudo systemctl disable selan-unseal`, delete `/etc/systemd/system/selan-unseal.service` and
   `/opt/selan`, and remove the server under Settings › Own servers. Deleting the VPS is the person's
   decision, in hPanel.
