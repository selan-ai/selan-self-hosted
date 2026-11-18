# Sourced by each case in ci/cases/: run as root in a fresh container from ci/dind-test.sh, at /opt/selan.
# The real proxy, gateway and selan-keys against a fake control, and every answer install.sh needs
# from the environment. install.sh runs traced, so ci/paths.py can tell which of its paths a case took.
# shellcheck shell=bash
set -euo pipefail

cd /opt/selan
root=$PWD
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
pass() { printf 'ok: %s\n' "$*"; }

# A probe, never part of the stack: python for socket checks and CI's fakes, curl for HTTP from a network.
probe=python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
export curl_image=curlimages/curl@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93
# The fake control alone runs unsigned (python, CI's own): every image of the stack is checked.
export SELAN_UNSIGNED_OK=$probe
export COMPOSE_FILE="$root/compose.yaml:$root/ci/compose.ci.yaml"
# The one token Add server shows; own-vault's first install adds the optional second one for selan-keys.
export SELAN_REGISTRATION_TOKEN=selanreg_ci-stack-test
export SELAN_PROXY_HOST=gw.selan-ci.test SELAN_BIND_ADDR=127.0.0.1 SELAN_TLS=internal SELAN_VAULT=openbao
export CONTROL_BASE_URL=https://fake-control:8443 SELAN_OUTSIDE_CHECK=no SELAN_NONINTERACTIVE=1

compose() { docker compose --project-directory "$root" "$@"; }
mode() { stat -c '%U %a' "$1"; }
ip_on() { docker inspect -f "{{(index .NetworkSettings.Networks \"selan_$2\").IPAddress}}" "selan-$1-1"; }
reaches() { # reaches <container> <host> <port>: a TCP connect from inside a container's own network namespace
  docker run --rm --network "container:selan-$1-1" "$probe" \
    python -c "import socket; socket.create_connection(('$2', $3), timeout=4)" >/dev/null 2>&1
}
# key_read <caller token> <name>: selan-keys' answer to GET /v1/keys/<name> from `inside`, then its status.
# The token goes in on stdin, never on a command line.
key_read() {
  printf 'Authorization: Bearer %s\n' "$1" |
    docker run --rm -i --network selan_inside "$curl_image" -s -H @- -w ' %{http_code}' "http://keys:8080/v1/keys/$2"
}
saved() { sed -n "s/^$1='\(.*\)'$/\1/p" .env; }
control_log() { compose logs --no-log-prefix fake-control; }
ready() { # ready <name> [curl options]: https://<name>.selan-ci.test/readyz answers 200 through Caddy
  local host=$1.selan-ci.test
  shift
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" --resolve "$host:443:127.0.0.1" "https://$host/readyz")" = 200 ]
}

# install [env assignments or -u NAME ...]: install.sh under `env`, traced by line (ci/traced-install.sh).
install() {
  local unset=() set=()
  while [ $# -gt 0 ]; do
    if [ "$1" = -u ]; then unset+=(-u "$2") && shift 2; else set+=("$1") && shift; fi
  done
  env "${unset[@]}" "${set[@]}" bash "$root/ci/traced-install.sh"
}

# refused <exit code> <pattern> [env ...]: install.sh exits with that code and says the pattern.
refused() {
  local code=$1 pattern=$2 status=0
  shift 2
  install "$@" >/tmp/refused.log 2>&1 || status=$?
  if [ "$status" != "$code" ] || ! grep -Eq -- "$pattern" /tmp/refused.log; then
    fail "expected exit $code saying /$pattern/, got $status: $(tail -n 3 /tmp/refused.log)"
  fi
}
