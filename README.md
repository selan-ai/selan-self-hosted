# selan-self-hosted

[Selan](https://selan.ai)'s proxy, MCP gateway and selan-keys on your own server, inside your VPN,
with every provider key in your own vault. This is what **Settings › Own servers** in Selan installs.

**Installing, and every upgrade, runs code Selan wrote, as root on your server**: `install.sh` and the
images it starts. What protects you is not trust in Selan at that moment but this: the code comes from a
release tag of this public repository that you choose, you can read all of it before it runs, and
nothing is fetched from Selan while it runs. The images are the digests that tag pins, each checked
against its cosign signature first, so the tag decides exactly what your server runs.

## Install

**Add server** shows one line, with a release tag and two one-time tokens, one for the proxy and the
gateway and one for selan-keys:

```sh
export SELAN_REGISTRATION_TOKEN=selanreg_… SELAN_KEYS_REGISTRATION_TOKEN=selanreg_…; git clone --depth 1 --branch <tag> https://github.com/selan-ai/selan-self-hosted /opt/selan && sudo --preserve-env=SELAN_REGISTRATION_TOKEN,SELAN_KEYS_REGISTRATION_TOKEN /opt/selan/install.sh
```

Each token is shown once and works once. It travels in the environment, never on a command line. To read
the code first, read this repository at that tag (`https://github.com/selan-ai/selan-self-hosted/tree/<tag>`),
or run the `git clone` half alone, read `/opt/selan`, then the `sudo` half.

It needs `git` (`apt-get install -y git`) and a user that can write `/opt`: as a user that cannot, run
`sudo install -d -o "$USER" /opt/selan` first, or run the line from a root shell. `install.sh` then makes
`/opt/selan` root's, since root runs `unseal.sh` from it at boot.

## What runs where

| Where | What | Talks to |
|---|---|---|
| Your server, `inside` and `egress` networks | `proxy`: selan-proxy, the endpoint your developers' Claude Code, Codex and Desktop use (`gw.<your domain>`) | Selan's auth and control, the providers, selan-keys |
| Your server, `inside`, `egress` and `gateway-db` networks | `gateway`: selan-mcp-gateway, for MCP connectors (`mcp.<your domain>`) | Selan's auth and control, the connectors, selan-keys, its Postgres |
| Your server, `gateway-db` only | `postgres`: the gateway's database, its sign-ins' rows (every secret itself is kept at selan-keys) | nobody: no ports, no route out |
| Your server, `vault`, `inside` and `egress` networks | `keys`: selan-keys, the only part with a vault identity; your admins add keys in the browser at `keys.<your domain>`, which reaches only its admin API (port 8081) and `/readyz` | your vault, Selan's auth and control |
| Your server, `vault` only | `openbao`: OpenBao, when you have no Vault of your own | nobody: no ports, no route out |
| Your server, `inside` and `front` | `caddy`: TLS for the three names on your VPN address, port 443 | the proxy, the gateway and selan-keys |
| Selan | auth, control (who may use which key, budgets, rotation, usage), the console | nothing on your side: your server calls Selan, never the other way |

`vault`, `inside` and `gateway-db` are internal Docker networks with no route out and no address on the host. The
vault shares `vault` with selan-keys alone, so it answers nothing else: the proxy and the gateway have no
vault address and no vault identity, and read a key from selan-keys with a token of their own that
`install.sh` makes for each (`PROXY_KEYS_TOKEN`, `GATEWAY_KEYS_TOKEN` in `.env`). `front` publishes Caddy's port on your VPN address and has no
NAT, so Caddy cannot reach out either, except with `SELAN_TLS=dns`, where it asks Let's Encrypt for
certificates over your DNS provider's API. The proxy, the gateway and selan-keys are on `egress`: the proxy and gateway
allow only Selan and the providers built into their image, and selan-keys calls Selan and your own Vault.

| File | |
|---|---|
| [`install.sh`](install.sh) | checks Docker (installs it on Debian or Ubuntu), writes `.env`, sets up the vault, checks every image's cosign signature, starts the stack, waits for `/readyz`, checks nothing answers from the internet. Makes a selan-keys token per caller. It runs from the checkout it is in and fetches nothing else |
| [`compose.yaml`](compose.yaml) | the six services and five networks, every image pinned by digest |
| [`compose.dns.yaml`](compose.dns.yaml) | with `SELAN_TLS=dns` only: gives Caddy a way out, to Let's Encrypt and your DNS provider |
| [`signers.txt`](signers.txt) | who must have signed each image, checked with cosign before it runs |
| [`Caddyfile`](Caddyfile) | TLS, and a 403 for any client outside `ALLOWED_CIDRS` |
| [`caddy/Dockerfile`](caddy/Dockerfile) | Caddy with the DNS provider modules, built and signed by this repository's CI |
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

`install.sh` reads each from the environment, else from `/opt/selan/.env`, else asks on the terminal
(a token without showing it). Every question has a variable, so it also runs unattended, as on a fresh
Ubuntu container with its own Docker daemon (`ci/dind-test.sh`); there it installs Docker itself and starts
it without systemd. Pass the ones you set through sudo:
`sudo --preserve-env=SELAN_REGISTRATION_TOKEN,SELAN_PROXY_HOST,…`.

| Variable | |
|---|---|
| `SELAN_REGISTRATION_TOKEN`, `SELAN_KEYS_REGISTRATION_TOKEN` | from Add server, the proxy's and gateway's and selan-keys' own; needed on the first run only, and removed from `.env` once the server has registered |
| `SELAN_PROXY_HOST` | the proxy's name, as entered under Add server: `gw.example.com` |
| `SELAN_GATEWAY_HOST` | the gateway's name; `mcp.` beside the proxy's by default |
| `SELAN_KEYS_HOST` | selan-keys' name, where your admins add keys; `keys.` beside the proxy's by default |
| `SELAN_BIND_ADDR` | this server's IPv4 address on your VPN |
| `SELAN_TLS` | `dns` or `files`; asked when unset. See "TLS on a private name" |
| `SELAN_DNS_PROVIDER`, `SELAN_DNS_TOKEN` | with `dns`: the provider, and an API token that may edit TXT records in your zone; kept in `.env` only |
| `SELAN_TLS_CERT`, `SELAN_TLS_KEY` | with `files`: paths to your CA's certificate chain and its key, copied into `/opt/selan/certs/` |
| `ALLOWED_CIDRS` | who Caddy lets in: `private_ranges` and CIDRs, separated by spaces; `private_ranges 100.64.0.0/10` by default, since Caddy's `private_ranges` leaves out Tailscale's 100.64.0.0/10 |
| `SELAN_VAULT` | `openbao` (started on this server) or `own`; `own` when `VAULT_ADDR` is set, asked otherwise |
| `VAULT_ADDR`, `VAULT_PREFIX` | your own Vault, and the path its keys live under (`kv/selan/`) |
| `KEYS_VAULT_ROLE_ID`, `KEYS_VAULT_SECRET_ID` | with `own`: selan-keys' AppRole on your Vault |
| `SELAN_OUTSIDE_CHECK` | `no` skips the check from the internet |
| `SELAN_PUBLIC_DNS`, `SELAN_CHECK_HOST` | where that check asks: `https://1.1.1.1` (DNS over HTTPS) and `https://check-host.net` by default |
| `SELAN_READY_TIMEOUT` | seconds to wait for each `/readyz`, 300 by default (OpenBao: 120). selan-keys starts and answers first: the proxy asks it as it starts, then every five minutes |
| `SELAN_NONINTERACTIVE` | `1` never asks: a missing setting fails, naming its variable. Without a terminal it never asks either |

## TLS on a private name

Your names resolve to a VPN address, so Let's Encrypt cannot reach the server to check them: its
HTTP-01 and TLS-ALPN challenges do not work behind a VPN. `install.sh` asks which of these to use:

- **`dns`**: Let's Encrypt over the DNS-01 challenge. Caddy writes a TXT record through your DNS
  provider's API, so the names need a public DNS zone (their A records can stay private). Providers:
  bunny, cloudflare, digitalocean, duckdns, gandi, hetzner, ionos, linode and vultr; give it a token
  limited to that zone. Caddy gets a way out for this alone (`compose.dns.yaml`). With another
  provider, use `files`.
- **`files`**: a certificate from your company's own CA, valid for all three names, as `fullchain.pem` and
  `privkey.pem` in `/opt/selan/certs/`. Your people's machines must trust that CA, as they do for your
  other internal services; control.selan.ai's Add key calls the proxy from the browser, which needs it.

`SELAN_TLS=internal`, Caddy's own CA, is for a trial on one machine: every client has to trust it by hand.

## The vault

**Without a Vault**, `install.sh` starts OpenBao, initialises it with one unseal key, and writes that
key and the root token to `/opt/selan/openbao-init.json`, readable by root only. It prints that path,
never the contents. Copy the file off the server and keep it: without it nobody can unseal OpenBao,
and with it anybody can read every key. It then turns on a KV v2 engine at `kv/`, a policy `selan`
that allows `kv/selan/*` and nothing else, and one AppRole, `selan-keys`, with that policy; its ids go
in `.env` and only the `keys` container gets them.

OpenBao starts sealed after every restart. `selan-unseal.service` unseals it at boot with the key in
that file. If you would rather unseal by hand, keep the file elsewhere, `systemctl disable selan-unseal`,
and run `/opt/selan/unseal.sh` with the file put back.

**Your own Vault** (HashiCorp Vault or OpenBao): answer `own` (or set `VAULT_ADDR`), and give
selan-keys' AppRole when asked, or in the environment, or in `/opt/selan/.env` (root, mode 0600):

```sh
KEYS_VAULT_ROLE_ID='...'
KEYS_VAULT_SECRET_ID='...'
```

The AppRole's policy allows `kv/data/selan/*` (create, read, update, delete) and `kv/metadata/selan/*`
(read, list, delete) on a KV v2 engine mounted at `kv/`, and nothing else. `install.sh` changes nothing
in your Vault, and OpenBao does not run.

## Upgrade

Selan publishes a new release as a new tag here. An upgrade is the same trust as the install: code Selan
wrote, from the tag you choose, which you can read first. To see what changes and then move to it:

```sh
sudo git -C /opt/selan fetch --depth 1 origin tag <new tag>
sudo git -C /opt/selan diff HEAD <new tag>
sudo git -C /opt/selan -c advice.detachedHead=false checkout <new tag> && sudo /opt/selan/install.sh
```

The token is not needed again. To stay where you are, do nothing. Settings › Own servers says when your
version is older than Selan supports.

Each image is pinned in `compose.yaml` by digest, by a pull request here, so Selan cannot change what
your server runs without a new tag. Before running a digest, `install.sh` checks its cosign signature
against the signer [`signers.txt`](signers.txt) names: selan-proxy, selan-mcp-gateway and selan-keys are
`europe-docker.pkg.dev/selan-prod/selan-public/<image>`, signed keylessly by their own GitLab CI at a
release tag; Caddy is `europe-docker.pkg.dev/selan-prod/selan-public/caddy` too, built from [`caddy/Dockerfile`](caddy/Dockerfile)
and signed by this repository's `caddy-image` workflow on `main`; OpenBao is signed by OpenBao's
release workflow. Postgres, the gateway's database, is the one image whose publisher signs none: `signers.txt`
says `unsigned` for it, and `install.sh` runs it by the digest pinned here alone. To check one yourself:

```sh
cosign verify --certificate-identity-regexp '<identity from signers.txt>' \
  --certificate-oidc-issuer '<issuer from signers.txt>' <image>@sha256:…
```

## Known gaps

- **GitLab, GitHub and Slack sign-ins** through your gateway need OAuth apps of your own, which this release
  does not configure; `compose.yaml` gives the gateway stand-ins for them.

## Backups

Selan cannot see your backups, disks, vault or VPN. Keep, off the server:

- `/opt/selan/openbao-init.json` (OpenBao's unseal key and root token) and `/opt/selan/.env`;
- the `selan_openbao-data` volume, OpenBao's data; stop OpenBao first, or use `bao operator raft snapshot save`:
  `docker run --rm -v selan_openbao-data:/d -v "$PWD:/b" alpine tar czf /b/openbao-data.tgz -C /d .`;
- `selan_proxy-identity`, `selan_gateway-identity` and `selan_keys-identity`: each component's Ed25519 key pair, which signs its
  calls to Selan, and selan-keys' X25519 key pair, which existing keys are sealed to when Selan hands them over.
  They are made on first start; only their public halves are sent, in `RegisterServer`. Lost, the server
  registers again with a new token from Add server;
- `selan_gateway-db`, the gateway's Postgres, whose password is `GATEWAY_DB_PASSWORD` in `.env`.

Watch from your own monitoring: the proxy, the gateway and selan-keys answer `/healthz`, `/readyz` and `/metrics`
(through Caddy, from your VPN), and compose restarts what exits.

## What Selan can and cannot see

Selan **sees**: who used which model, tokens, cost, limits and the status code of each request
(usage, as today), each key's name, provider, status and an irreversible fingerprint, and your
server's heartbeat (version, vault reachable, clock offset, error counts).

Selan **cannot**: read a key's value, send one anywhere, or reach your server. Your server calls
Selan; Selan never calls in. The proxy reads a key from selan-keys only by the name control gives,
selan-keys reads only under its vault prefix, and the proxy sends it only to the provider whose host is built into the image you pinned.
Provider error text stays on your side.

What you have to know: a compromised Selan could still stop answering, choose which of your keys a
request uses, and, since the console's code comes from Selan, change it to catch a key while it is
being typed. A compromised proxy of yours can lease as any of your members and read, through selan-keys,
every key under the vault prefix: your VPN, your vault policy and your image pins are yours to keep.

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

Both show the tag, `compose.yaml` and `install.sh` first, ask which TLS to use, and have you run the line with the tokens yourself:
Claude never sees a token or the vault's material. They finish with one real request through the
proxy.

## Tests

`.github/workflows/check.yml` runs shellcheck and actionlint, validates `compose.yaml` (with OpenBao, your
own Vault and DNS-01) and the `Caddyfile` in every TLS mode and with every DNS provider, and checks every
image is pinned to a digest that exists. Then it runs each case below on its own fresh host with its own
Docker daemon (`ci/dind-test.sh <case>`): a privileged container with git alone, this commit cloned to
`/opt/selan`, where `install.sh` installs Docker itself and gets every answer from the environment, as
selan-proxy-e2e installs it. The proxy, the gateway and selan-keys are the released images `compose.yaml`
pins, signatures checked; control (and selan-auth, for the gateway's boot) is a fake, `ci/fake_control.py`, served
over TLS from `ci/tls/` (a CA for CI alone, whose key was thrown away), which the three are given to trust.

Coverage is counted by paths, not lines: `install.sh` runs traced, and `ci/paths.py` fails the build unless
every command line ran in some case and every `fail` ran as a refusal. Run the cases locally with
`bash ci/dind-test.sh <case>`, then `python3 ci/paths.py ci-out/paths-*.txt`.

| Case | Host | What it proves |
|---|---|---|
| `openbao` | Ubuntu 24.04 | OpenBao on the server, tokens present: every image's cosign signature checked, three registrations with their public keys (selan-keys' sealing key too) and signed polls, keys 0600 in each volume, files root 0600, selan-keys reads a key with its AppRole for the proxy's token and refuses the gateway's and a stranger's, only selan-keys reaches the vault, only the gateway its Postgres, the vault and Caddy have no way out; a re-run changes nothing; a **sealed vault** after a restart is unsealed by `unseal.sh` and by a re-run; a secret id that stopped working is replaced; a wrong signer, a missing init file, an init file without OpenBao's data and one without a root token are refused |
| `own-vault` | Ubuntu 24.04 | **your own Vault** (an OpenBao dev server standing in): no OpenBao runs, the Vault's policies, auth methods and AppRole are unchanged, selan-keys reads a key through it; a missing or malformed address, role id or secret id is refused; a re-run changes nothing |
| `dns` | Ubuntu 24.04 | **DNS-01**: an unknown provider and a missing or malformed token are refused; with Caddy built from `caddy/`, Caddy gets a way out and asks the provider's API for the challenge record (CI's token is refused there, so no certificate); the token stays out of output, Caddy's log and its saved config; `install.sh` fails plainly when `/readyz` does not come |
| `own-ca` | Ubuntu 24.04 | **your own CA**: missing paths, missing files and files that are not PEM are refused; every name answers with that CA's certificate, checked against it alone; re-runs change nothing |
| `tokens` | Ubuntu 24.04 | a first run with a registration **token missing** or malformed is refused before anything is written; with both **present** it registers and the tokens leave `.env`; caller tokens are kept on a re-run; a broken one in `.env` is refused |
| `outside` | Ubuntu 24.04 | at a tag `install.sh` names it; the check from outside, against stand-ins for public DNS and check-host.net: a **public address that answers is refused with exit 2**, naming only the ports that answer; closed ports, a checker that does not answer, and no public address are each said; `SELAN_OUTSIDE_CHECK=no` skips it |
| `refusals` | Ubuntu 24.04 | every malformed or missing setting is refused, naming its variable; on a terminal every question is asked and kept, secrets unseen; a release without a codename; a VPN address found on `wg0`; non-root, a copy outside a checkout, a checkout elsewhere; unpinned and unknown images; an OpenBao and a Docker that will not start |
| `systemd` | Ubuntu 24.04 booted by systemd | a stopped Docker started with systemctl; `selan-unseal.service` installed; after a **reboot** the stack is back and OpenBao is unsealed with nobody's hands |
| `no-debian` | Alpine | outside Debian and Ubuntu `install.sh` installs nothing and says to install curl, then Docker with the compose plugin |
