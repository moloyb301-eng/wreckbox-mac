#!/usr/bin/env python3
"""yt-fill — get the tracks Soulseek can't find from YouTube Music, in the best quality your account allows.

For every library track that slsk-sync tried and couldn't get, it searches YouTube Music for the official
upload (artist's "song" entry, matching title, artist and length), downloads it with your YouTube Premium
login (taken from your browser) and hands it to the app through _inbox/, like slsk-sync does. The app then
files, analyses and tags it.

Only official audio ("song" entries), never music videos. Quality: Premium gets Opus ~300 kbps (format 774), kept as
.opus (never converted); otherwise AAC 256 kbps (141, .m4a) or the standard Opus ~160 / AAC 128 streams.

    yt-fill run                  # keep filling: process due tracks, sleep, repeat (wakes on requests)
    yt-fill once [--limit N]     # one pass, then exit
    yt-fill search "Artist - Title"
    yt-fill get <track id>       # this track now
    yt-fill status
"""
from __future__ import annotations

import argparse
import datetime as dt
import difflib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

from ytmusicapi import YTMusic
import yt_dlp

HERE = Path(__file__).resolve().parent
LIBRARY_ROOT = Path(os.environ.get("WRECKBOX_ROOT") or (Path.home() / "Music" / "DJ Library"))
WORK_DIR = LIBRARY_ROOT / "_youtube"
INBOX = LIBRARY_ROOT / "_inbox"
RECORDS_FILE = WORK_DIR / "yt.json"          # per track: status, videoId, format, kbps, when
REQUESTS_FILE = WORK_DIR / "requests.json"   # written by the app: {"<track id>": "<iso time>"} = get these now
CONFIG_FILE = WORK_DIR / "config.json"
LOG_FILE = WORK_DIR / "yt.log"
SLSK_SYNC = LIBRARY_ROOT / "_soulseek" / "sync.json"
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"

DEFAULTS = {
    "browser": "chrome",            # where you're signed in to YouTube (Premium): chrome, safari, firefox, brave, edge
    "interval_minutes": 30,
    "gap_seconds": 8,               # pause between downloads, so YouTube doesn't think it's a bot
    "retry_after_days": 7,
    "max_attempts": 3,
    "duration_tolerance_seconds": 4,
    "formats": "774/141/251/140/bestaudio",   # Premium Opus ~300k, AAC 256k, then the standard Opus 160k / AAC 128k
    "allow_videos": False,          # music videos often have intros / skits / other edits: official audio only
    "require_login": True,          # without your Premium login, wait instead of downloading at ~150 kbps
}

VARIANT_WORDS = {"remix", "rmx", "live", "acapella", "acappella", "instrumental", "karaoke", "cover", "slowed",
                 "reverb", "sped", "nightcore", "8d", "lofi", "lo-fi", "mashup", "bootleg", "unplugged", "reprise",
                 "extended", "vip", "edit"}

log = logging.getLogger("yt-fill")


# ── files ─────────────────────────────────────────────────────────────────────

def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save_json(path: Path, data) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
    tmp.replace(path)


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def days_since(iso: str | None) -> float:
    if not iso:
        return 1e9
    then = dt.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    return (dt.datetime.now(dt.timezone.utc) - then).total_seconds() / 86400


def config() -> dict:
    cfg = dict(DEFAULTS)
    cfg.update(load_json(CONFIG_FILE, {}))
    return cfg


# ── which tracks ──────────────────────────────────────────────────────────────

def due_tracks(cfg: dict, records: dict) -> list[dict]:
    """Requested tracks first, then tracks Soulseek tried and couldn't get, newest additions first."""
    library = load_json(LIBRARY_ROOT / "library.json", {"tracks": []})
    state = load_json(LIBRARY_ROOT / "state.json", {}).get("tracks", {})
    slsk = load_json(SLSK_SYNC, {})
    requests = load_json(REQUESTS_FILE, {})
    inbox = {p.stem for p in INBOX.glob("*") if p.is_file()} if INBOX.exists() else set()
    requested, rest = [], []
    for t in library["tracks"]:
        rec = records.get(t["id"], {})
        st = state.get(t["id"], {})
        if t["fileName"] in inbox:
            continue
        # Upgrade: something it got in standard quality (no Premium login at the time) — fetch again, once.
        if (st.get("status") == "downloaded" and st.get("source") == "youtube" and rec.get("status") == "done"
                and (rec.get("kbps") or 0) < 200 and not rec.get("upgrade_tried") and cfg.get("require_login")):
            requested.append(t)
            continue
        if st.get("status") in ("downloaded", "ignored"):
            continue
        if t["id"] in requests and requests[t["id"]] > (rec.get("last_try") or ""):
            requested.append(t)
            continue
        if slsk.get(t["id"], {}).get("status") not in ("not_found", "failed"):
            continue   # Soulseek first: it usually has lossless
        if rec.get("status") == "done":
            continue
        if rec and (rec.get("attempts", 0) >= cfg["max_attempts"] or days_since(rec.get("last_try")) < cfg["retry_after_days"]):
            continue
        rest.append(t)
    rest.sort(key=lambda t: t.get("firstAdded") or "", reverse=True)
    return requested + rest


