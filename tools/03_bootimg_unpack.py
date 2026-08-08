#!/usr/bin/env python3
"""
TOOL 03 - bootimg_unpack  (OUR OWN - pure python, NO magiskboot, NO Illegal instruction)
Parses boot / init_boot (ANDROID! v0-v4) and vendor_boot (VNDRBOOT v3/v4),
including the v4 vendor ramdisk TABLE, so the platform ramdisk AND the
recovery ramdisk both come out as separate files.
Usage: bootimg_unpack.py <image> <outdir>
"""
import json
import os
import struct
import sys

RD_TYPE = {0: "none", 1: "platform", 2: "recovery", 3: "dlkm"}
MAGICS = [
    (b"\x02\x21\x4c\x18", "lz4_legacy"),
    (b"\x04\x22\x4d\x18", "lz4"),
    (b"\x1f\x8b", "gzip"),
    (b"\xfd7zXZ", "xz"),
    (b"\x28\xb5\x2f\xfd", "zstd"),
    (b"\x5d\x00\x00", "lzma"),
    (b"\x42\x5a\x68", "bzip2"),
    (b"070701", "cpio"),
    (b"070702", "cpio"),
]


def sniff(path):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return "unknown"
    for magic, name in MAGICS:
        if head.startswith(magic):
            return name
    return "raw"


def pad(n, page):
    return (n + page - 1) // page * page


def cstr(b):
    return b.split(b"\x00", 1)[0].decode("utf-8", "replace")


def dump(f, off, size, path):
    if size <= 0:
        return None
    f.seek(off)
    left = size
    with open(path, "wb") as out:
        while left:
            c = f.read(min(left, 1 << 22))
            if not c:
                break
            out.write(c)
            left -= len(c)
    return path


def unpack_boot(f, outdir, info):
    f.seek(0)
    head = f.read(1660)
    hv = struct.unpack_from("<I", head, 40)[0]
    info["format"] = "boot"
    info["header_version"] = hv
    parts = []
    if hv >= 3:
        kernel_size, ramdisk_size, os_ver, header_size = struct.unpack_from("<IIII", head, 8)
        page = 4096
        info["cmdline"] = cstr(head[44:44 + 1536])
        off = pad(header_size, page)
        parts.append(("kernel", kernel_size))
        parts.append(("ramdisk", ramdisk_size))
    else:
        (kernel_size, _ka, ramdisk_size, _ra, second_size, _sa,
         _tags, page) = struct.unpack_from("<IIIIIIII", head, 8)
        page = page or 4096
        info["cmdline"] = cstr(head[64:64 + 512]) + cstr(head[608:608 + 1024])
        info["name"] = cstr(head[48:64])
        off = page
        parts.append(("kernel", kernel_size))
        parts.append(("ramdisk", ramdisk_size))
        parts.append(("second", second_size))
        if hv >= 1:
            parts.append(("recovery_dtbo", struct.unpack_from("<I", head, 1632)[0]))
        if hv >= 2:
            parts.append(("dtb", struct.unpack_from("<I", head, 1648)[0]))
    info["page_size"] = page
    for name, size in parts:
        if size <= 0:
            info[name] = {"size": 0, "note": "empty (normal for GKI boot)"}
            continue
        p = os.path.join(outdir, name)
        dump(f, off, size, p)
        info[name] = {"size": size, "file": name, "format": sniff(p)}
        off = pad(off + size, page)
    return info


def unpack_vendor(f, outdir, info):
    f.seek(0)
    head = f.read(2128)
    hv, page, _ka, _ra, vrd_size = struct.unpack_from("<IIIII", head, 8)
    page = page or 4096
    header_size, dtb_size = struct.unpack_from("<II", head, 2096)
    info.update({
        "format": "vendor_boot",
        "header_version": hv,
        "page_size": page,
        "cmdline": cstr(head[28:28 + 2048]),
        "name": cstr(head[2080:2096]),
    })
    tbl_size = tbl_num = tbl_entry = bootconfig_size = 0
    if hv >= 4:
        tbl_size, tbl_num, tbl_entry, bootconfig_size = struct.unpack_from("<IIII", head, 2112)

    o_ramdisk = pad(header_size, page)
    o_dtb = o_ramdisk + pad(vrd_size, page)
    o_table = o_dtb + pad(dtb_size, page)
    o_bootconfig = o_table + pad(tbl_size, page)

    if dtb_size:
        dump(f, o_dtb, dtb_size, os.path.join(outdir, "dtb"))
        info["dtb"] = {"size": dtb_size, "file": "dtb"}
    if bootconfig_size:
        dump(f, o_bootconfig, bootconfig_size, os.path.join(outdir, "bootconfig"))
        info["bootconfig"] = {"size": bootconfig_size, "file": "bootconfig"}

    frags = []
    if hv >= 4 and tbl_num and tbl_entry >= 108:
        f.seek(o_table)
        raw = f.read(tbl_size)
        for i in range(tbl_num):
            e = raw[i * tbl_entry:(i + 1) * tbl_entry]
            if len(e) < 44:
                break
            size, offset, rtype = struct.unpack_from("<III", e, 0)
            name = cstr(e[12:44])
            label = name or RD_TYPE.get(rtype, "frag%d" % i)
            fname = "ramdisk" if (rtype == 1 and not name) else "%s_ramdisk" % label
            p = os.path.join(outdir, fname)
            dump(f, o_ramdisk + offset, size, p)
            frags.append({"file": fname, "name": name, "type": RD_TYPE.get(rtype, str(rtype)),
                          "size": size, "format": sniff(p)})
    if not frags and vrd_size:
        p = os.path.join(outdir, "ramdisk")
        dump(f, o_ramdisk, vrd_size, p)
        frags.append({"file": "ramdisk", "name": "", "type": "platform",
                      "size": vrd_size, "format": sniff(p)})
    info["ramdisk_fragments"] = frags
    return info


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    img, outdir = argv[1], argv[2]
    os.makedirs(outdir, exist_ok=True)
    with open(img, "rb") as f:
        magic = f.read(8)
        info = {"image": os.path.basename(img), "bytes": os.path.getsize(img)}
        if magic == b"ANDROID!":
            unpack_boot(f, outdir, info)
        elif magic == b"VNDRBOOT":
            unpack_vendor(f, outdir, info)
        else:
            print("SKIP %s - not a boot image (magic %r)" % (img, magic))
            return 0
    with open(os.path.join(outdir, "header_info.json"), "w") as j:
        json.dump(info, j, indent=2, sort_keys=True)
    print("=== %s (%s v%s) ===" % (info["image"], info["format"], info["header_version"]))
    for k in ("kernel", "ramdisk", "dtb", "bootconfig", "second", "recovery_dtbo"):
        if isinstance(info.get(k), dict):
            d = info[k]
            print("  %-14s %10d  %s" % (k, d.get("size", 0),
                                        d.get("format", d.get("note", ""))))
    for fr in info.get("ramdisk_fragments", []):
        print("  fragment       %10d  type=%-9s name=%-10s fmt=%s -> %s"
              % (fr["size"], fr["type"], fr["name"] or "-", fr["format"], fr["file"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
