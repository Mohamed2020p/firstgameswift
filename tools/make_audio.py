# -*- coding: utf-8 -*-
"""
SUPERCARS audio synthesiser.   python tools/make_audio.py [--only name,name] [--kind engines|sfx|ambience|music|extras] [--plots DIR]

Everything is synthesised with numpy/scipy (no samples, no downloads) and encoded with the installed ffmpeg into
Supercars/Resources/Audio/<name>.m4a   (AAC-LC, mono for sfx/engines, stereo for music/ambience).

* one file for every case of SFX / MusicTrack / AmbienceTrack (parsed from Supercars/Core/Sounds.swift, so a new case without a
  generator is reported), engine layers engine_<type>_<layer>.m4a, plus a few extras (wind_loop, road_loop).
* Resources/Data/engine_audio.json  = engine layer table (refRPM/minRPM/maxRPM/file/loopFrames) + "loops" table for every seamless loop.

LOOP CONVENTION (important for AudioManager): a loop is synthesised as an EXACTLY periodic signal x[0..L).  The encoded file holds
the signal tiled to LOOP_HEAD + L + LOOP_TAIL frames (so AAC encoder delay / priming, whatever the decoder does with it, only ever
touches the head/tail).  The player takes the window [LOOP_HEAD, LOOP_HEAD + L) of the decoded file and loops that: because the
signal is periodic, any rotation of it is a seamless loop and the window never contains priming or padding.
"""
import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time

import numpy as np
from scipy import signal as sg

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Supercars", "Resources", "Audio")
DATA_DIR = os.path.join(ROOT, "Supercars", "Resources", "Data")
SOUNDS_SWIFT = os.path.join(ROOT, "Supercars", "Core", "Sounds.swift")
LOOP_HEAD = 8192
LOOP_TAIL = 4096

# ----------------------------------------------------------------------------------------------------------------------------
# basic helpers
# ----------------------------------------------------------------------------------------------------------------------------


def rng_for(name):
    seed = int.from_bytes(hashlib.md5(name.encode("utf-8")).digest()[:4], "little")
    return np.random.default_rng(seed)


def dbg(x_db):
    return 10.0 ** (x_db / 20.0)


def tt(n):
    return np.arange(n, dtype=np.float64) / SR


def nsamp(seconds):
    return int(round(seconds * SR))


def rms(x):
    return float(np.sqrt(np.mean(np.square(x)) + 1e-30))


def peak(x):
    return float(np.max(np.abs(x)) + 1e-30)


def mtof(m):
    return 440.0 * 2.0 ** ((np.asarray(m, dtype=np.float64) - 69.0) / 12.0)


def _sos(kind, f, order):
    nyq = SR * 0.5
    if kind == "band":
        lo = min(max(f[0], 5.0), nyq * 0.98)
        hi = min(max(f[1], lo * 1.05), nyq * 0.99)
        return sg.butter(order, [lo / nyq, hi / nyq], btype="band", output="sos")
    f = min(max(f, 5.0), nyq * 0.99)
    return sg.butter(order, f / nyq, btype=kind, output="sos")


def lp(x, f, order=2):
    return sg.sosfilt(_sos("low", f, order), x, axis=0)


def hp(x, f, order=2):
    return sg.sosfilt(_sos("high", f, order), x, axis=0)


def bp(x, lo, hi, order=2):
    return sg.sosfilt(_sos("band", (lo, hi), order), x, axis=0)


def biquad(kind, f, q=0.7071, gain_db=0.0):
    f = min(max(f, 5.0), SR * 0.49)
    w0 = 2.0 * math.pi * f / SR
    cw = math.cos(w0)
    sw = math.sin(w0)
    alpha = sw / (2.0 * q)
    A = 10.0 ** (gain_db / 40.0)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "bp":
        b = [alpha, 0.0, -alpha]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "notch":
        b = [1.0, -2 * cw, 1.0]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "peak":
        b = [1 + alpha * A, -2 * cw, 1 - alpha * A]
        a = [1 + alpha / A, -2 * cw, 1 - alpha / A]
    elif kind == "hishelf":
        s = 2.0 * math.sqrt(A) * alpha
        b = [A * ((A + 1) + (A - 1) * cw + s), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - s)]
        a = [(A + 1) - (A - 1) * cw + s, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - s]
    elif kind == "loshelf":
        s = 2.0 * math.sqrt(A) * alpha
        b = [A * ((A + 1) - (A - 1) * cw + s), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - s)]
        a = [(A + 1) + (A - 1) * cw + s, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - s]
    else:
        raise ValueError(kind)
    b = np.array(b, dtype=np.float64) / a[0]
    a = np.array(a, dtype=np.float64) / a[0]
    return b, a


def bq(x, kind, f, q=0.7071, gain_db=0.0):
    b, a = biquad(kind, f, q, gain_db)
    return sg.lfilter(b, a, x, axis=0)


def tv_bq(x, kind, f_curve, q=0.9, block=128):
    """time varying biquad (coefficients switched every `block` samples, state carried)."""
    y = np.empty_like(x)
    zi = np.zeros(2)
    n = len(x)
    fc = np.broadcast_to(np.asarray(f_curve, dtype=np.float64), (n,)) if np.ndim(f_curve) == 0 else np.asarray(f_curve)
    qc = np.broadcast_to(np.asarray(q, dtype=np.float64), (n,)) if np.ndim(q) == 0 else np.asarray(q)
    for s in range(0, n, block):
        e = min(n, s + block)
        m = (s + e) // 2
        b, a = biquad(kind, float(fc[m]), float(qc[m]))
        yb, zi = sg.lfilter(b, a, x[s:e], zi=zi)
        y[s:e] = yb
    return y


