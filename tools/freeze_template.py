#!/usr/bin/env python3
"""Freeze metadata only from the iPhone-verified MOV (no image/video samples)."""
from pathlib import Path
import sys
sys.dont_write_bytecode = True
from livewallpaper import Box, Movie, SP, make_table, replace, bykey, need

if len(sys.argv) != 3:
    raise SystemExit("freeze_template.py VERIFIED.mov OUT.mov")
m = Movie(sys.argv[1])
need((m.scale,m.duration)==(600,1800), "Unexpected donor timeline")
tracks = [t for t in m.tracks if t.handler == "meta"]
need([t.id for t in tracks]==[2,3,4] and tracks[1].start()==920, "Unexpected donor tracks or key")
p = bykey(m.root, "ftyp").encode() + Box(b"wide", b"").encode()
media = bytearray()
encoded = []
for t in tracks:
    need(t.offset_type=="stco", "Unexpected chunk offset type")
    offsets = []
    for _, chunk, _ in t.chunks():
        offsets.append((len(p)+8+len(media),))
        media.extend(chunk)
    encoded.append(Box(b"trak", replace(t.atom, (*SP, "stco"), make_table("I", offsets))).encode())
moov = Box(b"mvhd", m.mvhd).encode() + b"".join(encoded)
with Path(sys.argv[2]).open("xb") as f:
    f.write(p + Box(b"mdat", media).encode() + Box(b"moov", moov).encode())
