#!/bin/bash
# logged.sh LOG -- CMD...: run CMD, tee output to LOG framed by the command
# line and its exit code, and append a summary row to out/logs/commands.log.
set -uo pipefail
log=$1; shift; [ "$1" = -- ] && shift
mkdir -p "$(dirname "$log")"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
	echo "# started: $started"
	echo "# command: $*"
	echo
} >"$log"
"$@" 2>&1 | tee -a "$log"
rc=${PIPESTATUS[0]}
{
	echo
	echo "# finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "# exit code: $rc"
} >>"$log"
printf '%s\texit=%s\t%s\t%s\n' "$started" "$rc" "$log" "$*" >>"$(dirname "$log")/commands.log"
echo "[logged.sh] exit code $rc -> $log"
exit "$rc"
