#!/usr/bin/env bash
set -euo pipefail

cd "$CLAUDE_PROJECT_DIR"

echo "Rebuilding gateway image..." >&2
docker build -q -t tri-onyx-gateway:latest -f gateway.Dockerfile . >&2

echo "Rebuilding connector image..." >&2
docker build -q --no-cache -t tri-onyx-connector:latest -f connector.Dockerfile . >&2

echo "Rebuilding FUSE binary..." >&2
docker run --rm -v "$(pwd)/fuse:/src" -w /src golang:1.22 go build -o tri-onyx-fs ./cmd/tri-onyx-fs >&2

echo "Rebuilding agent image..." >&2
docker build -q --no-cache -t tri-onyx-agent:latest -f agent.Dockerfile . >&2

echo "All images rebuilt." >&2
