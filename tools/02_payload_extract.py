#!/usr/bin/env python3
"""
TOOL 02 - payload_extract  (OUR OWN - pure python, zero pip deps)
Extracts every partition image out of an Android A/B OTA.
Reads payload.bin DIRECTLY out of the OTA zip when it is STORED (no 8GB copy).
Usage:
  payload_extract.py <ota.zip|payload.bin> <outdir> [--list] [--only a,b] [--skip a,b]
"""
import bz2
import lzma
import os
import struct
import sys
import time
import zipfile

REPLACE, REPLACE_BZ, ZERO, DISCARD, REPLACE_XZ = 0, 1, 6, 7, 8
OPNAME = {0: "REPLACE", 1: "REPLACE_BZ", 6: "ZERO", 7: "DISCARD", 8: "REPLACE_XZ"}


# ---------- minimal protobuf wire reader (no protobuf package needed) ----------
def _varint(b, i):
    r = 0
    s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        if not (c & 0x80):
            return r, i
        s += 7


def _fields(b):
    i = 0
    n = len(b)
    while i < n:
        k, i = _varint(b, i)
        fn, wt = k >> 3, k & 7
        if wt == 0:
            v, i = _varint(b, i)
        elif wt == 2:
            ln, i = _varint(b, i)
            v = b[i:i + ln]
            i += ln
        elif wt == 5:
            v = struct.unpack_from("<I", b, i)[0]
            i += 4
        elif wt == 1:
            v = struct.unpack_from("<Q", b, i)[0]
            i += 8
        else:
            raise ValueError("bad protobuf wire type %d" % wt)
        yield fn, wt, v


def _extent(b):
    st = nb = 0
    for fn, _wt, v in _fields(b):
        if fn == 1:
            st = v
        elif fn == 2:
            nb = v
    return st, nb


def _op(b):
    o = {"type": 0, "off": 0, "len": 0, "dst": []}
    for fn, wt, v in _fields(b):
        if fn == 1:
            o["type"] = v
        elif fn == 2:
            o["off"] = v
        elif fn == 3:
            o["len"] = v
        elif fn == 6 and wt == 2:
            o["dst"].append(_extent(v))
    return o


def _pinfo_size(b):
    for fn, _wt, v in _fields(b):
        if fn == 1:
            return v
    return 0


def _partition(b):
    p = {"name": "", "size": 0, "ops": []}
    for fn, wt, v in _fields(b):
        if fn == 1 and wt == 2:
            p["name"] = v.decode("utf-8", "replace")
        elif fn == 7 and wt == 2:
            p["size"] = _pinfo_size(v)
        elif fn == 8 and wt == 2:
            p["ops"].append(_op(v))
    return p


def parse_manifest(m):
    block_size = 4096
    parts = []
    for fn, wt, v in _fields(m):
        if fn == 3 and wt == 0:
            block_size = v
        elif fn == 13 and wt == 2:
            parts.append(_partition(v))
    return block_size, parts


# ---------- payload source: zip (stored) or plain file ----------
class Source:
    def __init__(self, path):
        self.tmp = None
        if zipfile.is_zipfile(path):
            zf = zipfile.ZipFile(path)
            name = None
            for n in zf.namelist():
                if n == "payload.bin" or n.endswith("/payload.bin"):
                    name = n
                    break
            if name is None:
                raise SystemExit("ERROR: no payload.bin inside %s (not a full A/B OTA)" % path)
            zi = zf.getinfo(name)
            if zi.compress_type == zipfile.ZIP_STORED:
                f = open(path, "rb")
                f.seek(zi.header_offset)
                hdr = f.read(30)
                nlen, elen = struct.unpack_from("<HH", hdr, 26)
                self.base = zi.header_offset + 30 + nlen + elen
                self.f = f
                print("payload.bin is STORED inside the zip -> reading in place "
                      "(no 8GB copy, offset %d, size %d)" % (self.base, zi.file_size))
            else:
                out = os.path.join(os.path.dirname(os.path.abspath(path)), "payload.bin")
                print("payload.bin is DEFLATED -> extracting once to %s" % out)
                with zf.open(zi) as src, open(out, "wb") as dst:
                    while True:
                        c = src.read(1 << 22)
                        if not c:
                            break
                        dst.write(c)
                self.tmp = out
                self.f = open(out, "rb")
                self.base = 0
            zf.close()
        else:
            self.f = open(path, "rb")
            self.base = 0

    def read_at(self, off, size):
        self.f.seek(self.base + off)
        return self.f.read(size)

    def header(self):
        magic = self.read_at(0, 4)
        if magic != b"CrAU":
            raise SystemExit("ERROR: bad payload magic %r - not an Android OTA payload" % magic)
        ver = struct.unpack(">Q", self.read_at(4, 8))[0]
        msize = struct.unpack(">Q", self.read_at(12, 8))[0]
        if ver < 2:
            raise SystemExit("ERROR: payload version %d not supported" % ver)
        sigsize = struct.unpack(">I", self.read_at(20, 4))[0]
        manifest = self.read_at(24, msize)
        data_start = 24 + msize + sigsize
        return ver, manifest, data_start


