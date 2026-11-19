# selan-self-hosted

[Selan](https://selan.ai)'s proxy, MCP gateway and selan-keys on your own server, inside your VPN,
with every provider key in your own vault. This is what **Settings › General › Own proxy** in Selan installs.

The guide for people, without the detail below, is [selan.ai/docs/self-hosted](https://selan.ai/docs/self-hosted).
A release is a [tag](https://github.com/selan-ai/selan-self-hosted/tags) of this repository. To have Claude Code do
the install with you, see [With Claude Code](#with-claude-code).

**Installing, and every upgrade, runs code Selan wrote, as root on your server**: `install.sh` and the
images it starts. What protects you is not trust in Selan at that moment but this: the code comes from a
release tag of this public repository that you choose, you can read all of it before it runs, and
nothing is fetched from Selan while it runs. The images are the digests that tag pins, each checked
against its cosign signature first, so the tag decides exactly what your server runs.

## Install

**Add server** shows one line, with a release tag and a registration token for the proxy, the
gateway and selan-keys:

```sh
export SELAN_REGISTRATION_TOKEN=selanreg_…; { [ -d /opt/selan ] || sudo git clone --depth 1 --branch <tag> https://github.com/selan-ai/selan-self-hosted /opt/selan; } && sudo git -C /opt/selan fetch -q --depth 1 origin tag <tag> && sudo git -C /opt/selan checkout -q <tag> && sudo --preserve-env=SELAN_REGISTRATION_TOKEN /opt/selan/install.sh
```

The token is shown once and lasts an hour. It travels in the environment, never on a command line. To read
the code first, read this repository at that tag (`https://github.com/selan-ai/selan-self-hosted/tree/<tag>`),
or run the `git clone` half alone, read `/opt/selan`, then the `install.sh` half.

It needs `git` (`apt-get install -y git`). The clone is root's, since the unseal key and root's own
scripts live in `/opt/selan`. It is skipped when `/opt/selan` is already there, which is moved to the
line's tag instead, so a new token after a failed install runs `install.sh` again, at that tag.

## What runs where

| Where | What | Talks to |
|---|---|---|
| Your server, `inside` and `egress` networks | `proxy`: selan-proxy, the endpoint your developers' Claude Code, Codex and Desktop use (`gw.<your domain>`) | Selan's control, the providers built into its image, selan-keys |
| Your server, `inside`, `egress` and `gateway-db` networks | `gateway`: selan-mcp-gateway, for MCP connectors (`mcp.<your domain>`) | Selan's auth, control and reactor, the connectors' services, selan-keys, its Postgres |
| Your server, `gateway-db` only | `postgres`: the gateway's database, its sign-ins' rows (every secret itself is kept at selan-keys) | nobody: no ports, no route out |
| Your server, `vault`, `inside` and `egress` networks | `keys`: selan-keys, the only part with a vault identity; your admins add keys in the browser at `keys.<your domain>`, which reaches only its admin API (port 8081) and `/readyz` | your vault, Selan's control, the providers |
| Your server, `vault` only | `openbao`: OpenBao, when you have no Vault of your own | nobody: no ports, no route out |
| Your server, `vault` only | `unseal`: unseals OpenBao after every restart, with OpenBao | OpenBao alone |
| Your server, `inside` and `front` | `caddy`: TLS for the three names on your VPN address, port 443 | the proxy, the gateway and selan-keys |
| Selan | auth, control (who may use which key, budgets, rotation, usage), the console | nothing on your side: your server calls Selan, never the other way |

`vault`, `inside` and `gateway-db` are internal Docker networks with no route out and no address on the host. The
vault shares `vault` with selan-keys alone, so it answers nothing else: the proxy and the gateway have no
vault address and no vault identity, and read a key from selan-keys with a token of their own that
`install.sh` makes for each (`PROXY_KEYS_TOKEN`, `GATEWAY_KEYS_TOKEN` in `.env`). `front` publishes Caddy's port on your VPN address and has no
NAT, so Caddy cannot reach out either, except with `SELAN_TLS=dns`, where it asks Let's Encrypt for
certificates over your DNS provider's API. The proxy, the gateway and selan-keys are on `egress`: the proxy sends a key only to
the providers built into its image and refuses any other origin, the gateway calls Selan and its connectors'
services, and selan-keys calls Selan, the providers and your own Vault. [Services](#services) has each container in
full, [Every host the server calls](#every-host-the-server-calls) the whole list, and
[The trust boundary](#the-trust-boundary) who reaches what.

| File | |
|---|---|
| [`install.sh`](install.sh) | checks Docker (installs it on Debian or Ubuntu), writes `.env`, sets up the vault, checks every image's cosign signature, starts the stack, waits for `/readyz`, checks nothing answers from the internet. Makes a selan-keys token per caller. It runs from the checkout it is in and fetches nothing else |
| [`compose.yaml`](compose.yaml) | the seven services and five networks, every image pinned by digest |
| [`compose.dns.yaml`](compose.dns.yaml) | with `SELAN_TLS=dns` only: gives Caddy a way out, to Let's Encrypt and your DNS provider |
| [`signers.txt`](signers.txt) | who must have signed each image, checked with cosign before it runs |
| [`Caddyfile`](Caddyfile) | TLS, and a 403 for any client outside `ALLOWED_CIDRS` |
| [`caddy/Dockerfile`](caddy/Dockerfile) | Caddy with the DNS provider modules, built and signed by this repository's CI |
| [`openbao.hcl`](openbao.hcl) | OpenBao's storage (files in the `selan_openbao-data` volume) and listener |
| [`unseal-watch.sh`](unseal-watch.sh) | the `unseal` service: unseals OpenBao whenever it answers sealed |
| [`unseal.sh`](unseal.sh) | unseals OpenBao by hand, with the unseal service stopped |
| [`selan-keys.sh`](selan-keys.sh) | `/usr/local/bin/selan-keys`, which `install.sh` installs: runs selan-keys in its container, as `sudo selan-keys import` |
| [`.env.example`](.env.example) | every setting `install.sh` writes |

## Services

Every container `compose.yaml` runs, at v0.2.9. Each image is pinned by digest in `compose.yaml` at the tag, and
`install.sh` checks the cosign signature of every signed image against [`signers.txt`](signers.txt) before it pulls
it. Postgres, whose publisher signs none, runs by its digest alone.

| Service | Image | What it does, and why it is a part of its own | Called by | Calls out to | Keeps | If it is down |
|---|---|---|---|---|---|---|
| `caddy` | `selan-public/caddy`: Caddy 2.11.9 with the DNS provider modules, built from [`caddy/Dockerfile`](caddy/Dockerfile) and signed by this repository's `caddy-image` workflow on `main` | TLS for the three names, and a 403 for any client outside `ALLOWED_CIDRS`. The only container with a port on the host, so no other part needs one, and the only one that holds certificates | your VPN, on port 443 at `SELAN_BIND_ADDR`. It sends `gw.` to `proxy:8080`, `mcp.` to `gateway:8080`, and `keys.` to `keys:8081` (`/selan/*`) and `keys:8080` (`/readyz` only) | nothing. With `SELAN_TLS=dns`: Let's Encrypt and your DNS provider's API | `caddy-data`: certificates, its ACME account and, with `internal`, its own CA. No backup needed with `dns` or `files`; with `internal`, losing it means every client trusts a new CA | nobody on the VPN reaches the proxy, the gateway or `keys.`: requests, connectors and Add token fail. The other parts still call Selan by themselves |
| `proxy` | `selan-public/selan-proxy:0.1.1`, signed by selan-proxy's GitLab CI at a release tag | the endpoint Claude Code, Codex and Desktop use: asks control which key a request uses, reads it from selan-keys, calls the provider and reports usage. It has no vault address or vault identity, so the part every request reaches cannot read the vault | Caddy, on `8080` in `inside` | `control.selan.ai`; `keys:8080` with `PROXY_KEYS_TOKEN`; the providers built into its image, refusing any other origin before it dials | `proxy-identity`: its key pair and registration, the key that names detected secrets, and Gemini's thought signatures for a week. Back it up; lost, it registers again with a new token from Add server | developers' requests fail. With Own proxy on nothing falls back to Selan's proxy, which holds none of your keys. Selan marks it silent after five minutes |
| `gateway` | `selan-public/selan-mcp-gateway:0.1.2`, signed by selan-mcp-gateway's GitLab CI at a release tag | Selan's MCP gateway for your connectors at `mcp.`: Selan's own tools, Slack, GitLab, GitHub, Figma and PostgreSQL. A program of its own with a database of its own; a connector's secrets stay in your vault, read through selan-keys | Caddy, on `8080` in `inside` | `control.selan.ai`, `auth.selan.ai`, `reactor.selan.ai` (the `selan` tools that reach Reactor, which do not work on an own server yet); `keys:8080` with `GATEWAY_KEYS_TOKEN`; `postgres:5432`; its connectors' services | `gateway-identity`: its key pair and registration. Back it up; lost, it registers again | connectors on your gateway fail; model requests carry on |
| `postgres` | `docker.io/library/postgres:18.7-alpine`. Its publisher signs none, so `signers.txt` says `unsigned` and the pinned digest is the check | the gateway's database: its sign-ins' rows, each naming a key in your vault rather than holding it | the gateway alone, on `5432` in `gateway-db` | nothing: no route out | `gateway-db`; its password is `GATEWAY_DB_PASSWORD` in `.env`. Back it up | the gateway cannot read its sign-ins, so connectors fail; a gateway that is starting waits for it |
| `keys` | `selan-public/selan-keys:0.1.5`, signed by selan-keys' GitLab CI at a release tag | selan-keys, the only part with a vault identity: an AppRole limited to `kv/selan/`. It serves keys to the proxy and the gateway by name, takes new keys from your admins' browsers, checks keys, lists models and renews accounts as control asks, and stores the keys `selan-keys import` moves. With one holder of the vault credential, the vault answers nothing else | the proxy and the gateway on `8080`, each with its own token; your admins' browsers through Caddy, which reaches only the admin API on `8081` and `/readyz` | `control.selan.ai`; the vault (`openbao:8200`, or `VAULT_ADDR`); the providers, to check keys and list models; the sign-in and renewal hosts | `keys-identity`: its signing and sealing key pairs and its registration; the keys Selan hands over are sealed to it. Back it up; lost, it registers again | the proxy and the gateway cannot read keys: requests and connectors fail once their five-minute copies run out, and Add token fails |
| `openbao` | `quay.io/openbao/openbao:2.7.2`, signed by OpenBao's release workflow. Only without a Vault of your own (profile `openbao`) | the vault: every key, in a KV v2 engine at `kv/` | selan-keys and `unseal`, on `8200` in `vault` | nothing: no route out | `openbao-data`: every key. Back it up, with `/opt/selan/openbao-init.json` (the unseal key and root token), both off the server; see [Backups](#backups) | selan-keys cannot read the vault: requests fail once the five-minute copies run out, and Selan shows "It cannot read your vault." |
| `unseal` | the same OpenBao image and digest, running [`unseal-watch.sh`](unseal-watch.sh) | OpenBao starts sealed after every restart. This unseals it with `/opt/selan/openbao-unseal.key` (root only), so a crash, an upgrade or a reboot does not leave you down. You may unseal by hand instead; see [The vault](#the-vault) | nobody | `openbao:8200` only | nothing; it reads the key file | nothing at once; after OpenBao's next restart it stays sealed until `/opt/selan/unseal.sh` |

To see each one: `sudo docker compose --project-directory /opt/selan ps` (Postgres also says `healthy`),
`https://gw.<domain>/readyz` (the proxy, selan-keys and the vault), `https://mcp.<domain>/readyz` (the gateway,
selan-keys and Selan) and `https://keys.<domain>/readyz` (selan-keys and the vault), each answering 200 from your
VPN; `sudo docker compose --project-directory /opt/selan exec openbao bao status` says `Sealed false`; and
`sudo docker compose --project-directory /opt/selan logs --since 10m <service>` says why one is not.

## Every host the server calls

Nothing on the internet calls in to these containers: Caddy's port 443 is published on your VPN address alone (on
`127.0.0.1` with an SSH tunnel), and no other container has a port on the host. Your VPN may need a port of its own, such as WireGuard's UDP 51820.
Everything below is the server calling out.

| Who | Hosts | When |
|---|---|---|
| `git` | `github.com` | install and upgrade: this repository at a tag |
| `install.sh` | your distribution's package mirrors, `download.docker.com` | install, on Debian or Ubuntu, only when curl or Docker is missing |
| Docker | `europe-docker.pkg.dev` | install and upgrade: selan-proxy, selan-mcp-gateway, selan-keys and Caddy, and their signatures |
| Docker | `quay.io`, `docker.io`, `ghcr.io` | install and upgrade: OpenBao, Postgres, and cosign, which checks the signatures |
| cosign | Sigstore, under `sigstore.dev` | install and upgrade: the trust root signatures are checked against |
| `install.sh` | `1.1.1.1`, `check-host.net` | the check from outside at the end; `SELAN_OUTSIDE_CHECK=no` skips it |
| proxy, gateway, selan-keys | `control.selan.ai` | always: sessions, leases, usage, heartbeats and key work |
| gateway | `auth.selan.ai`, `reactor.selan.ai` | signing out a spent session; the `selan` tools that reach Reactor |
| proxy, selan-keys | `api.anthropic.com`, `chatgpt.com`, `api.openai.com`, `openrouter.ai`, `api.nexos.ai`, `api.kimi.ai`, `ollama.com` | requests (proxy); key checks and model lists (selan-keys) |
| proxy | `aiplatform.googleapis.com`, `aiplatform.us.rep.googleapis.com`, `aiplatform.eu.rep.googleapis.com` | Google Vertex requests |
| selan-keys | `platform.claude.com`, `auth.openai.com`, `auth.kimi.ai`, `oauth2.googleapis.com` | account sign-ins and renewals, and Vertex access tokens |
| gateway | `slack.com`, `gitlab.com`, `github.com`, `api.github.com`, `api.figma.com`, your PostgreSQL hosts | the connectors it serves; GitLab, GitHub and Slack sign-ins need OAuth apps of your own ([Known gaps](#known-gaps)) |
| selan-keys | your own Vault | only with `SELAN_VAULT=own` |
| Caddy | `acme-v02.api.letsencrypt.org`, your DNS provider's API | only with `SELAN_TLS=dns` |

A registry may send image layers from other hosts of its own.

## The trust boundary

| Who | Reaches | Holds a key |
|---|---|---|
| The internet, Selan included | nothing on the server | Selan: each key's name, once `selan-keys import` has moved the keys it held |
| Your VPN: developers' tools, admins' browsers | Caddy on port 443, and through it the proxy, the gateway and selan-keys' admin API | an admin's browser, while a key is typed |
| The proxy, the gateway | selan-keys with their own tokens, Selan, the providers or the connectors' services | a key read for a request, for up to five minutes |
| selan-keys | the vault, Selan, the providers' check and sign-in hosts | each key as it reads or writes it |
| The vault: OpenBao or yours | nothing | every key, at rest |

A key leaves the vault only through selan-keys, which sends it to its provider to check or renew it, or to the proxy
or the gateway, which send it only to its provider or its connector's service.

## VPN required

The proxy and the gateway are for your people only, so they listen on your VPN address and nowhere
else. Setting up the VPN is yours: Tailscale or WireGuard for a team, your company's own, or an SSH tunnel
with `SELAN_BIND_ADDR=127.0.0.1` for one person trying it. The `self-host-server` skill sets up any of them
with you. `install.sh` refuses a public listen address, and finds one on a `tailscale*`, `wg*`, `tun*`, `zt*`
or `nebula*` interface when you do not give `SELAN_BIND_ADDR`. Point `gw.`, `mcp.` and `keys.<your domain>`
at that address in the DNS your people use, not in public DNS.

At the end, `install.sh` asks [check-host.net](https://check-host.net) to connect from three
places on the internet to this server's public address, and to whatever public DNS gives for your three
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
| `SELAN_REGISTRATION_TOKEN` | from Add server: within its hour it registers the proxy, the gateway and selan-keys; needed on the first run only, and removed from `.env` once the server has registered. `SELAN_KEYS_REGISTRATION_TOKEN`, a second token for selan-keys alone, is optional |
| `SELAN_PROXY_HOST` | the proxy's name, as entered under Add server: `gw.example.com` |
| `SELAN_GATEWAY_HOST` | the gateway's name; `mcp.` beside the proxy's by default |
| `SELAN_KEYS_HOST` | selan-keys' name, where your admins add keys; `keys.` beside the proxy's by default |
| `SELAN_BIND_ADDR` | this server's IPv4 address on your VPN |
| `SELAN_TLS` | `dns` or `files`; asked when unset. See "TLS on a private name" |
| `SELAN_DNS_PROVIDER`, `SELAN_DNS_TOKEN` | with `dns`: the provider, and an API token that may edit TXT records in your zone; kept in `.env` only |
| `SELAN_TLS_CERT`, `SELAN_TLS_KEY` | with `files`: paths to your CA's certificate chain and its key, copied into `/opt/selan/certs/` |
| `ALLOWED_CIDRS` | who Caddy lets in: `private_ranges` and CIDRs, separated by spaces; `private_ranges 100.64.0.0/10` by default, since Caddy's `private_ranges` leaves out Tailscale's 100.64.0.0/10 |
| `LAUNCH_CONNECTORS` | your allowlist of connectors Selan's launch settings may hand your developers' apps, by exact URL, separated by commas; any other connector is dropped, so a compromised Selan cannot point an app elsewhere. By default the connectors your own gateway serves by itself: `https://<gateway>/<slug>/mcp` for `selan`, `slack-bot`, `gitlab`, `github`, `figma` and `postgresql`. Any other connector, Google's on your gateway included (some reach Selan's workspace service), is offered only once you add its URL |
| `LAUNCH_MARKETPLACES` | the same for plugin marketplaces, by exact URL; none by default |
| `LAUNCH_SETTINGS_DEFAULTS` | the Claude Code settings, by key, that Selan's defaults may set; none by default |
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
  other internal services; control.selan.ai's Add token calls the proxy from the browser, which needs it.

`SELAN_TLS=internal`, Caddy's own CA, is for a trial on one machine: every client has to trust it by hand.

## The vault

**Without a Vault**, `install.sh` starts OpenBao, initialises it with one unseal key, and writes that
key and the root token to `/opt/selan/openbao-init.json`, readable by root only. It prints that path,
never the contents. Copy the file off the server and keep it: without it nobody can unseal OpenBao,
and with it anybody can read every key. It then turns on a KV v2 engine at `kv/`, a policy `selan`
that allows `kv/selan/*` and nothing else, and one AppRole, `selan-keys`, with that policy; its ids go
in `.env` and only the `keys` container gets them.

OpenBao starts sealed after every restart. The `unseal` service, beside it in the stack, unseals it
whenever it answers sealed (after a crash, a restart, an upgrade or a reboot) with the key alone, copied
to `/opt/selan/openbao-unseal.key` (root only, mode 0600) and mounted into that service only. If you would
rather unseal by hand, `docker compose stop unseal`, delete `openbao-unseal.key`, and run
`/opt/selan/unseal.sh` after each restart.

**Your own Vault** (HashiCorp Vault or OpenBao): answer `own` (or set `VAULT_ADDR`), and give
selan-keys' AppRole when asked, or in the environment, or in `/opt/selan/.env` (root, mode 0600):

```sh
KEYS_VAULT_ROLE_ID='...'
KEYS_VAULT_SECRET_ID='...'
```

The AppRole's policy allows `kv/data/selan/*` (create, read, update, delete) and `kv/metadata/selan/*`
(read, list, delete) on a KV v2 engine mounted at `kv/`, and nothing else. `install.sh` changes nothing
in your Vault, and OpenBao does not run.

Keys Selan already holds move into your vault with `sudo selan-keys import` on this server, which prints each key as it is stored.

## Upgrade

Selan publishes a new release as a new tag here. An upgrade is the same trust as the install: code Selan
wrote, from the tag you choose, which you can read first. To see what changes and then move to it:

```sh
sudo git -C /opt/selan fetch --depth 1 origin tag <new tag>
sudo git -C /opt/selan diff HEAD <new tag>
sudo git -C /opt/selan -c advice.detachedHead=false checkout <new tag> && sudo /opt/selan/install.sh
```

The token is not needed again. Running Add server's line again does the same: it moves `/opt/selan` to the tag
the line names and runs `install.sh` with the settings in `.env`, and parts already registered ignore its token.
To stay where you are, do nothing. Settings › General › Own proxy says when your version is older than Selan
supports.

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

## Use the API

From a machine on your VPN, with a company API token from Settings › API tokens sent as `Authorization: Bearer`:

| Path | For |
|---|---|
| `POST https://gw.<domain>/anthropic/v1/messages` | Anthropic-shaped clients |
| `POST https://gw.<domain>/openai/v1/responses` | OpenAI-shaped clients; always with `"stream": true` |
| `GET /anthropic/v1/models`, `GET /openai/v1/models` | the models your company may use |

A model id is one `/anthropic/v1/models` lists: a bare Claude id such as `claude-haiku-5-5`, or
`claude-selan-<provider>-<model>` for another provider's, such as `claude-selan-openai-gpt-6-2-sol`. Claude Code takes
`ANTHROPIC_BASE_URL=https://gw.<domain>/anthropic` and `ANTHROPIC_AUTH_TOKEN`. Developers run `selan login` into the company and
`selan claude`; it reaches your proxy by itself. Examples, and Codex:
[selan.ai/docs/self-hosted#api](https://selan.ai/docs/self-hosted#api).

## Known gaps

- **MCP clients that sign in through Selan** (Claude Desktop, claude.ai) get a 401 from your gateway: it looks
  Selan sessions up through control, which does not resolve their resource tokens yet. Plain Selan sessions
  and `selanct_` tokens work. The gateway logs this once at start.
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
| [`self-host-server`](skills/self-host-server) | a server of yours over SSH, a Hostinger VPS (found through the Hostinger MCP server or API) or any Debian or Ubuntu host: the VPN (Tailscale, WireGuard or an SSH tunnel), DNS and TLS with it, then moving keys, turning it on, upgrades and removing it |
| [`self-host-local`](skills/self-host-local) | this machine, with Docker; it follows `self-host-server` with this machine's differences |

Without the plugin, put both skill folders in `~/.claude/skills`, by link or by copy:

```sh
git clone https://github.com/selan-ai/selan-self-hosted ~/selan-self-hosted
mkdir -p ~/.claude/skills
ln -s ~/selan-self-hosted/skills/self-host-server ~/.claude/skills/self-host-server
ln -s ~/selan-self-hosted/skills/self-host-local ~/.claude/skills/self-host-local
```

Both show the tag, `compose.yaml` and `install.sh` first, ask which TLS to use, and have you run the line with the tokens yourself:
Claude never sees a token or the vault's material. They finish with one real request through the
proxy.

## Tests

`.github/workflows/check.yml` runs shellcheck and actionlint, refuses a pipe into `grep -q` or `head` in a
script, validates `compose.yaml` (with OpenBao, your own Vault and DNS-01) and the `Caddyfile` in every TLS
mode and with every DNS provider, and checks every image is pinned to a digest that exists. Then it runs each case below on its own fresh host with its own
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
| `openbao` | Ubuntu 24.04 | OpenBao on the server, tokens present: every image's cosign signature checked, three registrations with their public keys (selan-keys' sealing key too) and signed polls, keys 0600 in each volume, files root 0600, selan-keys reads a key with its AppRole for the proxy's token and refuses the gateway's and a stranger's, only selan-keys reaches the vault, only the gateway its Postgres, the vault and Caddy have no way out; `sudo selan-keys import` opens an import in the keys container from any directory, on a terminal and from a pipe; a re-run changes nothing and writes a changed `selan-keys` again; OpenBao **restarted** (by compose or docker) is unsealed by the unseal service with nobody's hands, and with that service stopped by `unseal.sh` and by a re-run; a secret id that stopped working is replaced; a wrong signer, a missing init file, an init file without OpenBao's data, one without an unseal key and one without a root token are refused |
| `own-vault` | Ubuntu 24.04 | **your own Vault** (an OpenBao dev server standing in): no OpenBao runs, the Vault's policies, auth methods and AppRole are unchanged, selan-keys reads a key through it; a missing or malformed address, role id or secret id is refused; a re-run changes nothing |
| `dns` | Ubuntu 24.04 | **DNS-01**: an unknown provider and a missing or malformed token are refused; with Caddy built from `caddy/`, Caddy gets a way out and asks the provider's API for the challenge record (CI's token is refused there, so no certificate); the token stays out of output, Caddy's log and its saved config; `install.sh` fails plainly when `/readyz` does not come |
| `own-ca` | Ubuntu 24.04 | **your own CA**: missing paths, missing files and files that are not PEM are refused; every name answers with that CA's certificate, checked against it alone; re-runs change nothing |
| `tokens` | Ubuntu 24.04 | a first run with a registration **token missing** or malformed is refused before anything is written; with both **present** it registers and the tokens leave `.env`; caller tokens are kept on a re-run; a broken one in `.env` is refused |
| `outside` | Ubuntu 24.04 | at a tag `install.sh` names it; the check from outside, against stand-ins for public DNS and check-host.net: a **public address that answers is refused with exit 2**, naming only the ports that answer; closed ports, a checker that does not answer, and no public address are each said; `SELAN_OUTSIDE_CHECK=no` skips it |
| `refusals` | Ubuntu 24.04 | every malformed or missing setting is refused, naming its variable; on a terminal every question is asked and kept, secrets unseen; a release without a codename; a VPN address found on `wg0`; non-root, a copy outside a checkout, a checkout elsewhere; unpinned and unknown images; an OpenBao and a Docker that will not start |
| `systemd` | Ubuntu 24.04 booted by systemd | a stopped Docker started with systemctl; the boot unit of 0.2.2 and earlier retired; after a **reboot** the stack is back and the unseal service unseals OpenBao with nobody's hands |
| `no-debian` | Alpine | outside Debian and Ubuntu `install.sh` installs nothing and says to install curl, then Docker with the compose plugin |
| `upgrade` | Ubuntu 24.04 | an **upgrade** as README's "Upgrade" does it: a server installed from v0.2.4, with a key in its vault, checks out this commit and runs `install.sh` again with the same settings, twice; it exits 0, every service runs on the image this commit pins, the key is still read through selan-keys, `selan-keys` is installed, and the second run changes nothing |
