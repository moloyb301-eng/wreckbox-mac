#!/usr/bin/env python3
"""Full-track BPM / key / energy analysis with Essentia, for the DJ Library app.

    analyze.py FILE [FILE ...]

Prints one JSON object per line (same order as the arguments):
    {"path", "bpm", "bpmConfidence", "bpmAlternate", "key", "camelot", "keyStrength",
     "keyAgreement", "energy", "danceability", "loudnessLUFS", "durationSec", "error"}

BPM uses RhythmExtractor2013 (multifeature) and is folded into a DJ-friendly range;
the half/double tempo is reported as bpmAlternate when the fold was a judgement call.
Key uses the EDM-tuned "edma" profile, cross-checked with "bgate" and "krumhansl".
"""
import json
import math
import sys

import essentia
import essentia.standard as es

essentia.log.infoActive = False
essentia.log.warningActive = False

SR = 44100
# Camelot wheel: (tonic, scale) → code
_MAJOR = {"B": "1B", "F#": "2B", "Gb": "2B", "C#": "3B", "Db": "3B", "G#": "4B", "Ab": "4B",
          "D#": "5B", "Eb": "5B", "A#": "6B", "Bb": "6B", "F": "7B", "C": "8B", "G": "9B",
          "D": "10B", "A": "11B", "E": "12B"}
_MINOR = {"G#": "1A", "Ab": "1A", "D#": "2A", "Eb": "2A", "A#": "3A", "Bb": "3A", "F": "4A",
          "C": "5A", "G": "6A", "D": "7A", "A": "8A", "E": "9A", "B": "10A", "F#": "11A",
          "Gb": "11A", "C#": "12A", "Db": "12A"}


def camelot(key: str, scale: str) -> str | None:
    return (_MAJOR if scale == "major" else _MINOR).get(key)


def fold_bpm(bpm: float, lo: float = 70.0, hi: float = 180.0) -> tuple[float, float | None]:
    """Fold into [lo, hi]; return (bpm, alternate) where alternate is the half/double that's also plausible."""
    if bpm <= 0:
        return bpm, None
    while bpm < lo:
        bpm *= 2
    while bpm > hi:
        bpm /= 2
    alt = None
    if bpm < 95 and bpm * 2 <= 190:       # e.g. 87 vs 174 (DnB / halftime)
        alt = bpm * 2
    elif bpm > 150 and bpm / 2 >= 70:     # e.g. 160 vs 80 (trap / hip-hop)
        alt = bpm / 2
    return bpm, alt


def analyze(path: str) -> dict:
    out = {"path": path}
    try:
        audio = es.MonoLoader(filename=path, sampleRate=SR)()
        dur = len(audio) / SR
        out["durationSec"] = round(dur, 1)
        if dur < 5:
            raise ValueError("too short")

        # Tempo: analyse the body of the track (skip the first/last 10%, where intros/outros sit).
        a, b = int(len(audio) * 0.1), int(len(audio) * 0.9)
        body = audio[a:b] if dur > 60 else audio
        bpm, _beats, conf, _est, _intervals = es.RhythmExtractor2013(method="multifeature")(body)
        bpm, alt = fold_bpm(float(bpm))
        out["bpm"] = round(bpm, 1)
        out["bpmConfidence"] = round(float(conf) / 5.32, 2)   # multifeature confidence is 0–5.32
        out["bpmAlternate"] = round(alt, 1) if alt else None

        # Key: EDM profile first, then two other profiles to measure agreement.
        results = {}
        for profile in ("edma", "bgate", "krumhansl"):
            k, s, strength = es.KeyExtractor(profileType=profile, sampleRate=SR)(audio)
            results[profile] = (k, s, float(strength))
        k, s, strength = results["edma"]
        out["key"] = f"{k} {s}"
        out["camelot"] = camelot(k, s)
        out["keyStrength"] = round(strength, 2)
        out["keyAgreement"] = sum(1 for r in results.values() if r[:2] == (k, s))  # 1–3 profiles agree

        # Energy / danceability / loudness.
        dance, _ = es.Danceability(sampleRate=SR)(audio)
        out["danceability"] = round(min(float(dance) / 3.0, 1.0), 2)
        rms = float(es.RMS()(audio))
        out["energy"] = round(min(max((20 * math.log10(rms + 1e-9) + 30) / 24, 0.0), 1.0), 2)
        stereo, _sr, _ch, _md5, _br, _codec = es.AudioLoader(filename=path)()
        _mom, _short, integrated, _range = es.LoudnessEBUR128(sampleRate=_sr)(stereo)
        out["loudnessLUFS"] = round(float(integrated), 1)
    except Exception as e:  # report per file, keep going
        out["error"] = str(e)
    return out


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(json.dumps(analyze(p)), flush=True)