def human(n):
    for u in ("B", "K", "M", "G"):
        if n < 1024 or u == "G":
            return "%.1f%s" % (n, u)
        n /= 1024.0


def write_partition(src, data_start, block_size, part, out_path):
    total = part["size"] or 0
    written = 0
    with open(out_path, "wb") as out:
        for op in part["ops"]:
            t = op["type"]
            if t in (ZERO, DISCARD):
                # holes read back as zeros; truncate() at the end materialises them
                continue
            if t not in (REPLACE, REPLACE_BZ, REPLACE_XZ):
                raise RuntimeError(
                    "unsupported operation type %d (%s) - this looks like an "
                    "INCREMENTAL OTA, a full OTA is required"
                    % (t, OPNAME.get(t, "DIFF")))
            raw = src.read_at(data_start + op["off"], op["len"])
            if t == REPLACE_BZ:
                raw = bz2.decompress(raw)
            elif t == REPLACE_XZ:
                raw = lzma.decompress(raw)
            pos = 0
            for (start, nblocks) in op["dst"]:
                n = nblocks * block_size
                chunk = raw[pos:pos + n]
                pos += n
                if not chunk:
                    continue
                out.seek(start * block_size)
                out.write(chunk)
                written += len(chunk)
        if not total:
            total = max(
                [(s + n) * block_size for op in part["ops"] for (s, n) in op["dst"]] or [0])
        out.truncate(total)
    return total, written


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    src_path, outdir = argv[1], argv[2]
    only = skip = None
    for i, a in enumerate(argv):
        if a == "--only" and i + 1 < len(argv):
            only = set(x for x in argv[i + 1].split(",") if x)
        if a == "--skip" and i + 1 < len(argv):
            skip = set(x for x in argv[i + 1].split(",") if x)
    listing = "--list" in argv

    os.makedirs(outdir, exist_ok=True)
    src = Source(src_path)
    ver, manifest, data_start = src.header()
    block_size, parts = parse_manifest(manifest)
    print("payload v%d | block_size=%d | %d partitions" % (ver, block_size, len(parts)))

    if listing:
        for p in parts:
            print("  %-22s %10s  %d ops" % (p["name"], human(p["size"]), len(p["ops"])))
        return 0

    todo = []
    for p in parts:
        if only and p["name"] not in only:
            continue
        if skip and p["name"] in skip:
            continue
        todo.append(p)

    ok = 0
    failed = []
    t_all = time.time()
    for i, p in enumerate(todo, 1):
        dst = os.path.join(outdir, p["name"] + ".img")
        t0 = time.time()
        sys.stdout.write("[%2d/%2d] %-22s %10s ... " % (i, len(todo), p["name"], human(p["size"])))
        sys.stdout.flush()
        try:
            total, _w = write_partition(src, data_start, block_size, p, dst)
            dt = max(time.time() - t0, 0.001)
            print("OK  %s in %.1fs (%.0f MB/s)" % (human(total), dt, total / dt / 1048576))
            ok += 1
        except Exception as e:  # noqa: BLE001 - report, never abort the whole dump
            print("FAILED: %s" % e)
            failed.append(p["name"])
            if os.path.exists(dst):
                os.remove(dst)
    print("=== payload done: %d/%d images in %.0fs ===" % (ok, len(todo), time.time() - t_all))
    if failed:
        print("FAILED PARTITIONS: %s" % ", ".join(failed))
    if src.tmp and os.path.exists(src.tmp):
        os.remove(src.tmp)
        print("removed temporary payload.bin")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