def noise(n, r):
    return r.standard_normal(n)


def pink(n, r):
    w = r.standard_normal(n)
    W = np.fft.rfft(w)
    f = np.arange(len(W), dtype=np.float64)
    f[0] = 1.0
    W = W / np.sqrt(f)
    W[0] = 0
    y = np.fft.irfft(W, n)
    return y / (np.std(y) + 1e-12)


def brown(n, r):
    w = r.standard_normal(n)
    W = np.fft.rfft(w)
    f = np.arange(len(W), dtype=np.float64)
    f[0] = 1.0
    W = W / f
    W[0] = 0
    y = np.fft.irfft(W, n)
    return y / (np.std(y) + 1e-12)


def expdec(n, tau):
    return np.exp(-tt(n) / max(tau, 1e-6))


def env_ad(n, attack, tau):
    """attack (linear ramp seconds) then exponential decay with time constant tau."""
    t = tt(n)
    a = np.minimum(1.0, t / max(attack, 1e-5))
    return a * np.exp(-t / max(tau, 1e-6))


def env_asr(n, attack, release):
    """attack ramp, sustain, release ramp (seconds)."""
    e = np.ones(n)
    na = min(n, max(1, nsamp(attack)))
    nr = min(n, max(1, nsamp(release)))
    e[:na] *= np.linspace(0.0, 1.0, na)
    e[n - nr:] *= np.linspace(1.0, 0.0, nr)
    return e


def fade(x, fin=0.002, fout=0.006):
    y = np.array(x, dtype=np.float64, copy=True)
    ni = min(len(y), nsamp(fin))
    no = min(len(y), nsamp(fout))
    if ni > 1:
        w = np.linspace(0.0, 1.0, ni)
        y[:ni] = (y[:ni].T * w).T
    if no > 1:
        w = np.linspace(1.0, 0.0, no)
        y[len(y) - no:] = (y[len(y) - no:].T * w).T
    return y


def sine(f, n, phase=0.0):
    if np.ndim(f) == 0:
        return np.sin(2.0 * np.pi * f * tt(n) + phase)
    ph = 2.0 * np.pi * np.cumsum(np.asarray(f, dtype=np.float64)) / SR
    return np.sin(ph + phase)


def glide(f0, f1, n, log=True):
    if log:
        return f0 * (f1 / f0) ** (np.arange(n) / max(1, n - 1))
    return np.linspace(f0, f1, n)


def modal(n, freqs, decays, amps, phases=None, attack=0.0004):
    """sum of exponentially decaying sine modes (bells, metal, glass, wood)."""
    t = tt(n)
    y = np.zeros(n)
    for i, f in enumerate(freqs):
        d = decays[i] if np.ndim(decays) else decays
        a = amps[i] if np.ndim(amps) else amps
        ph = 0.0 if phases is None else phases[i]
        if f * 2 >= SR:
            continue
        y += a * np.exp(-t / d) * np.sin(2.0 * np.pi * f * t + ph)
    if attack > 0:
        y *= np.minimum(1.0, t / attack)
    return y


def place(dst, src, t, gain=1.0):
    i = int(round(t * SR))
    if i >= len(dst) or i < -len(src):
        return
    s0 = max(0, -i)
    n = min(len(src) - s0, len(dst) - max(i, 0))
    if n <= 0:
        return
    if dst.ndim == 2 and src.ndim == 1:
        dst[max(i, 0):max(i, 0) + n, :] += src[s0:s0 + n, None] * gain
    else:
        dst[max(i, 0):max(i, 0) + n] += src[s0:s0 + n] * gain


def wplace(dst, src, idx, gain=1.0):
    """circular add (dst is a loop buffer)."""
    n = len(dst)
    m = len(src)
    idx = int(idx) % n
    if m >= n:
        src = src[:n]
        m = n
    e = idx + m
    if e <= n:
        dst[idx:e] += src * gain
    else:
        k = n - idx
        dst[idx:] += src[:k] * gain
        dst[:m - k] += src[k:] * gain


def rev_ir(rt60, r, damp=5500.0, predelay=0.012, density=1.0):
    n = int(rt60 * 1.15 * SR) + nsamp(predelay) + 8
    t = tt(n)
    tail = r.standard_normal(n) * np.exp(-6.9078 * t / rt60)
    tail = bq(tail, "lp", damp, 0.6)
    # slow high frequency decay
    tail2 = bq(tail, "lp", damp * 0.35, 0.6)
    mix = np.exp(-t / (rt60 * 0.35))
    tail = tail * (1.0 - 0.6 * mix) + tail2 * (0.6 * mix)
    tail *= np.minimum(1.0, t / 0.004)
    ir = np.zeros(n)
    pd = nsamp(predelay)
    ir[pd:] = tail[:n - pd]
    # a few early reflections
    for k in range(6):
        ir[pd + int(r.uniform(0.002, 0.03) * SR)] += r.uniform(0.3, 0.9) * (1 if r.random() > 0.5 else -1) * density
    ir /= np.sqrt(np.sum(ir ** 2)) + 1e-12
    return ir


