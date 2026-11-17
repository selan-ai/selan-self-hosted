# selan-self-hosted

Public install for Selan's Own servers: a company's own proxy, MCP gateway and vault, inside its VPN.
`README.md` is the contract; `docs/design/self-hosted-secrets.md` in selan-control is the design.

## Rules

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck-clean, readable top to bottom.
  `install.sh` also runs under macOS's bash 3.2 (the local skill): no `mapfile`, no `"${empty[@]}"`.
- `install.sh` is idempotent: a second run with nothing new changes no file. `ci/stack-test.sh` checks it.
- A secret (the registration token, an AppRole secret id, the unseal key, the root token) never lands on
  a command line, in a log or in output. It goes through the environment, stdin or a root-only file.
- Every image in `compose.yaml` is pinned by digest; a release bumps one by pull request after trying it.
- The vault stays on `inside` alone, with no ports. Only the proxy and the gateway join `egress`.
- selan.ai serves `install.sh` at one commit with `PINNED_COMMIT` filled in (selan-website); keep that
  line exactly `PINNED_COMMIT=""` here.

## Checks, before pushing

```sh
git ls-files -z '*.sh' | xargs -0 shellcheck
sudo -E bash ci/stack-test.sh && sudo bash ci/stack-down.sh   # Docker; port 443 on 127.0.0.1 free
```

`main` takes changes by pull request only. Commits carry no AI attribution.