# ── matching ──────────────────────────────────────────────────────────────────

def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    s = s.replace("&", " and ")
    return " ".join(re.findall(r"[a-z0-9]+", s))


def clean_title(title: str) -> str:
    """Drop feat. / 'From "Film"' / remaster noise; keep remix and version names."""
    t = re.sub(r"[\(\[]\s*(feat|ft|with)\.?\s[^\)\]]*[\)\]]", "", title, flags=re.I)
    t = re.sub(r"[\(\[]\s*from\s[^\)\]]*[\)\]]", "", t, flags=re.I)          # (From "Aashiqui 2")
    t = re.sub(r"\s(feat|ft)\.?\s.*$", "", t, flags=re.I)
    t = re.sub(r"\s-\s.*(remaster|from\s|original mix|radio edit).*$", "", t, flags=re.I)
    return t.strip()


def words(s: str) -> set[str]:
    return set(norm(s).split())


def score(track: dict, r: dict, tol: int) -> float | None:
    """0..1 how well a YouTube Music result matches the track, or None if it's not the same recording."""
    want_title, got_title = norm(clean_title(track["title"])), norm(clean_title(r.get("title") or ""))
    if not got_title:
        return None
    # A remix / slowed / live version only matches if the Spotify title asks for it too.
    extra = (words(r.get("title") or "") & VARIANT_WORDS) - words(track["title"])
    if extra:
        return None
    t = difflib.SequenceMatcher(None, want_title, got_title).ratio()
    if want_title and (want_title in got_title or got_title in want_title):
        t = max(t, 0.9)
    if t < 0.72:
        return None
    ours = [norm(a) for a in track["artists"]]
    theirs = [norm(a.get("name") or "") for a in (r.get("artists") or [])]
    if not any(o and th and (o in th or th in o) for o in ours for th in theirs):
        return None
    d = r.get("duration_seconds")
    if track.get("durationMs") and d:
        diff = abs(d - track["durationMs"] / 1000)
        if diff > tol:
            return None
        dur = 1 - diff / (tol + 1)
    else:
        dur = 0.5
    return 0.6 * t + 0.25 * dur + (0.15 if r.get("resultType") == "song" else 0)


def manual_match(track: dict, r: dict) -> float:
    """For the manual panel: fan uploads name the uploader, not the artist, so this rates the title words and
    length, with the artist as a bonus. Slowed / remix / live versions the track isn't count against it."""
    s = score(track, r, 15)
    if s is not None:
        return round(s, 2)
    want, got = words(clean_title(track["title"])), words(r.get("title") or "")
    if not want:
        return 0.0
    t = len(want & got) / len(want)
    if (got & VARIANT_WORDS) - words(track["title"]):
        t *= 0.4
    artist = any(w in got | words(" ".join(a.get("name") or "" for a in r.get("artists") or [])) for a in track["artists"] for w in words(a))
    d, want_d = r.get("duration_seconds"), (track.get("durationMs") or 0) / 1000
    dur = max(0.0, 1 - abs(d - want_d) / 20) if d and want_d else 0.5
    return round(0.55 * t + 0.3 * dur + (0.15 if artist else 0), 2)


def find(yt: YTMusic, track: dict, cfg: dict) -> tuple[dict, float] | None:
    artist = track["artists"][0] if track["artists"] else ""
    title = clean_title(track["title"])
    best = None
    # Official "song" uploads = the artist's audio release (no video intros or edits), with full metadata.
    for kind in ("songs", "videos") if cfg.get("allow_videos") else ("songs",):
        try:
            results = yt.search(f"{artist} {title}", filter=kind, limit=10)
        except Exception as e:  # network hiccup / changed API: try the next kind
            log.info("  search failed (%s): %s", kind, e)
            continue
        for r in results:
            s = score(track, r, cfg["duration_tolerance_seconds"] if kind == "songs" else 3)
            if s is not None and (best is None or s > best[1]):
                best = (r, s)
        if best:
            return best
    return None


