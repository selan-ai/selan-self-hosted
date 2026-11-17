---
name: self-host-local
description: Use when someone wants Selan's self-hosted stack (Own servers: the proxy, the MCP gateway, OpenBao and Caddy) running on this machine with Docker, to try it or as a small server. Runs the repository's own install.sh; the person runs the line with the registration token themselves.
allowed-tools: Bash Read WebFetch
---

# Selan's own-server stack on this machine

The stack is `compose.yaml` in github.com/selan-ai/selan-self-hosted, brought up by its own
`install.sh`. This skill never repeats their steps; it checks the machine, shows what will run,
and has the person run the one line. Claude never sees the registration token, `.env` or
`openbao-init.json`: never `cat` them, and never put the token in a command you run.

1. **Check the machine.** `docker compose version` must work (Docker Desktop on macOS, Docker
   Engine with the compose plugin on Linux; `install.sh` installs it only on Debian or Ubuntu).
   Port 443 on the address it will listen on must be free.
2. **Pick the commit and show it.** Read the commit selan.ai serves:
   `curl -fsSL https://selan.ai/self-hosted/install.sh | sed -n 's/^PINNED_COMMIT="\(.*\)"$/\1/p'`.
   Print it, then the full `compose.yaml` and `install.sh` at that commit
   (`https://raw.githubusercontent.com/selan-ai/selan-self-hosted/<commit>/<file>`). If
   `compose.yaml` still has `${SELAN_PROXY_IMAGE:?…}`, no release is pinned yet: say so and stop.
   Say what it writes: `/opt/selan` (on macOS, a folder under `/Users` that Docker Desktop shares,
   given as `SELAN_DIR`), Docker volumes named `selan_*`, and nothing else. Wait for a yes.
3. **The names.** On this machine the proxy listens on `127.0.0.1` unless the person gives a VPN
   address. Its name is the address they entered under Settings › Own servers › Add server; for a
   trial, `gw.<something>.localhost` resolves to `127.0.0.1` with no DNS change. The gateway
   defaults to `mcp.` beside it.
4. **The person runs the line.** In their own terminal, with the token from Add server pasted
   into the first line themselves (on macOS add `SELAN_DIR` to both lists):
   ```sh
   export SELAN_REGISTRATION_TOKEN=selanreg_... SELAN_PROXY_HOST=gw.example.localhost SELAN_BIND_ADDR=127.0.0.1
   curl -fsSL https://selan.ai/self-hosted/install.sh | sudo --preserve-env=SELAN_REGISTRATION_TOKEN,SELAN_PROXY_HOST,SELAN_BIND_ADDR bash
   ```
   It prints where OpenBao's unseal key and root token are (root only); tell them to keep a copy
   off this machine. `SELAN_OUTSIDE_CHECK=no` (added to both lists) skips the check from the
   internet on a laptop behind NAT, where it has nothing to find.
5. **Check it.** `sudo docker compose --project-directory /opt/selan ps` shows proxy, gateway,
   openbao and caddy running, and
   `curl -sk --resolve gw.example.localhost:443:127.0.0.1 https://gw.example.localhost/readyz`
   answers 200. The server appears under Settings › Own servers.
6. **One real request.** The person runs it, since it needs their token:
   ```sh
   read -rs T && printf 'Authorization: Bearer %s\n' "$T" | curl -sk https://gw.example.localhost/anthropic/v1/messages \
     -H @- -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
     -d '{"model":"claude-haiku-5-5","max_tokens":20,"messages":[{"role":"user","content":"Reply with ok"}]}'; unset T
   ```
   An answer with `"content"` is the proof. An error names the failing part (the vault, Selan, the
   provider); fix that part, never by reading the vault's files.
7. **Remove it.** `sudo docker compose --project-directory /opt/selan --profile openbao down -v`
   deletes the containers and the vault's data with every key in it; say so before running it, then
   `sudo rm -rf /opt/selan`, and remove the server under Settings › Own servers.
