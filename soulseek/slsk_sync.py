#!/usr/bin/env python3
"""slsk-sync — fetch the DJ Library's missing tracks from Soulseek.

Reads ~/Music/DJ Library/library.json (built by `djlib library` from your Spotify
playlists) and state.json (what the DJ Library app already has), searches Soulseek
for every track that is still missing, picks the best-quality matching file and
downloads it. Finished files are renamed to the app's own "Artist - Title.ext"
naming and moved into _inbox/, where the DJ Library app matches them, files them
into Tracks/ and marks them downloaded. Partial downloads never touch _inbox/.

    slsk-sync run                 # keep syncing: process missing tracks, sleep, repeat
    slsk-sync once [--limit N]    # one pass, then exit
    slsk-sync search "query"      # show ranked candidates for a query (no download)
    slsk-sync status              # counts from the sync log
    slsk-sync retry               # clear failed/not-found marks so they're tried again
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import logging
import os
import re
import shutil
import sys
import time
import tomllib
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from aioslsk.client import SoulSeekClient
from aioslsk.exceptions import AioSlskException, AuthenticationError
from aioslsk.protocol.primitives import AttributeKey
from aioslsk.settings import CredentialsSettings, Settings, SharedDirectorySettingEntry
from aioslsk.transfer.state import TransferState

HERE = Path(__file__).resolve().parent
# The apps pass their own locations; the defaults match the original Mac setup.
LIBRARY_ROOT = Path(os.environ.get("WRECKBOX_ROOT") or (Path.home() / "Music" / "DJ Library"))
WORK_DIR = LIBRARY_ROOT / "_soulseek"
INCOMING = WORK_DIR / "incoming"          # aioslsk writes partial files here
INBOX = LIBRARY_ROOT / "_inbox"           # finished files are handed to the app here
SYNC_FILE = WORK_DIR / "sync.json"
OVERRIDES_FILE = WORK_DIR / "overrides.json"   # written by the DJ Library app: retry requests + custom queries
LOG_FILE = WORK_DIR / "sync.log"
CONFIG_FILE = Path(os.environ.get("WRECKBOX_SLSK_CONFIG") or (HERE / "config.toml"))

log = logging.getLogger("slsk-sync")

# ── Config ────────────────────────────────────────────────────────────────────

DEFAULTS = {
    "soulseek": {"username": "", "password": "", "listen_port": 60000, "share_dirs": []},
    "sync": {
        "interval_minutes": 30,      # pause between passes in `run` mode
        "max_concurrent": 3,         # tracks searched/downloaded in parallel
        "search_wait_seconds": 12,   # how long to collect search results
        "search_gap_seconds": 4,     # min gap between searches (server rate limits)
        "queue_timeout_minutes": 4,  # give up on a peer that hasn't started sending by then
        "stall_timeout_minutes": 3,  # give up on a transfer with no progress for this long
        "candidates_per_track": 4,   # peers to try before marking the track failed
        "retry_after_hours": 24,     # wait before retrying a failed / not-found track
        "max_attempts": 5,           # stop retrying after this many passes
        "min_lossy_kbps": 256,       # reject MP3/AAC below this bitrate
        "duration_tolerance_seconds": 5,
    },
}


def load_config() -> dict:
    cfg = json.loads(json.dumps(DEFAULTS))
    if CONFIG_FILE.exists():
        user = tomllib.loads(CONFIG_FILE.read_text())
        for section, values in user.items():
            cfg.setdefault(section, {}).update(values)
    return cfg

# ── Library + sync state ──────────────────────────────────────────────────────


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


def hours_since(iso: str | None) -> float:
    if not iso:
        return 1e9
    then = dt.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    return (dt.datetime.now(dt.timezone.utc) - then).total_seconds() / 3600


def in_inbox(stem: str) -> bool:
    return any(p.stem == stem for p in INBOX.glob("*") if p.is_file())


def missing_tracks(cfg: dict, sync: dict) -> list[dict]:
    """Library tracks the app doesn't have yet and that are due for a (re)try."""
    library = load_json(LIBRARY_ROOT / "library.json", None)
    if library is None:
        raise SystemExit(f"Can't read {LIBRARY_ROOT / 'library.json'} — run `djlib spotify` and `djlib library` first.")
    app_state = load_json(LIBRARY_ROOT / "state.json", {}).get("tracks", {})
    overrides = load_json(OVERRIDES_FILE, {})
    s = cfg["sync"]
    out, retried = [], set()
    for t in library["tracks"]:
        if app_state.get(t["id"], {}).get("status") in ("downloaded", "ignored"):
            continue
        rec = sync.get(t["id"], {})
        if in_inbox(t["fileName"]):
            continue
        # "Retry" in the app: a retry request newer than the last attempt makes the track due right away.
        if (overrides.get(t["id"], {}).get("retryAt") or "") > (rec.get("last_try") or ""):
            retried.add(t["id"])
            out.append(t)
            continue
        if rec.get("status") == "done":
            continue
        if rec.get("status") in ("failed", "not_found"):
            if rec.get("attempts", 0) >= s["max_attempts"] or hours_since(rec.get("last_try")) < s["retry_after_hours"]:
                continue
        out.append(t)
    # Newest additions first, so fresh playlist adds arrive quickly.
    out.sort(key=lambda t: t.get("firstAdded") or "", reverse=True)
    # The DJ Library app's Download queue (playlist / genre priorities) overrides that order.
    queue = load_json(WORK_DIR / "queue.json", None)
    if queue and queue.get("ids"):
        rank = {tid: i for i, tid in enumerate(queue["ids"])}
        if queue.get("onlyPriority"):   # explicit retries still run, even outside the priorities
            out = [t for t in out if t["id"] in rank or t["id"] in retried]
        out.sort(key=lambda t: rank.get(t["id"], len(rank)))   # stable: unranked keep newest-first
    out.sort(key=lambda t: t["id"] not in retried)               # explicit retries go first
    return out

