# selan-self-hosted

[Selan](https://selan.ai)'s proxy and MCP gateway on your own server, inside your VPN, with every
provider key in your own vault. This is what **Settings › Own servers** in Selan installs: one line,
then the files in this repository, read before you run them.

```sh
export SELAN_REGISTRATION_TOKEN=selanreg_...
curl -fsSL https://selan.ai/self-hosted/install.sh | sudo --preserve-env=SELAN_REGISTRATION_TOKEN bash
```

The token comes from **Add server**, is shown once and works once. It travels in the environment,
never on a command line.

## What runs where

| Where | What | Talks to |
|---|---|---|
| Your server, `inside` and `egress` networks | `proxy`: selan-proxy, the endpoint your developers' Claude Code, Codex and Desktop use (`gw.<your domain>`) | Selan's auth and control, the providers, your vault |
| Your server, `inside` and `egress` networks | `gateway`: selan-mcp-gateway, for MCP connectors (`mcp.<your domain>`) | Selan's auth and control, the connectors, your vault |
| Your server, `inside` only | `openbao`: OpenBao, when you have no Vault of your own | nobody: no ports, no route out |
| Your server, `inside` and `front` | `caddy`: TLS for both names on your VPN address, port 443 | the proxy and the gateway |
| Selan | auth, control (who may use which key, budgets, rotation, usage), the console | nothing on your side: your server calls Selan, never the other way |

`inside` is an internal Docker network with no route out and no address on the host, so the vault
answers only the proxy and the gateway. `front` publishes Caddy's port on your VPN address and has no
NAT, so Caddy cannot reach out either. Only the proxy and the gateway are on `egress`, and they allow
only Selan, the providers built into their image, and your vault.

| File | |
|---|---|
| [`install.sh`](install.sh) | checks Docker (installs it on Debian or Ubuntu), fetches this repository at one commit into `/opt/selan`, writes `.env`, sets up the vault, starts the stack, waits for `/readyz`, checks nothing answers from the internet |
| [`compose.yaml`](compose.yaml) | the four services and three networks |
| [`Caddyfile`](Caddyfile) | TLS, and a 403 for any client outside `ALLOWED_CIDRS` |
| [`openbao.hcl`](openbao.hcl) | OpenBao's storage (files in the `selan_openbao-data` volume) and listener |
| [`unseal.sh`](unseal.sh) | unseals OpenBao after a restart; `selan-unseal.service` runs it at boot |
| [`.env.example`](.env.example) | every setting `install.sh` writes |

## VPN required

The proxy and the gateway are for your people only, so they listen on your VPN address and nowhere
else. Setting up the VPN (Tailscale, WireGuard, your company's own) is yours. `install.sh` refuses a
public listen address, and finds one on a `tailscale*`, `wg*`, `tun*`, `zt*` or `nebula*` interface
when you do not give `SELAN_BIND_ADDR`. Point `gw.<your domain>` and `mcp.<your domain>` at that
address in the DNS your people use, not in public DNS.

At the end, `install.sh` asks [check-host.net](https://check-host.net) to connect from three
places on the internet to this server's public address, and to whatever public DNS gives for your two
names, on ports 443, 80, 8080 and 8200. If any of them answers it says so plainly and exits 2. That
sends your server's public address to check-host.net; `SELAN_OUTSIDE_CHECK=no` skips it.

## Settings

`install.sh` reads each from the environment, else from `/opt/selan/.env`, else asks on the terminal.
Pass the ones you set through sudo: `sudo --preserve-env=SELAN_REGISTRATION_TOKEN,SELAN_PROXY_HOST,…`.

| Variable | |
|---|---|
| `SELAN_REGISTRATION_TOKEN` | from Add server; needed on the first run only, and removed from `.env` once the server has registered |
| `SELAN_PROXY_HOST` | the proxy's name, as entered under Add server: `gw.example.com` |
| `SELAN_GATEWAY_HOST` | the gateway's name; `mcp.` beside the proxy's by default |
| `SELAN_BIND_ADDR` | this server's IPv4 address on your VPN |
| `SELAN_TLS` | `internal`: Caddy's own CA, which your clients then have to trust. `files`: `/opt/selan/certs/fullchain.pem` and `privkey.pem`, valid for both names, from your CA or an ACME DNS challenge |
| `ALLOWED_CIDRS` | who Caddy lets in: `private_ranges` (the default) or CIDRs separated by spaces |
| `VAULT_ADDR`, `VAULT_PREFIX` | your own Vault, and the path its keys live under (`kv/selan/`) |
| `SELAN_DIR` | where the files go; `/opt/selan` by default |

## The vault

**Without a Vault**, `install.sh` starts OpenBao, initialises it with one unseal key, and writes that
key and the root token to `/opt/selan/openbao-init.json`, readable by root only. It prints that path,
never the contents. Copy the file off the server and keep it: without it nobody can unseal OpenBao,
and with it anybody can read every key. It then turns on a KV v2 engine at `kv/`, a policy `selan`
that allows `kv/selan/*` and nothing else, and two AppRoles, `selan-proxy` and `selan-gateway`, with
that policy; their ids go in `.env`.

OpenBao starts sealed after every restart. `selan-unseal.service` unseals it at boot with the key in
that file. If you would rather unseal by hand, keep the file elsewhere, `systemctl disable selan-unseal`,
and run `/opt/selan/unseal.sh` with the file put back.

**Your own Vault** (HashiCorp Vault or OpenBao): set `VAULT_ADDR` and put the AppRole ids in
`/opt/selan/.env` (root, mode 0600) before running `install.sh`:

```sh
PROXY_VAULT_ROLE_ID='...'
PROXY_VAULT_SECRET_ID='...'
GATEWAY_VAULT_ROLE_ID='...'      # optional: the proxy's are used when empty
GATEWAY_VAULT_SECRET_ID='...'
```

Each AppRole's policy allows `kv/data/selan/*` (create, read, update, delete) and `kv/metadata/selan/*`
(read, list, delete) on a KV v2 engine mounted at `kv/`, and nothing else. `install.sh` changes nothing
in your Vault, and OpenBao does not run.

## Upgrade

A release of selan-proxy or selan-mcp-gateway is pinned in `compose.yaml` by digest,
`europe-docker.pkg.dev/selan-prod/selan-public/<image>@sha256:…`, by a pull request here, so Selan
cannot change what your server runs. The images are public and signed with cosign; check one with
`cosign verify` before you take it. To upgrade, run the install line again: it fetches the commit
selan.ai now serves and pulls the digests that commit pins; the token is not needed again. To stay
where you are, do not. Settings › Own servers says when your version is older than Selan supports.

Until the first release of each image, `compose.yaml` names it as `${SELAN_PROXY_IMAGE:?…}` and
`${SELAN_GATEWAY_IMAGE:?…}`, which refuses to start: there is nothing to run yet.

## Backups

Selan cannot see your backups, disks, vault or VPN. Keep, off the server:

- `/opt/selan/openbao-init.json` (OpenBao's unseal key and root token) and `/opt/selan/.env`;
- the `selan_openbao-data` volume, OpenBao's data; stop OpenBao first, or use `bao operator raft snapshot save`:
  `docker run --rm -v selan_openbao-data:/d -v "$PWD:/b" alpine tar czf /b/openbao-data.tgz -C /d .`;
- `selan_proxy-identity` and `selan_gateway-identity`, each component's key pair. Lost, the server
  registers again with a new token from Add server.

Watch from your own monitoring: the proxy and the gateway answer `/healthz`, `/readyz` and `/metrics`
(through Caddy, from your VPN), and compose restarts what exits.

## What Selan can and cannot see

Selan **sees**: who used which model, tokens, cost, limits and the status code of each request
(usage, as today), each key's name, provider, status and an irreversible fingerprint, and your
server's heartbeat (version, vault reachable, clock offset, error counts).

Selan **cannot**: read a key's value, send one anywhere, or reach your server. Your server calls
Selan; Selan never calls in. The proxy reads a key only by the name control gives, only under its
vault prefix, and sends it only to the provider whose host is built into the image you pinned.
Provider error text stays on your side.

What you have to know: a compromised Selan could still stop answering, choose which of your keys a
request uses, and, since the console's code comes from Selan, change it to catch a key while it is
being typed. A compromised proxy of yours can lease as any of your members and read every key under
its vault prefix: your VPN, your vault policy and your image pins are yours to keep.

## With Claude Code

This repository is also a Claude Code plugin:

```
/plugin marketplace add selan-ai/selan-self-hosted
/plugin install selan-self-hosted@selan-self-hosted
```

| Skill | Where it runs the stack |
|---|---|
| `self-host-local` | this machine, with Docker |
| `self-host-server` | a server of yours over SSH, such as a Hostinger VPS found through the Hostinger MCP server |

Both show the commit and `compose.yaml` first, and have you run the line with the token yourself:
Claude never sees the token or the vault's material. They finish with one real request through the
proxy.

## How install.sh is served

`https://selan.ai/self-hosted/install.sh` is this repository's `install.sh` at one commit, with that
commit written into its `PINNED_COMMIT=""` line, so the script fetches exactly the files it came
with. Run from a checkout of this repository, it uses that checkout instead.

## Checks

`.github/workflows/check.yml` runs shellcheck, validates `compose.yaml` and the `Caddyfile`, checks
every image is pinned to a digest that exists, and runs `ci/stack-test.sh`: `install.sh` brings the
stack up with OpenBao, stand-ins for the proxy and gateway (until their images are pinned) and a
fake control, and the test asserts `/readyz`, the registration, the file modes, that the vault answers
nothing outside `inside`, that only the proxy and gateway reach the internet, that a second run
changes nothing, and that OpenBao comes back after a restart.