def reverb(x, rt60=1.2, wet=0.25, r=None, damp=5500.0, predelay=0.012, extend=True):
    """convolution reverb for a one-shot; returns an extended array (mono in -> mono out, (n,2) in -> (n,2))."""
    if r is None:
        r = np.random.default_rng(1)
    if x.ndim == 1:
        ir = rev_ir(rt60, r, damp, predelay)
        w = sg.fftconvolve(x, ir)
        n = len(w) if extend else len(x)
        out = np.zeros(n)
        out[:len(x)] += x
        out += wet * w[:n] * (rms(x) / (rms(w[:len(x)]) + 1e-12)) * 0.6 if False else 0.0
        out[:min(n, len(w))] += wet * w[:min(n, len(w))] * 2.2
        return out
    outs = []
    for c in range(x.shape[1]):
        outs.append(reverb(x[:, c], rt60, wet, r, damp, predelay, extend))
    return np.stack(outs, axis=1)


def soft_limit(x, ceil=0.89, knee=0.6):
    """transparent below knee*ceil, smooth tanh saturation up to ceil."""
    thr = ceil * knee
    a = np.abs(x)
    over = a > thr
    y = np.array(x, dtype=np.float64, copy=True)
    if np.any(over):
        s = np.sign(x[over])
        y[over] = s * (thr + (ceil - thr) * np.tanh((a[over] - thr) / (ceil - thr)))
    return y


def normalise(x, peak_db):
    p = peak(x)
    return x * (dbg(peak_db) / p)


def trim_tail(x, thresh_db=-62.0, min_len=0.05):
    a = np.max(np.abs(x), axis=1) if x.ndim == 2 else np.abs(x)
    p = a.max() + 1e-30
    idx = np.nonzero(a > p * dbg(thresh_db))[0]
    if len(idx) == 0:
        return x
    end = min(len(x), int(idx[-1]) + nsamp(0.02))
    end = max(end, nsamp(min_len))
    return x[:end]


def circ(fn, x, tiles=3):
    """apply a linear time-invariant function to a PERIODIC signal so that the result is exactly periodic too."""
    L = len(x)
    y = fn(np.tile(x, tiles))
    k = tiles // 2
    return y[k * L:(k + 1) * L]


def circ_conv(x, ir):
    """exact circular convolution of periodic x (n,) or (n,2) with ir (m,) (m may exceed n: wrapped)."""
    n = x.shape[0]
    if len(ir) > n:
        folded = np.zeros(n)
        for s in range(0, len(ir), n):
            seg = ir[s:s + n]
            folded[:len(seg)] += seg
        ir = folded
    H = np.fft.rfft(ir, n)
    if x.ndim == 1:
        return np.fft.irfft(np.fft.rfft(x) * H, n)
    out = np.empty_like(x)
    for c in range(x.shape[1]):
        out[:, c] = np.fft.irfft(np.fft.rfft(x[:, c]) * H, n)
    return out


# ----------------------------------------------------------------------------------------------------------------------------
# registry
# ----------------------------------------------------------------------------------------------------------------------------

JOBS = {}          # name -> dict(kind, fn, peak, loop, stereo, bitrate)


def job(name, kind="sfx", peak_db=-3.0, loop=False, stereo=False, bitrate=None):
    def deco(fn):
        JOBS[name] = dict(kind=kind, fn=fn, peak=peak_db, loop=loop, stereo=stereo, bitrate=bitrate)
        return fn
    return deco


def sfx(name, peak_db=-3.0, loop=False):
    return job(name, "sfx", peak_db, loop, False, 96)


# ----------------------------------------------------------------------------------------------------------------------------
# ENGINES
# ----------------------------------------------------------------------------------------------------------------------------

ENGINE_SPECS = {
    "v6":  dict(cyl=6,  idle=1000, red=8200),
    "v8":  dict(cyl=8,  idle=1100, red=8800),
    "v10": dict(cyl=10, idle=1150, red=9200),
    "v12": dict(cyl=12, idle=1200, red=9000),
    "v16": dict(cyl=16, idle=1250, red=8600),
}

# tone parameters per engine ---------------------------------------------------------------------------------------------------
#  td/ta   : combustion pulse decay / attack (ms)            fp: exhaust pipe resonances (Hz, quarter-wave style combs)
#  g       : pipe feedback                                    form: formant peaks (Hz, dB, Q)
#  lp      : muffler low-pass at full revs (Hz)               intake: intake noise gain             drive: waveshaping
#  whine   : (order, gain) gear/supercharger whine            turbo : list of (order, gain) whistle partials at high revs
ENGINE_TONE = {
    "v6": dict(td=0.30, ta=0.04, fp=(176.0, 261.0), g=0.50, form=[(420, 6, 2.0), (900, 6, 3.0), (2300, 5, 3.0)], lp=3800,
               intake=0.30, drive=1.6, whine=(11, 0.012), turbo=[(9, 0.010), (11, 0.006)], jit=0.075, pops=0.5, thump=0.9),
    "v8":  dict(td=0.36, ta=0.04, fp=(138.0, 207.0), g=0.58, form=[(180, 6, 1.5), (650, 7, 3.0), (1500, 6, 3.0), (3200, 3, 3.0)],
                lp=4800, intake=0.34, drive=1.9, whine=(13, 0.010), turbo=[], jit=0.06, pops=1.0, thump=1.2),
    "v10": dict(td=0.22, ta=0.035, fp=(250.0, 371.0), g=0.46, form=[(400, 4, 2.0), (1200, 6, 3.0), (2200, 9, 4.0), (3600, 8, 4.0), (5200, 4, 3.0)],
                lp=7000, intake=0.28, drive=1.7, whine=(15, 0.012), turbo=[], jit=0.04, pops=0.8, thump=0.8),
    "v12": dict(td=0.18, ta=0.03, fp=(310.0, 466.0), g=0.38, form=[(300, 3, 2.0), (1000, 4, 3.0), (2600, 7, 3.0), (4200, 6, 3.0)],
                lp=7600, intake=0.24, drive=1.4, whine=(17, 0.010), turbo=[], jit=0.018, pops=0.35, thump=0.7),
    "v16": dict(td=0.60, ta=0.06, fp=(92.0, 137.0), g=0.66, form=[(100, 6, 1.3), (300, 5, 2.0), (800, 5, 2.0), (1800, 3, 2.0)],
                lp=2700, intake=0.36, drive=1.6, whine=(19, 0.012), turbo=[(14, 0.020), (17, 0.016), (21, 0.010)], jit=0.025, pops=0.7, thump=1.4),
}


