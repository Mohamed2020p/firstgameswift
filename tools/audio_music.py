# -*- coding: utf-8 -*-
"""SUPERCARS ambience beds (6) and music tracks (5), all synthesised. Registered into make_audio.JOBS (stereo, seamless loops)."""
import numpy as np
from scipy import signal as sg

import make_audio as M
from make_audio import (SR, tt, nsamp, noise, pink, brown, expdec, env_ad, sine, glide, modal, wplace, lp, hp, bp, bq, soft_limit,
                        fade, rms, peak, dbg, mtof, job)
from audio_sfx import pnoise, band, lowshape, highshape, saw, square, bell, pluck, click, thump

# ----------------------------------------------------------------------------------------------------------------------------
# stereo helpers
# ----------------------------------------------------------------------------------------------------------------------------


def pan(x, p):
    a = (p + 1.0) * np.pi / 4.0
    return np.stack([x * np.cos(a), x * np.sin(a)], axis=1)


def add(buf, mono, t, gain=1.0, p=0.0):
    wplace(buf, pan(mono, p), int(round(t * SR)), gain)


def stereo_pnoise(L, r, shape):
    return np.stack([pnoise(L, r, shape), pnoise(L, r, shape)], axis=1)


def chirp(f0, f1, dur, vib=0.0, vf=30.0):
    n = nsamp(dur)
    f = glide(f0, f1, n, log=False)
    if vib:
        f = f * (1 + vib * np.sin(2 * np.pi * vf * tt(n)))
    y = sine(f, n)
    return y * np.sin(np.pi * np.arange(n) / n) ** 1.5


def bird(r):
    """one song phrase: a few chirps"""
    kind = r.integers(0, 3)
    parts = []
    base = r.uniform(2600, 4800)
    if kind == 0:
        for k in range(int(r.integers(3, 7))):
            parts.append(chirp(base * r.uniform(0.9, 1.2), base * r.uniform(1.2, 1.7), r.uniform(0.05, 0.09)))
            parts.append(np.zeros(nsamp(r.uniform(0.03, 0.07))))
    elif kind == 1:
        for k in range(int(r.integers(4, 9))):
            parts.append(chirp(base * 1.4, base * 0.9, 0.045, vib=0.05, vf=70))
            parts.append(np.zeros(nsamp(0.045)))
    else:
        parts.append(chirp(base * 0.8, base * 1.6, 0.16, vib=0.03, vf=22))
        parts.append(np.zeros(nsamp(0.05)))
        parts.append(chirp(base * 1.7, base * 1.0, 0.22, vib=0.04, vf=18))
    return np.concatenate(parts)


def car_pass(r, dur, f_lo=300, f_hi=1400):
    n = nsamp(dur)
    t = tt(n)
    c = t / dur
    fc = f_lo + (f_hi - f_lo) * np.sin(np.pi * c)
    y = M.tv_bq(noise(n, r), "bp", fc, 0.8) + 0.4 * lp(noise(n, r), 250)
    env = np.sin(np.pi * c) ** 2
    return y * env


def siren(dur, f_lo=650, f_hi=1050, rate=0.35):
    n = nsamp(dur)
    t = tt(n)
    f = f_lo + (f_hi - f_lo) * (0.5 + 0.5 * np.sin(2 * np.pi * rate * t))
    ph = np.cumsum(f) / SR
    y = sum(np.sin(2 * np.pi * ph * k) / k for k in (1, 2, 3, 5))
    return bp(y, 500, 3000) * np.minimum(1.0, np.minimum(t / 1.0, (dur - t) / 1.0))


def dist_muffle(x, amount=0.5):
    return lp(x, 1500 + 3000 * (1 - amount))


AMB_L = nsamp(24.0)