# ── Matching + ranking ───────────────────────────────────────────────────────

AUDIO_EXT = {"flac", "wav", "aiff", "aif", "alac", "m4a", "mp3", "aac", "ogg", "opus"}
LOSSLESS_RANK = {"flac": 5, "aiff": 4, "aif": 4, "wav": 4, "alac": 4}
VARIANT_WORDS = {"remix", "rmx", "live", "acapella", "acappella", "instrumental", "karaoke", "cover",
                 "edit", "extended", "vip", "bootleg", "rework", "sped", "slowed", "nightcore",
                 "reverb", "8d", "mashup", "flip", "dub", "version", "demo", "radio"}


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    s = s.replace("&", " and ")
    return " ".join(re.findall(r"[a-z0-9]+", s))


def clean_title(title: str) -> str:
    """Drop feat./remaster noise from a Spotify title; keep remix/edit names."""
    t = re.sub(r"[\(\[]\s*(feat|ft|with)\.?\s[^\)\]]*[\)\]]", "", title, flags=re.I)
    t = re.sub(r"\s(feat|ft)\.?\s.*$", "", t, flags=re.I)
    t = re.sub(r"\s-\s.*(remaster|original mix|radio edit|mono|stereo).*$", "", t, flags=re.I)
    t = re.sub(r"[\(\[]\s*(original mix|remaster(ed)?[^\)\]]*)[\)\]]", "", t, flags=re.I)
    return t.strip()


def search_queries(track: dict) -> list[str]:
    custom = (load_json(OVERRIDES_FILE, {}).get(track["id"], {}).get("query") or "").strip()
    artist = norm(track["artists"][0]) if track["artists"] else ""
    title = norm(clean_title(track["title"]))
    bare = norm(re.sub(r"[\(\[].*?[\)\]]|\s-\s.*$", "", track["title"]))
    qs = [norm(custom)] if custom else []
    qs.append(f"{artist} {title}".strip())
    if bare and bare != title:
        qs.append(f"{artist} {bare}".strip())
    return qs