def firing_layout(et, layer):
    """(crank angles in degrees within 720, bank index per cylinder, amplitude weights)."""
    cyl = ENGINE_SPECS[et]["cyl"]
    ang = np.arange(cyl) * (720.0 / cyl)
    bank = np.array([i % 2 for i in range(cyl)])
    w = np.ones(cyl)
    if et == "v8" and layer in ("idle", "decel"):
        # cross-plane V8 (L R L L R L R R): unequal bank spacing -> the famous burble
        bank = np.array([0, 1, 0, 0, 1, 0, 1, 1])
        w = np.array([1.0, 0.86, 0.92, 1.38, 0.86, 0.92, 0.86, 1.38])
    if et == "v10":
        ang = ang + np.array([0.0, 2.0, -2.0, 1.2, -1.2, 2.0, -2.0, 1.2, -1.2, 0.0])
        w = np.array([1.0, 0.95, 1.05, 0.97, 1.03, 1.0, 0.95, 1.05, 0.97, 1.03])
    if et == "v6":
        w = np.array([1.0, 0.94, 1.04, 0.97, 1.05, 0.96])
    return ang, bank, w


def layer_table(et):
    sp = ENGINE_SPECS[et]
    idle = float(sp["idle"])
    red = float(sp["red"])

    def rnd(v):
        return float(int(round(v / 50.0) * 50))
    ref_low = rnd(red * 0.36)
    ref_mid = rnd(red * 0.60)
    ref_high = rnd(red * 0.85)
    ref_dec = rnd(red * 0.52)
    return {
        "idle": dict(ref=idle, lo=600.0, hi=rnd(idle * 1.9)),
        "low": dict(ref=ref_low, lo=rnd(ref_low * 0.6), hi=rnd(ref_low * 1.55)),
        "mid": dict(ref=ref_mid, lo=rnd(ref_mid * 0.62), hi=rnd(ref_mid * 1.5)),
        "high": dict(ref=ref_high, lo=rnd(ref_high * 0.62), hi=rnd(red * 1.08)),
        "decel": dict(ref=ref_dec, lo=1500.0, hi=rnd(red * 1.08)),
    }


def _pulse_kernel(td_ms, ta_ms):
    n = int(SR * td_ms * 1e-3 * 9) + 8
    t = tt(n)
    k = np.exp(-t / (td_ms * 1e-3)) - np.exp(-t / (ta_ms * 1e-3))
    k /= np.sum(k)
    return k


def _add_impulses(buf, times, amps):
    """fractional position impulse insertion (linear interpolation)."""
    idx = np.floor(times).astype(np.int64)
    frac = times - idx
    ok = (idx >= 0) & (idx < len(buf) - 1)
    np.add.at(buf, idx[ok], amps[ok] * (1.0 - frac[ok]))
    np.add.at(buf, idx[ok] + 1, amps[ok] * frac[ok])


def _comb_neg(x, D, g):
    a = np.zeros(D + 1)
    a[0] = 1.0
    a[D] = g          # y[n] = x[n] - g*y[n-D]  (open pipe end: inverted reflection)
    return sg.lfilter([1.0], a, x)


def _engine_chain(et, banks_imp, N, rpm_mean, layer, r, periodic, prm_scale=1.0):
    """impulse trains (one array per bank, in event amplitude) -> exhaust / muffler / formants. Returns mono float array (N)."""
    tone = ENGINE_TONE[et]
    red = ENGINE_SPECS[et]["red"]
    x = min(1.0, rpm_mean / red)
    td = tone["td"] * (1.35 - 0.7 * x)
    kern = _pulse_kernel(td, tone["ta"])
    fp = tone["fp"]
    g = tone["g"] * (0.85 if layer == "decel" else 1.0)
    fc = tone["lp"] * (0.55 + 0.6 * x)
    mixed = np.zeros(N)

    def fn(b_imp, bank_id):
        y = sg.lfilter(kern, [1.0], b_imp)
        d1 = int(SR / (2.0 * fp[0] * (1.0 + 0.035 * bank_id)))
        d2 = int(SR / (2.0 * fp[1] * (1.0 - 0.03 * bank_id)))
        p1 = _comb_neg(y, max(2, d1), g)
        p2 = _comb_neg(y, max(2, d2), g * 0.8)
        z = 0.62 * p1 + 0.38 * p2
        return z

    for bi, b_imp in enumerate(banks_imp):
        if periodic:
            mixed += circ(lambda v, bi=bi: fn(v, bi), b_imp)
        else:
            mixed += fn(b_imp, bi)

    def post(v):
        v = bq(v, "hp", 22.0, 0.7)
        v = lp(v, fc, 2)
        for (f, gdb, q) in tone["form"]:
            gdb_eff = gdb * (0.8 + 0.5 * x) if f > 1000 else gdb
            v = bq(v, "peak", f * (0.85 + 0.25 * x), q, gdb_eff)
        return v
    if periodic:
        mixed = circ(post, mixed)
    else:
        mixed = post(mixed)
    return mixed