def _amb_common(r, traffic=0.8, murmur=0.0, wind=0.0):
    L = AMB_L
    t = tt(L)
    y = np.zeros((L, 2))
    if traffic > 0:
        tr = stereo_pnoise(L, r, lambda f: (1 / (1 + (f / 260) ** 2.5)) * (1 + 0.8 * np.exp(-((f - 110) / 60) ** 2)))
        for c in range(2):
            tr[:, c] *= 0.7 + 0.3 * np.sin(2 * np.pi * (2 / 24.0) * t + c * 1.7) + 0.1 * np.sin(2 * np.pi * (5 / 24.0) * t + c)
        y += tr * traffic
    if murmur > 0:
        mm = stereo_pnoise(L, r, band(900, 700))
        for c in range(2):
            mm[:, c] *= 0.5 + 0.5 * np.abs(np.sin(2 * np.pi * (3 / 24.0) * t + c * 2.0 + 0.3))
        y += mm * murmur
    if wind > 0:
        w = stereo_pnoise(L, r, lambda f: 1 / (1 + (f / 500) ** 2.5) * (1 + np.exp(-((f - 180) / 100) ** 2)))
        for c in range(2):
            w[:, c] *= 0.6 + 0.4 * np.sin(2 * np.pi * (1 / 24.0) * t + c * 2.3) ** 2
        y += w * wind
    return y


@job("cityDay", "ambience", -8.0, True, True, 128)
def _city_day(r):
    y = _amb_common(r, 0.9, 0.18, 0.15)
    for k in range(9):
        add(y, car_pass(r, r.uniform(2.5, 5.0)), r.uniform(0, 24), r.uniform(0.3, 0.7), r.choice([-0.9, 0.9]) * r.uniform(0.4, 1.0))
    for k in range(3):
        f = r.choice([392.0, 440.0, 349.0])
        n = nsamp(r.uniform(0.35, 0.8))
        h = (saw(f, n, 10) + saw(f * 1.26, n, 10)) * np.minimum(1.0, tt(n) / 0.02) * np.minimum(1.0, (n / SR - tt(n)) / 0.05)
        add(y, lp(h, 1800) * 0.16, r.uniform(0, 24), 1.0, r.uniform(-0.8, 0.8))
    for k in range(5):
        add(y, bird(r) * 0.06, r.uniform(0, 24), 1.0, r.uniform(-1, 1))
    return y


@job("cityNight", "ambience", -10.0, True, True, 128)
def _city_night(r):
    y = _amb_common(r, 0.45, 0.05, 0.25)
    L = AMB_L
    t = tt(L)
    hum = (sine(60, L) * 0.6 + sine(120, L) * 0.25 + sine(180, L) * 0.1) * 0.05
    y += hum[:, None]
    for k in range(3):
        add(y, car_pass(r, r.uniform(3, 6), 200, 900), r.uniform(0, 24), r.uniform(0.2, 0.5), r.choice([-0.9, 0.9]))
    add(y, lp(siren(6.5), 2500) * 0.08, 9.0, 1.0, -0.6)
    add(y, lp(siren(4.5, 700, 1100, 0.5), 2200) * 0.05, 19.0, 1.0, 0.7)
    return y


@job("suburbDay", "ambience", -9.0, True, True, 128)
def _suburb_day(r):
    L = AMB_L
    t = tt(L)
    y = _amb_common(r, 0.2, 0.0, 0.2)
    leaves = stereo_pnoise(L, r, band(3500, 2000))
    for c in range(2):
        leaves[:, c] *= (0.3 + 0.7 * np.abs(np.sin(2 * np.pi * (1 / 24.0 * 4) * t + c * 1.1 + 0.4))) * 0.14
    y += leaves
    for k in range(16):
        add(y, bird(r) * r.uniform(0.05, 0.12), r.uniform(0, 24), 1.0, r.uniform(-1, 1))
    mower = (saw(96, L, 12) * 0.3 + lp(noise(L, r), 800) * 0.2) * (0.6 + 0.4 * np.sin(2 * np.pi * (2 / 24.0) * t))
    y += pan(mower * 0.03, 0.8)
    return y


@job("suburbNight", "ambience", -11.0, True, True, 128)
def _suburb_night(r):
    L = AMB_L
    t = tt(L)
    y = _amb_common(r, 0.12, 0.0, 0.3)
    for (fc, rate, p, g) in ((4300.0, 24.0, -0.5, 0.06), (5100.0, 20.0, 0.5, 0.05), (3900.0, 27.0, 0.0, 0.04)):
        gate = (np.sin(2 * np.pi * rate * t) > 0.2) * (0.5 + 0.5 * np.sin(2 * np.pi * (6 / 24.0) * t + fc)) ** 2
        cr = sine(fc, L) * gate
        cr = bp(cr, fc * 0.8, fc * 1.2)
        y += pan(cr * g, p)
    for k in range(2):
        tm = r.uniform(2, 20)
        n = nsamp(0.4)
        hoot = sine(glide(430, 380, n) * (1 + 0.02 * np.sin(2 * np.pi * 8 * tt(n))), n) * np.sin(np.pi * np.arange(n) / n) ** 1.5
        add(y, hoot * 0.07, tm, 1.0, -0.7)
        add(y, hoot * 0.07, tm + 0.55, 1.0, -0.7)
    return y


