# Caddy with the DNS provider modules for the DNS-01 challenge, which a private name needs: HTTP-01 and
# TLS-ALPN cannot reach a server inside a VPN. Built and signed by .github/workflows/caddy-image.yml.
FROM --platform=$BUILDPLATFORM caddy:2.11.9-builder@sha256:f9beaa5ddbe7df6f26ebbcf9cbf44e05a1917b9bba464f0c3229038d7e2e6e13 AS build
ARG TARGETOS TARGETARCH
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH xcaddy build v2.11.9 --output /caddy \
  --with github.com/caddy-dns/bunny@v1.2.0 \
  --with github.com/caddy-dns/cloudflare@v0.2.4 \
  --with github.com/caddy-dns/digitalocean@v0.0.0-20250606074528-04bde2867106 \
  --with github.com/caddy-dns/duckdns@v0.5.0 \
  --with github.com/caddy-dns/gandi@v1.2.1 \
  --with github.com/caddy-dns/hetzner@v1.0.0 \
  --with github.com/caddy-dns/ionos@v1.3.0 \
  --with github.com/caddy-dns/linode@v0.8.0 \
  --with github.com/caddy-dns/vultr@v0.0.0-20250723121531-55bf3e9768be

FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
COPY --from=build /caddy /usr/bin/caddy
