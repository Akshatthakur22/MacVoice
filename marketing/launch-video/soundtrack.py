"""Synthesizes the launch video's music bed and sound effects.

Usage: python3 soundtrack.py cues.json out.wav
cues.json comes from the page's cues() function (written by render.js), so
every click and whoosh lines up with the animation.
"""
import json
import sys

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

SR = 48000
DUR = 55.0
BPM = 96
BEAT = 60 / BPM
BAR = BEAT * 4
N = int(SR * DUR)
rng = np.random.default_rng(7)


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def lp(x, hz, order=2):
    return sosfilt(butter(order, hz, "low", fs=SR, output="sos"), x)


def hp(x, hz, order=2):
    return sosfilt(butter(order, hz, "high", fs=SR, output="sos"), x)


def bp(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], "band", fs=SR, output="sos"), x)


def add(buf, sig, t, gain=1.0, pan=0.0):
    i = int(t * SR)
    if i >= N:
        return
    sig = sig[: N - i]
    l, r = np.sqrt((1 - pan) / 2), np.sqrt((1 + pan) / 2)
    buf[0, i : i + len(sig)] += sig * gain * l * 1.414
    buf[1, i : i + len(sig)] += sig * gain * r * 1.414


def tvec(d):
    return np.arange(int(d * SR)) / SR


# I - vi - IV - V in C, voiced warm (MIDI notes)
CHORDS = [
    [48, 55, 60, 64, 67, 74],  # Cadd9
    [45, 52, 57, 60, 64, 71],  # Am9-ish
    [41, 48, 57, 60, 64, 67],  # Fmaj7
    [43, 50, 55, 59, 62, 69],  # G6/9
]

music = np.zeros((2, N))

# ---- pad: detuned additive saws, slow attack, low-passed
for bar in range(int(DUR / BAR) + 1):
    t0 = bar * BAR
    ch = CHORDS[bar % 4]
    d = BAR + 0.9
    t = tvec(d)
    env = np.minimum(1, t / 0.5) * np.minimum(1, (d - t) / 0.9)
    for side, det in ((-0.6, -0.08), (0.6, 0.08)):
        sig = np.zeros_like(t)
        for n in ch[1:]:
            f = midi(n + det)
            for h in range(1, 7):
                sig += np.sin(2 * np.pi * f * h * t + rng.random() * 6.28) / h
        sig = lp(sig, 1400 if t0 > 4.8 else 900) * env
        add(music, sig, t0, 0.018, side)

# ---- bass: root on beats 1 and 3, from the drop onward
DROP = 5.0
for bar in range(int(DUR / BAR) + 1):
    for b in (0, 2, 3.5):
        t0 = bar * BAR + b * BEAT
        if t0 < DROP or t0 > 53.0:
            continue
        f = midi(CHORDS[bar % 4][0] - 12)
        d = BEAT * (1.6 if b < 3 else 0.45)
        t = tvec(d)
        env = np.minimum(1, t / 0.01) * np.exp(-t / (d * 0.6))
        sig = (np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t)) * env
        add(music, sig, t0, 0.20)

# ---- pluck arpeggio: 8th notes
pattern = [2, 3, 4, 5, 4, 3, 5, 4]
for bar in range(int(DUR / BAR) + 1):
    ch = CHORDS[bar % 4]
    for k in range(8):
        t0 = bar * BAR + k * BEAT / 2
        if t0 < DROP - 0.01 or t0 > 52.5:
            continue
        f = midi(ch[pattern[k]] + 12)
        t = tvec(0.6)
        env = np.minimum(1, t / 0.004) * np.exp(-t / 0.16)
        sig = (np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t) + 0.12 * np.sin(6 * np.pi * f * t)) * env
        add(music, sig, t0, 0.045 * (1.0 if k % 2 == 0 else 0.75), -0.35 if k % 2 else 0.35)

# ---- drums: soft kick on every beat, hats on off-beats; sidechain envelope for the pad
duck = np.ones(N)
for beat in range(int(DUR / BEAT) + 1):
    t0 = beat * BEAT
    if t0 < DROP - 0.01 or t0 > 52.0:
        continue
    t = tvec(0.35)
    f = 45 + 75 * np.exp(-t / 0.03)
    kick = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.12)
    add(music, kick, t0, 0.30 if beat % 2 == 0 else 0.20)
    i = int(t0 * SR)
    seg = 1 - 0.45 * np.exp(-tvec(0.4) / 0.11)
    duck[i : i + len(seg)] = np.minimum(duck[i : i + len(seg)], seg[: N - i])
    th = t0 + BEAT / 2
    hat = hp(rng.standard_normal(int(0.05 * SR)), 7000) * np.exp(-tvec(0.05) / 0.012)
    add(music, hat, th, 0.05, 0.25)