@job("houseInterior", "ambience", -14.0, True, True, 128)
def _house(r):
    L = AMB_L
    t = tt(L)
    room = stereo_pnoise(L, r, lowshape(200, 2)) * 0.05
    fridge = (sine(120, L) * 0.5 + sine(240, L) * 0.25 + sine(360, L) * 0.08) * (0.5 + 0.5 * np.sin(2 * np.pi * (1 / 24.0) * t)) * 0.025
    outside = stereo_pnoise(L, r, band(3500, 1800)) * 0.006
    y = room + pan(fridge, -0.3) + outside
    for k in range(24):
        tick = modal(nsamp(0.06), [2300 if k % 2 == 0 else 1900, 3400], [0.01, 0.007], [1.0, 0.5]) * 0.05
        add(y, tick, k * 1.0 + 0.2, 1.0, 0.6)
    return y


@job("garageInterior", "ambience", -13.0, True, True, 128)
def _garage(r):
    L = AMB_L
    t = tt(L)
    room = stereo_pnoise(L, r, lowshape(350, 2)) * 0.05
    flu = sum(np.sin(2 * np.pi * 100 * k * t + k) / k for k in (1, 2, 3, 5)) * 0.03 * (0.8 + 0.2 * np.sin(2 * np.pi * 7 * t))
    comp = (sine(55, L) * 0.6 + sine(110, L) * 0.3) * 0.03 * (0.6 + 0.4 * np.sin(2 * np.pi * (3 / 24.0) * t) ** 2)
    y = room + pan(flu, 0.2) + pan(comp, -0.5)
    hiss = stereo_pnoise(L, r, band(4500, 2500)) * 0.006
    y += hiss
    for k in range(6):
        drip = modal(nsamp(0.5), [1450 * r.uniform(0.9, 1.15), 2650], [0.05, 0.03], [1.0, 0.4]) * 0.09
        drip = M.reverb(drip, 1.4, 0.35, r)
        add(y, drip, r.uniform(0, 22), 1.0, r.uniform(-0.8, 0.8))
    for k in range(5):
        tk = modal(nsamp(0.3), [r.uniform(700, 1400), r.uniform(1600, 2600)], [0.04, 0.03], [1.0, 0.5]) * 0.07
        add(y, M.reverb(tk, 1.2, 0.3, r), r.uniform(0, 22), 1.0, r.uniform(-0.8, 0.8))
    return y


# ----------------------------------------------------------------------------------------------------------------------------
# MUSIC
# ----------------------------------------------------------------------------------------------------------------------------


def kick(r, punch=1.0):
    n = nsamp(0.4)
    y = sine(glide(170, 46, n) , n) * expdec(n, 0.11)
    y += 0.5 * sine(glide(90, 42, n), n) * expdec(n, 0.2)
    y[:nsamp(0.004)] += noise(nsamp(0.004), r) * 0.3 * punch
    return np.tanh(y * 1.6)


def snare(r, tone=190.0):
    n = nsamp(0.3)
    y = bp(noise(n, r), 1600, 7500) * expdec(n, 0.07) + sine(tone, n) * expdec(n, 0.05) * 0.6
    return y


def clap(r):
    n = nsamp(0.3)
    y = np.zeros(n)
    for tm in (0.0, 0.011, 0.022):
        m = nsamp(0.03)
        y[int(tm * SR):int(tm * SR) + m] += bp(noise(m, r), 1100, 3800)[:n - int(tm * SR)][:m] * expdec(m, 0.006)
    y += bp(noise(n, r), 900, 3200) * expdec(n, 0.09) * np.minimum(1.0, tt(n) / 0.03) * 0.8
    return y


