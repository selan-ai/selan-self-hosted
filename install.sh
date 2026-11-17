#!/usr/bin/env bash
# Installs Selan's proxy, MCP gateway and selan-keys on this server, inside the company's VPN, with its vault,
# from the checkout it sits in: a release tag of this repository the company chose and read first.
#
#   export SELAN_REGISTRATION_TOKEN=selanreg_... SELAN_KEYS_REGISTRATION_TOKEN=selanreg_...; git clone --depth 1 \
#     --branch <tag> https://github.com/selan-ai/selan-self-hosted /opt/selan &&
#     sudo --preserve-env=SELAN_REGISTRATION_TOKEN,SELAN_KEYS_REGISTRATION_TOKEN /opt/selan/install.sh
#
# It fetches nothing of this repository and nothing from selan.ai. Safe to run again: it keeps what is
# set up, and run from a newer tag it upgrades. Settings come from the environment, else .env, else a
# question: README, "Settings".
set -euo pipefail

# Runs `cosign verify` for every image; pinned, as everything this script starts is.
COSIGN_IMAGE=ghcr.io/sigstore/cosign/cosign:v3.1.4@sha256:0f06154836d2de34f887a5c273506d52ca43edaa1d9e53e6510fa78a48f69c2d
DNS_PROVIDERS="bunny cloudflare digitalocean duckdns gandi hetzner ionos linode vultr"

say() { printf '%s\n' "$*"; }
fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
step() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || fail "run as root: sudo --preserve-env=SELAN_REGISTRATION_TOKEN,SELAN_KEYS_REGISTRATION_TOKEN $0"
umask 077

# ---------------------------------------------------------------- tools and Docker

debian_like() {
  [ -r /etc/os-release ] && grep -Eq '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release
}

install_curl() {
  command -v curl >/dev/null && return
  debian_like || fail "install curl first; this script installs it only on Debian or Ubuntu"
  step "Installing curl"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl >/dev/null
}

install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    return
  fi
  debian_like || fail "install Docker with the compose plugin first (https://docs.docker.com/engine/install/); this script installs it only on Debian or Ubuntu"
  step "Installing Docker from Docker's own apt repository"
  # shellcheck disable=SC1091
  . /etc/os-release
  local distro=$ID
  [ "$distro" = ubuntu ] || [ "$distro" = debian ] || distro=$(printf '%s' "$ID_LIKE" | grep -Eo 'ubuntu|debian' | head -n 1)
  local codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
  [ -n "$codename" ] || fail "cannot tell this release's codename from /etc/os-release"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$distro" "$codename" >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
}

start_docker() {
  docker info >/dev/null 2>&1 && return
  command -v systemctl >/dev/null && systemctl enable --now docker >/dev/null 2>&1 || true
  for _ in $(seq 30); do
    docker info >/dev/null 2>&1 && return
    sleep 1
  done
  fail "Docker is installed but not running"
}

# ---------------------------------------------------------------- this checkout, at the tag it was cloned at

find_checkout() {
  DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent/x}")" 2>/dev/null && pwd || true)
  [ -n "$DIR" ] && [ -f "$DIR/compose.yaml" ] && [ -f "$DIR/signers.txt" ] ||
    fail "run install.sh from a clone of https://github.com/selan-ai/selan-self-hosted at a release tag; README, \"Install\""
  local git=(git -c safe.directory="$DIR" -C "$DIR")
  COMMIT=$("${git[@]}" rev-parse -q --verify HEAD 2>/dev/null || echo "an unversioned copy")
  TAG=$("${git[@]}" describe --tags --exact-match HEAD 2>/dev/null || echo "no tag")
  step "Installing from $DIR at $TAG ($COMMIT)"
  [ "$TAG" != "no tag" ] || say "This checkout is not at a release tag; README, \"Upgrade\", says how to check one out."
  # OpenBao reads its config as uid 100, whatever umask the clone was made under.
  chmod go+r "$DIR/openbao.hcl" "$DIR/Caddyfile"
}

