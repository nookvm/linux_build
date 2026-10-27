#!/bin/bash
# Populate vendor/linux at the pinned gitlink (shallow) and fetch the signed
# tag. Safe to rerun; see scripts/init-source.sh.
set -euo pipefail
cd "$(dirname "$0")"
exec scripts/init-source.sh "$@"
