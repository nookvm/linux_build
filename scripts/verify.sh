#!/bin/bash
# Runs inside the native linux/arm64 builder container with --network none:
#   /repo      this repository, read-only
#   /repo/out  artifacts from ./build.sh (logs are written here)
# Checks only out/ (plus the pinned inputs); never needs the build volume.
set -euo pipefail

. /repo/versions.env
OUT=/repo/out
CHECK=(python3 -I /repo/scripts/artifact_check.py)

step() { printf '\n==== %s ====\n' "$*"; }

step "environment"
echo "uname -m: $(uname -m)"
[ "$(uname -m)" = aarch64 ] || { echo "not a native aarch64 container" >&2; exit 1; }

step "SHA256SUMS"
(cd "$OUT" && sha256sum -c SHA256SUMS)

step "VERSION"
cat "$OUT/VERSION"
release=$(sed -n 's/^kernel_release=//p' "$OUT/VERSION")
[ "$release" = "${LINUX_VERSION}${KERNEL_LOCALVERSION}" ] \
	|| { echo "kernel_release $release != ${LINUX_VERSION}${KERNEL_LOCALVERSION}" >&2; exit 1; }
grep -qx "linux_commit=$LINUX_COMMIT" "$OUT/VERSION"
grep -qx "alpine_minirootfs_sha256=$ALPINE_MINIROOTFS_SHA256" "$OUT/VERSION"
echo "ok: release $release, commit and Alpine hash match versions.env"

step "Image: arm64 boot header"
file "$OUT/Image"
"${CHECK[@]}" image "$OUT/Image"
banner=$(grep -a -o -m1 "Linux version ${release} [^%]*" "$OUT/Image" | sed -n 1p | tr -d '\0')
echo "banner: $banner"
[ -n "$banner" ] || { echo "Linux version banner for $release not found" >&2; exit 1; }

step "vmlinux / System.map"
file "$OUT/vmlinux"
grep -qE 'ELF 64-bit LSB (pie )?executable, ARM aarch64' <<<"$(file -b "$OUT/vmlinux")" \
	|| { echo "vmlinux is not an aarch64 ELF executable" >&2; exit 1; }
for sym in _text _stext primary_entry start_kernel _end; do
	grep -qE " [tTdDbBA] ${sym}\$" "$OUT/System.map" || { echo "System.map lacks $sym" >&2; exit 1; }
done
sm_text=$(awk '$3 == "_text" {print $1}' "$OUT/System.map")
elf_text=$(nm "$OUT/vmlinux" | awk '$3 == "_text" {print $1}')
[ "$sm_text" = "$elf_text" ] || { echo "System.map _text $sm_text != vmlinux $elf_text" >&2; exit 1; }
echo "ok: System.map symbols present, _text=$sm_text matches vmlinux"

step "kernel config"
missing=0
while IFS= read -r line; do
	case "$line" in
	'# CONFIG_'*' is not set') ;;
	''|'#'*) continue ;;
	esac
	if grep -qxF -- "$line" "$OUT/kernel.config"; then
		echo "ok: $line"
	else
		echo "MISSING: $line"; missing=1
	fi
done </repo/config/required.txt
[ "$missing" = 0 ] || exit 1
if grep -n '=m$' "$OUT/kernel.config"; then echo "modular options present" >&2; exit 1; fi
echo "ok: no =m options (no modules needed for boot)"
"${CHECK[@]}" ikconfig "$OUT/Image" "$OUT/kernel.config"

step "initramfs: gzip + newc structure, modes, required files"
gzip -t "$OUT/initramfs.cpio.gz"
echo "ok: gzip -t"
"${CHECK[@]}" cpio-check "$OUT/initramfs.cpio.gz"
"${CHECK[@]}" cpio-list "$OUT/initramfs.cpio.gz" | diff -u "$OUT/initramfs.manifest" -
echo "ok: archive matches initramfs.manifest"

step "initramfs: extract and execute in native arm64 container"
root=$(mktemp -d /tmp/initramfs.XXXXXX)
(cd "$root" && zcat "$OUT/initramfs.cpio.gz" | cpio --quiet -idm --no-absolute-filenames)
echo "extracted to $root: $(find "$root" | wc -l) paths"
readelf -l "$root/bin/busybox" | grep -o 'Requesting program interpreter: [^]]*'
readelf -l "$root/sbin/apk" | grep -o 'Requesting program interpreter: [^]]*'
for bin in bin/busybox sbin/apk; do
	interp=$(readelf -l "$root/$bin" | sed -n 's/.*Requesting program interpreter: \([^]]*\)]/\1/p')
	[ "$interp" = /lib/ld-musl-aarch64.so.1 ] || { echo "$bin interpreter $interp" >&2; exit 1; }
	[ -x "$root$interp" ] || { echo "$interp missing" >&2; exit 1; }
	readelf -d "$root/$bin" | awk '/NEEDED/ {gsub(/[][]/, "", $5); print $5}' | while read -r lib; do
		found=
		for dir in /lib /usr/lib; do
			if [ -e "$root$dir/$lib" ]; then found=$dir/$lib; break; fi
		done
		[ -n "$found" ] || { echo "$bin needs $lib: not in rootfs" >&2; exit 1; }
		echo "ok: $bin NEEDED $lib -> $found"
	done
done
run() { echo "+ chroot rootfs $*" >&2; chroot "$root" "$@"; }
run /bin/busybox --help | sed -n 1p
applets=$(run /bin/busybox --list)
echo "busybox applets: $(wc -l <<<"$applets")"
for applet in sh init mount mknod mkdir ip udhcpc getty hostname reboot poweroff; do
	grep -qx "$applet" <<<"$applets" || { echo "busybox lacks $applet" >&2; exit 1; }
done
echo "ok: busybox provides sh init mount mknod mkdir ip udhcpc getty hostname reboot poweroff"
run /sbin/apk --version
# No repositories: read the installed db only, never the network.
pkgs=$(run /sbin/apk --repositories-file /dev/null info -v)
echo "apk installed packages: $(wc -l <<<"$pkgs")"
grep -E '^(busybox|apk-tools|musl|ca-certificates-bundle|alpine-baselayout)-[0-9]' <<<"$pkgs"
diff -u "$OUT/rootfs-packages.txt" <(LC_ALL=C sort <<<"$pkgs")
echo "ok: apk db matches rootfs-packages.txt"
for script in /init /etc/nookvm/rc.sysinit /etc/nookvm/net-up /usr/share/udhcpc/default.script; do
	run /bin/sh -n "$script"
	echo "ok: sh -n $script"
done
# Missing-NIC path: no /sys/class/net/eth0 in the chroot, must exit 0 at once.
start=$(date +%s)
run /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin timeout 10 /etc/nookvm/net-up
echo "ok: net-up without eth0 exited 0 in $(( $(date +%s) - start ))s; log: $(cat "$root/run/nookvm-net.log")"
rm -rf "$root"

step "summary"
(cd "$OUT" && sha256sum Image initramfs.cpio.gz kernel.config vmlinux System.map)
echo "VERIFY PASSED"
echo "Not validated here: booting this kernel in the NookVM VMM (no DTB/loader"
echo "exists there yet), serial console I/O, virtio-mmio block/net and DHCP."
