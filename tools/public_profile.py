#!/usr/bin/env python3
"""Retiming for the public release template (never uses personal captures).

Upstream: tmfadhlul/apple-video-to-livephotos, templates/metadata.mov.
That metadata-only input is distributed under the MIT license. The release
builder includes the upstream copyright and permission notice.
"""
from hashlib import sha256
from pathlib import Path
import sys

from livewallpaper import (
    Box, Movie, INFO, STILL, MATRIX, SP, assign_edits, boxes, bykey, get,
    make_table, need, pack, replace, splice, track_header,
)

SOURCE_SHA256 = "d9aee0440214bfb0fad75cfe8cde11f098b4546a8ff9fff13807a63d12cff800"


def make_profile(source, output):
    donor = Movie(source)
    need(sha256(donor.data).hexdigest() == SOURCE_SHA256, "Unexpected public template hash")
    need(donor.scale == 600 and donor.mvhd[0] == 0, "Unexpected movie timebase")
    need(len(donor.tracks) == 2, "Public source must contain two metadata tracks")

    lead = bykey(donor.root, "ftyp").encode() + Box(b"wide", b"").encode()
    media = bytearray()
    tracks = []
    for track_id, track in enumerate(donor.tracks, 2):
        keys = {item[0] for item in track.timed_keys.values()}
        need(track.handler == "meta" and not track.v1 and track.offset_type == "stco"
             and not any(atom.key == b"tref" for atom in boxes(track.atom)), "Unsupported metadata track")
        header = get(track.atom, "mdia", "mdhd")
        need(header[0] == 0, "Unexpected media header")

        if track_id == 2:
            need(keys == {INFO} and len(track.sizes) == 60, "Unexpected motion descriptors")
            step, duration = 30, 1800
            edits = [(duration, 0, 65536)]
        else:
            need(keys == {STILL, MATRIX} and len(track.sizes) == 1, "Unexpected still descriptors")
            step, duration = 1, 921
            edits = [(920, -1, 65536), (1, 0, 65536)]
        timing = make_table("II", [(len(track.sizes), step)])
        header = splice(header, 12, pack("II", 600, len(track.sizes) * step))
        data = replace(track.atom, ("tkhd",), track_header(track, track_id, duration))
        data = replace(data, ("mdia", "mdhd"), header)
        data = assign_edits(data, edits)
        data = replace(data, (*SP, "stts"), timing)

        offsets = []
        for _, chunk, _ in track.chunks():
            offsets.append((len(lead) + 8 + len(media),))
            media.extend(chunk)
        data = replace(data, (*SP, "stco"), make_table("I", offsets))
        tracks.append(Box(b"trak", data).encode())

    header = splice(donor.mvhd, 16, pack("I", 1800))
    header = splice(header, len(header) - 4, pack("I", 4))
    # Deliberately omit the donor's global meta and its original UUID.
    moov = Box(b"mvhd", header).encode() + b"".join(tracks)
    with Path(output).open("xb") as file:
        file.write(lead + Box(b"mdat", bytes(media)).encode() + Box(b"moov", moov).encode())


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("public_profile.py UPSTREAM.mov OUTPUT.mov")
    make_profile(*sys.argv[1:])