def _pop_burst(r, strength=1.0):
    n = nsamp(0.06)
    nz = bp(noise(n, r), 500.0, 3800.0, 2) * np.exp(-tt(n) / 0.006)
    lf = np.sin(2 * np.pi * (120.0 - 400.0 * tt(n)) * tt(n)) * np.exp(-tt(n) / 0.012)
    return (nz * 0.9 + lf * 0.6) * strength


def engine_loop(et, layer, rpm_target, r):
    """one perfectly periodic loop of a running engine at (about) rpm_target.  Returns (samples, actual_rpm)."""
    sp = ENGINE_SPECS[et]
    tone = ENGINE_TONE[et]
    cyl = sp["cyl"]
    C = int(round(SR * 120.0 / rpm_target))
    rpm = 120.0 * SR / C
    nC = max(2, int(round(2.3 * rpm / 120.0)))
    L = C * nC
    x = min(1.0, rpm / sp["red"])
    ang, bank, wcyl = firing_layout(et, layer)
    on = layer != "decel"

    # jitter model: cylinder-to-cylinder amplitude variation is strongest at idle, smoother when revving
    jit = tone["jit"] * (2.4 - 1.6 * x) * (1.4 if layer == "idle" else 1.0) * (1.6 if layer == "decel" else 1.0)
    cyc = np.arange(nC)[:, None]
    base_t = cyc * C + (ang[None, :] / 720.0) * C
    tj = r.standard_normal(base_t.shape) * (0.000018 * SR) * (1.5 - x)         # ~20 us timing jitter
    times = (base_t + tj) % L
    # slow "lope": smooth periodic amplitude drift (integer number of cycles per loop)
    lope = np.ones(nC)
    for k in (1, 2, 3):
        lope += (0.05 if layer == "idle" else 0.025) * (1.4 - x) / k * np.sin(2 * np.pi * (k * np.arange(nC) / nC) + r.uniform(0, 6.28))
    amps = wcyl[None, :] * (1.0 + jit * r.standard_normal(base_t.shape)) * lope[:, None]
    amps = np.clip(amps, 0.25, None)
    if not on:
        amps = amps * 0.42
    banks_imp = []
    for b in (0, 1):
        buf = np.zeros(L * 3)
        m = (bank[None, :] == b) & np.ones_like(amps, dtype=bool)
        t_b = times[m]
        a_b = amps[m]
        for tile in range(3):
            _add_impulses(buf, t_b + tile * L, a_b)
        banks_imp.append(buf)
    # the chain works on the 3-tile signal directly (already periodic) -> take the middle one at the end
    mixed3 = np.zeros(L * 3)
    tone_mix = _engine_chain_tiled(et, banks_imp, L * 3, rpm, layer, r)
    mixed3 += tone_mix
    core = mixed3[L:2 * L]
    core = core / (rms(core) + 1e-12)

    # ---------------- intake / mechanical / noise (all periodic) ----------------
    nz = noise(L, r)
    env_e = np.zeros(L * 3)
    for b in (0, 1):
        env_e += banks_imp[b]
    env_e = circ(lambda v: lp(v, rpm / 60.0 * cyl / 2.0 * 1.3, 2), env_e[L:2 * L])
    env_e = np.clip(env_e / (np.max(env_e) + 1e-12), 0.0, None)
    intake = circ(lambda v: bp(v, 220.0, 2600.0 * (0.6 + 0.6 * x), 2), nz) * (0.45 + 0.9 * env_e)
    intake = intake / (rms(intake) + 1e-12)
    roar = circ(lambda v: bp(v, 90.0, 700.0, 2), noise(L, r))
    roar = roar / (rms(roar) + 1e-12)
    hiss = circ(lambda v: hp(bp(v, 2500.0, 9000.0, 2), 2500.0, 1), noise(L, r))
    hiss = hiss / (rms(hiss) + 1e-12) * (0.5 + 1.5 * x)

    # valve / injector ticks
    ticks = np.zeros(L)
    n_ticks = int(nC * cyl / 2 * 2)
    for _ in range(n_ticks):
        pos = int(r.integers(0, L))
        tk = bp(noise(nsamp(0.004), r), 2500.0, 9000.0, 1) * np.exp(-tt(nsamp(0.004)) / 0.0009)
        wplace(ticks, tk, pos, r.uniform(0.3, 1.0))
    ticks = ticks / (rms(ticks) + 1e-12)

    # gear / supercharger whine (integer orders of the crank frequency => periodic)
    rev_hz = rpm / 60.0
    whine_order, whine_g = tone["whine"]
    t = tt(L)
    whine = np.sin(2 * np.pi * whine_order * rev_hz * t) + 0.4 * np.sin(2 * np.pi * (whine_order * 2) * rev_hz * t + 1.1)
    whine *= 1.0 + 0.15 * np.sin(2 * np.pi * 3 * t / (L / SR))
    whine = whine / (rms(whine) + 1e-12)

    mix = core * 1.0
    mix += intake * tone["intake"] * 0.30 * (0.9 if on else 0.35) * (0.35 + 0.65 * x)
    mix += roar * (0.05 + 0.10 * x) * (1.0 if on else 0.6)
    mix += hiss * 0.012 * (1.0 if on else 0.4)
    mix += ticks * (0.05 if layer == "idle" else 0.015)
    mix += whine * whine_g * (0.4 + 1.2 * x)

    # turbo whistle (quad-turbo V16 at high revs, a touch of it on the V6)
    if tone["turbo"] and layer in ("mid", "high", "decel"):
        amt = {"mid": 0.55, "high": 1.0, "decel": 0.35}[layer]
        for i, (order, gg) in enumerate(tone["turbo"]):
            wob = 1.0 + 0.25 * np.sin(2 * np.pi * (3 + i) * t / (L / SR) + i)
            mix += gg * amt * wob * np.sin(2 * np.pi * order * rev_hz * t + 0.7 * i) * (1.0 + 0.4 * x)

    # exhaust pops / burble on the over-run
    if layer == "decel":
        pops = np.zeros(L)
        count = int(nC * 0.35 * tone["pops"]) + 2
        for _ in range(count):
            pos = int(r.integers(0, L))
            wplace(pops, _pop_burst(r, r.uniform(0.35, 1.0)), pos)
        mix += pops * 0.25

    # a bit of drive (the "engine is working hard" edge) then re-filter
    drive = tone["drive"] * (0.55 + 0.6 * x if on else 0.5) * 0.75
    s_arg = mix / (rms(mix) * 2.4 + 1e-9)
    mix = np.tanh(drive * s_arg) / np.tanh(drive)
    mix = circ(lambda v: lp(v, min(14000.0, tone["lp"] * (0.9 + 1.2 * x) + 2500), 2), mix)
    mix -= np.mean(mix)

    tgt_rms = {"idle": -25.0, "low": -23.5, "mid": -22.0, "high": -21.0, "decel": -24.5}[layer]
    mix = mix * (dbg(tgt_rms) / (rms(mix) + 1e-12))
    mix = soft_limit(mix, dbg(-8.0), 0.55)
    return mix, rpm


