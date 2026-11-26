#!/usr/bin/env python3
"""Writes and reads the Finder .DS_Store of the Mac DMG, so the window layout needs no Finder scripting.

  dmg-dsstore.py write MOUNT --volname NAME --background REL --window W,H [--title-bar N] [--origin X,Y]
                       --icon-size N --text-size N --item NAME=X,Y [--item ...] [--offscreen NAME ...]
                       [--bookmark FILE]
  dmg-dsstore.py dump FILE      prints the records as JSON (plists decoded, the background alias decoded)

`write` runs against the read-write image while it is mounted (scripts/make-dmg.sh): the background picture is
referenced by a classic Finder alias (icvp's backgroundImageAlias, as Finder and dmgbuild write it) and, with
--bookmark, by a bookmark (pBBk, which Finder tries first; scripts/dmg-bookmark.swift makes it). Both name the
volume (its name and creation date, or its UUID) and the file ids of the picture and its folder, which exist only
once the volume does. They survive the conversion to UDZO and every later mount, so they resolve on any Mac.
MOUNT is where the image is mounted now; the alias records /Volumes/<volname> as the mount point, where a user's
Finder mounts it. Positions (--item) are icon centres in points from the top left of the window's content area;
--window is the content size in points; Finder's window bounds also hold the title bar (--title-bar points).

Python 3.9 or later, standard library only (macOS: st_birthtime). No Finder, no AppleScript, no network.
"""
import argparse
import json
import os
import plistlib
import struct
import sys

MAC_EPOCH_OFFSET = 2082844800  # seconds from 1904-01-01 to 1970-01-01
PAGE_SIZE = 0x1000
OFFSCREEN = (1200, 120)  # Iloc for hidden items, outside the window, should someone show hidden files


# ---------------------------------------------------------------------------------------------------------------
# The background alias (Alias Manager record, version 2), field for field as Finder writes it for a file on a
# disk image volume.

def _pstr(s, size):
    b = s.encode('utf-8')[:size - 1]
    return bytes([len(b)]) + b + b'\0' * (size - 1 - len(b))


def _tag(code, data):
    out = struct.pack('>hH', code, len(data)) + data
    return out + (b'\0' if len(data) & 1 else b'')


def make_alias(mount, volname, rel):
    """A Finder alias to MOUNT/REL (a file inside one folder at the volume root)."""
    target = os.path.join(mount, rel)
    folder = os.path.dirname(target)
    fst, dst, vst = os.stat(target), os.stat(folder), os.stat(mount)
    parent = os.path.dirname(rel.strip('/'))
    if parent == '' or '/' in parent:
        raise SystemExit('error: the background must be in one folder at the volume root, such as .background/x.tiff')
    folder_name = os.path.basename(folder)
    filename = os.path.basename(target)
    voldate = int(vst.st_birthtime) + MAC_EPOCH_OFFSET
    crdate = int(fst.st_birthtime) + MAC_EPOCH_OFFSET
    body = struct.pack('>h28sI2shI64sII4s4shhI2s10s',
                       0,                       # kind: file
                       _pstr(volname, 28),
                       voldate,
                       b'H+',                   # what Finder writes for HFS+ and APFS volumes alike
                       5,                       # disk type: ejectable
                       dst.st_ino,              # parent folder id
                       _pstr(filename, 64),
                       fst.st_ino,              # file id
                       crdate,
                       b'\0\0\0\0', b'\0\0\0\0',  # creator, type
                       -1, -1,                  # levels from / to
                       0x00000d02,              # volume attributes, as Finder writes them for a disk image
                       b'\0\0', b'\0' * 10)
    rel_posix = '/' + rel.strip('/')
    tags = b''.join([
        _tag(0, folder_name.encode('utf-8')),
        _tag(16, struct.pack('>Q', voldate << 16)),
        _tag(17, struct.pack('>Q', crdate << 16)),
        _tag(1, struct.pack('>I', dst.st_ino)),
        _tag(2, (volname + ':' + folder_name + ':\0' + filename).encode('utf-8')),
        _tag(14, struct.pack('>H', len(filename)) + filename.encode('utf-16-be')),
        _tag(15, struct.pack('>H', len(volname)) + volname.encode('utf-16-be')),
        _tag(18, rel_posix.encode('utf-8')),
        _tag(19, ('/Volumes/' + volname).encode('utf-8')),
        struct.pack('>hH', -1, 0),
    ])
    record = body + tags
    return struct.pack('>4sHH', b'\0\0\0\0', 8 + len(record), 2) + record


