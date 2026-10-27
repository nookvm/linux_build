#!/bin/bash
# Remove generated files only: out/ (including out/logs/), build/ and the
# Docker work volume; never vendor/linux or any tracked file.
#   ./clean.sh --image   also remove this builder image tag (versions.env)
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
BUILDER=nookvm-linux-builder:debian13-$DEBIAN_SNAPSHOT
VOLUME=nookvm-linux-build-work

image=
case "${1-}" in
"") ;;
--image) image=1 ;;
*) echo "usage: ./clean.sh [--image]" >&2; exit 2 ;;
esac

rm -rf out build
docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
if [ -n "$image" ]; then
	docker image rm "$BUILDER" >/dev/null 2>&1 || true
fi
