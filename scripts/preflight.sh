#!/bin/bash
# Host side: require a native linux/arm64 Docker engine (OrbStack) and the
# kernel submodule. Starts OrbStack when its engine is not running.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "host: $(uname -sm)"
[ "$(uname -m)" = arm64 ] || [ "$(uname -m)" = aarch64 ] \
	|| { echo "BLOCKER: host is $(uname -m), not arm64; native arm64 build impossible" >&2; exit 1; }

if ! docker info >/dev/null 2>&1; then
	if command -v orb >/dev/null; then
		echo "Docker engine not reachable; starting OrbStack (orb start)"
		orb start
	fi
fi
if ! out=$(docker info --format '{{.Architecture}} {{.OSType}} {{.Name}} {{.ServerVersion}}' 2>&1); then
	echo "BLOCKER: Docker engine not reachable: $out" >&2
	exit 1
fi
echo "docker context: $(docker context show)"
echo "docker engine: $out"
read -r arch ostype _ <<<"$out"
[ "$arch" = aarch64 ] && [ "$ostype" = linux ] \
	|| { echo "BLOCKER: engine is $ostype/$arch, need linux/aarch64 (no emulation)" >&2; exit 1; }
if command -v orb >/dev/null; then
	echo "orbstack: $(orb version | head -1), status $(orb status)"
fi

[ -e vendor/linux/.git ] && [ -f vendor/linux/Makefile ] \
	|| { echo "vendor/linux is not populated: run ./source.sh" >&2; exit 1; }
echo "preflight ok"
