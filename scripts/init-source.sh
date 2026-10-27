#!/bin/bash
# Host side: populate vendor/linux at the pinned gitlink (shallow), fetch the
# signed tag object for verification, and keep the macOS worktree clean.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./versions.env

git submodule sync -- vendor/linux
git submodule update --init --depth 1 -- vendor/linux
L=(git -C vendor/linux)
if ! "${L[@]}" rev-parse -q --verify "refs/tags/$LINUX_TAG" >/dev/null; then
	"${L[@]}" fetch --depth 1 --no-tags origin "refs/tags/$LINUX_TAG:refs/tags/$LINUX_TAG"
fi
[ "$("${L[@]}" rev-parse "refs/tags/$LINUX_TAG^{commit}")" = "$LINUX_COMMIT" ]
[ "$("${L[@]}" rev-parse HEAD)" = "$LINUX_COMMIT" ]

# Linux has paths differing only in case (xt_DSCP.c / xt_dscp.c, ...). On a
# case-insensitive filesystem both twins share one file, so one of them is
# always wrong and the worktree is dirty. Leave every twin out of the
# worktree via sparse checkout (git matches sparse patterns case-insensitively
# here, so a twin cannot be kept alone). The build never uses this worktree:
# it exports the pinned commit inside the case-sensitive Linux container.
touch vendor/.case-probe
if [ -e vendor/.CASE-PROBE ]; then
	twins=$("${L[@]}" ls-tree -r --name-only "$LINUX_COMMIT" \
		| awk '{l = tolower($0); n[l]++; p[l] = p[l] $0 "\n"}
		       END {for (l in n) if (n[l] > 1) printf "%s", p[l]}' | LC_ALL=C sort)
	skipped=$("${L[@]}" ls-files -v | awk '/^S / {print substr($0, 3)}' | LC_ALL=C sort)
	if [ -n "$twins" ] && [ "$skipped" != "$twins" ]; then
		# Never discard edits: refuse on staged changes, on modified
		# non-twin files, and on a twin whose content is not one of its
		# pinned blobs (a collision is the only allowed difference).
		refuse() {
			echo "vendor/linux has local modifications; refusing to touch the worktree: $*" >&2
			exit 1
		}
		"${L[@]}" diff --cached --quiet || refuse "staged changes"
		others=$("${L[@]}" status --porcelain --untracked-files=no \
			| cut -c4- | grep -vxF -f <(echo "$twins") || true)
		[ -z "$others" ] || refuse "$(echo $others)"
		blobs=$("${L[@]}" ls-tree -r "$LINUX_COMMIT" -- $twins | awk -F'\t' '{split($1, a, " "); print a[3] "\t" tolower($2)}')
		while IFS= read -r path; do
			[ -e "vendor/linux/$path" ] || continue
			h=$("${L[@]}" hash-object -- "$path")
			low=$(echo "$path" | tr '[:upper:]' '[:lower:]')
			grep -qxF "$h	$low" <<<"$blobs" || refuse "$path differs from both pinned twins"
		done <<<"$twins"
		echo "case-insensitive filesystem: leaving case-colliding paths out of the worktree:"
		echo "$twins" | sed 's/^/  /'
		"${L[@]}" sparse-checkout disable
		echo "$twins" | (cd vendor/linux && xargs rm -f --)
		"${L[@]}" sparse-checkout set --no-cone '/*' $(echo "$twins" | sed 's|^|!/|')
	fi
fi
rm -f vendor/.case-probe
"${L[@]}" status --short
echo "vendor/linux at $LINUX_COMMIT ($LINUX_TAG)"