# ── downloading ───────────────────────────────────────────────────────────────

COOKIE_FILE = WORK_DIR / "cookies.txt"   # your YouTube login, copied from the browser once per pass (private to you)


class NoLogin(Exception):
    pass


def refresh_cookies(cfg: dict) -> None:
    """Reads the browser's YouTube login once (macOS asks for the browser's keychain item — "Always Allow"
    keeps it quiet) and saves just the YouTube / Google cookies for this pass's downloads."""
    if not cfg.get("browser"):
        return
    from yt_dlp.cookies import extract_cookies_from_browser
    import http.cookiejar
    jar = extract_cookies_from_browser(cfg["browser"])
    out = http.cookiejar.MozillaCookieJar(str(COOKIE_FILE))
    for c in jar:
        if c.domain.endswith(("youtube.com", "google.com")):
            out.set_cookie(c)
    if not any(c.name in ("SAPISID", "__Secure-3PSID", "LOGIN_INFO") for c in out):
        # Empty when macOS refused the keychain prompt, or you're signed out of YouTube in that browser.
        raise NoLogin(f"no YouTube login found in {cfg['browser']}")
    COOKIE_FILE.touch(mode=0o600, exist_ok=True)
    os.chmod(COOKIE_FILE, 0o600)
    out.save(ignore_discard=True, ignore_expires=True)

def download(video_id: str, dest_stem: str, cfg: dict) -> dict:
    """Downloads the best audio into _inbox/<dest_stem>.opus|.m4a, as YouTube sends it. Returns {format, kbps, codec, path}."""
    tmp = Path(tempfile.mkdtemp(prefix="yt-", dir=WORK_DIR))
    try:
        opts = {
            "format": cfg["formats"],
            "outtmpl": str(tmp / "%(id)s.%(ext)s"),
            "noplaylist": True,
            "quiet": True,
            "no_warnings": True,
            "noprogress": True,
        }
        if COOKIE_FILE.exists():
            opts["cookiefile"] = str(COOKIE_FILE)
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"https://music.youtube.com/watch?v={video_id}", download=True)
        got = next(p for p in tmp.iterdir() if p.is_file())
        codec = (info.get("acodec") or "").split(".")[0]
        kbps = round(info.get("abr") or 0)
        INBOX.mkdir(parents=True, exist_ok=True)
        if codec == "mp4a":
            out = tmp / f"{dest_stem}.m4a"
            # Re-wrap only (no re-encode) so the file is a clean .m4a.
            subprocess.run([FFMPEG, "-v", "error", "-y", "-i", str(got), "-vn", "-c:a", "copy", "-movflags", "+faststart", str(out)], check=True)
        else:
            # Opus stays Opus (the user's rule: never convert to FLAC): re-wrapped from WebM into .opus, not re-encoded.
            out = tmp / f"{dest_stem}.opus"
            subprocess.run([FFMPEG, "-v", "error", "-y", "-i", str(got), "-vn", "-c:a", "copy", str(out)], check=True)
        final = INBOX / out.name
        shutil.move(str(out), final)   # the app only ever sees complete files
        return {"format": info.get("format_id"), "kbps": kbps, "codec": codec, "path": str(final)}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ── passes ────────────────────────────────────────────────────────────────────

def mark(records: dict, track: dict, status: str, **extra) -> None:
    rec = records.get(track["id"], {})
    rec.update({"status": status, "last_try": now_iso(), "attempts": rec.get("attempts", 0) + 1, **extra})
    records[track["id"]] = rec
    save_json(RECORDS_FILE, records)


def fill(track: dict, yt: YTMusic, cfg: dict, records: dict) -> bool:
    name = f"{', '.join(track['artists'])} - {track['title']}"
    hit = find(yt, track, cfg)
    if not hit:
        log.info("✗ not on YouTube Music: %s", name)
        mark(records, track, "not_found")
        return False
    r, s = hit
    if records.get(track["id"], {}).get("status") == "done":
        records[track["id"]]["upgrade_tried"] = True   # only one upgrade attempt per track
    try:
        got = download(r["videoId"], track["fileName"], cfg)
    except Exception as e:
        log.info("✗ download failed: %s — %s", name, str(e).splitlines()[0][:200])
        mark(records, track, "failed", videoId=r["videoId"], reason=str(e).splitlines()[0][:200])
        return False
    log.info("✓ %s  [%s %s kbps, %s, match %.2f]", name, got["codec"], got["kbps"], r.get("resultType"), s)
    mark(records, track, "done", videoId=r["videoId"], format=got["format"], kbps=got["kbps"], codec=got["codec"],
         ytTitle=r.get("title"), match=round(s, 2))
    return True


