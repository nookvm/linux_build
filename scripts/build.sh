#!/bin/bash
# Runs inside the native linux/arm64 builder container (see ../build.sh):
#   /repo        this repository, read-only (vendor/linux is never written)
#   /repo/out    artifacts (read-write)
#   /repo/build  download cache (read-write)
#   /work        Docker volume, case-sensitive: exported source + kbuild tree
set -euo pipefail

. /repo/versions.env
OUT=/repo/out
DL=/repo/build/downloads
SRC=/work/src/linux
KBUILD=/work/kbuild
ROOTFS=/work/rootfs
GIT=(git -c safe.directory='*' -C /repo/vendor/linux)

step() { printf '\n==== %s ====\n' "$*"; }

step "environment"
echo "uname -m: $(uname -m)"
[ "$(uname -m)" = aarch64 ] || { echo "not a native aarch64 container" >&2; exit 1; }
if grep -qs qemu /proc/sys/fs/binfmt_misc/* 2>/dev/null; then
	echo "note: host has qemu binfmt handlers registered; this container runs natively (uname -m above)"
fi
echo "nproc: $(nproc)"

step "pinned kernel source"
gitlink=$(git -c safe.directory='*' -C /repo ls-files --stage vendor/linux | awk '$1 == "160000" {print $2}')
head=$("${GIT[@]}" rev-parse HEAD)
tagged=$("${GIT[@]}" rev-parse "refs/tags/${LINUX_TAG}^{commit}")
tagobj=$("${GIT[@]}" rev-parse "refs/tags/${LINUX_TAG}")
echo "gitlink=$gitlink head=$head ${LINUX_TAG}=$tagged tag-object=$tagobj"
for v in "$gitlink" "$head" "$tagged"; do
	[ "$v" = "$LINUX_COMMIT" ] || { echo "commit mismatch: $v != $LINUX_COMMIT" >&2; exit 1; }
done
[ "$tagobj" = "$LINUX_TAG_OBJECT" ] || { echo "tag object mismatch" >&2; exit 1; }
export GNUPGHOME=$(mktemp -d)
gpg --batch --quiet --import /repo/keys/gregkh-38DBBDC86092693E.asc
status=$("${GIT[@]}" verify-tag --raw "$LINUX_TAG" 2>&1) || { echo "$status"; exit 1; }
grep -E '^\[GNUPG:\] (GOODSIG|VALIDSIG)' <<<"$status"
grep -q "^\[GNUPG:\] VALIDSIG $LINUX_TAG_SIGNER_FPR " <<<"$status" \
	|| { echo "tag not signed by $LINUX_TAG_SIGNER_FPR" >&2; exit 1; }
echo "tag ${LINUX_TAG} signature: valid, signer ${LINUX_TAG_SIGNER_FPR}"

# The macOS checkout is case-insensitive, so the build never reads the
# worktree: it exports the pinned commit from the submodule's objects.
if [ "$(cat /work/src/.commit 2>/dev/null)" != "$LINUX_COMMIT" ]; then
	step "export ${LINUX_COMMIT} to ${SRC}"
	rm -rf /work/src && mkdir -p "$SRC"
	"${GIT[@]}" archive --format=tar "$LINUX_COMMIT" | tar -x -C "$SRC"
	echo "$LINUX_COMMIT" >/work/src/.commit
else
	echo "export of ${LINUX_COMMIT} already present in ${SRC}"
fi

export SOURCE_DATE_EPOCH=$("${GIT[@]}" log -1 --format=%ct "$LINUX_COMMIT")
export KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')"
export KBUILD_BUILD_USER=nookvm KBUILD_BUILD_HOST=nookvm-builder
# Fixed "#1" in the banner even when the kbuild tree is reused.
export KBUILD_BUILD_VERSION=1
# LOCALVERSION set (empty) keeps setlocalversion from adding a git "+".
KMAKE=(make -C "$SRC" O="$KBUILD" ARCH=arm64 LOCALVERSION= -j"$(nproc)")
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH KBUILD_BUILD_TIMESTAMP=$KBUILD_BUILD_TIMESTAMP"

step "kernel config: allnoconfig + config/nookvm.config"
mkdir -p "$KBUILD"
"${KMAKE[@]}" KCONFIG_ALLCONFIG=/repo/config/nookvm.config allnoconfig
missing=0
while IFS= read -r line; do
	case "$line" in
	'# CONFIG_'*' is not set') ;;
	''|'#'*) continue ;;
	esac
	grep -qxF -- "$line" "$KBUILD/.config" || { echo "dropped by Kconfig: $line"; missing=1; }
done </repo/config/nookvm.config
[ "$missing" = 0 ] || exit 1
echo "every line of config/nookvm.config is present in .config"
if grep -q '=m$' "$KBUILD/.config"; then echo "modular options present" >&2; exit 1; fi

step "kernel build: Image vmlinux"
"${KMAKE[@]}" Image vmlinux

step "initramfs: Alpine ${ALPINE_VERSION} minirootfs"
mkdir -p "$DL"
tarball="$DL/$ALPINE_MINIROOTFS"
if ! echo "$ALPINE_MINIROOTFS_SHA256  $tarball" | sha256sum -c --status 2>/dev/null; then
	curl -fsSL --retry 3 -o "$tarball.part" "$ALPINE_MINIROOTFS_URL"
	mv "$tarball.part" "$tarball"
fi
echo "$ALPINE_MINIROOTFS_SHA256  $tarball" | sha256sum -c
echo "$ALPINE_MINIROOTFS_SHA512  $tarball" | sha512sum -c
rm -rf "$ROOTFS" && mkdir -p "$ROOTFS"
tar -xzpf "$tarball" --numeric-owner -C "$ROOTFS"
# NookVM overlay (modes set explicitly, independent of the checkout).
install -m 0755 /repo/rootfs/init "$ROOTFS/init"
install -m 0644 /repo/rootfs/etc/inittab /repo/rootfs/etc/hostname \
	/repo/rootfs/etc/hosts /repo/rootfs/etc/motd "$ROOTFS/etc/"
install -d -m 0755 "$ROOTFS/etc/nookvm"
install -m 0755 /repo/rootfs/etc/nookvm/rc.sysinit /repo/rootfs/etc/nookvm/net-up \
	"$ROOTFS/etc/nookvm/"
# The kernel opens /dev/console for PID 1 before /init mounts devtmpfs.
mknod -m 0600 "$ROOTFS/dev/console" c 5 1
mknod -m 0666 "$ROOTFS/dev/null" c 1 3
chroot "$ROOTFS" /sbin/apk --repositories-file /dev/null info -v | LC_ALL=C sort >/work/rootfs-packages.txt
find "$ROOTFS" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
(cd "$ROOTFS" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
	| cpio --quiet -o -H newc --reproducible) | gzip -n -9 >/work/initramfs.cpio.gz

step "collect artifacts"
rm -rf "$OUT/staging" && mkdir -p "$OUT/staging"
S=$OUT/staging
cp "$KBUILD/arch/arm64/boot/Image" "$S/Image"
cp "$KBUILD/vmlinux" "$S/vmlinux"
cp "$KBUILD/System.map" "$S/System.map"
cp "$KBUILD/.config" "$S/kernel.config"
cp /work/initramfs.cpio.gz /work/rootfs-packages.txt "$S/"
python3 -I /repo/scripts/artifact_check.py cpio-list "$S/initramfs.cpio.gz" >"$S/initramfs.manifest"
release=$(cat "$KBUILD/include/config/kernel.release")

{
	echo "kernel_release=$release"
	echo "linux_version=$LINUX_VERSION"
	echo "linux_tag=$LINUX_TAG"
	echo "linux_tag_object=$LINUX_TAG_OBJECT"
	echo "linux_commit=$LINUX_COMMIT"
	echo "linux_url=$LINUX_URL"
	echo "linux_tag_signer=$LINUX_TAG_SIGNER_FPR"
	echo "alpine_version=$ALPINE_VERSION"
	echo "alpine_minirootfs=$ALPINE_MINIROOTFS"
	echo "alpine_minirootfs_sha256=$ALPINE_MINIROOTFS_SHA256"
	echo "alpine_minirootfs_url=$ALPINE_MINIROOTFS_URL"
	echo "builder_base_image=$BUILDER_BASE_IMAGE"
	echo "debian_snapshot=$DEBIAN_SNAPSHOT"
	echo "builder_image_id=${BUILDER_IMAGE_ID:-unknown}"
	echo "source_date_epoch=$SOURCE_DATE_EPOCH"
	echo "kbuild_build_timestamp=$KBUILD_BUILD_TIMESTAMP"
	echo "kbuild_build_user=$KBUILD_BUILD_USER"
	echo "kbuild_build_host=$KBUILD_BUILD_HOST"
	echo "kbuild_build_version=$KBUILD_BUILD_VERSION"
	echo "arch=arm64 page_size=4K"
	echo "cmdline_recommended=console=ttyS0,115200 rdinit=/init"
} >"$S/VERSION"

{
	echo "# Builder toolchain (native linux/arm64 container)"
	echo "uname: $(uname -srm)"
	echo "debian: $(cat /etc/debian_version)"
	echo "gcc: $(gcc --version | head -1)"
	echo "ld: $(ld --version | head -1)"
	echo "as: $(as --version | head -1)"
	echo "make: $(make --version | head -1)"
	echo "bison: $(bison --version | head -1)"
	echo "flex: $(flex --version | head -1)"
	echo "bc: $(bc --version | head -1)"
	echo "openssl: $(openssl version 2>/dev/null || echo n/a)"
	echo "cpio: $(cpio --version | head -1)"
	echo "gzip: $(gzip --version | head -1)"
	echo "tar: $(tar --version | head -1)"
	echo "git: $(git --version)"
	echo "gpg: $(gpg --version | head -1)"
	echo "python3: $(python3 --version)"
	echo "kernel_compiler (from vmlinux): $(cat "$KBUILD/include/generated/compile.h" | grep -E 'LINUX_COMPILER|UTS_VERSION' | tr '\n' ' ')"
	echo
	echo "# dpkg-query -W (all installed packages)"
	dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' | LC_ALL=C sort
} >"$S/toolchain.txt"

(cd "$S" && sha256sum Image initramfs.cpio.gz kernel.config vmlinux System.map \
	VERSION toolchain.txt rootfs-packages.txt initramfs.manifest >SHA256SUMS)
for f in "$S"/*; do mv -f "$f" "$OUT/"; done
rmdir "$S"

step "result"
(cd "$OUT" && ls -l Image initramfs.cpio.gz kernel.config vmlinux System.map && cat SHA256SUMS)
echo "kernel release: $release"
