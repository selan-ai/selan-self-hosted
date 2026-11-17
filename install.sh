#!/usr/bin/env bash
# Installs Selan's proxy and MCP gateway on this server, inside the company's VPN, with its vault.
#
#   export SELAN_REGISTRATION_TOKEN=selanreg_...
#   curl -fsSL https://selan.ai/self-hosted/install.sh | sudo --preserve-env=SELAN_REGISTRATION_TOKEN bash
#
# Safe to run again: it keeps what is already set up, and with a newer commit it upgrades.
# Settings it reads from the environment, else from /opt/selan/.env, else asks: README, "Settings".
set -euo pipefail

REPO=https://github.com/selan-ai/selan-self-hosted
# selan.ai writes the commit it serves this file from here; README, "How install.sh is served".
PINNED_COMMIT=""

say() { printf '%s\n' "$*"; }
fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
step() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || fail "run as root: curl -fsSL https://selan.ai/self-hosted/install.sh | sudo --preserve-env=SELAN_REGISTRATION_TOKEN bash"
umask 077

# ---------------------------------------------------------------- tools and Docker

debian_like() {
  [ -r /etc/os-release ] && grep -Eq '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release
}

install_tools() {
  local missing=()
  for tool in curl git; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  [ "${#missing[@]}" = 0 ] && return
  debian_like || fail "install ${missing[*]} first; this script installs them only on Debian or Ubuntu"
  step "Installing ${missing[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git >/dev/null
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

# ---------------------------------------------------------------- this repository, at one commit

fetch_repo() {
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent/x}")" 2>/dev/null && pwd || true)
  if [ -n "$PINNED_COMMIT" ]; then
    [[ "$PINNED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "PINNED_COMMIT is not a commit sha"
    DIR=${SELAN_DIR:-/opt/selan}
    step "Fetching $REPO at $PINNED_COMMIT into $DIR"
    install -d -m 0700 "$DIR"
    # The checked-out files are mounted into OpenBao and Caddy, which do not run as root.
    (
      umask 022
      [ -d "$DIR/.git" ] || git -C "$DIR" init -q
      git -C "$DIR" fetch -q --depth 1 "$REPO" "$PINNED_COMMIT"
      git -C "$DIR" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
    ) || fail "could not check out $PINNED_COMMIT in $DIR; move local changes to this repository's files away first"
    [ "$(git -C "$DIR" rev-parse HEAD)" = "$PINNED_COMMIT" ] || fail "$DIR is not at $PINNED_COMMIT"
    COMMIT=$PINNED_COMMIT
  elif [ -n "$here" ] && [ -f "$here/compose.yaml" ] && [ -f "$here/unseal.sh" ]; then
    DIR=$here
    COMMIT=$(git -C "$DIR" rev-parse -q --verify HEAD 2>/dev/null || echo "an unversioned copy")
    step "Using this checkout, $DIR, at $COMMIT"
  else
    fail "this copy of install.sh is not pinned to a commit; use https://selan.ai/self-hosted/install.sh"
  fi
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

  BIND_ADDR=$(setting SELAN_BIND_ADDR)
  [ -n "$BIND_ADDR" ] || BIND_ADDR=$(vpn_address)
  [ -n "$BIND_ADDR" ] || BIND_ADDR=$(ask SELAN_BIND_ADDR "This server's address on your VPN (100.x, 10.x, 172.16-31.x or 192.168.x)")
  private_ipv4 "$BIND_ADDR" ||
    fail "SELAN_BIND_ADDR '$BIND_ADDR' is not a private IPv4 address; the proxy listens on your VPN only, never on a public address"

  TLS=$(setting SELAN_TLS)
  TLS=${TLS:-internal}
  case "$TLS" in
    internal) ;;
    files)
      [ -s "$DIR/certs/fullchain.pem" ] && [ -s "$DIR/certs/privkey.pem" ] ||
        fail "SELAN_TLS=files needs $DIR/certs/fullchain.pem and privkey.pem, for both $PROXY_HOST and $GATEWAY_HOST"
      ;;
    *) fail "SELAN_TLS is internal or files, not '$TLS'" ;;
  esac

  ALLOWED=$(setting ALLOWED_CIDRS)
  ALLOWED=${ALLOWED:-private_ranges}
  [[ "$ALLOWED" =~ ^(private_ranges|[0-9a-f.:/\ ]+)$ ]] || fail "ALLOWED_CIDRS is private_ranges or a space-separated list of CIDRs"

  CONTROL=$(setting CONTROL_BASE_URL)
  AUTH=$(setting AUTH_BASE_URL)
  for url in "$CONTROL" "$AUTH"; do
    [ -z "$url" ] || [[ "$url" =~ ^https://[a-z0-9.-]+(:[0-9]+)?$ ]] || [[ "$url" =~ ^http://[a-z0-9-]+(:[0-9]+)?$ ]] ||
      fail "'$url' is not a base URL like https://control.selan.ai"
  done

  TOKEN=${SELAN_REGISTRATION_TOKEN:-}
  [ -n "$TOKEN" ] || TOKEN=$(saved SELAN_REGISTRATION_TOKEN)
  if [ -z "$TOKEN" ] && [ ! -f "$ENV_FILE" ]; then
    fail "SELAN_REGISTRATION_TOKEN is not set: copy the line from Settings › Own servers › Add server in Selan"
  fi
  [ -z "$TOKEN" ] || [[ "$TOKEN" =~ ^selanreg_[A-Za-z0-9_-]+$ ]] || fail "SELAN_REGISTRATION_TOKEN does not look like selanreg_…"

  OWN_VAULT=$(setting VAULT_ADDR)
  PREFIX=$(setting VAULT_PREFIX)
  PREFIX=${PREFIX:-kv/selan/}
  [[ "$PREFIX" =~ ^[A-Za-z0-9_/-]+/$ ]] || fail "VAULT_PREFIX is a path ending in /, like kv/selan/"
  PROXY_ROLE=$(setting PROXY_VAULT_ROLE_ID)
  PROXY_SECRET=$(setting PROXY_VAULT_SECRET_ID)
  GATEWAY_ROLE=$(setting GATEWAY_VAULT_ROLE_ID)
  GATEWAY_SECRET=$(setting GATEWAY_VAULT_SECRET_ID)
  for id in "$PROXY_ROLE" "$PROXY_SECRET" "$GATEWAY_ROLE" "$GATEWAY_SECRET"; do
    [[ "$id" =~ ^[A-Za-z0-9_.-]*$ ]] || fail "an AppRole id in $ENV_FILE has characters a role or secret id never has"
  done

  say "proxy    https://$PROXY_HOST"
  say "gateway  https://$GATEWAY_HOST"
  say "listens  $BIND_ADDR:443 (TLS: $TLS), answering $ALLOWED"
  if [ -n "$OWN_VAULT" ]; then say "vault    yours, $OWN_VAULT"; else say "vault    OpenBao, on this server"; fi
}

# .env is the only place the token and the vault's AppRole ids are kept: root's, mode 0600.
write_env() {
  local tmp="$ENV_FILE.tmp"
  install -m 0600 /dev/null "$tmp"
  {
    printf '# Written by install.sh at %s. Root only: it holds the registration token and vault ids.\n' "$COMMIT"
    printf "SELAN_PROXY_HOST='%s'\n" "$PROXY_HOST"
    printf "SELAN_GATEWAY_HOST='%s'\n" "$GATEWAY_HOST"
    printf "SELAN_BIND_ADDR='%s'\n" "$BIND_ADDR"
    printf "SELAN_TLS='%s'\n" "$TLS"
    printf "ALLOWED_CIDRS='%s'\n" "$ALLOWED"
    [ -z "$CONTROL" ] || printf "CONTROL_BASE_URL='%s'\n" "$CONTROL"
    [ -z "$AUTH" ] || printf "AUTH_BASE_URL='%s'\n" "$AUTH"
    printf "SELAN_REGISTRATION_TOKEN='%s'\n" "$TOKEN"
    if [ -n "$OWN_VAULT" ]; then
      printf "COMPOSE_PROFILES=''\n"
      printf "VAULT_ADDR='%s'\n" "$OWN_VAULT"
    else
      printf "COMPOSE_PROFILES='openbao'\n"
    fi
    printf "VAULT_PREFIX='%s'\n" "$PREFIX"
    printf "PROXY_VAULT_ROLE_ID='%s'\n" "$PROXY_ROLE"
    printf "PROXY_VAULT_SECRET_ID='%s'\n" "$PROXY_SECRET"
    printf "GATEWAY_VAULT_ROLE_ID='%s'\n" "$GATEWAY_ROLE"
    printf "GATEWAY_VAULT_SECRET_ID='%s'\n" "$GATEWAY_SECRET"
  } >"$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

# ---------------------------------------------------------------- the vault

compose() { docker compose --project-directory "$DIR" "$@"; }
bao() { compose exec -T -e BAO_TOKEN openbao bao "$@"; }

own_vault() {
  [[ "$OWN_VAULT" =~ ^https?://[A-Za-z0-9.:-]+(/.*)?$ ]] || fail "VAULT_ADDR '$OWN_VAULT' is not a URL"
  [ -n "$PROXY_ROLE" ] && [ -n "$PROXY_SECRET" ] ||
    fail "with VAULT_ADDR set, put PROXY_VAULT_ROLE_ID and PROXY_VAULT_SECRET_ID (an AppRole limited to ${PREFIX}*) in $ENV_FILE, mode 0600; README, \"Your own Vault\""
  if [ -z "$GATEWAY_ROLE" ] || [ -z "$GATEWAY_SECRET" ]; then
    GATEWAY_ROLE=$PROXY_ROLE GATEWAY_SECRET=$PROXY_SECRET
  fi
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
# The proxy and the gateway read and write their keys under ${PREFIX}, and nothing else.
path "$mount/data/$path/*" { capabilities = ["create", "read", "update", "delete"] }
path "$mount/metadata/$path/*" { capabilities = ["read", "list", "delete"] }
path "$mount/metadata/$path" { capabilities = ["list"] }
EOF
  approle selan-proxy PROXY_ROLE PROXY_SECRET
  approle selan-gateway GATEWAY_ROLE GATEWAY_SECRET
  say "AppRoles selan-proxy and selan-gateway may use ${PREFIX}* only."
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
  step "Starting the proxy and the gateway"
  write_env
  compose config --quiet
  compose pull --quiet
  compose up -d --remove-orphans
}

wait_ready() {
  local host
  step "Waiting for your server to register with Selan and answer /readyz"
  for host in "$PROXY_HOST" "$GATEWAY_HOST"; do
    for i in $(seq 60); do
      curl -fsSk --max-time 5 -o /dev/null --resolve "$host:443:$BIND_ADDR" "https://$host/readyz" 2>/dev/null && break
      [ "$i" = 60 ] && {
        compose logs --tail 30 proxy gateway >&2 || true
        fail "https://$host/readyz did not answer within 5 minutes"
      }
      sleep 5
    done
    say "https://$host/readyz answers on $BIND_ADDR."
  done
  # Registered: the one-time token has done its work, so it leaves .env.
  TOKEN=""
  write_env
}

public_ipv4s() {
  local host
  for host in "$PROXY_HOST" "$GATEWAY_HOST"; do
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
    say "(on Hostinger: hPanel › VPS › Firewall) and make sure $PROXY_HOST and $GATEWAY_HOST resolve to your VPN address."
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
  install_tools
  install_docker
  start_docker
  fetch_repo
  read_settings
  if [ -n "$OWN_VAULT" ]; then own_vault; else openbao; fi
  start
  wait_ready
  check_outside
  step "Done"
  say "Commit:  $COMMIT"
  say "Files:   $DIR (settings in $DIR/.env, root only)"
  [ -n "$OWN_VAULT" ] || say "Vault:   OpenBao; unseal key and root token in $DIR/openbao-init.json (root only). Back it up off this server."
  say "Selan shows this server under Settings › Own servers. Run this line again to upgrade."
}

main "$@"
