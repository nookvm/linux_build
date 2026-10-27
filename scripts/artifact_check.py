#!/usr/bin/env python3
"""Structural checks of the build artifacts (stdlib only, run with -I).

  image    <Image>                              arm64 Image header
  ikconfig <Image> <kernel.config>              embedded config == file
  cpio-list <initramfs.cpio.gz>                 manifest on stdout
  cpio-check <initramfs.cpio.gz>                newc/gzip/rootfs checks
"""

import gzip
import stat
import struct
import sys

ARM64_MAGIC = 0x644D5241  # "ARM\x64"
NEWC_MAGIC = b"070701"


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def ok(msg):
    print(f"ok: {msg}")


# ----- arm64 Image ---------------------------------------------------------

def check_image(path):
    data = open(path, "rb").read()
    if len(data) < 64:
        fail("Image shorter than its 64-byte header")
    if data[:2] == b"\x1f\x8b":
        fail("Image is gzip-compressed; an uncompressed Image is required")
    (code0, code1, text_offset, image_size, flags,
     res2, res3, res4, magic, res5) = struct.unpack("<IIQQQQQQII", data[:64])
    print(f"code0=0x{code0:08x} code1=0x{code1:08x} text_offset=0x{text_offset:x} "
          f"image_size=0x{image_size:x} flags=0x{flags:x} magic=0x{magic:08x} "
          f"res5(pe_offset)=0x{res5:x} file_size=0x{len(data):x}")
    if magic != ARM64_MAGIC:
        fail(f"magic 0x{magic:08x} != ARM\\x64")
    ok("magic ARM\\x64 at offset 56")
    if res2 or res3 or res4:
        fail("reserved header fields res2..res4 are not zero")
    if image_size == 0:
        fail("image_size is 0 (pre-3.17 header)")
    if image_size < len(data):
        fail("image_size smaller than the file")
    ok(f"image_size {image_size} >= file size {len(data)} (includes BSS)")
    if text_offset != 0:
        fail(f"text_offset 0x{text_offset:x} != 0")
    ok("text_offset 0: load at a 2 MiB aligned RAM address")
    endian = flags & 1
    page = (flags >> 1) & 3
    anywhere = (flags >> 3) & 1
    if endian != 0:
        fail("kernel is big-endian")
    ok("flags bit0: little-endian")
    if page != 1:
        fail(f"flags page-size field {page} != 1 (4 KiB)")
    ok("flags bits1-2: 4 KiB pages")
    print(f"ok: flags bit3 (physical placement anywhere) = {anywhere}")
    # head.S: code0 is efi_signature_nop ("MZ" with the EFI stub, a plain
    # NOP without), code1 is "b primary_entry".
    if (code1 & 0xFC000000) != 0x14000000:
        fail(f"code1 0x{code1:08x} is not a B (branch to primary_entry)")
    if res5 == 0:
        if code0 != 0xD503201F:
            fail(f"no PE header and code0 0x{code0:08x} is not NOP")
        ok("code0 NOP, code1 B primary_entry, no EFI/PE header (direct boot only)")
    else:
        if code0 & 0xFFFF != 0x5A4D:
            fail("PE offset set but code0 lacks the MZ signature")
        ok("code0 MZ (EFI stub), code1 B primary_entry")


# ----- embedded config (CONFIG_IKCONFIG) ----------------------------------

def check_ikconfig(image_path, config_path):
    data = open(image_path, "rb").read()
    start = data.find(b"IKCFG_ST")
    end = data.find(b"IKCFG_ED", start)
    if start < 0 or end < 0:
        fail("IKCFG_ST/IKCFG_ED markers not found in Image")
    embedded = gzip.decompress(data[start + 8:end])
    on_disk = open(config_path, "rb").read()
    if embedded != on_disk:
        fail("config embedded in Image differs from kernel.config")
    ok(f"embedded config ({len(embedded)} bytes) is identical to {config_path}")


