#!/usr/bin/env python3
"""Build/inspect ordinary, self-contained QuickTime Live Photo pairs on macOS.

Use a known working wallpaper MOV as a donor for timed metadata, never as a
video/still/audio source. No network access or third-party libraries.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import uuid

CID = "com.apple.quicktime.content.identifier"
INFO = "com.apple.quicktime.live-photo-info"
STILL = "com.apple.quicktime.still-image-time"
MATRIX = "com.apple.quicktime.live-photo-still-image-transform"
DIMS = MATRIX + "-reference-dimensions"
ORIENT = "com.apple.quicktime.video-orientation"
IDENTITY = (65536, 0, 0, 0, 65536, 0, 0, 0, 1073741824)
SP = ("mdia", "minf", "stbl")
LP = ("edts", "elst")


def need(test, msg):
    if not test:
        raise ValueError(msg)


def unpack(fmt, data, off=0):
    return struct.unpack_from(">" + fmt, data, off)


def pack(fmt, *args):
    return struct.pack(">" + fmt, *args)


def splice(data, offset, replacement):
    need(0 <= offset <= len(data) - len(replacement), "Patch outside atom")
    return data[:offset] + replacement + data[offset + len(replacement):]


@dataclass(frozen=True)
class Box:
    key: bytes
    payload: bytes
    pos: int = 0
    header: int = 8

    def encode(self):
        size = len(self.payload) + 8
        return pack("I4s", size, self.key) + self.payload


def boxes(data, start=0, zero_terminator=False):
    p = start
    while p < len(data):
        if zero_terminator and data[p:] == b"\0" * 4:
            break
        size, key = unpack("I4s", data, p)
        header = 8
        if size == 1:
            size, = unpack("Q", data, p + 8)
            header = 16
        elif size == 0:
            size = len(data) - p
        need(header <= size <= len(data) - p, f"Invalid atom {key!r} at {p}")
        yield Box(key, data[p + header:p + size], p, header)
        p += size


def bykey(items, key):
    matches = [b for b in items if b.key == key.encode("ascii")]
    need(len(matches) == 1, f"Expected one {key} atom; found {len(matches)}")
    return matches[0]


def get(data, *path):
    for key in path:
        data = bykey(boxes(data), key).payload
    return data


def replace(data, path, new):
    head, *rest = path
    key = head.encode()
    seen = 0
    result = []
    for atom in boxes(data):
        if atom.key == key:
            seen += 1
            payload = replace(atom.payload, rest, new) if rest else new
            atom = Box(key, payload)
        result.append(atom.encode())
    need(seen == 1, f"Cannot replace unique atom: {head}")
    return b"".join(result)


def table(payload, fmt, offset=4):
    size = struct.calcsize(">" + fmt)
    count, = unpack("I", payload, offset)
    entries = payload[offset + 4:]
    need(len(entries) == count * size, f"Bad table {fmt}")
    return list(struct.iter_unpack(">" + fmt, entries))


def make_table(fmt, rows):
    return b"\0" * 4 + pack("I", len(rows)) + b"".join(pack(fmt, *r) for r in rows)


def run_lengths(values):
    rows = []
    for value in values:
        if rows and rows[-1][1] == value:
            rows[-1] = rows[-1][0] + 1, value
        else:
            rows.append((1, value))
    return rows


def clock(payload):
    need(payload[0] in (0, 1), "Unsupported header version")
    return unpack("IQ" if payload[0] else "II", payload, 20 if payload[0] else 12)


class Track:
    def __init__(self, atom, movie):
        self.atom, self.movie = atom, movie
        self.tkhd = get(atom, "tkhd")
        need(self.tkhd[0] in (0, 1), "Unsupported track header")
        self.v1 = bool(self.tkhd[0])
        self.id, = unpack("I", self.tkhd, 20 if self.v1 else 12)
        self.duration, = unpack("Q" if self.v1 else "I", self.tkhd, 28 if self.v1 else 20)
        self.matrix = unpack("9i", self.tkhd, 52 if self.v1 else 40)
        self.display_size = tuple(i / 65536 for i in unpack("II", self.tkhd, len(self.tkhd) - 8))
        self.handler = get(atom, "mdia", "hdlr")[8:12].decode("ascii")
        self.scale, self.media_duration = clock(get(atom, "mdia", "mdhd"))
        self.stbl = get(atom, *SP)
        self.edits = []
        if any(x.key == b"edts" for x in boxes(atom)):
            elst = get(atom, *LP)
            need(elst[0] in (0, 1), "Unsupported edit list")
            self.edits = table(elst, "QqI" if elst[0] else "IiI")
        stsd = get(self.stbl, "stsd")
        self.entries = list(boxes(stsd, 8))
        need(len(self.entries) == unpack("I", stsd, 4)[0], "Bad stsd count")
        self.stts = table(get(self.stbl, "stts"), "II")
        self.sample_durations = [d for n, d in self.stts for _ in range(n)]
        stsz = get(self.stbl, "stsz")
        default, count = unpack("II", stsz, 4)
        self.sizes = ([default] * count if default else
                      [n for n, in table(stsz, "I", offset=8)])
        need(len(self.sizes) == len(self.sample_durations), "stts/stsz mismatch")
        offset_boxes = [x for x in boxes(self.stbl) if x.key in (b"stco", b"co64")]
        need(len(offset_boxes) == 1, "One stco or co64 expected")
        self.offset_type = offset_boxes[0].key.decode()
        self.offsets = [n for n, in table(offset_boxes[0].payload, "Q" if self.offset_type == "co64" else "I")]
        self.stsc = table(get(self.stbl, "stsc"), "III")
        self.timed_keys = {}
        if self.handler == "meta":
            for entry in self.entries:
                if entry.key != b"mebx":
                    continue
                k = bykey(boxes(entry.payload, 8), "keys")
                for key_box in boxes(k.payload):
                    key_index, = unpack("I", key_box.key)
                    fields = list(boxes(key_box.payload))
                    key = bykey(fields, "keyd").payload
                    dtype = bykey(fields, "dtyp").payload
                    self.timed_keys[key_index] = (key[4:].decode("ascii"), dtype, fields)

    def chunks(self):
        need(self.stsc and self.stsc[0][0] == 1, "Missing first chunk")
        current, sample_index = 0, 0
        for i, pos in enumerate(self.offsets, 1):
            if current + 1 < len(self.stsc) and i == self.stsc[current + 1][0]:
                current += 1
            _, n, desc = self.stsc[current]
            need(1 <= desc <= len(self.entries), "Invalid sample description index")
            sizes = self.sizes[sample_index:sample_index+n]
            need(len(sizes) == n, "Invalid chunk sample count")
            length = sum(sizes)
            need(any(a <= pos and pos + length <= b for a, b in self.movie.media_spans),
                 "Chunk lies outside mdat")
            yield pos, self.movie.data[pos:pos+length], sizes
            sample_index += n
        need(sample_index == len(self.sizes), "Incomplete chunk table")

    def samples(self):
        for _, chunk, sizes in self.chunks():
            pos = 0
            for size in sizes:
                yield chunk[pos:pos+size]
                pos += size

    def box_list(self):
        return [x.key.decode("latin-1") for x in boxes(self.stbl)]

    def start(self):
        total = 0
        for n, at, rate in self.edits:
            if at != -1:
                break
            total += n
        return total

    def details(self):
        out = dict(id=self.id, handler=self.handler, timescale=self.scale,
                   media_duration_ticks=self.media_duration, track_duration_movie_ticks=self.duration,
                   track_matrix=self.matrix, display_size=self.display_size,
                   edit_list=self.edits, samples=len(self.sizes), sample_bytes=sum(self.sizes),
                   sample_timing_runs=self.stts, sample_to_chunk=self.stsc, chunk_offsets=self.offsets,
                   table_atoms=self.box_list(), sample_entries=[x.key.decode("latin-1") for x in self.entries])
        if "stss" in self.box_list():
            out["sync_samples"] = [n for n, in table(get(self.stbl, "stss"), "I")]
        if "ctts" in self.box_list():
            raw = get(self.stbl, "ctts")
            rows = table(raw, "Ii")
            out["composition_offsets"] = dict(version=raw[0], run_count=len(rows),
                                               offsets_ticks=sorted({offset for _, offset in rows}))
        if self.handler == "vide":
            entry, = self.entries
            out["encoded_dimensions"] = unpack("HH", entry.payload, 24)
            out["sample_description_extensions"] = {}
            for ext in boxes(entry.payload, 78, zero_terminator=True):
                out["sample_description_extensions"][ext.key.decode("latin-1")] = ext.payload.hex()
                if ext.key == b"hvcC":
                    out["codec_profile"] = f"HEVC profile {ext.payload[1] & 31}, level {ext.payload[12] / 30:g}, {8+(ext.payload[17]&7)} bit"
                elif ext.key == b"avcC":
                    out["codec_profile"] = f"AVC profile {ext.payload[1]}, level {ext.payload[3] / 10:g}"
        if self.handler == "meta":
            out["timed_keys"] = {}
            for idx, (key, dtype, fields) in self.timed_keys.items():
                entry = {"key": key, "type_hex": dtype.hex(),
                         "properties": [x.key.decode("ascii") for x in fields]}
                for setup in (x for x in fields if x.key == b"setu"):
                    for field in boxes(setup.payload):
                        if field.key == b"dims":
                            entry["setup_dimensions"] = unpack("II", field.payload)
                        if field.key == b"cfgv" and field.payload.startswith(b"bplist00"):
                            entry["setup_versions"] = plistlib.loads(field.payload)
                out["timed_keys"][idx] = entry
            samples = list(self.samples())
            out["payload_sha256"] = hashlib.sha256(b"".join(samples)).hexdigest()
            out["first_sample_hex"] = samples[0].hex()
            out["different_samples"] = len(set(samples))
            for value in boxes(samples[0]):
                idx, = unpack("I", value.key)
                key = self.timed_keys[idx][0]
                if key == STILL:
                    out["still_marker_int8"], = unpack("b", value.payload)
                    out["still_time_seconds"] = self.start() / self.movie.scale
                elif key == MATRIX:
                    out["still_projective_matrix"] = unpack("9d", value.payload)
                elif key == DIMS:
                    out["still_transform_reference_dimensions"] = unpack("2f", value.payload)
                elif key == ORIENT:
                    out["timed_orientation_int16"], = unpack("h", value.payload)
        return out


class Movie:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        self.root = list(boxes(self.data))
        self.moov = get(self.data, "moov")
        self.mvhd = get(self.moov, "mvhd")
        self.scale, self.duration = clock(self.mvhd)
        self.media_spans = [(x.pos + x.header, x.pos + x.header + len(x.payload))
                            for x in self.root if x.key == b"mdat"]
        self.tracks = [Track(x.payload, self) for x in boxes(self.moov) if x.key == b"trak"]

    def video(self):
        tracks = [t for t in self.tracks if t.handler == "vide"]
        need(len(tracks) == 1, "Exactly one video track is required")
        return tracks[0]

    def globals(self):
        ms = [x for x in boxes(self.moov) if x.key == b"meta"]
        if not ms:
            return {}
        m = ms[0].payload
        k = get(m, "keys")
        names = {i: x.payload.decode("utf-8") for i, x in enumerate(boxes(k, 8), 1)}
        out = {}
        for item in boxes(get(m, "ilst")):
            idx, = unpack("I", item.key)
            value = get(item.payload, "data")
            dtype, _locale = unpack("II", value)
            body = value[8:]
            out[names[idx]] = {
                "type": dtype,
                "value": {1: lambda: body.decode(), 21: lambda: int.from_bytes(body, "big", signed=True),
                          22: lambda: int.from_bytes(body, "big"), 23: lambda: unpack("f", body)[0]}.get(dtype, body.hex)()
            }
        return out

    def details(self):
        details = [t.details() for t in self.tracks]
        spans = sorted((p, p + len(c)) for t in self.tracks for p, c, _ in t.chunks())
        merged = []
        for a, b in spans:
            if merged and a <= merged[-1][1]:
                merged[-1] = merged[-1][0], max(merged[-1][1], b)
            else:
                merged.append((a, b))
        return dict(file=self.path.name, top_atoms=[(x.key.decode("ascii"), x.pos, len(x.payload)+x.header)
                                                    for x in self.root],
                    movie_timescale=self.scale, movie_duration_ticks=self.duration,
                    movie_duration_seconds=self.duration / self.scale,
                    movie_metadata=self.globals(), tracks=details,
                    mdat_bytes_not_referenced=sum(b-a for a,b in self.media_spans) -
                                              sum(b-a for a,b in merged))


def track_header(track, ident, duration):
    a = 20 if track.v1 else 12
    b = 28 if track.v1 else 20
    raw = splice(track.tkhd, a, pack("I", ident))
    return splice(raw, b, pack("Q" if track.v1 else "I", duration))


def media_duration(track, atom, duration):
    mdhd = get(track.atom, "mdia", "mdhd")
    mdhd = splice(mdhd, 24 if mdhd[0] else 16, pack("Q" if mdhd[0] else "I", duration))
    return replace(atom, ("mdia", "mdhd"), mdhd)


def assign_edits(atom, rows):
    base = get(atom, *LP)
    elst = make_table("QqI" if base[0] else "IiI", rows)
    return replace(atom, LP, base[:4] + elst[4:])


def movie_metadata(ident):
    def atom(k, p):
        return Box(k, p).encode()
    return (atom(b"hdlr", b"\0" * 8 + b"mdta" + b"\0" * 14) +
            atom(b"keys", b"\0" * 4 + pack("I", 1) + atom(b"mdta", CID.encode())) +
            atom(b"ilst", atom(pack("I", 1), atom(b"data", pack("II", 1, 0) + ident.encode()))))


def identifier(movie):
    return movie.globals().get(CID, {}).get("value")


def verify_sample_count(track):
    need(sum(track.sample_durations) == track.media_duration, f"Inconsistent media duration: track {track.id}")
    need(sum(row[0] for row in track.edits) == track.duration, f"Inconsistent edit list: track {track.id}")


def transplant(reference, video_source, key_ticks, out, ident, raw_transform=False):
    video = video_source.video()
    need(video_source.scale == reference.scale, "Movie timescales must match; normalize the source first")
    need(video.matrix == IDENTITY, "Normalize rotation/reflection into the video pixels first")
    need(len(video.entries) == 1, "Multiple video sample descriptions are not supported")
    dims = unpack("HH", video.entries[0].payload, 24)
    need(0 < dims[0] < dims[1], "An upright portrait video is required")
    ref_video = reference.video()
    need(ref_video.matrix == IDENTITY, "Donor must have a portrait video with identity track matrix")
    need(0 <= key_ticks < video.duration, "The key must fall within the video")
    ctts = [0] * len(video.sizes)
    if "ctts" in video.box_list():
        ctts = [delta for count, delta in table(get(video.stbl, "ctts"), "Ii") for _ in range(count)]
    need(len(ctts) == len(video.sizes), "Invalid composition offset count")
    need(len(video.edits) == 1 and video.edits[0][2] == 65536,
         "Video must have a single rate-1 edit")
    elapsed = 0
    presentation_times = set()
    for dur, offset in zip(video.sample_durations, ctts):
        presentation_times.add(elapsed + offset - video.edits[0][1])
        elapsed += dur
    need(Fraction(key_ticks * video.scale, video_source.scale) in presentation_times,
         "The key must be aligned to a presentation frame")
    if raw_transform:
        need(dims == unpack("HH", ref_video.entries[0].payload, 24),
             "Unchanged donor transform requires the same stored video dimensions")
    verify_sample_count(video)

    donors = []
    for t in reference.tracks:
        if t.handler != "meta":
            continue
        keys = {entry[0] for entry in t.timed_keys.values()}
        need(keys in ({INFO}, {ORIENT}, {STILL, MATRIX, DIMS}),
             f"Unsupported donor metadata track: {keys}")
        need(not any(x.key == b"tref" for x in boxes(t.atom)),
             "Donor track references are unsupported by this tool")
        verify_sample_count(t)
        donors.append((t, keys))
    need(len(donors) == 3 and {frozenset(k) for _, k in donors} ==
         {frozenset(k) for k in ({INFO}, {ORIENT}, {STILL, MATRIX, DIMS})},
         "Donor must have one motion track, one orientation track and one three-field still track")

    prefix = bykey(video_source.root, "ftyp").encode() + Box(b"wide", b"").encode()
    mdat = bytearray()
    out_tracks = []

    def place(track, atom, chunks):
        offsets = []
        for c in chunks:
            offsets.append((len(prefix) + 8 + len(mdat),))
            mdat.extend(c)
        atom = replace(atom, (*SP, track.offset_type),
                       make_table("Q" if track.offset_type == "co64" else "I", offsets))
        out_tracks.append(Box(b"trak", atom).encode())

    need(not any(x.key == b"tref" for x in boxes(video.atom)), "Video track references not supported")
    place(video, replace(video.atom, ("tkhd",), track_header(video, 1, video.duration)),
          (c for _, c, _ in video.chunks()))
    for tid, (t, keys) in enumerate(donors, 2):
        data = t.atom
        if STILL in keys:
            need(len(t.sizes) == len(t.offsets) == 1 and t.start() > 0 and
                 len(t.edits) == 2 and t.edits[1][1:] == (0, 65536),
                 "Unsupported donor still sample or edits")
            sample = next(t.samples())
            if not raw_transform:
                corrected = []
                for field in boxes(sample):
                    idx, = unpack("I", field.key)
                    name = t.timed_keys[idx][0]
                    if name == MATRIX:
                        field = Box(field.key, pack("9d", 1, 0, 0, 0, 1, 0, 0, 0, 1))
                    elif name == DIMS:
                        field = Box(field.key, pack("2f", *dims))
                    corrected.append(field.encode())
                corrected_sample = b"".join(corrected)
                need(len(corrected_sample) == len(sample), "Unexpected still sample length")
                sample = corrected_sample
            final_duration = min(t.edits[1][0], video.duration - key_ticks)
            data = assign_edits(data, ([(key_ticks, -1, 65536)] if key_ticks else []) +
                                [(final_duration, 0, 65536)])
            duration = key_ticks + final_duration
            chunks = [sample]
        else:
            need(t.edits == [(reference.duration, 0, 65536)] and t.duration == reference.duration,
                 "Donor motion and orientation tracks must span the donor clip")
            duration = video.duration
            if duration != t.duration:
                # Quantize cumulative times, not individual deltas, so rounding cannot drift.
                ends = [0]
                source_end = 0
                for d in t.sample_durations:
                    source_end += d
                    ends.append(round(Fraction(source_end * duration, t.duration)))
                ds = [b-a for a,b in zip(ends, ends[1:])]
                need(min(ds) > 0, "Duration too short for donor sample cadence")
                data = replace(data, (*SP, "stts"), make_table("II", run_lengths(ds)))
                data = media_duration(t, data, ends[-1])
                data = assign_edits(data, [(duration, 0, 65536)])
            chunks = [c for _, c, _ in t.chunks()]
        data = replace(data, ("tkhd",), track_header(t, tid, duration))
        place(t, data, chunks)

    need(video_source.duration == video.duration, "Movie duration must match its video")
    mvhd = splice(video_source.mvhd, len(video_source.mvhd)-4, pack("I", len(out_tracks)+1))
    moov = (Box(b"mvhd", mvhd).encode() + b"".join(out_tracks) +
            Box(b"meta", movie_metadata(ident)).encode())
    with out.open("xb") as f:
        f.write(prefix + Box(b"mdat", mdat).encode() + Box(b"moov", moov).encode())
    checked = Movie(out)
    need(identifier(checked) == ident, "Output has wrong content identifier")
    need(checked.video().details()["encoded_dimensions"] == dims, "Video dimensions changed during mux")
    for a,b in zip(checked.video().chunks(), video.chunks(), strict=True):
        need(a[1:] == b[1:], "Video bytes changed during mux")
    for new, (old, keys) in zip(checked.tracks[1:], donors, strict=True):
        verify_sample_count(new)
        need(get(new.stbl, "stsd") == get(old.stbl, "stsd"), "Metadata descriptor changed")
        if STILL in keys:
            need(new.start() == key_ticks, "Output key timing differs")
        else:
            need(list(old.samples()) == list(new.samples()), "Motion/orientation payload changed")
    need(checked.details()["mdat_bytes_not_referenced"] == 0, "Unexpected unreferenced media")


def execute(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def compile_helper(tmp):
    binary = tmp / "medien"
    execute(["xcrun", "swiftc", "-O", "-parse-as-library", "-suppress-warnings",
             "-module-cache-path", tmp / "module-cache", Path(__file__).with_name("Medien.swift"), "-o", binary])
    return binary


def normalize(ffmpeg, source_path, normal, dims, fps, duration, source_key, target_key,
              motion_window=None):
    # Match the donor duration/raster. Keep the original frame order up to the
    # supplied still point, then hold that frame. No generated frames or audio.
    need(target_key > 0 and (target_key * fps).denominator == 1, "Donor key must land on a video frame")
    need((duration * fps).denominator == 1, "Donor duration must align to the frame grid")
    w, h = dims
    action = target_key if motion_window is None else motion_window
    need(0 < action <= target_key and (action * fps).denominator == 1,
         "Motion window must fit before the key and align to the video frame grid")
    lead = int((target_key - action) * fps)
    rate = action / source_key
    # Apply leading padding after CFR sampling, so it uses exact output frame
    # units. The key retains the donor's timestamp regardless of the window.
    lead_filter = f"tpad=start_mode=clone:start={lead}," if lead else ""
    vf = (f"settb=AVTB,trim=end={float(source_key)+0.0001:.6f},"
          f"setpts=(PTS-STARTPTS)*{rate.numerator}/{rate.denominator},"
          f"tpad=stop_mode=clone:stop_duration={float(duration):.6f},"
          f"fps=fps={fps}:start_time=0:round=near,"
          f"{lead_filter}"
          f"scale={w}:{h}:flags=lanczos,setsar=1,format=yuv420p")
    execute([ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-n",
             "-threads", 2, "-noautorotate", "-i", source_path, "-map", "0:v:0", "-an",
             "-map_metadata", "-1", "-filter_threads", 2, "-vf", vf, "-frames:v", int(duration * fps),
             "-c:v", "libx265", "-preset", "medium", "-crf", "16", "-profile:v", "main",
             "-x265-params", "pools=2:frame-threads=2:log-level=error:level-idc=5.1",
             "-color_range", "tv", "-color_primaries", "bt709", "-color_trc", "bt709",
             "-colorspace", "bt709", "-tag:v", "hvc1", "-use_editlist", "1",
             "-movie_timescale", 600, "-video_track_timescale", 600,
             "-movflags", "+negative_cts_offsets", normal], timeout=240)

def build(args):
    out = Path(args.output)
    photo, movie = out.with_suffix(".heic"), out.with_suffix(".mov")
    need(out.parent.is_dir(), "Create the output directory first")
    need(not (photo.exists() or movie.exists() or photo.is_symlink() or movie.is_symlink()),
         "Output already exists; use a fresh basename")
    need(args.motion_window is None or args.mode == "reference",
         "--motion-window requires reference mode")
    ref, source = Movie(args.reference), Movie(args.video)
    reference_key, = [t for t in ref.tracks if STILL in {x[0] for x in t.timed_keys.values()}]
    source_video = source.video()
    source_key = None
    for t in source.tracks:
        if STILL in {x[0] for x in t.timed_keys.values()}:
            source_key = Fraction(t.start(), source.scale)
    if args.key_seconds is not None:
        source_key = Fraction(args.key_seconds)
    if source_key is None:
        # Last frame of a constant-frame-rate input.
        need(len(source_video.stts) == 1, "Supply --key-seconds for variable-frame-rate input")
        source_key = Fraction(source_video.duration, source.scale) - Fraction(source_video.stts[0][1], source_video.scale)
    need(0 < source_key < Fraction(source_video.duration, source.scale), "Key must be inside input video")
    ident = str(uuid.uuid4()).upper()
    with tempfile.TemporaryDirectory(prefix="livewallpaper-") as work:
        work = Path(work)
        medien = Path(args.helper).resolve() if args.helper else compile_helper(work)
        if args.mode == "reference":
            need(ref.scale == 600 and ref.video().scale == 600 and len(ref.video().stts) == 1,
                 "Reference mode requires a constant-frame-rate 600 Hz template")
            w,h = unpack("HH", ref.video().entries[0].payload, 24)
            fps = Fraction(600, ref.video().stts[0][1])
            need(fps.denominator == 1, "Reference fps must divide 600")
            normal = work / "normalized.mov"
            need(source_video.matrix == IDENTITY, "Normalize input rotation into the pixels first")
            need(len(source_video.entries) == 1, "A single source video sample description is required")
            source_entry = source_video.entries[0]
            colr = [x.payload for x in boxes(source_entry.payload, 78, zero_terminator=True)
                    if x.key == b"colr"]
            need(any(p[:10] in (b"nclc" + pack("HHH", 1, 1, 1), b"nclx" + pack("HHH", 1, 1, 1))
                     and (p[:4] == b"nclc" or p[10] == 0) for p in colr),
                 "Reference encoding expects an SDR BT.709 input tagged in the video description")
            normalize(args.ffmpeg, args.video, normal, (w, h), fps.numerator,
                      Fraction(ref.duration, ref.scale), source_key, Fraction(reference_key.start(), ref.scale),
                      Fraction(args.motion_window) if args.motion_window is not None else None)
            source = Movie(normal)
            need(source.video().duration == ref.duration, "Normalized duration differs from reference")
            key_ticks = reference_key.start()
        else:
            exact_key = source_key * source.scale
            need(exact_key.denominator == 1, "Key time is not representable in the movie timescale")
            key_ticks = int(exact_key)
        work_photo, work_movie = work / "pair.heic", work / "pair.mov"
        execute([medien, "cover", args.image, work_photo, ident], timeout=60)
        transplant(ref, source, key_ticks, work_movie, ident, args.keep_reference_transform)
        if args.check_live:
            execute([medien, "check-live", work_photo, work_movie], timeout=30)
        # O_EXCL semantics; never overwrite an existing file.
        created = []
        try:
            for src, dst in [(work_photo, photo), (work_movie, movie)]:
                with dst.open("xb") as f:
                    created.append(dst)
                    f.write(src.read_bytes())
        except BaseException:
            for path in created:
                path.unlink()
            raise
    print(f"{photo}\n{movie}\nUUID {ident}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    inspect = sub.add_parser("inspect", help="show QuickTime atoms and metadata as JSON")
    inspect.add_argument("movies", nargs="+")
    make = sub.add_parser("build", help="generate a fresh HEIC/MOV pair")
    make.add_argument("--reference", required=True, help="known working donor MOV")
    make.add_argument("--video", required=True, help="new video source")
    make.add_argument("--image", required=True, help="new still (visually matches key frame)")
    make.add_argument("--output", required=True, help="fresh output basename without extension")
    make.add_argument("--mode", choices=("reference", "preserve-video"), default="reference")
    make.add_argument("--key-seconds", help="source key in seconds (decimal or fraction)")
    make.add_argument("--motion-window",
                      help="fit the action into these seconds just before the donor key, e.g. 0.3")
    make.add_argument("--keep-reference-transform", action="store_true",
                      help="retain the donor still transform bytes (diagnostic mode)")
    make.add_argument("--check-live", action="store_true", help="test PHLivePhoto without importing")
    make.add_argument("--helper", help="prebuilt Medien.swift executable")
    make.add_argument("--ffmpeg", default="ffmpeg", help="FFmpeg with libx265 (reference mode)")
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            print(json.dumps([Movie(path).details() for path in args.movies], indent=2))
        else:
            build(args)
    except (ValueError, OSError, struct.error, subprocess.SubprocessError) as e:
        parser.exit(1, f"Fehler: {e}\n")


if __name__ == "__main__":
    main()
