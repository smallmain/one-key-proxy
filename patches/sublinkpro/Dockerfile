ARG UPSTREAM_IMAGE=zerodeng/sublink-pro:v1.2.22@sha256:4d4f9c928a886f509f0c188379c32e0f1c3c263a564b0a771d760a4bfe8481ea
ARG GO_IMAGE=golang:1.27.3@sha256:2920bb124f1a2e12a1d39f0cab756ae0068441ee1da7655dec7f5e374944095b

FROM ${UPSTREAM_IMAGE} AS upstream
FROM ${GO_IMAGE} AS build

ENV CGO_ENABLED=0 GOMAXPROCS=2 GOFLAGS=-p=1 GOTOOLCHAIN=local GOMEMLIMIT=1400MiB
WORKDIR /src
COPY upstream.tar.gz /tmp/upstream.tar.gz
RUN printf '%s  %s\n' \
      144d5c18bb9f52ce97fa33365aa441fbe52a08279b0ef1ac499de21bbab5f2e8 \
      /tmp/upstream.tar.gz | sha256sum -c - \
    && tar -xzf /tmp/upstream.tar.gz --strip-components=1
COPY socks5-surge.patch /tmp/socks5-surge.patch
RUN git apply --check /tmp/socks5-surge.patch \
    && git apply /tmp/socks5-surge.patch \
    && test -z "$(gofmt -l node/protocol/socks5.go node/protocol/socks5_surge_test.go)"
COPY --from=upstream /app/static ./static
ARG GOPROXY=https://proxy.golang.org,direct
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOPROXY=${GOPROXY} go test ./... \
    && go vet ./node/protocol \
    && go build -tags=prod -ldflags='-s -w' -o /out/sublinkPro .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/.cache/golangci-lint \
    GOPROXY=${GOPROXY} go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 \
    && GOPROXY=${GOPROXY} /go/bin/golangci-lint run --concurrency 1 --timeout 8m

FROM upstream
LABEL org.opencontainers.image.revision="fda7261c4e1f43e82082d4c0632ee3b9d620af85" \
      com.one-key-proxy.sublinkpro.patch="socks5-surge.1"
COPY --from=build /out/sublinkPro /app/sublinkPro