def _engine_chain_tiled(et, banks_imp3, N, rpm, layer, r):
    """like _engine_chain but the impulse trains are already tiled (periodic) so plain filtering is enough."""
    tone = ENGINE_TONE[et]
    red = ENGINE_SPECS[et]["red"]
    x = min(1.0, rpm / red)
    td = tone["td"] * (1.35 - 0.7 * x)
    kern = _pulse_kernel(td, tone["ta"])
    fp = tone["fp"]
    g = tone["g"] * (0.85 if layer == "decel" else 1.0)
    fc = tone["lp"] * (0.55 + 0.6 * x)
    out = np.zeros(N)
    for bi, b_imp in enumerate(banks_imp3):
        y = sg.lfilter(kern, [1.0], b_imp)
        d1 = int(SR / (2.0 * fp[0] * (1.0 + 0.035 * bi)))
        d2 = int(SR / (2.0 * fp[1] * (1.0 - 0.03 * bi)))
        p1 = _comb_neg(y, max(2, d1), g)
        p2 = _comb_neg(y, max(2, d2), g * 0.8)
        out += 0.62 * p1 + 0.38 * p2
    out = bq(out, "hp", 22.0, 0.7)
    out = lp(out, fc, 2)
    for (f, gdb, q) in tone["form"]:
        gdb_eff = gdb * (0.8 + 0.5 * x) if f > 1000 else gdb
        out = bq(out, "peak", f * (0.85 + 0.25 * x), q, gdb_eff)
    return out


def engine_variable(et, rpm_curve, fire_amp, n, r, tail_noise=0.0):
    """non periodic engine with a time varying rpm curve (array n).  fire_amp: per-sample combustion strength 0..1.
    Used for start / stop / rev sounds.  Returns mono (n)."""
    sp = ENGINE_SPECS[et]
    tone = ENGINE_TONE[et]
    cyl = sp["cyl"]
    ang, bank, wcyl = firing_layout(et, "high")
    phase = np.cumsum(np.maximum(rpm_curve, 0.0) / 120.0 / SR)      # crank cycles (720 deg each)
    total = phase[-1]
    banks_imp = [np.zeros(n), np.zeros(n)]
    sample_idx = np.arange(n, dtype=np.float64)
    for c in range(int(total) + 1):
        for i in range(cyl):
            target = c + ang[i] / 720.0
            if target >= total:
                continue
            tpos = float(np.interp(target, phase, sample_idx))
            ia = int(min(n - 1, max(0, tpos)))
            a = fire_amp[ia] * wcyl[i] * (1.0 + tone["jit"] * 2.0 * r.standard_normal())
            if a <= 0:
                continue
            b = int(bank[i])
            _add_impulses(banks_imp[b], np.array([tpos]), np.array([a]))
    rpm_mean = float(np.mean(rpm_curve[fire_amp > 0.05])) if np.any(fire_amp > 0.05) else 1000.0
    core = _engine_chain(et, banks_imp, n, rpm_mean, "high", r, False)
    core = core / (rms(core) + 1e-12) * 0.6
    return core


