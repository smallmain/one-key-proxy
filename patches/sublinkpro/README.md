# SublinkPro SOCKS5 Surge Export

Adds SOCKS5 to SublinkPro's Surge client capabilities and implements native Surge
policy output. Local nodes remain unencrypted SOCKS5 without authentication.
The patch also covers optional credentials, IPv6, UDP settings, host replacement,
invalid policy fields, and complete subscription/group generation with Go tests.
The upstream English and Chinese protocol tables are updated with the patch.

## Pinned Inputs

- Upstream: `v1.2.22`
- Commit: `fda7261c4e1f43e82082d4c0632ee3b9d620af85`
- Source SHA-256: `144d5c18bb9f52ce97fa33365aa441fbe52a08279b0ef1ac499de21bbab5f2e8`
- Runtime: `zerodeng/sublink-pro:v1.2.22@sha256:4d4f9c928a886f509f0c188379c32e0f1c3c263a564b0a771d760a4bfe8481ea`
- Builder: `golang:1.27.3@sha256:2920bb124f1a2e12a1d39f0cab756ae0068441ee1da7655dec7f5e374944095b`
- Static analysis: `golangci-lint v2.15.0`, built with the same pinned Go compiler

The runtime image supplies the matching official frontend and runtime tools. Only
the Go executable is replaced. No database migration is introduced by this patch.
The supplied pins were verified on the deployed Linux amd64 host.

## Build

Run in this directory, using Docker with BuildKit:

```sh
curl -fL --retry 3 \
  https://codeload.github.com/ZeroDeng01/sublinkPro/tar.gz/fda7261c4e1f43e82082d4c0632ee3b9d620af85 \
  -o upstream.tar.gz
docker build --progress=plain -t sublinkpro:v1.2.22-socks5-surge.1 .
```

If the official Go module proxy is unreachable from the build host, pass
`--build-arg GOPROXY=https://goproxy.cn,https://proxy.golang.org,direct` to the build.
The Go checksum database remains enabled.

The build checks the source digest, runs `git apply --check`, checks formatting,
runs the upstream Go tests and protocol vet checks, builds the production
executable, and runs `golangci-lint` before producing the runtime image.
Go download/build caches are outside the final image. The source
archive is Git-ignored and the Docker context only includes the required files.

## Deployment

The deployment copy is stored on `smallmain.com` at:

```text
/opt/1panel/docker/compose/sublink-pro/custom/
```

The parent `docker-compose.yml` selects `sublinkpro:v1.2.22-socks5-surge.1` for the
`sublinkpro` service. Its database, templates, logs, port and network mounts are
retained. Recreate only this service after selecting a validated image:

```sh
sudo docker compose -f /opt/1panel/docker/compose/sublink-pro/docker-compose.yml \
  up -d --no-deps --pull never sublinkpro
```

After switching, verify API authentication, managed node IDs/tags, and the actual
Surge subscription's local proxy lines and residential-group membership. Reload
Surge separately after the subscription output has been verified.

## Updates

To undo only the patch, select the pinned official `v1.2.22` runtime image and
recreate the service using the current database. Pre-upgrade data snapshots and
the old-version rollback image are not retained.

For a future upstream release, review whether native SOCKS5 Surge support has been
added. If it has, switch to that official image after testing. Otherwise rebase
the patch and tests onto the new fixed commit and update all source/image pins.
Running a generic `latest` update will not preserve this custom patch.

## Verified Deployment

Verified on `smallmain.com` on 2026-10-29:

- Running image: `sublinkpro:v1.2.22-socks5-surge.1`
- Image ID: `sha256:5a129b0c9c63826ca0a4faa39dd588a08334ee03b174c252072b77d4448845b8`
- Formatting, `go test ./...`, `go vet ./node/protocol`, production build: passed
- `golangci-lint v2.15.0`: `0 issues`
- API inventory: all 428 nodes retained; local IDs, names, groups and tags retained
- Actual Surge output: 219 original policies retained, plus all 8 local SOCKS5 policies
- Local listeners: `127.0.0.1`, original ports, no authentication, `udp-relay=true`
- Residential group: all 5 local residential policies match its existing filter

After verification, both deployment snapshots and the old-version rollback image
were deleted at the user's request on 2026-10-29.
