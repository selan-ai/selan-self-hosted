#!/usr/bin/env bash
# Every image compose.yaml runs, the cosign image install.sh runs and caddy/Dockerfile builds from is
# pinned by digest, and every pinned digest exists. Until their first release, selan-proxy, the gateway,
# selan-keys and Caddy may be the pending form instead, ${SELAN_PROXY_IMAGE:?...}, which refuses to start.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0
images() {
  sed -n 's/^ *image: *//p' compose.yaml
  sed -n 's/^COSIGN_IMAGE=//p' install.sh
  sed -n 's/^FROM \(--platform=[^ ]* \)\{0,1\}\([^ ]*\).*/\2/p' caddy/Dockerfile
}
while read -r image; do
  case "$image" in
    "\${SELAN_PROXY_IMAGE:?"* | "\${SELAN_GATEWAY_IMAGE:?"* | "\${SELAN_CADDY_IMAGE:?"* | "\${SELAN_KEYS_IMAGE:?"*)
      echo "pending: ${image%%:?*}} has no release pinned yet"
      ;;
    *@sha256:*)
      [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || {
        echo "error: $image is not a full sha256 digest" >&2
        fail=1
        continue
      }
      if docker buildx imagetools inspect "$image" >/dev/null 2>&1; then
        echo "pinned: $image"
      else
        echo "error: $image does not exist in its registry" >&2
        fail=1
      fi
      ;;
    *)
      echo "error: $image is not pinned by digest" >&2
      fail=1
      ;;
  esac
done < <(images)
exit "$fail"