@dataclass
class Candidate:
    username: str
    path: str
    ext: str
    size: int
    bitrate: int | None
    duration: int | None
    free_slot: bool
    speed: int
    queue: int
    quality: float

    @property
    def label(self) -> str:
        q = self.ext.upper() + (f" {self.bitrate}kbps" if self.bitrate and self.ext not in LOSSLESS_RANK else "")
        return f"{q}  {self.size / 1_048_576:.1f}MB  {self.username}  {'free' if self.free_slot else f'queue {self.queue}'}  {self.speed // 1024}KB/s"


def quality_of(ext: str, bitrate: int | None, min_kbps: int) -> float | None:
    if ext in LOSSLESS_RANK:
        return 10 + LOSSLESS_RANK[ext]
    if ext == "m4a" and (bitrate is None or bitrate > 500):
        return 13  # Apple Lossless in an .m4a container
    if bitrate is None:
        return None  # lossy file of unknown quality — skip
    if bitrate < min_kbps:
        return None
    # Lossy tops out at 320 kbps; higher claims are mislabelled, so never let them outrank lossless (10+).
    bitrate = min(bitrate, 320)
    return {"mp3": 0.0, "m4a": -0.5, "aac": -0.5, "ogg": -1.0, "opus": -1.0}.get(ext, -2) + bitrate / 32


def file_matches(track: dict, path: str, duration: int | None, tol: int) -> bool:
    parts = path.replace("\\", "/").split("/")
    hay = norm(" ".join(parts[-3:]))   # file name + album + artist folders
    name = norm(parts[-1].rsplit(".", 1)[0])
    title_words = norm(clean_title(track["title"])).split()
    if not title_words or not all(w in name.split() or w in hay.split() for w in title_words):
        return False
    artist_words = {w for a in track["artists"] for w in norm(a).split() if len(w) > 1}
    if artist_words and not any(w in hay.split() for w in artist_words):
        return False
    wanted = set(norm(track["title"]).split())
    if any(w in name.split() and w not in wanted for w in VARIANT_WORDS):
        return False
    if duration and track.get("durationMs"):
        if abs(duration - track["durationMs"] / 1000) > tol:
            return False
    return True


def rank(track: dict, results, cfg: dict, loose: str | None = None) -> list[Candidate]:
    """`loose` = a custom query: its words must appear in the file path instead of the usual title/artist check."""
    s = cfg["sync"]
    cands: list[Candidate] = []
    for r in results:
        for f in r.shared_items:
            ext = (f.extension or f.filename.rsplit(".", 1)[-1]).lower().lstrip(".")
            if ext not in AUDIO_EXT:
                continue
            attrs = {a.key: a.value for a in f.attributes}
            bitrate = attrs.get(AttributeKey.BITRATE.value)
            duration = attrs.get(AttributeKey.DURATION.value)
            q = quality_of(ext, bitrate, s["min_lossy_kbps"])
            if q is None or f.filesize < 500_000:
                continue
            if loose:
                hay = norm(" ".join(f.filename.replace("\\", "/").split("/")[-3:])).split()
                if not all(w in hay for w in norm(loose).split()):
                    continue
                if duration and track.get("durationMs") and abs(duration - track["durationMs"] / 1000) > s["duration_tolerance_seconds"] * 3:
                    continue
            elif not file_matches(track, f.filename, duration, s["duration_tolerance_seconds"]):
                continue
            cands.append(Candidate(r.username, f.filename, ext, f.filesize, bitrate, duration,
                                   r.has_free_slots, r.avg_speed, r.queue_size, q))
    # Best format first; within a format prefer peers that can send right now, then speed.
    cands.sort(key=lambda c: (c.quality, c.free_slot, -min(c.queue, 50), c.speed), reverse=True)
    # One file per user, so a failed peer doesn't eat every retry.
    seen, unique = set(), []
    for c in cands:
        if c.username not in seen:
            seen.add(c.username)
            unique.append(c)
    return unique

# ── Soulseek client ──────────────────────────────────────────────────────────


_lock_file = None


