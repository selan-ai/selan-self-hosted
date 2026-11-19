---
name: self-host-local
description: Use when someone wants Selan's self-hosted stack (Own proxy: the proxy, the MCP gateway, selan-keys, OpenBao and Caddy) running on this machine with Docker, to try it or as a small server. Follows the self-host-server skill's steps with this machine's differences; the person runs Add server's line with the registration token themselves.
allowed-tools: Bash Read WebFetch
---

# Selan's Own proxy on this machine

The same stack and the same `install.sh` as on a server, so this skill follows the **self-host-server**
skill (`../self-host-server/SKILL.md`, beside this one). Read it first and keep its rules: Claude never
sees a registration token, `.env`, `openbao-init.json` or a private key, and the person runs the line.
Its steps 5 to 13, upgrade included, hold here, run locally instead of over SSH, with these differences.
The same steps for people are https://selan.ai/docs/self-hosted.

1. **Instead of its steps 1 to 4.** `docker compose version` must work (Docker Desktop on macOS, Docker
   Engine with the compose plugin on Linux; `install.sh` installs it only on Debian or Ubuntu), and nothing
   listens on port 443 here. For a trial no VPN or DNS is needed: the proxy listens on `127.0.0.1`, and
   `gw.<something>.localhost` resolves there by itself. For a name other people will use, this machine
   needs a VPN address and A records, as its steps 3 and 4 say.
2. **TLS (its step 6).** For a `.localhost` trial, `SELAN_TLS=internal` (Caddy's own CA) is enough; every
   client then has to trust that CA, or use `-k`. A real name takes step 6 as written.
3. **Where it is cloned (its step 7).** `/opt/selan` on Linux. On macOS Docker Desktop shares folders
   under `/Users`, so the person replaces every `/opt/selan` in Add server's line with one there; no
   `selan-keys` command is installed then, and step 9's `docker compose exec` form names that folder.
   The settings, each also added to `--preserve-env`:
   ```sh
   export SELAN_PROXY_HOST=gw.example.localhost SELAN_BIND_ADDR=127.0.0.1 SELAN_TLS=internal SELAN_VAULT=openbao SELAN_OUTSIDE_CHECK=no
   ```
   `SELAN_OUTSIDE_CHECK=no` skips the check from the internet, which on a laptop behind NAT has nothing
   to find. They keep a copy of the OpenBao file it prints off this machine.
4. **Checks (its step 8)** are local, in the folder it was cloned to (`stat -f '%Su %Lp'` on macOS), and
   `curl -sk --resolve gw.example.localhost:443:127.0.0.1 https://gw.example.localhost/readyz` answers 200.
5. **Turning it on (its step 9)** sends the whole company's requests to this machine: on a laptop, only
   for a trial company or a company of one.
6. **The request (its step 10)** runs on this machine, to `https://gw.example.localhost/v1/messages`,
   with `-k` under `internal`.
