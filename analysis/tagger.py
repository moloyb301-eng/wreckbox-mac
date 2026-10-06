#!/usr/bin/env python3
"""Write WreckBox's track data into the audio files themselves, so Rekordbox (and anything else) sees it.

    tagger.py < jobs.json      → prints one JSON result per job

Each job: {"path", "title", "artists": [..], "album", "year", "genre", "bpm", "key", "camelot",
           "isrc", "cover"}   (cover = local image path or http(s) URL; any field may be null)

Writes title / artist / album / year / genre / BPM / initial key / ISRC / front cover for MP3, AIFF and
WAV (ID3v2.3, the version Rekordbox reads best), FLAC (Vorbis comments + picture) and M4A/ALAC (MP4 atoms).
Existing tags that WreckBox doesn't manage (label, MusicBrainz ids, …) are kept.
The file is tagged as a copy and swapped in atomically, so a crash can't leave a half-written track.
"""
import json
import os
import shutil
import sys
import tempfile
import urllib.request

import mutagen
from mutagen.aiff import AIFF
from mutagen.flac import FLAC, Picture
from mutagen.id3 import APIC, COMM, ID3, TBPM, TCON, TDRC, TIT2, TKEY, TPE1, TPE2, TALB, TSRC, ID3NoHeaderError
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4, MP4Cover, MP4FreeForm
from mutagen.wave import WAVE


def cover_bytes(src):
    if not src:
        return None
    try:
        if src.startswith("http"):
            # Spotify serves 640 px covers at the same id with a different size prefix.
            src = src.replace("ab67616d00001e02", "ab67616d0000b273")
            with urllib.request.urlopen(src, timeout=15) as r:
                return r.read()
        with open(src, "rb") as f:
            return f.read()
    except Exception:
        return None


def mime(data):
    return "image/png" if data[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"


def key_name(job):
    """'A minor' → 'Am', 'F# major' → 'F#' (the short form Rekordbox and ID3 TKEY use)."""
    k = (job.get("key") or "").strip()
    if not k:
        return None
    parts = k.split()
    return parts[0] + ("m" if len(parts) > 1 and parts[1].lower().startswith("min") else "")


def bpm_text(job):
    b = job.get("bpm")
    return str(int(round(b))) if b else None


def tag_id3(tags, job, cover):
    def put(frame_cls, value, **kw):
        if value:
            tags.setall(frame_cls.__name__, [frame_cls(encoding=3, text=value, **kw)])
    artists = job.get("artists") or []
    put(TIT2, job.get("title"))
    put(TPE1, " / ".join(artists) if artists else None)   # ID3v2.3 has no multi-value; "/" is the convention
    put(TPE2, artists[0] if artists else None)
    put(TALB, job.get("album"))
    put(TDRC, job.get("year"))
    put(TCON, job.get("genre"))
    put(TBPM, bpm_text(job))
    put(TKEY, key_name(job))
    put(TSRC, job.get("isrc"))
    if job.get("comment"):   # "Energy 7" — Rekordbox's Comments column
        tags.delall("COMM")
        tags.add(COMM(encoding=3, lang="eng", desc="", text=job["comment"]))
    if cover:
        tags.delall("APIC")
        tags.add(APIC(encoding=3, mime=mime(cover), type=3, desc="Cover", data=cover))


def tag_vorbis(f, job, cover):
    def put(k, v):
        if v:
            f[k] = v if isinstance(v, list) else [v]
    put("title", job.get("title"))
    put("artist", job.get("artists") or None)
    put("albumartist", (job.get("artists") or [None])[0])
    put("album", job.get("album"))
    put("date", job.get("year"))
    put("genre", job.get("genre"))
    put("bpm", bpm_text(job))
    put("initialkey", key_name(job))
    put("isrc", job.get("isrc"))
    put("comment", job.get("comment"))
    if cover:
        f.clear_pictures()
        p = Picture()
        p.type, p.mime, p.desc, p.data = 3, mime(cover), "Cover", cover
        f.add_picture(p)


def tag_mp4(f, job, cover):
    t = f.tags if f.tags is not None else f.add_tags() or f.tags
    def put(k, v):
        if v:
            t[k] = v if isinstance(v, list) else [v]
    put("\xa9nam", job.get("title"))
    put("\xa9ART", ", ".join(job.get("artists") or []) or None)
    put("aART", (job.get("artists") or [None])[0])
    put("\xa9alb", job.get("album"))
    put("\xa9day", job.get("year"))
    put("\xa9gen", job.get("genre"))
    if bpm_text(job):
        t["tmpo"] = [int(bpm_text(job))]
    if key_name(job):
        t["----:com.apple.iTunes:initialkey"] = [MP4FreeForm(key_name(job).encode())]
    if job.get("isrc"):
        t["----:com.apple.iTunes:ISRC"] = [MP4FreeForm(job["isrc"].encode())]
    put("\xa9cmt", job.get("comment"))
    if cover:
        fmt = MP4Cover.FORMAT_PNG if mime(cover) == "image/png" else MP4Cover.FORMAT_JPEG
        t["covr"] = [MP4Cover(cover, imageformat=fmt)]


def tag_file(path, job, cover):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".mp3":
        try:
            tags = ID3(path)
        except ID3NoHeaderError:
            tags = ID3()
        tag_id3(tags, job, cover)
        tags.save(path, v2_version=3)
    elif ext in (".aif", ".aiff"):
        f = AIFF(path)
        if f.tags is None:
            f.add_tags()
        tag_id3(f.tags, job, cover)
        f.save(v2_version=3)
    elif ext == ".wav":
        f = WAVE(path)
        if f.tags is None:
            f.add_tags()
        tag_id3(f.tags, job, cover)
        f.save(v2_version=3)
    elif ext == ".flac":
        f = FLAC(path)
        tag_vorbis(f, job, cover)
        f.save()
    elif ext in (".m4a", ".mp4", ".aac", ".alac"):
        f = MP4(path)
        tag_mp4(f, job, cover)
        f.save()
    else:
        raise ValueError(f"unsupported format {ext}")


def run(job):
    path = job["path"]
    if not os.path.isfile(path):
        return {"path": path, "ok": False, "error": "file not found"}
    cover = cover_bytes(job.get("cover"))
    # Tag a copy next to the original, then swap it in (same folder → atomic rename).
    fd, tmp = tempfile.mkstemp(prefix=".wreckbox-", suffix=os.path.splitext(path)[1], dir=os.path.dirname(path))
    os.close(fd)
    try:
        shutil.copy2(path, tmp)
        tag_file(tmp, job, cover)
        if mutagen.File(tmp) is None:
            raise ValueError("file unreadable after tagging")
        os.replace(tmp, path)
        return {"path": path, "ok": True, "cover": cover is not None}
    except Exception as e:
        if os.path.exists(tmp):
            os.unlink(tmp)
        return {"path": path, "ok": False, "error": str(e)}


if __name__ == "__main__":
    jobs = json.load(sys.stdin)
    for job in jobs:
        print(json.dumps(run(job)), flush=True)