# At boot root runs unseal.sh from here, so a server install leaves nobody else able to change these files.
own_checkout() {
  [ "$DIR" = /opt/selan ] || return 0
  chown -R root:root "$DIR"
  chmod -R go-w "$DIR"
}

# ---------------------------------------------------------------- settings: environment, then .env, then a question

ENV_FILE=""

saved() {
  [ -f "$ENV_FILE" ] || return 0
  local line
  line=$(grep -E "^$1=" "$ENV_FILE" | tail -n 1) || return 0
  line=${line#*=}
  line=${line#\'}
  printf '%s' "${line%\'}"
}

# The environment wins over .env, so a run with a new value changes it.
setting() {
  local value=${!1:-}
  [ -n "$value" ] || value=$(saved "$1")
  printf '%s' "$value"
}

ask() {
  local answer=""
  [ -r /dev/tty ] || fail "$2 is not set; export $1 and run again"
  printf '%s: ' "$2" >/dev/tty
  read -r answer </dev/tty || true
  printf '%s' "$answer"
}

valid_host() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }

private_ipv4() {
  local a b
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
  [ "$a" = 10 ] || [ "$a" = 127 ] ||
    { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } ||
    { [ "$a" = 192 ] && [ "$b" = 168 ]; } ||
    { [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }
}

# The first address on a VPN interface: Tailscale, WireGuard, OpenVPN, ZeroTier, Nebula.
vpn_address() {
  command -v ip >/dev/null || return 0
  ip -4 -o addr show 2>/dev/null |
    awk '$2 ~ /^(tailscale|wg|tun|zt|nebula)/ { split($4, a, "/"); print a[1]; exit }'
}

read_settings() {
  ENV_FILE="$DIR/.env"
  step "Settings"

  PROXY_HOST=$(setting SELAN_PROXY_HOST)
  [ -n "$PROXY_HOST" ] || PROXY_HOST=$(ask SELAN_PROXY_HOST "The proxy's name, as entered under Add server (gw.example.com)")
  PROXY_HOST=${PROXY_HOST#https://}
  PROXY_HOST=${PROXY_HOST%/}
  valid_host "$PROXY_HOST" || fail "SELAN_PROXY_HOST '$PROXY_HOST' is not a host name like gw.example.com"

  GATEWAY_HOST=$(setting SELAN_GATEWAY_HOST)
  [ -n "$GATEWAY_HOST" ] || GATEWAY_HOST="mcp.${PROXY_HOST#*.}"
  valid_host "$GATEWAY_HOST" || fail "SELAN_GATEWAY_HOST '$GATEWAY_HOST' is not a host name"

  KEYS_HOST=$(setting SELAN_KEYS_HOST)
  [ -n "$KEYS_HOST" ] || KEYS_HOST="keys.${PROXY_HOST#*.}"
  valid_host "$KEYS_HOST" || fail "SELAN_KEYS_HOST '$KEYS_HOST' is not a host name"

  BIND_ADDR=$(setting SELAN_BIND_ADDR)
  [ -n "$BIND_ADDR" ] || BIND_ADDR=$(vpn_address)
  [ -n "$BIND_ADDR" ] || BIND_ADDR=$(ask SELAN_BIND_ADDR "This server's address on your VPN (100.x, 10.x, 172.16-31.x or 192.168.x)")
  private_ipv4 "$BIND_ADDR" ||
    fail "SELAN_BIND_ADDR '$BIND_ADDR' is not a private IPv4 address; the proxy listens on your VPN only, never on a public address"

  read_tls
  ALLOWED=$(setting ALLOWED_CIDRS)
  ALLOWED=${ALLOWED:-private_ranges}
  [[ "$ALLOWED" =~ ^(private_ranges|[0-9a-f.:/\ ]+)$ ]] || fail "ALLOWED_CIDRS is private_ranges or a space-separated list of CIDRs"

  CONTROL=$(setting CONTROL_BASE_URL)
  AUTH=$(setting AUTH_BASE_URL)
  for url in "$CONTROL" "$AUTH"; do
    [ -z "$url" ] || [[ "$url" =~ ^https://[a-z0-9.-]+(:[0-9]+)?$ ]] || [[ "$url" =~ ^http://[a-z0-9-]+(:[0-9]+)?$ ]] ||
      fail "'$url' is not a base URL like https://control.selan.ai"
  done

  TOKEN=$(registration_token SELAN_REGISTRATION_TOKEN)
  KEYS_TOKEN=$(registration_token SELAN_KEYS_REGISTRATION_TOKEN)
  PROXY_KEYS_TOKEN=$(caller_token PROXY_KEYS_TOKEN)
  GATEWAY_KEYS_TOKEN=$(caller_token GATEWAY_KEYS_TOKEN)

  OWN_VAULT=$(setting VAULT_ADDR)
  PREFIX=$(setting VAULT_PREFIX)
  PREFIX=${PREFIX:-kv/selan/}
  [[ "$PREFIX" =~ ^[A-Za-z0-9_/-]+/$ ]] || fail "VAULT_PREFIX is a path ending in /, like kv/selan/"
  KEYS_ROLE=$(setting KEYS_VAULT_ROLE_ID)
  KEYS_SECRET=$(setting KEYS_VAULT_SECRET_ID)
  for id in "$KEYS_ROLE" "$KEYS_SECRET"; do
    [[ "$id" =~ ^[A-Za-z0-9_.-]*$ ]] || fail "an AppRole id in $ENV_FILE has characters a role or secret id never has"
  done

  say "proxy    https://$PROXY_HOST"
  say "gateway  https://$GATEWAY_HOST"
  say "keys     https://$KEYS_HOST (selan-keys, the only part that reads the vault)"
  say "listens  $BIND_ADDR:443 (TLS: $TLS_SAID), answering $ALLOWED"
  if [ -n "$OWN_VAULT" ]; then say "vault    yours, $OWN_VAULT"; else say "vault    OpenBao, on this server"; fi
}

# Each one-time token from Add server: needed on the first run, gone from .env once used.
registration_token() {
  local token=${!1:-}
  [ -n "$token" ] || token=$(saved "$1")
  [ -n "$token" ] || [ -f "$ENV_FILE" ] ||
    fail "$1 is not set: copy the line from Settings › Own servers › Add server in Selan"
  [ -z "$token" ] || [[ "$token" =~ ^selanreg_[A-Za-z0-9_-]+$ ]] || fail "$1 does not look like selanreg_…"
  printf '%s' "$token"
}

# What the proxy and the gateway present to selan-keys, one each: made here once, kept in .env.
caller_token() {
  local token
  token=$(saved "$1")
  [ -n "$token" ] || token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  [[ "$token" =~ ^[0-9a-f]{64}$ ]] || fail "$1 in $ENV_FILE is not 64 hex characters; delete the line to make a new one"
  printf '%s' "$token"
}

ask_secret() {
  local answer=""
  [ -r /dev/tty ] || fail "$2 is not set; export $1 and run again"
  printf '%s (not shown): ' "$2" >/dev/tty
  read -rs answer </dev/tty || true
  printf '\n' >/dev/tty
  printf '%s' "$answer"
}

# A private name cannot be proved to Let's Encrypt over HTTP-01 or TLS-ALPN: DNS-01, or the company's CA.
read_tls() {
  TLS=$(setting SELAN_TLS)
  [ -n "$TLS" ] || TLS=$(ask SELAN_TLS "TLS certificates: dns (Let's Encrypt, over your DNS provider's API) or files (from your own CA)")
  DNS_PROVIDER="" DNS_TOKEN=""
  case "$TLS" in
    dns)
      DNS_PROVIDER=$(setting SELAN_DNS_PROVIDER)
      [ -n "$DNS_PROVIDER" ] || DNS_PROVIDER=$(ask SELAN_DNS_PROVIDER "Your DNS provider, one of: $DNS_PROVIDERS")
      [[ " $DNS_PROVIDERS " == *" $DNS_PROVIDER "* ]] ||
        fail "SELAN_DNS_PROVIDER '$DNS_PROVIDER' is not one of: $DNS_PROVIDERS. With another, use SELAN_TLS=files"
      DNS_TOKEN=$(setting SELAN_DNS_TOKEN)
      [ -n "$DNS_TOKEN" ] || DNS_TOKEN=$(ask_secret SELAN_DNS_TOKEN "An API token for $DNS_PROVIDER that may edit TXT records in your zone")
      [[ "$DNS_TOKEN" =~ ^[A-Za-z0-9._:~+/=-]+$ ]] || fail "SELAN_DNS_TOKEN is empty or has characters an API token never has"
      TLS_SAID="Let's Encrypt over DNS-01 at $DNS_PROVIDER"
      ;;
    files)
      certificate_files
      TLS_SAID="your CA's certificate in $DIR/certs"
      ;;
    internal) TLS_SAID="Caddy's own CA, for a trial: every client has to trust it" ;;
    *) fail "SELAN_TLS is dns or files (or internal, for a trial), not '$TLS'" ;;
  esac
}

# Copied in from SELAN_TLS_CERT and SELAN_TLS_KEY, or asked for, unless certs/ already has them.
certificate_files() {
  local cert key
  cert=${SELAN_TLS_CERT:-} key=${SELAN_TLS_KEY:-}
  if [ -z "$cert" ] && [ ! -s "$DIR/certs/fullchain.pem" ]; then
    cert=$(ask SELAN_TLS_CERT "Path to the certificate chain (PEM) your CA issued for $PROXY_HOST, $GATEWAY_HOST and $KEYS_HOST")
  fi
  if [ -z "$key" ] && [ ! -s "$DIR/certs/privkey.pem" ]; then
    key=$(ask SELAN_TLS_KEY "Path to its private key (PEM)")
  fi
  install -d -m 0700 "$DIR/certs"
  if [ -n "$cert" ]; then
    [ -s "$cert" ] || fail "$cert is not a file"
    cmp -s "$cert" "$DIR/certs/fullchain.pem" || install -m 0644 "$cert" "$DIR/certs/fullchain.pem"
  fi
  if [ -n "$key" ]; then
    [ -s "$key" ] || fail "$key is not a file"
    cmp -s "$key" "$DIR/certs/privkey.pem" || install -m 0600 "$key" "$DIR/certs/privkey.pem"
  fi
  grep -q 'BEGIN CERTIFICATE' "$DIR/certs/fullchain.pem" 2>/dev/null || fail "$DIR/certs/fullchain.pem is not a PEM certificate chain"
  grep -q 'PRIVATE KEY' "$DIR/certs/privkey.pem" 2>/dev/null || fail "$DIR/certs/privkey.pem is not a PEM private key"
}

# .env is the only place the tokens and the vault's AppRole ids are kept: root's, mode 0600.
write_env() {
  local tmp="$ENV_FILE.tmp"
  install -m 0600 /dev/null "$tmp"
  {
    printf '# Written by install.sh at %s. Root only: it holds the registration token, the DNS token and vault ids.\n' "$TAG"
    printf "SELAN_PROXY_HOST='%s'\n" "$PROXY_HOST"
    printf "SELAN_GATEWAY_HOST='%s'\n" "$GATEWAY_HOST"
    printf "SELAN_KEYS_HOST='%s'\n" "$KEYS_HOST"
    printf "SELAN_BIND_ADDR='%s'\n" "$BIND_ADDR"
    printf "SELAN_TLS='%s'\n" "$TLS"
    if [ "$TLS" = dns ]; then
      printf "SELAN_DNS_PROVIDER='%s'\n" "$DNS_PROVIDER"
      printf "SELAN_DNS_TOKEN='%s'\n" "$DNS_TOKEN"
      printf "COMPOSE_FILE='%s'\n" "$DIR/compose.yaml:$DIR/compose.dns.yaml"
    fi
    printf "ALLOWED_CIDRS='%s'\n" "$ALLOWED"
    [ -z "$CONTROL" ] || printf "CONTROL_BASE_URL='%s'\n" "$CONTROL"
    [ -z "$AUTH" ] || printf "AUTH_BASE_URL='%s'\n" "$AUTH"
    printf "SELAN_REGISTRATION_TOKEN='%s'\n" "$TOKEN"
    printf "SELAN_KEYS_REGISTRATION_TOKEN='%s'\n" "$KEYS_TOKEN"
    printf "PROXY_KEYS_TOKEN='%s'\n" "$PROXY_KEYS_TOKEN"
    printf "GATEWAY_KEYS_TOKEN='%s'\n" "$GATEWAY_KEYS_TOKEN"
    if [ -n "$OWN_VAULT" ]; then
      printf "COMPOSE_PROFILES=''\n"
      printf "VAULT_ADDR='%s'\n" "$OWN_VAULT"
    else
      printf "COMPOSE_PROFILES='openbao'\n"
    fi
    printf "VAULT_PREFIX='%s'\n" "$PREFIX"
    printf "KEYS_VAULT_ROLE_ID='%s'\n" "$KEYS_ROLE"
    printf "KEYS_VAULT_SECRET_ID='%s'\n" "$KEYS_SECRET"
  } >"$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

# ---------------------------------------------------------------- the vault

compose() { docker compose --project-directory "$DIR" "$@"; }
bao() { compose exec -T -e BAO_TOKEN openbao bao "$@"; }

own_vault() {
  [[ "$OWN_VAULT" =~ ^https?://[A-Za-z0-9.:-]+(/.*)?$ ]] || fail "VAULT_ADDR '$OWN_VAULT' is not a URL"
  [ -n "$KEYS_ROLE" ] && [ -n "$KEYS_SECRET" ] ||
    fail "with VAULT_ADDR set, put KEYS_VAULT_ROLE_ID and KEYS_VAULT_SECRET_ID (an AppRole limited to ${PREFIX}*) in $ENV_FILE, mode 0600; README, \"Your own Vault\""
  say "Using your Vault at $OWN_VAULT; nothing in it is changed."
}

# OpenBao for a company without a Vault: initialised once, its material in one root-only file.
openbao() {
  local init="$DIR/openbao-init.json" initialised=""
  step "OpenBao"
  write_env
  compose up -d openbao >/dev/null 2>&1 || compose up -d openbao

  for _ in $(seq 60); do
    # bao status exits 2 while sealed, so the answer is read from its output, not its code.
    initialised=$(BAO_TOKEN='' bao status -format=json 2>/dev/null | grep -Eo '"initialized": *(true|false)' || true)
    [ -n "$initialised" ] && break
    sleep 2
  done
  [ -n "$initialised" ] || fail "OpenBao is not answering; docker compose --project-directory $DIR logs openbao"

  if [[ "$initialised" == *false ]]; then
    [ ! -s "$init" ] || fail "OpenBao's data is empty but $init exists: restore the openbao-data volume, or move $init away to start over"
    BAO_TOKEN='' bao operator init -key-shares=1 -key-threshold=1 -format=json >"$init.tmp"
    mv -f "$init.tmp" "$init"
    say "Initialised. Its unseal key and root token are in $init (root only, mode 0600): back it up off this server."
  else
    [ -s "$init" ] || fail "OpenBao is already initialised but $init is missing; restore it from your backup"
    say "Already initialised; the unseal key and root token are in $init."
  fi
  chmod 0600 "$init"
  "$DIR/unseal.sh"
  install_unseal_unit

  BAO_TOKEN=$(sed -n 's/^ *"root_token": *"\([^"]*\)".*/\1/p' "$init")
  [ -n "$BAO_TOKEN" ] || fail "no root token in $init"
  export BAO_TOKEN

  local mount=${PREFIX%%/*} path=${PREFIX#*/}
  path=${path%/}
  bao secrets list -format=json | grep -q "\"$mount/\"" || bao secrets enable -path="$mount" kv-v2 >/dev/null
  bao auth list -format=json | grep -q '"approle/"' || bao auth enable approle >/dev/null
  bao policy write selan - >/dev/null <<EOF
# selan-keys reads and writes the company's keys under ${PREFIX}, and nothing else.
path "$mount/data/$path/*" { capabilities = ["create", "read", "update", "delete"] }
path "$mount/metadata/$path/*" { capabilities = ["read", "list", "delete"] }
path "$mount/metadata/$path" { capabilities = ["list"] }
EOF
  approle selan-keys KEYS_ROLE KEYS_SECRET
  say "AppRole selan-keys may use ${PREFIX}* only; the proxy and the gateway have no vault identity."
  unset BAO_TOKEN
}

# Keeps a secret id that still logs in, so a second run changes nothing.
approle() {
  local role=$1 role_var=$2 secret_var=$3
  bao write "auth/approle/role/$role" token_policies=selan token_ttl=1h token_max_ttl=4h \
    secret_id_ttl=0 token_no_default_policy=true >/dev/null
  printf -v "$role_var" '%s' "$(bao read -field=role_id "auth/approle/role/$role/role-id")"
  local secret=${!secret_var}
  if [ -z "$secret" ] || ! bao write -field=token_accessor auth/approle/login \
    role_id="${!role_var}" secret_id=- <<<"$secret" >/dev/null 2>&1; then
    secret=$(bao write -f -field=secret_id "auth/approle/role/$role/secret-id")
  fi
  printf -v "$secret_var" '%s' "$secret"
}

install_unseal_unit() {
  [ "$DIR" = /opt/selan ] && [ -d /run/systemd/system ] || return 0
  cat >/etc/systemd/system/selan-unseal.service <<EOF
[Unit]
Description=Unseal Selan's OpenBao after Docker starts it
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$DIR/unseal.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable selan-unseal.service >/dev/null 2>&1
}

# ---------------------------------------------------------------- up, ready, and not public

start() {
  step "Starting the proxy, the gateway and selan-keys"
  write_env
  compose config --quiet
  verify_images
  compose pull --quiet --policy missing
  compose up -d --remove-orphans
}

# SELAN_UNSIGNED_OK names exact image references to start unchecked: CI's stand-ins, never a release.
unsigned_ok() { [[ " ${SELAN_UNSIGNED_OK:-} " == *" $1 "* ]]; }

# Every image compose runs: pinned by digest, and signed by the identity signers.txt names for it.
verify_images() {
  step "Checking each image's cosign signature"
  local image name repo identity issuer images log
  log=$(mktemp)
  images=$(compose config --images | sort -u)
  for image in $images; do
    if unsigned_ok "$image"; then
      say "NOT CHECKED: $image (SELAN_UNSIGNED_OK)"
      continue
    fi
    [[ "$image" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || fail "$image is not pinned by digest"
    name=${image%@*}
    repo=$name
    [[ "${name##*/}" != *:* ]] || repo=${name%:*}
    read -r identity issuer < <(awk -v r="$repo" '$1 == r { print $2, $3 }' "$DIR/signers.txt") ||
      fail "signers.txt names nobody who signs $repo"
    if ! docker run --rm "$COSIGN_IMAGE" verify --certificate-identity-regexp "$identity" \
      --certificate-oidc-issuer "$issuer" "$image" >/dev/null 2>"$log"; then
      tail -n 3 "$log" >&2
      rm -f "$log"
      fail "$image is not signed by $identity; nothing was started from it"
    fi
    say "signed:  $image"
  done
  rm -f "$log"
}

wait_ready() {
  local host
  step "Waiting for your server to register with Selan and answer /readyz"
  for host in "$PROXY_HOST" "$GATEWAY_HOST" "$KEYS_HOST"; do
    for i in $(seq 60); do
      curl -fsSk --max-time 5 -o /dev/null --resolve "$host:443:$BIND_ADDR" "https://$host/readyz" 2>/dev/null && break
      [ "$i" = 60 ] && {
        compose logs --tail 30 proxy gateway keys >&2 || true
        fail "https://$host/readyz did not answer within 5 minutes"
      }
      sleep 5
    done
    say "https://$host/readyz answers on $BIND_ADDR."
  done
  # Registered: the one-time tokens have done their work, so they leave .env.
  TOKEN="" KEYS_TOKEN=""
  write_env
}

public_ipv4s() {
  local host
  for host in "$PROXY_HOST" "$GATEWAY_HOST" "$KEYS_HOST"; do
    curl -fsS --max-time 10 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$host&type=A" |
      grep -Eo '"data": *"[0-9.]+"' | grep -Eo '[0-9.]+' || true
  done
  curl -4fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p' || true
}

# One TCP connect from three of check-host.net's nodes: answered, closed, or unknown.
probe() {
  local started id result
  started=$(curl -fsS --max-time 15 -H 'Accept: application/json' "https://check-host.net/check-tcp?host=$1&max_nodes=3") || {
    echo unknown
    return
  }
  id=$(printf '%s' "$started" | sed -n 's/.*"request_id": *"\([^"]*\)".*/\1/p')
  [ -n "$id" ] || {
    echo unknown
    return
  }
  for _ in $(seq 15); do
    sleep 2
    result=$(curl -fsS --max-time 15 -H 'Accept: application/json' "https://check-host.net/check-result/$id") || continue
    if [[ "$result" == *'"time"'* ]]; then
      echo answered
      return
    fi
    [[ "$result" == *null* ]] || {
      echo closed
      return
    }
  done
  echo unknown
}

check_outside() {
  step "Checking from outside that nothing here answers on the internet"
  if [ "${SELAN_OUTSIDE_CHECK:-yes}" = no ]; then
    say "Skipped: SELAN_OUTSIDE_CHECK=no."
    return
  fi
  local ips=() ip port answer exposed=() unknown=()
  while read -r ip; do
    [ -z "$ip" ] || private_ipv4 "$ip" || ips+=("$ip")
  done < <(public_ipv4s | sort -u)
  if [ "${#ips[@]}" = 0 ]; then
    say "Not checked: neither public DNS nor this server's way out names a public address."
    return
  fi
  for ip in "${ips[@]}"; do
    for port in 443 80 8080 8200; do
      answer=$(probe "$ip:$port")
      case "$answer" in
        answered) exposed+=("$ip:$port") ;;
        unknown) unknown+=("$ip:$port") ;;
      esac
    done
  done
  if [ "${#exposed[@]}" -gt 0 ]; then
    say ""
    say "WARNING: ${exposed[*]} answers from the internet."
    say "Your proxy and vault must be reachable on your VPN only. Close those ports in your firewall"
    say "(on Hostinger: hPanel › VPS › Firewall) and make sure $PROXY_HOST, $GATEWAY_HOST and $KEYS_HOST resolve to your VPN address."
    say "Port 443 here is published on $BIND_ADDR only; anything else answering is another service on this server."
    exit 2
  fi
  if [ "${#unknown[@]}" -gt 0 ]; then
    say "Could not check ${unknown[*]} from outside (check-host.net did not answer). Check them yourself from off your VPN."
  else
    say "From outside, nothing answers on ${ips[*]} at ports 443, 80, 8080 or 8200."
  fi
}

main() {
  install_curl
  install_docker
  start_docker
  find_checkout
  own_checkout
  read_settings
  if [ -n "$OWN_VAULT" ]; then own_vault; else openbao; fi
  start
  wait_ready
  check_outside
  step "Done"
  say "Tag:     $TAG ($COMMIT)"
  say "Files:   $DIR (settings in $DIR/.env, root only)"
  [ -n "$OWN_VAULT" ] || say "Vault:   OpenBao; unseal key and root token in $DIR/openbao-init.json (root only). Back it up off this server."
  say "Selan shows this server under Settings › Own servers. README, \"Upgrade\", says how to move to a newer tag."
}

main "$@"