def run_pass(cfg: dict, limit: int | None) -> int:
    records = load_json(RECORDS_FILE, {})
    todo = due_tracks(cfg, records)[: limit or None]
    if not todo:
        log.info("Nothing to get from YouTube right now")
        return 0
    log.info("Pass: %d tracks to look for on YouTube Music", len(todo))
    try:
        refresh_cookies(cfg)
    except Exception as e:
        if cfg.get("require_login"):
            log.info("⏸ YouTube login not available (%s). Waiting — in the keychain prompt choose Always Allow, "
                     "and make sure you're signed in to YouTube in %s.", e, cfg.get("browser"))
            return 0
        log.info("Couldn't read your YouTube login (%s) — downloading in standard quality", e)
    yt = YTMusic()
    ok = 0
    for i, t in enumerate(todo):
        if i:
            time.sleep(cfg["gap_seconds"])
        ok += fill(t, yt, cfg, records)
    log.info("Pass finished: %d of %d downloaded", ok, len(todo))
    return ok


def in_inbox(stem: str) -> bool:
    return any(p.stem == stem for p in INBOX.glob("*") if p.is_file())


def decoded_copies(records: dict) -> list[dict]:
    """YouTube copies made before 2026-10-07, when Opus was decoded to FLAC: the user wants files as they came, so
    these are fetched again (same video) as .opus. The app swaps each one in for the FLAC."""
    library = load_json(LIBRARY_ROOT / "library.json", {"tracks": []})
    state = load_json(LIBRARY_ROOT / "state.json", {}).get("tracks", {})
    out = []
    for t in library["tracks"]:
        st, rec = state.get(t["id"], {}), records.get(t["id"], {})
        if (st.get("status") == "downloaded" and st.get("source") == "youtube" and (st.get("localPath") or "").endswith(".flac")
                and rec.get("videoId") and rec.get("codec") != "mp4a" and not in_inbox(t["fileName"])):
            out.append(t)
    return out


def native_pass(cfg: dict, limit: int = 30) -> int:
    records = load_json(RECORDS_FILE, {})
    todo = decoded_copies(records)[:limit]
    if not todo:
        return 0
    log.info("Original format: fetching %d YouTube tracks again as Opus (they were decoded to FLAC)", len(todo))
    ok = 0
    for i, t in enumerate(todo):
        if i:
            time.sleep(cfg["gap_seconds"])
        name = f"{', '.join(t['artists'])} - {t['title']}"
        try:
            got = download(records[t["id"]]["videoId"], t["fileName"], cfg)
        except Exception as e:
            log.info("✗ couldn't fetch %s again: %s", name, str(e).splitlines()[0][:200])
            continue
        records[t["id"]].update(format=got["format"], kbps=got["kbps"], codec=got["codec"], native=now_iso())
        save_json(RECORDS_FILE, records)
        log.info("✓ %s  [%s %s kbps, original format]", name, got["codec"], got["kbps"])
        ok += 1
    return ok


def sleep_until_requested(seconds: float) -> None:
    """Sleep between passes, but wake early when the app asks for a track."""
    def stamp():
        return REQUESTS_FILE.stat().st_mtime if REQUESTS_FILE.exists() else 0
    start, before = time.monotonic(), stamp()
    while time.monotonic() - start < seconds:
        time.sleep(5)
        if stamp() != before:
            log.info("New request from the app — starting a pass")
            return


# ── lock + main ───────────────────────────────────────────────────────────────

_lock_file = None


