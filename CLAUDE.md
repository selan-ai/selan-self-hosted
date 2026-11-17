# selan-self-hosted

Public install for Selan's Own servers: a company's own proxy, MCP gateway and vault, inside its VPN.
`README.md` is the contract; `docs/design/self-hosted-secrets.md` in selan-control is the design.

## Rules

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck-clean, readable top to bottom.
  `install.sh` also runs under macOS's bash 3.2 (the local skill): no `mapfile`, no `"${empty[@]}"`.
- `install.sh` is idempotent: a second run with nothing new changes no file. `ci/stack-test.sh` checks it.
- A secret (the registration token, the DNS token, an AppRole secret id, the unseal key, the root token)
  never lands on a command line, in a log or in output. It goes through the environment, stdin or a root-only file.
- Every image in `compose.yaml` is pinned by digest; a release bumps one by pull request after trying it.
  Caddy is ours (`caddy/`): a change there publishes from `main` (`caddy-image`), then a PR pins it.
- The vault stays on `inside` alone, with no ports. Only the proxy and the gateway join `egress`,
  and Caddy with `SELAN_TLS=dns` (`compose.dns.yaml`), for Let's Encrypt and the DNS provider.
- Nothing is served by Selan at install time: the line clones a release tag, and `install.sh` runs from
  that checkout and never fetches this repository or anything from selan.ai.
- `install.sh` checks every image's cosign signature against `signers.txt` before pulling it; a new image
  gets its signer line in the same pull request. `SELAN_UNSIGNED_OK` is for CI's stand-ins only.
- A release is a `vX.Y.Z` tag on `main`, cut once `check` is green; Add server's line names it.

## Checks, before pushing

```sh
git ls-files -z '*.sh' | xargs -0 shellcheck
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
sudo -E bash ci/stack-test.sh && sudo bash ci/stack-down.sh   # Docker; port 443 on 127.0.0.1 free
```

`main` takes changes by pull request only. Commits carry no AI attribution.