# ---- engine files ------------------------------------------------------------------------------------------------------------

ENGINE_INFO = {}   # filled while generating: (et, layer) -> dict(rpm, L)


def make_engine_job(et, layer):
    name = "engine_%s_%s" % (et, layer)

    def fn(r):
        table = layer_table(et)[layer]
        x, rpm = engine_loop(et, layer, table["ref"], r)
        ENGINE_INFO[(et, layer)] = dict(rpm=rpm, L=len(x))
        return x
    JOBS[name] = dict(kind="engine", fn=fn, peak=-8.0, loop=True, stereo=False, bitrate=112)


for _et in ENGINE_SPECS:
    for _ly in ("idle", "low", "mid", "high", "decel"):
        make_engine_job(_et, _ly)

# ==== INSERT: SFX ====
# ==== INSERT: AMBIENCE ====
# ==== INSERT: MUSIC ====

# ----------------------------------------------------------------------------------------------------------------------------
# encoding / verification / main
# ----------------------------------------------------------------------------------------------------------------------------

_ENC = None


def pick_encoder():
    global _ENC
    if _ENC is not None:
        return _ENC
    try:
        txt = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True).stdout.decode("utf-8", "ignore")
    except OSError:
        raise SystemExit("ffmpeg not found in PATH")
    if "libfdk_aac" in txt:
        _ENC = ["-c:a", "libfdk_aac"]
    elif "libvo_aacenc" in txt:
        _ENC = ["-c:a", "libvo_aacenc"]
    else:
        _ENC = ["-c:a", "aac", "-strict", "experimental"]
    return _ENC


def to_int16(x):
    return np.clip(np.round(x * 32767.0), -32768, 32767).astype("<i2")


