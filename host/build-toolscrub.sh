#!/bin/bash
# Reproducible build of ai-fortress-toolscrub.
#
# Compiles the Go source in host/toolscrub/ inside a digest-pinned
# golang container so the host doesn't need a Go toolchain. Outputs a
# static binary at host/build/ai-fortress-toolscrub.
#
# Re-pin: `docker pull golang:1.22-alpine && docker inspect --format='{{index .RepoDigests 0}}' golang:1.22-alpine`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/toolscrub"
OUT_DIR="$SCRIPT_DIR/build"
BIN="$OUT_DIR/ai-fortress-toolscrub"

GOLANG_IMAGE='golang@sha256:1699c10032ca2582ec89a24a1312d986a3f094aed3d5c1147b19880afe40e052'

mkdir -p "$OUT_DIR"

echo "Running go vet + tests inside $GOLANG_IMAGE …"
docker run --rm \
  -v "$SRC_DIR":/src \
  -w /src \
  "$GOLANG_IMAGE" \
  sh -c 'go vet ./... && go test ./...'

echo "Compiling static binary …"
docker run --rm \
  -v "$SRC_DIR":/src \
  -v "$OUT_DIR":/out \
  -w /src \
  -e CGO_ENABLED=0 \
  -e GOOS=linux \
  -e GOARCH=amd64 \
  "$GOLANG_IMAGE" \
  go build -trimpath -ldflags='-s -w' -o /out/ai-fortress-toolscrub ./...

ls -lh "$BIN"
file "$BIN" 2>/dev/null || true
echo "build OK: $BIN"
