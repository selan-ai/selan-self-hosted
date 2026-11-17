#!/usr/bin/env bash
# Every image compose.yaml runs is pinned by digest, and every pinned digest exists.
# Until its first release, selan-proxy and selan-mcp-gateway may be the pending form instead,
# ${SELAN_PROXY_IMAGE:?...}, which refuses to start; README, "Upgrade".
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0
while read -r image; do
  case "$image" in
    "\${SELAN_PROXY_IMAGE:?"* | "\${SELAN_GATEWAY_IMAGE:?"*)
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
done < <(sed -n 's/^ *image: *//p' compose.yaml)
exit "$fail"