def acquire_lock() -> None:
    global _lock_file
    import fcntl
    _lock_file = open(WORK_DIR / "yt.lock", "a+")
    try:
        fcntl.flock(_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise SystemExit("yt-fill is already running — not starting a second copy.")
    (WORK_DIR / "yt.pid").write_text(str(os.getpid()))


def setup_logging() -> None:
    fmt = logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%d %H:%M:%S")
    for h in (logging.StreamHandler(sys.stdout), logging.FileHandler(LOG_FILE)):
        h.setFormatter(fmt)
        log.addHandler(h)
    log.setLevel(logging.INFO)


def main() -> None:
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    ap = argparse.ArgumentParser(prog="yt-fill", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run")
    once = sub.add_parser("once")
    once.add_argument("--limit", type=int)
    s = sub.add_parser("search")
    s.add_argument("query")
    g = sub.add_parser("get")
    g.add_argument("id")
    sub.add_parser("status")
    sj = sub.add_parser("search-json")   # the app's "Find manually" panel
    sj.add_argument("query")
    sj.add_argument("--track")
    gr = sub.add_parser("grab")          # download this video / link for this track
    gr.add_argument("track")
    gr.add_argument("link")
    a = ap.parse_args()
    setup_logging()
    cfg = config()

    if a.cmd == "search":
        artist, _, title = a.query.partition(" - ")
        track = {"artists": [artist] if title else [], "title": title or a.query, "durationMs": None}
        yt = YTMusic()
        for kind in ("songs", "videos"):
            for r in yt.search(a.query, filter=kind, limit=8):
                sc = score(track, r, 99)
                print(f"{kind[:-1]:5} {'%.2f' % sc if sc is not None else ' -  '}  {r.get('title')} — "
                      f"{', '.join(x['name'] for x in r.get('artists') or [])}  ({r.get('duration')})  {r.get('videoId')}")
        return
    if a.cmd == "search-json":
        library = load_json(LIBRARY_ROOT / "library.json", {"tracks": []})
        track = next((t for t in library["tracks"] if t["id"] == a.track), None) if a.track else None
        yt = YTMusic()
        out = []
        for kind in ("songs", "videos"):
            try:
                results = yt.search(a.query, filter=kind, limit=12)
            except Exception as e:
                print(json.dumps({"error": str(e)[:200]}))
                return
            for r in results:
                if not r.get("videoId"):
                    continue
                thumbs = r.get("thumbnails") or []
                out.append({
                    "videoId": r["videoId"], "title": r.get("title") or "", "type": kind[:-1],
                    "artists": ", ".join(x.get("name") or "" for x in r.get("artists") or []),
                    "album": (r.get("album") or {}).get("name"), "duration": r.get("duration"),
                    "seconds": r.get("duration_seconds"), "thumbnail": thumbs[-1]["url"] if thumbs else None,
                    # How well it matches the track (title, artist, length), when the panel says which track.
                    "match": manual_match(track, r) if track else None,
                })
        print(json.dumps(out))
        return
    if a.cmd == "grab":
        library = load_json(LIBRARY_ROOT / "library.json", {"tracks": []})
        track = next((t for t in library["tracks"] if t["id"] == a.track), None)
        if not track:
            print(json.dumps({"ok": False, "error": f"no track {a.track}"}))
            return
        m = re.search(r"(?:v=|youtu\.be/|/shorts/|/embed/|^)([A-Za-z0-9_-]{11})(?:[&?#/]|$)", a.link.strip())
        if not m:
            print(json.dumps({"ok": False, "error": "That doesn't look like a YouTube link"}))
            return
        try:
            refresh_cookies(cfg)
        except Exception:
            pass   # standard quality without the login
        records = load_json(RECORDS_FILE, {})
        try:
            got = download(m.group(1), track["fileName"], cfg)
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e).splitlines()[0][:200]}))
            return
        mark(records, track, "done", videoId=m.group(1), format=got["format"], kbps=got["kbps"], codec=got["codec"], manual=True)
        log.info("✓ %s — %s  [%s %s kbps, picked by hand]", ", ".join(track["artists"]), track["title"], got["codec"], got["kbps"])
        print(json.dumps({"ok": True, "codec": got["codec"], "kbps": got["kbps"]}))
        return
    if a.cmd == "status":
        recs = load_json(RECORDS_FILE, {})
        counts: dict[str, int] = {}
        for r in recs.values():
            counts[r.get("status", "?")] = counts.get(r.get("status", "?"), 0) + 1
        print(json.dumps(counts))
        return
    if a.cmd == "get":
        library = load_json(LIBRARY_ROOT / "library.json", {"tracks": []})
        track = next((t for t in library["tracks"] if t["id"] == a.id), None)
        if not track:
            raise SystemExit(f"no track {a.id}")
        refresh_cookies(cfg)
        fill(track, YTMusic(), cfg, load_json(RECORDS_FILE, {}))
        return

    acquire_lock()
    if not Path(FFMPEG).exists():
        raise SystemExit("ffmpeg is missing (brew install ffmpeg)")
    while True:
        got = run_pass(cfg, getattr(a, "limit", None))
        if a.cmd == "run":
            got += native_pass(cfg)   # after new tracks: put back the original format of decoded copies
        if a.cmd == "once":
            break
        waiting = got == 0 and "⏸" in (LOG_FILE.read_text(errors="ignore").splitlines() or [""])[-1]
        minutes = 2 if waiting else cfg["interval_minutes"]
        log.info("Sleeping %d min", minutes)
        sleep_until_requested(minutes * 60)


if __name__ == "__main__":
    main()