music *= duck

# ---- arrangement envelope: gentle intro rise, end fade
tt = np.arange(N) / SR
arr = np.clip(0.35 + 0.65 * tt / DROP, 0, 1) * np.clip((DUR - tt) / 3.5, 0, 1)
music *= arr

# ---- final sustained chord under the CTA
t = tvec(7.0)
env = np.minimum(1, t / 0.2) * np.exp(-t / 2.6)
sig = sum(np.sin(2 * np.pi * midi(n + 12) * t) * (0.6 if n < 55 else 1) for n in CHORDS[0][1:])
add(music, lp(sig, 3000) * env, 48.2, 0.05)

# ---- sound effects
sfx = np.zeros((2, N))


def noise(d):
    return rng.standard_normal(int(d * SR))


def make(kind):
    if kind == "tick":
        t = tvec(0.04)
        s = np.sin(2 * np.pi * 2200 * t) * np.exp(-t / 0.006) + 0.4 * hp(noise(0.04), 3000) * np.exp(-t / 0.004)
        return s, 0.05
    if kind == "key":
        t = tvec(0.05)
        s = bp(noise(0.05), 1500, 6000) * np.exp(-t / 0.006) + 0.6 * np.sin(2 * np.pi * 180 * t) * np.exp(-t / 0.01)
        return s, 0.10
    if kind == "thock":
        t = tvec(0.12)
        s = np.sin(2 * np.pi * 230 * t) * np.exp(-t / 0.025) + 0.5 * bp(noise(0.12), 800, 3000) * np.exp(-t / 0.01)
        return s, 0.22
    if kind == "blip":
        t = tvec(0.22)
        f = np.where(t < 0.08, 880, 1320)
        s = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.07) * np.minimum(1, t / 0.003)
        return s, 0.10
    if kind == "done":
        t = tvec(0.8)
        s = (np.sin(2 * np.pi * 1046.5 * t) * np.exp(-t / 0.18)
             + np.where(t > 0.09, np.sin(2 * np.pi * 1568 * t) * np.exp(-np.maximum(t - 0.09, 0) / 0.3), 0))
        return s * np.minimum(1, t / 0.003), 0.09
    if kind == "chime":
        t = tvec(2.5)
        s = sum(a * np.sin(2 * np.pi * 784 * r * t) * np.exp(-t / dcy) for r, a, dcy in ((1, 1, 0.9), (2.0, 0.5, 0.6), (2.76, 0.3, 0.4), (5.4, 0.12, 0.2)))
        return s * np.minimum(1, t / 0.002), 0.10
    if kind in ("whoosh", "swoosh"):
        d = 0.7 if kind == "whoosh" else 0.42
        t = tvec(d)
        env = np.sin(np.pi * np.clip(t / d, 0, 1)) ** 2
        n = noise(d)
        lo = lp(n, 900)
        hi = lp(n, 4500)
        mixw = t / d
        s = (lo * (1 - mixw) + hi * mixw) * env
        return s, 0.10 if kind == "whoosh" else 0.06
    if kind == "pop":
        t = tvec(0.12)
        f = 520 * np.exp(-t / 0.05) + 260
        s = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.04) * np.minimum(1, t / 0.002)
        return s, 0.22
    raise ValueError(kind)


def main():
    cues_path, out = sys.argv[1], sys.argv[2]
    cues = json.load(open(cues_path))
    for c in cues:
        sig, g = make(c["k"])
        # whooshes swell into their cue time
        t0 = c["t"] - (0.5 if c["k"] == "whoosh" else 0.28 if c["k"] == "swoosh" else 0)
        add(sfx, sig, max(0, t0), g, float(rng.uniform(-0.25, 0.25)))
    mix = music + sfx
    mix = np.tanh(mix * 1.1) / 1.1  # gentle soft clip
    mix /= np.max(np.abs(mix)) / 0.89
    wavfile.write(out, SR, (mix.T * 32767).astype(np.int16))
    print("wrote", out, f"{len(cues)} cues")


if __name__ == "__main__":
    main()