def encode_m4a(path, pcm, channels, bitrate_k):
    data = to_int16(pcm).tobytes()
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "s16le", "-ar", str(SR), "-ac", str(channels), "-i", "pipe:0"]
    cmd += pick_encoder()
    cmd += ["-b:a", "%dk" % bitrate_k, "-ar", str(SR), "-ac", str(channels), path]
    p = subprocess.run(cmd, input=data, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg failed for %s: %s" % (path, p.stderr.decode("utf-8", "ignore")[-400:]))


def decode_m4a(path):
    p = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-f", "f32le", "-ar", str(SR), "-"], capture_output=True)
    ch = 1
    pr = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=channels", "-of", "csv=p=0", path],
                        capture_output=True)
    try:
        ch = int(pr.stdout.decode().strip())
    except ValueError:
        ch = 1
    a = np.frombuffer(p.stdout, dtype="<f4").astype(np.float64)
    if ch > 1:
        a = a[:len(a) // ch * ch].reshape(-1, ch)
    return a


def build_file_signal(x, loop):
    """periodic loop -> file signal (head + loop + tail); one shot -> as is."""
    if not loop:
        return x
    L = len(x)
    total = LOOP_HEAD + L + LOOP_TAIL
    reps = int(math.ceil(total / L)) + 1
    tiled = np.tile(x, (reps, 1)) if x.ndim == 2 else np.tile(x, reps)
    return tiled[:total]


def parse_swift_cases():
    with open(SOUNDS_SWIFT, "r", encoding="utf-8") as f:
        src = f.read()
    names = []
    for m in re.finditer(r"enum\s+(SFX|MusicTrack|AmbienceTrack)\s*:\s*String[^{]*\{(.*?)\n\}", src, re.S):
        body = m.group(2)
        for line in body.splitlines():
            line = line.split("//")[0].strip()
            if line.startswith("case "):
                for nm in line[5:].split(","):
                    nm = nm.strip()
                    if nm:
                        names.append((m.group(1), nm))
    return names


def run_job(name, spec, plots_dir=None):
    r = rng_for(name)
    x = spec["fn"](r)
    x = np.asarray(x, dtype=np.float64)
    loop = spec["loop"]
    if not loop:
        x = trim_tail(x)
        x = fade(x, 0.0005, 0.012)
    x = np.nan_to_num(x)
    x = x - np.mean(x, axis=0) * (1.0 if not spec["kind"] in ("music",) else 1.0)
    if spec["kind"] == "music":
        pass
    else:
        x = normalise(x, spec["peak"])
    x = np.clip(x, -0.999, 0.999)
    ch = 2 if x.ndim == 2 else 1
    fs = build_file_signal(x, loop)
    path = os.path.join(OUT_DIR, name + ".m4a")
    encode_m4a(path, fs, ch, spec["bitrate"] or (96 if ch == 1 else 128))
    info = dict(name=name, kind=spec["kind"], frames=len(x), ch=ch, loop=loop, size=os.path.getsize(path))
    if loop:
        d = np.abs(x[0] - x[-1]) if x.ndim == 1 else float(np.max(np.abs(x[0] - x[-1])))
        dif = np.diff(x, axis=0)
        info["seam"] = float(d / (np.sqrt(np.mean(dif ** 2)) + 1e-12))
    dec = decode_m4a(path)
    info["dec_peak_db"] = 20 * math.log10(peak(dec) + 1e-12)
    info["src_peak_db"] = 20 * math.log10(peak(x) + 1e-12)
    info["dur"] = len(x) / SR
    if plots_dir:
        plot_spec(name, x, plots_dir)
    return info


def plot_spec(name, x, plots_dir):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        return
    m = x if x.ndim == 1 else x.mean(axis=1)
    if len(m) > SR * 20:
        m = m[:SR * 20]
    fig, ax = plt.subplots(2, 1, figsize=(11, 6))
    f, t, S = sg.spectrogram(m, SR, nperseg=2048, noverlap=1536)
    ax[0].pcolormesh(t, f, 10 * np.log10(S + 1e-14), vmin=-110, vmax=-30, shading="auto")
    ax[0].set_ylim(0, 10000)
    ax[0].set_title(name)
    ax[1].plot(np.arange(len(m)) / SR, m, lw=0.4)
    os.makedirs(plots_dir, exist_ok=True)
    fig.tight_layout()
    fig.savefig(os.path.join(plots_dir, name + ".png"), dpi=70)
    plt.close(fig)


def write_engine_json(existing_only=False):
    path = os.path.join(DATA_DIR, "engine_audio.json")
    os.makedirs(DATA_DIR, exist_ok=True)
    doc = {}
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                doc = json.load(f)
        except Exception:
            doc = {}
    for et, sp in ENGINE_SPECS.items():
        table = layer_table(et)
        layers = []
        decel = None
        for ly in ("idle", "low", "mid", "high", "decel"):
            info = ENGINE_INFO.get((et, ly))
            prev = None
            if et in doc:
                for e in doc[et].get("layers", []) + ([doc[et]["decel"]] if "decel" in doc[et] else []):
                    if e.get("layer") == ly:
                        prev = e
            t = table[ly]
            entry = dict(layer=ly, file="engine_%s_%s" % (et, ly), refRPM=t["ref"], minRPM=t["lo"], maxRPM=t["hi"])
            if info is not None:
                entry["loopFrames"] = int(info["L"])
                entry["synthRPM"] = round(float(info["rpm"]), 2)
            elif prev is not None:
                entry["loopFrames"] = prev.get("loopFrames", 0)
                entry["synthRPM"] = prev.get("synthRPM", t["ref"])
            else:
                continue
            if ly == "decel":
                decel = entry
            else:
                layers.append(entry)
        if layers or decel:
            doc[et] = dict(layers=layers, idleRPM=sp["idle"], redlineRPM=sp["red"])
            if decel:
                doc[et]["decel"] = decel
    doc["loopHead"] = LOOP_HEAD
    doc["loopTail"] = LOOP_TAIL
    return path, doc


LOOPS = {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma separated names (prefix match allowed with *)")
    ap.add_argument("--kind", default="", help="engine|sfx|ambience|music|extra")
    ap.add_argument("--plots", default="", help="write spectrogram PNGs to this directory")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    os.makedirs(OUT_DIR, exist_ok=True)

    # coverage check against Sounds.swift
    missing = []
    for enum, nm in parse_swift_cases():
        if nm not in JOBS:
            missing.append("%s.%s" % (enum, nm))
    if missing:
        print("WARNING: no generator for: " + ", ".join(missing))
    if args.list:
        for k, v in JOBS.items():
            print(k, v["kind"])
        return

    names = list(JOBS.keys())
    if args.kind:
        names = [n for n in names if JOBS[n]["kind"] == args.kind]
    if args.only:
        pats = [p.strip() for p in args.only.split(",") if p.strip()]
        sel = []
        for n in names:
            for p in pats:
                if p.endswith("*") and n.startswith(p[:-1]) or n == p:
                    sel.append(n)
                    break
        names = sel

    infos = []
    t0 = time.time()
    for n in names:
        t1 = time.time()
        try:
            info = run_job(n, JOBS[n], args.plots or None)
        except Exception as e:                       # keep going, report at the end
            import traceback
            traceback.print_exc()
            print("FAILED", n, e)
            continue
        infos.append(info)
        print("  %-26s %6.2fs %8.1f KB  peak %6.1f dBFS  (%.1fs)" % (n, info["dur"], info["size"] / 1024.0, info["dec_peak_db"], time.time() - t1))
        sys.stdout.flush()

    # engine + loop tables
    path, doc = write_engine_json()
    loops = doc.get("loops", {})
    for info in infos:
        if info["loop"]:
            loops[info["name"]] = dict(loopFrames=int(info["frames"]), channels=info["ch"])
    doc["loops"] = loops
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)

    # summary
    print("\n%-26s %-8s %8s %6s %9s %8s %s" % ("file", "kind", "sec", "ch", "KB", "peak dB", "seam"))
    total = 0
    for info in infos:
        total += info["size"]
        print("%-26s %-8s %8.2f %6d %9.1f %8.1f %s" % (info["name"], info["kind"], info["dur"], info["ch"], info["size"] / 1024.0,
                                                      info["dec_peak_db"], ("%.2f" % info["seam"]) if "seam" in info else ""))
    print("total this run: %.2f MB in %d files (%.0fs)" % (total / 1048576.0, len(infos), time.time() - t0))
    allsize = sum(os.path.getsize(os.path.join(OUT_DIR, f)) for f in os.listdir(OUT_DIR) if f.endswith(".m4a"))
    print("Audio folder total: %.2f MB" % (allsize / 1048576.0))


if __name__ == "__main__":
    main()