def hat(r, open_=False):
    n = nsamp(0.3 if open_ else 0.08)
    return hp(noise(n, r), 7000) * expdec(n, 0.09 if open_ else 0.018)


def bass_note(f, dur, cutoff=700, drive=1.4):
    n = nsamp(dur)
    t = tt(n)
    y = saw(f, n, 18) + 0.6 * sine(f, n)
    fc = cutoff * (0.35 + 0.65 * np.exp(-t / 0.12))
    y = M.tv_bq(y, "lp", fc, 1.4)
    env = np.minimum(1.0, t / 0.004) * np.minimum(1.0, (dur - t) / 0.02)
    return np.tanh(y * drive) * env


def pad_note(f, dur, detune=0.006):
    n = nsamp(dur)
    t = tt(n)
    y = (saw(f * (1 - detune), n, 14) + saw(f, n, 14) + saw(f * (1 + detune), n, 14)) / 3.0
    y = lp(y, 2200, 2)
    env = np.minimum(1.0, t / 0.45) * np.minimum(1.0, (dur - t) / 0.9)
    return y * env


def epiano(f, dur):
    n = nsamp(dur)
    t = tt(n)
    mod = sine(f * 14, n) * expdec(n, 0.06) * 2.2 + sine(f * 1, n) * 0.0
    y = np.sin(2 * np.pi * f * t + mod) * expdec(n, dur * 0.4) + 0.3 * np.sin(2 * np.pi * f * 2 * t) * expdec(n, dur * 0.2)
    return y * np.minimum(1.0, t / 0.004)


def chord_notes(root, kind):
    q = {"m": [0, 3, 7], "M": [0, 4, 7], "m7": [0, 3, 7, 10], "M7": [0, 4, 7, 11], "7": [0, 4, 7, 10], "sus": [0, 5, 7]}[kind]
    return [root + i for i in q]


