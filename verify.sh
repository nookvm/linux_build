#!/bin/bash
# Structural and execution checks of out/ in the native linux/arm64 builder
# container, offline (--network none). Logs go to out/logs/.
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
ROOT=$(pwd -P)
BUILDER=nookvm-linux-builder:debian13-$DEBIAN_SNAPSHOT
LOG=scripts/logged.sh

mkdir -p out/logs
"$LOG" out/logs/preflight.log -- scripts/preflight.sh
[ -f out/SHA256SUMS ] || { echo "out/SHA256SUMS missing: run ./build.sh first" >&2; exit 1; }
"$LOG" out/logs/verify.log -- docker run --rm --platform linux/arm64 \
	-v "$ROOT:/repo:ro" -v "$ROOT/out:/repo/out" --network none \
	"$BUILDER" /repo/scripts/verify.sh