# ----- initramfs (gzip + newc) --------------------------------------------

def parse_newc(path):
    raw = open(path, "rb").read()
    if raw[:2] != b"\x1f\x8b":
        fail("initramfs is not gzip (magic 1f 8b missing)")
    blob = gzip.decompress(raw)
    entries = []
    off = 0
    while True:
        hdr = blob[off:off + 110]
        if len(hdr) < 110:
            fail(f"truncated header at offset {off}")
        if hdr[:6] != NEWC_MAGIC:
            fail(f"entry at offset {off}: magic {hdr[:6]!r} is not newc 070701")
        f = [int(hdr[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        ino, mode, uid, gid, nlink, mtime, size, dmaj, dmin, rmaj, rmin, namesize, _ = f
        name_off = off + 110
        name = blob[name_off:name_off + namesize - 1].decode("utf-8", "replace")
        data_off = (name_off + namesize + 3) & ~3
        content = blob[data_off:data_off + size]
        off = (data_off + size + 3) & ~3
        if name == "TRAILER!!!":
            break
        if name.startswith("./"):
            name = name[2:]
        entries.append(dict(name=name,
                            mode=mode, uid=uid, gid=gid, size=size, mtime=mtime,
                            rdev=(rmaj, rmin), data=content, nlink=nlink, ino=ino))
    return raw, blob, entries, off


def kind(mode):
    for test, k in ((stat.S_ISDIR, "d"), (stat.S_ISREG, "f"), (stat.S_ISLNK, "l"),
                    (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b"), (stat.S_ISFIFO, "p"),
                    (stat.S_ISSOCK, "s")):
        if test(mode):
            return k
    return "?"


def cpio_list(path):
    import hashlib
    _, _, entries, _ = parse_newc(path)
    print("# type mode uid gid size sha256|target|rdev path")
    for e in entries:
        k = kind(e["mode"])
        if k == "f":
            extra = hashlib.sha256(e["data"]).hexdigest() if e["size"] else "-"
        elif k == "l":
            extra = "->" + e["data"].decode()
        elif k in "cb":
            extra = "%d:%d" % e["rdev"]
        else:
            extra = "-"
        print(f"{k} {stat.S_IMODE(e['mode']):04o} {e['uid']} {e['gid']} {e['size']} {extra} /{e['name']}")


def cpio_check(path):
    raw, blob, entries, end = parse_newc(path)
    ok(f"gzip stream, {len(raw)} bytes compressed, {len(blob)} bytes decompressed")
    ok(f"{len(entries)} newc (070701) entries followed by TRAILER!!!")
    if blob[end:].strip(b"\0"):
        fail("non-zero data after TRAILER!!!")
    by = {}
    for e in entries:
        if e["name"] in by:
            fail(f"duplicate entry /{e['name']}")
        by[e["name"]] = e
    ok("no duplicate paths")
    if any(e["name"].startswith("/") or ".." in e["name"].split("/") for e in entries):
        fail("absolute or '..' path in archive")
    ok("all paths relative, no '..'")

    def need(name, k, perm=None, uid=0, gid=0):
        e = by.get(name)
        if e is None:
            fail(f"/{name} missing")
        if kind(e["mode"]) != k:
            fail(f"/{name} is type {kind(e['mode'])}, expected {k}")
        if perm is not None and stat.S_IMODE(e["mode"]) != perm:
            fail(f"/{name} mode {stat.S_IMODE(e['mode']):04o} != {perm:04o}")
        if (e["uid"], e["gid"]) != (uid, gid):
            fail(f"/{name} owner {e['uid']}:{e['gid']} != {uid}:{gid}")
        return e

    init = need("init", "f", 0o755)
    if not init["data"].startswith(b"#!/bin/sh\n"):
        fail("/init does not start with #!/bin/sh")
    if b"exec /sbin/init" not in init["data"]:
        fail("/init does not exec /sbin/init")
    ok("/init: regular file 0755 root:root, #!/bin/sh, execs /sbin/init")

    def link(name, target):
        e = need(name, "l")
        if e["data"].decode() != target:
            fail(f"/{name} -> {e['data'].decode()}, expected {target}")

    link("bin/sh", "/bin/busybox")
    link("sbin/init", "/bin/busybox")
    ok("/bin/sh and /sbin/init -> /bin/busybox")
    for name in ("bin/busybox", "sbin/apk", "lib/ld-musl-aarch64.so.1",
                 "etc/nookvm/rc.sysinit", "etc/nookvm/net-up",
                 "usr/share/udhcpc/default.script"):
        need(name, "f", 0o755)
    ok("busybox, apk, musl loader, rc.sysinit, net-up, udhcpc script: 0755 root:root")
    for name in ("sbin/udhcpc", "sbin/ip", "bin/mount", "sbin/getty", "sbin/reboot",
                 "sbin/poweroff", "bin/hostname", "bin/mknod", "bin/mkdir"):
        need(name, "l")
    ok("BusyBox applet links present (udhcpc ip mount getty reboot poweroff ...)")

    elf = by["bin/busybox"]["data"]
    if elf[:4] != b"\x7fELF" or elf[4] != 2 or struct.unpack("<H", elf[18:20])[0] != 183:
        fail("/bin/busybox is not a 64-bit AArch64 ELF")
    ok("/bin/busybox: ELF64 e_machine=183 (AArch64)")

    for name, perm in (("dev", 0o755), ("proc", 0o755), ("sys", 0o755), ("run", 0o755),
                       ("tmp", 0o1777), ("root", 0o700), ("etc", 0o755)):
        need(name, "d", perm)
    ok("dirs: /dev /proc /sys /run 0755, /tmp 1777, /root 0700")
    need("etc/shadow", "f", 0o640, 0, 42)
    ok("/etc/shadow 0640 root:shadow(42)")
    con = need("dev/console", "c", 0o600)
    if con["rdev"] != (5, 1):
        fail(f"/dev/console rdev {con['rdev']} != (5, 1)")
    ok("/dev/console char 5:1 0600 (initial console before devtmpfs)")
    null = need("dev/null", "c", 0o666)
    if null["rdev"] != (1, 3):
        fail(f"/dev/null rdev {null['rdev']} != (1, 3)")
    ok("/dev/null char 1:3 0666")

    for name in ("etc/apk/repositories", "etc/ssl/certs/ca-certificates.crt",
                 "etc/apk/world", "lib/apk/db/installed", "etc/inittab", "etc/hostname"):
        need(name, "f")
    repos = by["etc/apk/repositories"]["data"].decode()
    if "alpine/v3.23/main" not in repos:
        fail("/etc/apk/repositories does not point at v3.23/main")
    ok("apk repositories (v3.23), CA bundle, apk db retained")
    inittab = by["etc/inittab"]["data"].decode()
    if "ttyS0::respawn:" not in inittab or "openrc" in inittab:
        fail("/etc/inittab is not the NookVM one")
    ok("/etc/inittab: ttyS0 respawn shell, no OpenRC")
    for bad in ("sbin/openrc", "sbin/openrc-init", "usr/sbin/sshd", "usr/bin/dropbear",
                "etc/init.d/sshd"):
        if bad in by:
            fail(f"/{bad} must not be in the rootfs")
    ok("no OpenRC, sshd or dropbear")
    if any(e["mtime"] != entries[0]["mtime"] for e in entries):
        fail("mtimes are not normalized")
    ok(f"all mtimes normalized to {entries[0]['mtime']} (SOURCE_DATE_EPOCH)")


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    {"image": lambda: check_image(args[0]),
     "ikconfig": lambda: check_ikconfig(args[0], args[1]),
     "cpio-list": lambda: cpio_list(args[0]),
     "cpio-check": lambda: cpio_check(args[0])}[cmd]()


if __name__ == "__main__":
    main()