def parse_alias(b):
    """The fields of a version-2 alias that the layout depends on (for dump and the tests)."""
    _, length, version = struct.unpack('>4sHH', b[:8])
    f = struct.unpack('>h28sI2shI64sII4s4shhI2s10s', b[8:150])
    out = {'length': length, 'version': version, 'kind': f[0],
           'volname': f[1][1:1 + f[1][0]].decode('utf-8'), 'voldate': f[2], 'fstype': f[3].decode(),
           'disktype': f[4], 'parent_id': f[5], 'filename': f[6][1:1 + f[6][0]].decode('utf-8'),
           'file_id': f[7], 'crdate': f[8], 'tags': {}}
    p = 150
    while p + 4 <= len(b):
        code, n = struct.unpack('>hH', b[p:p + 4])
        if code == -1:
            break
        d = b[p + 4:p + 4 + n]
        p += 4 + n + (n & 1)
        if code in (0, 2, 18, 19):
            v = d.decode('utf-8', 'replace')
        elif code in (14, 15):
            v = d[2:].decode('utf-16-be')
        elif code in (16, 17):
            v = struct.unpack('>Q', d)[0] >> 16
        elif code == 1:
            v = list(struct.unpack('>%dI' % (len(d) // 4), d))
        else:
            v = d.hex()
        out['tags'][str(code)] = v
    return out


# ---------------------------------------------------------------------------------------------------------------
# The .DS_Store file: a buddy-allocated file ("Bud1") holding one B-tree ("DSDB") of records sorted by file name
# (case-insensitive), then record code.

def _record(name, code, typ, value):
    out = struct.pack('>I', len(name)) + name.encode('utf-16-be') + code.encode() + typ.encode()
    if typ == 'long':
        return out + struct.pack('>I', value)
    if typ == 'blob':
        return out + struct.pack('>I', len(value)) + value
    raise ValueError(typ)


class Buddy:
    """Hands out power-of-two blocks from a 2^31 address space, splitting larger free blocks as Finder does."""

    def __init__(self):
        self.free = [[] for _ in range(32)]
        self.free[31] = [0]

    def alloc(self, width):
        w = width
        while not self.free[w]:
            w += 1
        while w > width:
            off = self.free[w].pop(0)
            w -= 1
            self.free[w] = sorted(self.free[w] + [off, off ^ (1 << w)])
        return self.free[width].pop(0)


def build_ds_store(records):
    records = sorted(records, key=lambda r: (r[0].lower(), r[1]))
    node = struct.pack('>II', 0, len(records)) + b''.join(_record(*r) for r in records)
    if len(node) > PAGE_SIZE:
        raise SystemExit('error: the records do not fit in one B-tree node')
    buddy = Buddy()
    assert buddy.alloc(5) == 0          # the file header (36 bytes from offset -4)
    root_off = buddy.alloc(11)          # block 0: the allocator's own info block (2048 bytes)
    dsdb_off = buddy.alloc(5)           # block 1: the DSDB header (20 bytes)
    node_off = buddy.alloc(12)          # block 2: the one leaf node (one page)
    addresses = [root_off | 11, dsdb_off | 5, node_off | 12]
    root = struct.pack('>II', len(addresses), 0) + struct.pack('>%dI' % len(addresses), *addresses)
    root += b'\0' * (4 * (256 - len(addresses)))
    root += struct.pack('>I', 1) + bytes([4]) + b'DSDB' + struct.pack('>I', 1)
    for w in range(32):
        root += struct.pack('>I', len(buddy.free[w])) + b''.join(struct.pack('>I', o) for o in buddy.free[w])
    assert len(root) <= 2048
    dsdb = struct.pack('>IIIII', 2, 0, len(records), 1, PAGE_SIZE)
    size = max(root_off + 2048, dsdb_off + 32, node_off + PAGE_SIZE)
    data = bytearray(size + 4)

    def put(off, b):
        data[off + 4:off + 4 + len(b)] = b

    data[0:36] = struct.pack('>I4sIII16s', 1, b'Bud1', root_off, 2048, root_off, b'\0' * 16)
    put(root_off, root)
    put(dsdb_off, dsdb)
    put(node_off, node)
    return bytes(data)


def parse_ds_store(data):
    """Records as (name, code, type, value) from a .DS_Store, following every B-tree node."""
    if data[:8] != b'\0\0\0\1Bud1':
        raise ValueError('not a .DS_Store (no Bud1 header)')
    root_off, root_size, root_off2 = struct.unpack('>III', data[8:20])
    if root_off != root_off2:
        raise ValueError('header offsets disagree')

    def rd(off, n):
        return data[off + 4:off + 4 + n]

    count, _ = struct.unpack('>II', rd(root_off, 8))
    addresses = struct.unpack('>%dI' % count, rd(root_off + 8, 4 * count))
    p = root_off + 8 + 4 * ((count + 255) // 256 * 256)
    toc = {}
    for _ in range(struct.unpack('>I', rd(p, 4))[0]):
        n = rd(p + 4, 1)[0]
        toc[rd(p + 5, n).decode()] = struct.unpack('>I', rd(p + 5 + n, 4))[0]
        p += 5 + n

    def block(i):
        a = addresses[i]
        return rd(a & ~0x1f, 1 << (a & 0x1f))

    top, _levels, nrecords, _nodes, _page = struct.unpack('>IIIII', block(toc['DSDB'])[:20])
    out = []

    def walk(i):
        b = block(i)
        nxt, n = struct.unpack('>II', b[:8])
        q = 8
        for _ in range(n):
            if nxt:
                walk(struct.unpack('>I', b[q:q + 4])[0])
                q += 4
            ln = struct.unpack('>I', b[q:q + 4])[0]
            name = b[q + 4:q + 4 + 2 * ln].decode('utf-16-be')
            q += 4 + 2 * ln
            code, typ = b[q:q + 4].decode(), b[q + 4:q + 8].decode()
            q += 8
            if typ in ('long', 'shor'):
                v = struct.unpack('>I', b[q:q + 4])[0]
                q += 4
            elif typ == 'bool':
                v = b[q]
                q += 1
            elif typ in ('type',):
                v = b[q:q + 4].decode()
                q += 4
            elif typ in ('comp', 'dutc'):
                v = b[q:q + 8].hex()
                q += 8
            elif typ == 'blob':
                ln = struct.unpack('>I', b[q:q + 4])[0]
                v = b[q + 4:q + 4 + ln]
                q += 4 + ln
            elif typ == 'ustr':
                ln = struct.unpack('>I', b[q:q + 4])[0]
                v = b[q + 4:q + 4 + 2 * ln].decode('utf-16-be')
                q += 4 + 2 * ln
            else:
                raise ValueError('unknown record type %r' % typ)
            out.append((name, code, typ, v))
        if nxt:
            walk(nxt)

    walk(top)
    if len(out) != nrecords:
        raise ValueError('the DSDB header counts %d records, the tree holds %d' % (nrecords, len(out)))
    return out


def decode_value(code, typ, v):
    if typ == 'blob' and v[:8] == b'bplist00':
        pl = plistlib.loads(v)
        if 'backgroundImageAlias' in pl:
            pl['backgroundImageAlias'] = parse_alias(pl['backgroundImageAlias'])
        return pl
    if typ == 'blob' and code == 'Iloc':
        x, y = struct.unpack('>II', v[:8])
        return {'x': x, 'y': y}
    if isinstance(v, bytes):
        return v.hex()
    return v


# ---------------------------------------------------------------------------------------------------------------

def pair(s):
    a, b = s.split(',')
    return int(a), int(b)


def cmd_write(args):
    mount = os.path.abspath(args.mount)
    if not os.path.isdir(mount):
        raise SystemExit('error: no folder at %s' % mount)
    bg = args.background.strip('/')
    if not os.path.isfile(os.path.join(mount, bg)):
        raise SystemExit('error: no background at %s' % os.path.join(mount, bg))
    w, h = args.window
    ox, oy = args.origin
    bwsp = {
        'WindowBounds': '{{%d, %d}, {%d, %d}}' % (ox, oy, w, h + args.title_bar),
        'ShowToolbar': False, 'ShowStatusBar': False, 'ShowPathbar': False, 'ShowTabView': False,
        'ShowSidebar': False, 'ContainerShowSidebar': False, 'PreviewPaneVisibility': False,
    }
    icvp = {
        'viewOptionsVersion': 1, 'arrangeBy': 'none', 'iconSize': float(args.icon_size),
        'textSize': float(args.text_size), 'labelOnBottom': True, 'showItemInfo': False, 'showIconPreview': True,
        'gridSpacing': 100.0, 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'backgroundType': 2, 'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'backgroundImageAlias': make_alias(mount, args.volname, bg),
    }
    records = [
        ('.', 'bwsp', 'blob', plistlib.dumps(bwsp, fmt=plistlib.FMT_BINARY, sort_keys=True)),
        ('.', 'icvp', 'blob', plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY, sort_keys=True)),
        ('.', 'vSrn', 'long', 1),
    ]
    if args.bookmark:
        with open(args.bookmark, 'rb') as f:
            records.append(('.', 'pBBk', 'blob', f.read()))
    for item in args.item:
        name, xy = item.rsplit('=', 1)
        if not os.path.lexists(os.path.join(mount, name)):
            raise SystemExit('error: no %s at the volume root' % name)
        x, y = pair(xy)
        records.append((name, 'Iloc', 'blob', struct.pack('>IIII', x, y, 0xffffffff, 0xffff0000)))
    for name in args.offscreen:
        if os.path.lexists(os.path.join(mount, name)):
            records.append((name, 'Iloc', 'blob', struct.pack('>IIII', *OFFSCREEN, 0xffffffff, 0xffff0000)))
    data = build_ds_store(records)
    parse_ds_store(data)  # round trip before writing
    with open(os.path.join(mount, '.DS_Store'), 'wb') as f:
        f.write(data)


def cmd_dump(args):
    with open(args.file, 'rb') as f:
        records = parse_ds_store(f.read())
    out = {}
    for name, code, typ, v in records:
        out.setdefault(name, {})[code] = decode_value(code, typ, v)
    json.dump(out, sys.stdout, indent=2, sort_keys=True, default=str)
    sys.stdout.write('\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    w = sub.add_parser('write')
    w.add_argument('mount')
    w.add_argument('--volname', required=True)
    w.add_argument('--background', required=True, help='path of the picture relative to the volume root')
    w.add_argument('--window', type=pair, required=True, help='content width,height in points')
    w.add_argument('--origin', type=pair, default=(200, 120), help='window position x,y on screen')
    w.add_argument('--title-bar', type=int, default=0, help='points added to the height for the title bar')
    w.add_argument('--icon-size', type=int, required=True)
    w.add_argument('--text-size', type=int, required=True)
    w.add_argument('--item', action='append', default=[], help='NAME=X,Y (icon centre in points)')
    w.add_argument('--offscreen', action='append', default=[], help='a hidden item to park outside the window')
    w.add_argument('--bookmark', help='a file holding a bookmark to the background (stored as pBBk)')
    w.set_defaults(fn=cmd_write)
    d = sub.add_parser('dump')
    d.add_argument('file')
    d.set_defaults(fn=cmd_dump)
    args = ap.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