def acquire_lock() -> None:
    """Only one slsk-sync at a time: hold an exclusive lock on _soulseek/sync.pid (the app reads it too)."""
    global _lock_file
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = WORK_DIR / "sync.lock"
    _lock_file = open(lock_path, "a+")
    try:
        if os.name == "nt":
            import msvcrt
            _lock_file.seek(0)
            msvcrt.locking(_lock_file.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        pid = (WORK_DIR / "sync.pid").read_text().strip() if (WORK_DIR / "sync.pid").exists() else "?"
        fail(f"slsk-sync is already running (pid {pid}) — not starting a second copy.")
    # The pid lives in its own file so other programs can read it while the lock is held (Windows
    # byte-range locks block reads of the locked file).
    (WORK_DIR / "sync.pid").write_text(str(os.getpid()))


def fail(message: str) -> None:
    """Log a fatal problem (so the app's Soulseek page shows it) and exit."""
    log.error("✗ %s", message)
    raise SystemExit(message)


class Syncer:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.sync = load_json(SYNC_FILE, {})
        self.client: SoulSeekClient | None = None
        self._search_lock = asyncio.Lock()
        self._last_search = 0.0

    async def connect(self) -> None:
        ss = self.cfg["soulseek"]
        if not ss["username"] or not ss["password"]:
            fail(f"Add your Soulseek username and password to {CONFIG_FILE}")
        acquire_lock()
        INCOMING.mkdir(parents=True, exist_ok=True)
        # Partial files left by a crash or a forced quit; no transfer is active yet, so they're safe to drop.
        for p in INCOMING.rglob("*"):
            if p.is_file():
                p.unlink(missing_ok=True)
        INBOX.mkdir(parents=True, exist_ok=True)
        settings = Settings(credentials=CredentialsSettings(username=ss["username"], password=ss["password"]))
        settings.shares.download = str(INCOMING)
        settings.shares.scan_on_start = bool(ss["share_dirs"])
        settings.shares.directories = [SharedDirectorySettingEntry(path=os.path.expanduser(d)) for d in ss["share_dirs"]]
        settings.network.listening.port = int(ss["listen_port"])
        settings.network.listening.obfuscated_port = int(ss["listen_port"]) + 1
        settings.network.server.reconnect.auto = True
        settings.rooms.auto_join = False
        self.client = SoulSeekClient(settings)
        await self.client.start()
        try:
            await self.client.login()
        except AuthenticationError as e:
            await self.client.stop()
            fail(f"Soulseek login failed: {e}. Check the username/password in {CONFIG_FILE} "
                 "(a new username is created on first login; if it's taken by someone else, pick another).")
        log.info("Logged in to Soulseek as %s", ss["username"])

    async def close(self) -> None:
        if self.client:
            await self.client.stop()

    def mark(self, track: dict, status: str, **extra) -> None:
        rec = self.sync.setdefault(track["id"], {})
        if status in ("failed", "not_found"):
            rec["attempts"] = rec.get("attempts", 0) + 1
        rec.update(status=status, last_try=now_iso(), name=track["fileName"], **extra)
        save_json(SYNC_FILE, self.sync)

    async def search(self, query: str):
        async with self._search_lock:   # space searches out to stay under server limits
            wait = self.cfg["sync"]["search_gap_seconds"] - (time.monotonic() - self._last_search)
            if wait > 0:
                await asyncio.sleep(wait)
            self._last_search = time.monotonic()
            req = await self.client.searches.search(query)
        await asyncio.sleep(self.cfg["sync"]["search_wait_seconds"])
        return list(req.results)

    async def find(self, track: dict) -> tuple[list[Candidate], dict]:
        """Candidates for the first query that yields any, plus what was searched (for the app's results page)."""
        info = {"queries": [], "filesSeen": 0, "usersSeen": 0}
        custom = bool((load_json(OVERRIDES_FILE, {}).get(track["id"], {}).get("query") or "").strip())
        for q in search_queries(track):
            results = await self.search(q)
            info["queries"].append(q)
            info["filesSeen"] += sum(len(r.shared_items) for r in results)
            info["usersSeen"] += len(results)
            # A custom query is the user's own wording: trust it for the title/artist check, keep the quality rules.
            cands = rank(track, results, self.cfg, loose=q if custom and len(info["queries"]) == 1 else None)
            if cands:
                return cands, info
        return [], info

    async def download(self, track: dict, c: Candidate) -> Path | None:
        s = self.cfg["sync"]
        try:
            transfer = await self.client.transfers.download(c.username, c.path)
        except AioSlskException as e:
            log.info("  ✗ %s: %s", c.username, e)
            return None
        started = time.monotonic()
        last_bytes, last_progress = 0, time.monotonic()
        try:
            while True:
                await asyncio.sleep(2)
                st = transfer.state.VALUE
                if st == TransferState.COMPLETE:
                    break
                if st in (TransferState.FAILED, TransferState.ABORTED):
                    log.info("  ✗ %s: %s", c.username, transfer.fail_reason or transfer.abort_reason or st.name.lower())
                    await self._discard(transfer)   # drop the partial file and the transfer entry
                    return None
                if st == TransferState.DOWNLOADING or transfer.bytes_transfered:
                    if transfer.bytes_transfered > last_bytes:
                        last_bytes, last_progress = transfer.bytes_transfered, time.monotonic()
                    elif time.monotonic() - last_progress > s["stall_timeout_minutes"] * 60:
                        raise TimeoutError("stalled")
                elif time.monotonic() - started > s["queue_timeout_minutes"] * 60:
                    raise TimeoutError(f"still queued (place {transfer.place_in_queue or '?'})")
        except TimeoutError as e:
            log.info("  ✗ %s: %s", c.username, e)
            await self._discard(transfer)
            return None

        src = Path(transfer.local_path or "")
        if not src.is_file() or src.stat().st_size < 0.9 * c.size:
            log.info("  ✗ %s: incomplete file", c.username)
            await self._discard(transfer)
            return None
        dest = INBOX / f"{track['fileName']}.{c.ext}"
        n = 2
        while dest.exists():
            dest = INBOX / f"{track['fileName']} ({n}).{c.ext}"
            n += 1
        shutil.move(str(src), dest)   # same volume → atomic rename; the app never sees a partial file
        await self._forget(transfer)
        return dest

    async def _discard(self, transfer) -> None:
        try:
            await self.client.transfers.abort(transfer)
        except Exception:
            pass
        if transfer.local_path and Path(transfer.local_path).is_file():
            Path(transfer.local_path).unlink(missing_ok=True)
        await self._forget(transfer)

    async def _forget(self, transfer) -> None:
        try:
            await self.client.transfers.remove(transfer)
        except Exception:
            pass

    async def process(self, track: dict) -> str:
        who = f"{', '.join(track['artists'])} – {track['title']}"
        cands, info = await self.find(track)
        reason = ("no results" if info["filesSeen"] == 0
                  else f"{info['filesSeen']} files from {info['usersSeen']} users, none matched")
        if not cands:
            log.info("· not found: %s (%s)", who, reason)
            self.mark(track, "not_found", reason=reason, queries=info["queries"])
            return "not_found"
        for c in cands[: self.cfg["sync"]["candidates_per_track"]]:
            log.info("↓ %s  ←  %s", who, c.label)
            dest = await self.download(track, c)
            if dest:
                log.info("✓ %s → _inbox/%s", who, dest.name)
                self.mark(track, "done", file=dest.name, source=f"{c.username}:{c.path}", format=c.ext,
                          bitrate=c.bitrate, sizeBytes=c.size, queries=info["queries"], reason=None)
                return "done"
        self.mark(track, "failed", reason=f"{min(len(cands), self.cfg['sync']['candidates_per_track'])} sources tried, none delivered",
                  queries=info["queries"])
        return "failed"

    async def run_pass(self, limit: int | None = None) -> dict:
        tracks = missing_tracks(self.cfg, self.sync)
        if (WORK_DIR / "queue.json").exists():
            log.info("Following the app's download queue")
        if limit:
            tracks = tracks[:limit]
        log.info("Pass: %d tracks to look for", len(tracks))
        counts = {"done": 0, "failed": 0, "not_found": 0}
        queue: asyncio.Queue = asyncio.Queue()
        for t in tracks:
            queue.put_nowait(t)

        async def worker():
            while not queue.empty():
                t = queue.get_nowait()
                try:
                    counts[await self.process(t)] += 1
                except Exception as e:  # keep the pass going if one track blows up
                    log.exception("error on %s: %s", t["fileName"], e)
                    self.mark(t, "failed", error=str(e))
                    counts["failed"] += 1

        await asyncio.gather(*[worker() for _ in range(self.cfg["sync"]["max_concurrent"])])
        log.info("Pass finished: %(done)d downloaded, %(not_found)d not found, %(failed)d failed", counts)
        return counts

# ── CLI ──────────────────────────────────────────────────────────────────────


def setup_logging() -> None:
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%d %H:%M:%S")
    for h in (logging.StreamHandler(sys.stdout), logging.FileHandler(LOG_FILE)):
        h.setFormatter(fmt)
        log.addHandler(h)
    log.setLevel(logging.INFO)
    logging.getLogger("aioslsk").setLevel(logging.CRITICAL)


async def sleep_until_nudged(seconds: float) -> None:
    """Sleep between passes, but wake early when the app changes the queue or asks for a retry."""
    def stamp():
        return tuple(p.stat().st_mtime if p.exists() else 0 for p in (OVERRIDES_FILE, WORK_DIR / "queue.json"))
    start, before = time.monotonic(), stamp()
    while time.monotonic() - start < seconds:
        await asyncio.sleep(10)
        if stamp() != before:
            log.info("Queue or retry requests changed — starting a new pass")
            return


async def cmd_run(cfg: dict, once: bool, limit: int | None) -> None:
    s = Syncer(cfg)
    await s.connect()
    try:
        while True:
            await s.run_pass(limit)
            if once:
                break
            log.info("Sleeping %d min (checks the library again for new playlist tracks)", cfg["sync"]["interval_minutes"])
            await sleep_until_nudged(cfg["sync"]["interval_minutes"] * 60)
    finally:
        await s.close()


async def cmd_search(cfg: dict, query: str) -> None:
    s = Syncer(cfg)
    await s.connect()
    try:
        artist, _, title = query.partition(" - ")
        track = {"artists": [artist] if title else [], "title": title or query, "durationMs": None}
        results = await s.search(norm(query))
        cands = rank(track, results, cfg)
        print(f"{sum(len(r.shared_items) for r in results)} files from {len(results)} users; {len(cands)} usable matches:")
        for c in cands[:15]:
            print(f"  {c.label}\n      {c.path}")
    finally:
        await s.close()


def cmd_status() -> None:
    sync = load_json(SYNC_FILE, {})
    by = {}
    for rec in sync.values():
        by[rec.get("status")] = by.get(rec.get("status"), 0) + 1
    fmts = {}
    for rec in sync.values():
        if rec.get("status") == "done":
            fmts[rec.get("format")] = fmts.get(rec.get("format"), 0) + 1
    cfg = load_config()
    print(f"Downloaded: {by.get('done', 0)}  ({', '.join(f'{k} {v}' for k, v in sorted(fmts.items())) or '-'})")
    print(f"Not found:  {by.get('not_found', 0)}    Failed: {by.get('failed', 0)}")
    print(f"Still due:  {len(missing_tracks(cfg, sync))}")
    print(f"Log: {LOG_FILE}")


def main() -> None:
    p = argparse.ArgumentParser(prog="slsk-sync", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run")
    o = sub.add_parser("once")
    o.add_argument("--limit", type=int)
    q = sub.add_parser("search")
    q.add_argument("query")
    sub.add_parser("status")
    sub.add_parser("retry")
    a = p.parse_args()

    cfg = load_config()
    if a.cmd == "status":
        return cmd_status()
    if a.cmd == "retry":
        sync = load_json(SYNC_FILE, {})
        n = 0
        for rec in sync.values():
            if rec.get("status") in ("failed", "not_found"):
                rec["attempts"], rec["last_try"] = 0, None
                n += 1
        save_json(SYNC_FILE, sync)
        return print(f"{n} tracks will be retried on the next pass")
    setup_logging()
    try:
        if a.cmd == "search":
            asyncio.run(cmd_search(cfg, a.query))
        else:
            asyncio.run(cmd_run(cfg, once=a.cmd == "once", limit=getattr(a, "limit", None)))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
