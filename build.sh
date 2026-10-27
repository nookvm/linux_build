#!/bin/bash
# Build out/Image, out/initramfs.cpio.gz, kernel.config, vmlinux, ... in a
# native linux/arm64 container. The host never runs make; Kbuild's make runs
# only inside the container (scripts/build.sh). Logs go to out/logs/.
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
ROOT=$(pwd -P)
BUILDER=nookvm-linux-builder:debian13-$DEBIAN_SNAPSHOT
VOLUME=nookvm-linux-build-work
LOG=scripts/logged.sh

mkdir -p out/logs build/downloads
"$LOG" out/logs/preflight.log -- scripts/preflight.sh
"$LOG" out/logs/builder.log -- docker build --platform linux/arm64 \
	--build-arg BUILDER_BASE_IMAGE="$BUILDER_BASE_IMAGE" \
	--build-arg DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" \
	-t "$BUILDER" docker
"$LOG" out/logs/build.log -- docker run --rm --platform linux/arm64 \
	-v "$ROOT:/repo:ro" -v "$ROOT/out:/repo/out" \
	-v "$ROOT/build:/repo/build" -v "$VOLUME:/work" \
	-e BUILDER_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$BUILDER")" \
	"$BUILDER" /repo/scripts/build.sh