def build_track(r, bpm, bars, prog, style):
    beat = 60.0 / bpm
    bar = beat * 4
    step = beat / 4
    L = int(round(bars * bar * SR))
    drums = np.zeros((L, 2))
    bassb = np.zeros((L, 2))
    padb = np.zeros((L, 2))
    leadb = np.zeros((L, 2))
    fxb = np.zeros((L, 2))
    kick_times = []

    sc = style
    for b in range(bars):
        t0 = b * bar
        ch_root, ch_kind = prog[b % len(prog)]
        notes = chord_notes(ch_root, ch_kind)
        # ---- drums
        for s in range(16):
            ts = t0 + s * step
            if sc["kick"] == "four":
                if s % 4 == 0:
                    add(drums, kick(r), ts, 0.95); kick_times.append(ts)
            elif sc["kick"] == "half":
                if s in (0, 8) or (sc.get("kick_extra") and s in sc["kick_extra"]):
                    add(drums, kick(r, 0.6), ts, 0.85); kick_times.append(ts)
            elif sc["kick"] == "boom":
                if s in (0, 6, 10):
                    add(drums, kick(r, 0.4), ts, 0.8); kick_times.append(ts)
            if sc["snare"] and s in (4, 12):
                if sc["snare"] == "clap":
                    add(drums, clap(r), ts, 0.7, 0.05)
                else:
                    add(drums, snare(r), ts, 0.65, -0.05)
            hs = sc["hats"]
            if hs == "eighth" and s % 2 == 0:
                add(drums, hat(r, s % 8 == 6), ts, 0.28 if s % 4 == 0 else 0.4, 0.3)
            elif hs == "off" and s % 4 == 2:
                add(drums, hat(r, True), ts, 0.35, 0.3)
            elif hs == "sixteenth":
                add(drums, hat(r, False), ts, 0.16 + 0.14 * (s % 2 == 0) + 0.1 * (s % 4 == 2), 0.3 if s % 2 else -0.3)
        # ---- bass
        root_f = float(mtof(ch_root - 24 + 12))
        pat = sc["bass"]
        for s in range(16):
            ts = t0 + s * step
            if pat == "eighths" and s % 2 == 1 or pat == "eighths" and s % 4 == 0:
                oct_ = 12 if (s % 8 == 7) else 0
                add(bassb, bass_note(float(mtof(ch_root - 12 + oct_)), step * 1.7), ts, 0.7)
            elif pat == "sixteenth":
                oct_ = 12 if s % 4 == 3 else (7 if s % 8 == 5 else 0)
                add(bassb, bass_note(float(mtof(ch_root - 12 + oct_)), step * 0.9, 900, 1.8), ts, 0.62)
            elif pat == "whole" and s == 0:
                add(bassb, bass_note(float(mtof(ch_root - 24)), bar * 0.98, 300, 1.1), ts, 0.7)
            elif pat == "boom" and s in (0, 6, 10):
                n_ = nsamp(step * 4)
                add(bassb, sine(float(mtof(ch_root - 24)), n_) * expdec(n_, 0.4) * 0.9, ts, 0.9)
        # ---- pad
        if sc["pad"]:
            for nt in notes:
                add(padb, pad_note(float(mtof(nt + 0)), bar * 1.02), t0, sc["pad"] * 0.16, r.uniform(-0.6, 0.6))
                add(padb, pad_note(float(mtof(nt + 12)), bar * 1.02, 0.009), t0, sc["pad"] * 0.09, r.uniform(-0.8, 0.8))
        # ---- arp / lead
        arp = sc["arp"]
        if arp:
            tones = notes + [n_ + 12 for n_ in notes] + [notes[0] + 24]
            seq = sc["arp_seq"]
            for s in range(16):
                if arp == "eighth" and s % 2 == 1:
                    continue
                idx = seq[(s // (2 if arp == "eighth" else 1)) % len(seq)]
                f = float(mtof(tones[idx % len(tones)] + 12 * sc.get("arp_oct", 1)))
                add(leadb, pluck(f, step * (3.2 if arp == "eighth" else 2.4), 1.0), t0 + s * step, sc["arp_gain"], ((s % 4) - 1.5) * 0.4)
        if sc.get("keys"):
            for k, nt in enumerate(notes):
                add(leadb, epiano(float(mtof(nt + 12)), beat * 3.6), t0 + (0 if b % 2 == 0 else beat * 0.5) + k * 0.012, sc["keys"] * 0.18, -0.2 + 0.2 * k)
            if b % 2 == 1:
                for k, nt in enumerate(notes):
                    add(leadb, epiano(float(mtof(nt + 12)), beat * 1.8), t0 + beat * 2.5 + k * 0.012, sc["keys"] * 0.12, -0.2 + 0.2 * k)
        if sc.get("melody"):
            mel = sc["melody"]
            if b % 8 >= sc.get("melody_from", 4) % 8 or sc.get("melody_from", 4) == 0:
                for i, (bt, dg, ln) in enumerate(mel[b % len(mel)]):
                    nt = notes[dg % len(notes)] + 12 * (1 + dg // len(notes))
                    n_ = nsamp(ln * beat)
                    t = tt(n_)
                    y = saw(float(mtof(nt)), n_, 16) * np.minimum(1.0, t / 0.01) * np.minimum(1.0, (ln * beat - t) / 0.08)
                    y = lp(y, 3200, 2) * (1 + 0.1 * np.sin(2 * np.pi * 5.5 * t))
                    add(leadb, y, t0 + bt * beat, sc["melody_gain"], 0.15)
        if sc.get("riser") and b in sc["riser"]:
            n_ = nsamp(bar)
            tr = tt(n_) / bar
            ris = M.tv_bq(noise(n_, r), "bp", 300 + 7000 * tr ** 2, 1.5) * tr ** 2
            add(fxb, ris, t0, 0.35)

    # sidechain pumping on pad / lead
    if sc.get("sidechain"):
        duck = np.ones(L)
        tt_ = tt(L)
        for kt in kick_times:
            i = int(kt * SR)
            m = min(L - i, nsamp(0.28))
            if m > 0:
                duck[i:i + m] = np.minimum(duck[i:i + m], 1 - sc["sidechain"] * np.exp(-tt(m) / 0.09))
        for buf in (padb,):
            buf *= duck[:, None]

    # reverb bus (circular convolution so the loop stays seamless)
    wet = padb * 0.9 + leadb * 0.8 + drums * 0.12
    ir_l = M.rev_ir(sc["rt"], r)
    ir_r = M.rev_ir(sc["rt"], r)
    rv = np.stack([M.circ_conv(wet[:, 0], ir_l), M.circ_conv(wet[:, 1], ir_r)], axis=1)
    mix = drums * 1.0 + bassb * 1.0 + padb * 1.0 + leadb * 0.9 + fxb + rv * sc["wet"]
    mix = np.stack([M.circ(lambda z: hp(z, 28, 2), mix[:, c]) for c in range(2)], axis=1)
    mix = soft_limit(mix, 0.92, 0.55)
    mix = mix / (peak(mix) + 1e-9) * 0.52
    return mix


def _melody_a():
    return [[(0, 2, 1.0), (1.5, 4, 0.5), (2, 3, 1.0), (3.25, 2, 0.5)], [(0, 4, 1.5), (2, 3, 0.5), (3, 2, 1.0)],
            [(0, 3, 1.0), (1.5, 2, 0.5), (2, 4, 1.5)], [(0, 5, 0.5), (0.5, 4, 0.5), (1, 3, 1.0), (2, 2, 2.0)]]


@job("menu", "music", 0.0, True, True, 128)
def _music_menu(r):
    prog = [(57, "m"), (53, "M"), (48, "M"), (55, "M")]
    st = dict(kick="half", snare="clap", hats="off", bass="eighths", pad=1.0, arp="sixteenth", arp_seq=[0, 2, 4, 2, 1, 3, 5, 3], arp_gain=0.28, arp_oct=1,
              sidechain=0.35, rt=2.4, wet=0.55, melody=_melody_a(), melody_from=8, melody_gain=0.16, riser=[7, 15])
    return build_track(r, 92, 16, prog, st)


@job("drive", "music", 0.0, True, True, 128)
def _music_drive(r):
    prog = [(52, "m"), (48, "M"), (55, "M"), (50, "M")]
    st = dict(kick="four", snare="clap", hats="off", bass="eighths", pad=1.0, arp="sixteenth", arp_seq=[0, 3, 5, 3, 2, 4, 6, 4], arp_gain=0.30, arp_oct=1,
              sidechain=0.5, rt=1.9, wet=0.45, melody=_melody_a(), melody_from=4, melody_gain=0.2, riser=[3, 7, 11, 15])
    return build_track(r, 118, 16, prog, st)


@job("race", "music", 0.0, True, True, 128)
def _music_race(r):
    prog = [(54, "m"), (50, "M"), (57, "M"), (52, "M")]
    st = dict(kick="four", snare="snare", hats="sixteenth", bass="sixteenth", pad=0.8, arp="sixteenth", arp_seq=[0, 4, 3, 5, 0, 5, 3, 6], arp_gain=0.34, arp_oct=1,
              sidechain=0.6, rt=1.5, wet=0.4, melody=_melody_a(), melody_from=0, melody_gain=0.24, riser=[7, 15])
    return build_track(r, 140, 16, prog, st)


@job("garage", "music", 0.0, True, True, 128)
def _music_garage(r):
    prog = [(50, "m7"), (55, "7"), (48, "M7"), (53, "M7")]
    st = dict(kick="boom", snare="snare", hats="off", bass="boom", pad=0.5, arp=None, arp_seq=[0], arp_gain=0.0, keys=1.0,
              sidechain=0.0, rt=2.0, wet=0.6, riser=[15])
    x = build_track(r, 100, 16, prog, st)
    # vinyl crackle (periodic so the loop stays seamless)
    L = len(x)
    cr = np.zeros(L)
    for i in r.integers(0, L, 900):
        m = nsamp(0.004)
        wplace(cr, noise(m, r) * expdec(m, 0.0008) * r.uniform(0.1, 0.5), i)
    x = x + pan(cr * 0.06, 0.0)
    x = x / (peak(x) + 1e-9) * 0.52
    return x


@job("night", "music", 0.0, True, True, 128)
def _music_night(r):
    prog = [(49, "m"), (45, "M"), (52, "M"), (47, "M")]
    st = dict(kick="half", snare=None, hats="off", bass="whole", pad=1.4, arp="eighth", arp_seq=[0, 2, 1, 3, 2, 4], arp_gain=0.22, arp_oct=1,
              sidechain=0.15, rt=3.2, wet=0.7, riser=[15])
    x = build_track(r, 78, 16, prog, st)
    return x
