# -*- coding: utf-8 -*-
"""SUPERCARS sound effects, UI sounds and extras (registered into make_audio.JOBS).  Pure numpy/scipy synthesis."""
import numpy as np
from scipy import signal as sg

import make_audio as M
from make_audio import (SR, tt, nsamp, noise, pink, brown, expdec, env_ad, sine, glide, modal, place, wplace, lp, hp, bp, bq, reverb,
                        soft_limit, fade, circ, rms, peak, dbg, mtof, sfx, job)

# ----------------------------------------------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------------------------------------------


def pnoise(n, r, shape=None):
    """exactly periodic noise (random phases in the frequency domain) with an optional magnitude shape(f)."""
    W = r.standard_normal(n // 2 + 1) + 1j * r.standard_normal(n // 2 + 1)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    if shape is not None:
        W = W * shape(f)
    W[0] = 0
    y = np.fft.irfft(W, n)
    return y / (np.std(y) + 1e-12)


def band(fc, bw):
    return lambda f: 1.0 / (1.0 + ((f - fc) / bw) ** 2)


def lowshape(fc, order=2):
    return lambda f: 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def highshape(fc, order=2):
    return lambda f: 1.0 / np.sqrt(1.0 + (fc / np.maximum(f, 1.0)) ** (2 * order))


def S(*xs):
    """sum of signals of different lengths (zero padded)"""
    n = max(len(x) for x in xs)
    y = np.zeros(n)
    for x in xs:
        y[:len(x)] += x
    return y


def click(n, r, fc=3000, tau=0.0015, gain=1.0):
    """tiny broadband tick"""
    x = noise(n, r) * expdec(n, tau)
    return bp(x, fc * 0.5, fc * 2.0) * gain


def thump(n, f0=90.0, f1=45.0, tau=0.06):
    fr = glide(f0, f1, n)
    return sine(fr, n) * expdec(n, tau)


def saw(f, n, nh=30, phase=0.0):
    t = tt(n)
    y = np.zeros(n)
    k = 1
    while k <= nh and f * k < SR * 0.45:
        y += np.sin(2 * np.pi * f * k * t + phase * k) / k
        k += 1
    return y * (2 / np.pi)


def square(f, n, nh=25):
    t = tt(n)
    y = np.zeros(n)
    k = 1
    while k <= nh and f * k < SR * 0.45:
        y += np.sin(2 * np.pi * f * k * t) / k
        k += 2
    return y * (4 / np.pi)


def bell(freq, dur, r, bright=1.0, decay=1.0):
    n = nsamp(dur)
    ratios = [1.0, 2.0, 2.76, 4.07, 5.4, 6.8]
    amps = [1.0, 0.5 * bright, 0.35 * bright, 0.2 * bright, 0.12 * bright, 0.07 * bright]
    dec = [0.9 * decay, 0.6 * decay, 0.4 * decay, 0.3 * decay, 0.2 * decay, 0.12 * decay]
    return modal(n, [freq * q for q in ratios], dec, amps, phases=[r.uniform(0, 6.28) for _ in ratios], attack=0.0008)


def pluck(freq, dur, bright=1.0):
    n = nsamp(dur)
    y = saw(freq, n, nh=18) * expdec(n, dur * 0.35)
    fc = np.linspace(min(9000, freq * 10 * bright), freq * 2.0, n)
    return M.tv_bq(y, "lp", fc, 0.8)


def engine_tone(rpm_curve, cyl, n, r, gain=1.0, jitter=0.05):
    """firing-pulse engine sound for start / stop transitions."""
    fire = rpm_curve / 60.0 * cyl * 0.5
    ph = np.cumsum(fire) / SR
    idx = np.nonzero(np.diff(np.floor(ph)) > 0)[0]
    imp = np.zeros(n)
    for i in idx:
        imp[i] = 1.0 + r.normal(0, jitter) * 4
    kn = nsamp(0.028)
    kt = tt(kn)
    kernel = np.exp(-kt / 0.006) * np.sin(2 * np.pi * 75 * kt + 0.4) + 0.5 * np.exp(-kt / 0.002) * np.sin(2 * np.pi * 210 * kt)
    y = sg.fftconvolve(imp, kernel)[:n]
    y = bq(y, "peak", 130, 1.2, 6)
    y = bq(y, "peak", 320, 1.6, 5)
    y = bq(y, "peak", 900, 2.0, 4)
    y = np.tanh(y * 2.2 / (np.max(np.abs(y)) + 1e-9)) * 0.7
    y = y + 0.15 * bp(noise(n, r), 300, 1800) * np.abs(y)
    return y * gain


# ----------------------------------------------------------------------------------------------------------------------------
# CAR
# ----------------------------------------------------------------------------------------------------------------------------


@sfx("engineStart", -3.0)
def _engine_start(r):
    n = nsamp(2.3)
    t = tt(n)
    # starter motor: whirr with growing pitch, cranking pulses (compression strokes)
    crank_rpm = np.minimum(220.0, 60.0 + 260.0 * (1 - np.exp(-t / 0.35)))
    crank_rpm[t > 1.15] = 0
    starter_f = 70 + crank_rpm * 0.7
    ph = np.cumsum(starter_f) / SR
    starter = sum(np.sin(2 * np.pi * ph * k) / k for k in (1, 2, 3, 5, 7)) * 0.25
    starter = bq(starter, "peak", 900, 2.0, 5)
    starter *= np.where(t < 1.15, 1.0, 0.0) * np.minimum(1.0, t / 0.08)
    # compression pulses
    rate = np.where(t < 1.15, crank_rpm / 60.0 * 4 / 2.0, 0.0)
    pulses = np.zeros(n)
    phase = np.cumsum(rate) / SR
    for i in np.nonzero(np.diff(np.floor(phase)) > 0)[0]:
        seg = nsamp(0.09)
        pulses[i:i + seg] += (thump(min(seg, n - i), 95, 50, 0.03) * 0.6)[:max(0, min(seg, n - i))]
    # ignition: rpm jumps up then settles at idle
    rpm = np.where(t < 1.15, 0.0, 1150 + 1500 * np.exp(-(t - 1.15) / 0.28))
    rpm = np.maximum(rpm, 1.0)
    eng = engine_tone(rpm, 8, n, r, gain=1.0, jitter=0.08) * np.where(t >= 1.13, 1.0, 0.0)
    eng *= np.minimum(1.0, (t - 1.13) / 0.05).clip(0, 1)
    boom = thump(n, 70, 40, 0.09) * np.where(t >= 1.15, 1.0, 0.0)
    boom = np.roll(boom, nsamp(1.15))
    boom[:nsamp(1.15)] = 0
    y = 0.55 * starter + 0.55 * pulses + 1.3 * eng + 0.7 * boom
    return reverb(y, 0.35, 0.10, r)


@sfx("engineStop", -3.0)
def _engine_stop(r):
    n = nsamp(1.6)
    t = tt(n)
    rpm = 1100.0 * np.exp(-t / 0.28)
    rpm[t > 0.9] = 1.0
    rpm = np.maximum(rpm, 1.0)
    y = engine_tone(rpm, 8, n, r, gain=1.0, jitter=0.12) * np.where(t < 0.85, 1.0, 0.0) * np.clip((0.85 - t) / 0.2, 0, 1)
    tick = np.zeros(n)
    for k, tm in enumerate([0.9, 1.18, 1.32]):
        place(tick, S(bp(noise(nsamp(0.05), r), 200, 3000) * expdec(nsamp(0.05), 0.01), thump(nsamp(0.08), 120, 60, 0.02)), tm, 0.5 / (k + 1))
    return reverb(y + tick, 0.3, 0.1, r)


@sfx("exhaustPop", -3.0)
def _exhaust_pop(r):
    n = nsamp(0.5)
    y = np.zeros(n)
    for tm, g in ((0.0, 1.0), (0.085, 0.55), (0.17, 0.3)):
        m = nsamp(0.2)
        c = hp(noise(m, r), 700) * expdec(m, 0.012) + 0.8 * thump(m, 130, 60, 0.03) + 0.4 * bp(noise(m, r), 1500, 5000) * expdec(m, 0.004)
        place(y, c, tm, g)
    return reverb(y, 0.4, 0.12, r)


@sfx("gearShift", -4.0)
def _gear_shift(r):
    n = nsamp(0.3)
    y = thump(n, 110, 55, 0.035) * 0.9
    place(y, modal(nsamp(0.1), [1300, 2350, 3900], [0.02, 0.012, 0.008], [1.0, 0.6, 0.3]), 0.012, 0.8)
    place(y, click(nsamp(0.05), r, 4000, 0.002), 0.0, 1.2)
    place(y, thump(nsamp(0.12), 90, 50, 0.03), 0.09, 0.5)
    return y


@sfx("turboWhoosh", -3.0)
def _turbo(r):
    n = nsamp(1.5)
    t = tt(n)
    env = np.minimum(1.0, t / 0.35) * np.exp(-np.maximum(0, t - 0.45) / 0.5)
    fc = 700 + 4800 * np.minimum(1.0, t / 0.6)
    w = M.tv_bq(noise(n, r), "bp", fc, 1.6)
    whistle = sine(3600 + 2600 * np.minimum(1.0, t / 0.5), n) * 0.07 + sine(5400 + 3200 * np.minimum(1.0, t / 0.5), n) * 0.03
    y = (w * 0.7 + whistle) * env
    # blow-off flutter
    m = nsamp(0.5)
    flutter = hp(noise(m, r), 2500) * expdec(m, 0.11) * (0.6 + 0.4 * np.sin(2 * np.pi * 34 * tt(m)))
    place(y, flutter, 0.55, 0.9)
    return y


@sfx("horn", -3.0)
def _horn(r):
    n = nsamp(1.1)
    t = tt(n)
    y = (saw(415, n, 14) + 0.9 * saw(523, n, 14) + 0.5 * saw(330, n, 10)) * 0.4
    y = bq(y, "peak", 1400, 2.0, 6)
    y = bq(y, "lp", 3800)
    env = np.minimum(1.0, t / 0.02) * np.minimum(1.0, (1.1 - t) / 0.04)
    return np.tanh(y * 1.5) * env


@sfx("headlightClick", -5.0)
def _headlight(r):
    n = nsamp(0.15)
    y = click(n, r, 2600, 0.002)
    place(y, click(nsamp(0.05), r, 1800, 0.002), 0.045, 0.7)
    place(y, modal(nsamp(0.08), [1800, 3600], [0.012, 0.006], [1.0, 0.4]), 0.0, 0.6)
    return y


@sfx("tyreSkidAsphalt", -4.0, loop=True)
def _skid_asphalt(r):
    L = nsamp(2.0)
    base = pnoise(L, r, band(2600, 900))
    hiss = pnoise(L, r, highshape(4500, 2)) * 0.25
    t = tt(L)
    am = 0.72 + 0.28 * np.sin(2 * np.pi * 7.0 * t) * np.sin(2 * np.pi * 3.0 * t + 0.6)
    sq = 0.0
    for f0, g in ((1250.0, 0.35), (1870.0, 0.25), (2510.0, 0.15)):
        f0 = round(f0 * 2.0) / 2.0
        wob = 1 + 0.015 * np.sin(2 * np.pi * 5.0 * t)
        ph = np.cumsum(f0 * wob) / SR
        ph = ph - ph[-1] * (np.arange(L) / L)      # make phase periodic
        sq = sq + g * np.sin(2 * np.pi * ph)
    y = (base * 0.6 + hiss + sq * 0.9) * am
    return y


@sfx("tyreSkidGrass", -5.0, loop=True)
def _skid_grass(r):
    L = nsamp(2.0)
    y = pnoise(L, r, band(900, 700)) * 0.7 + pnoise(L, r, lowshape(220)) * 0.6
    t = tt(L)
    y *= 0.75 + 0.25 * np.sin(2 * np.pi * 4.0 * t + 1.1)
    crackles = np.zeros(L)
    for i in r.integers(0, L, 260):
        wplace(crackles, click(nsamp(0.012), r, 3500, 0.0025), i, r.uniform(0.2, 0.7))
    return y + 0.4 * crackles


@sfx("kerbRumble", -3.0, loop=True)
def _kerb(r):
    L = nsamp(1.0)
    t = tt(L)
    f = 32.0
    car = np.maximum(0.0, np.sin(2 * np.pi * f * t)) ** 2
    y = pnoise(L, r, band(90, 60)) * (0.35 + 0.65 * car)
    y += 0.55 * np.sin(2 * np.pi * 64 * t) * car + 0.3 * np.sin(2 * np.pi * 96 * t + 0.4) * car
    y += 0.25 * pnoise(L, r, band(400, 250)) * car
    return circ(lambda z: lp(z, 700), y)


@sfx("gravelRoll", -4.0, loop=True)
def _gravel(r):
    L = nsamp(2.0)
    y = np.zeros(L)
    for i in r.integers(0, L, 2200):
        m = nsamp(r.uniform(0.004, 0.012))
        wplace(y, bp(noise(m, r), r.uniform(1200, 3500), r.uniform(3500, 8000)) * expdec(m, 0.002) * r.uniform(0.2, 1.0), i)
    y += 0.35 * pnoise(L, r, band(800, 500))
    return y


def _crash(r, heavy):
    dur = 2.2 if heavy else 1.1
    n = nsamp(dur)
    y = np.zeros(n)
    low = 52.0 if heavy else 88.0
    body = thump(nsamp(0.4), low * 1.6, low, 0.11 if heavy else 0.06) * (1.5 if heavy else 1.1)
    place(y, body, 0.0)
    place(y, bp(noise(nsamp(0.08), r), 300, 5000) * expdec(nsamp(0.08), 0.008), 0.0, 1.6)
    freqs = [r.uniform(130, 260), r.uniform(320, 520), r.uniform(600, 900), r.uniform(1100, 1500), r.uniform(1800, 2500), r.uniform(2900, 3800), r.uniform(4200, 5600)]
    if heavy:
        freqs = [r.uniform(70, 110), r.uniform(140, 200)] + freqs
    dec = [r.uniform(0.09, 0.4) * (1.6 if heavy else 1.0) for _ in freqs]
    amps = [r.uniform(0.3, 1.0) / (1 + 0.25 * i) for i in range(len(freqs))]
    place(y, modal(nsamp(dur), freqs, dec, amps), 0.003, 0.9)
    # crumple / debris rattle
    for k in range(60 if heavy else 26):
        tm = 0.03 + r.exponential(0.28 if heavy else 0.14)
        if tm > dur - 0.1:
            continue
        m = nsamp(r.uniform(0.01, 0.05))
        c = modal(m, [r.uniform(600, 4200)], [r.uniform(0.006, 0.03)], [1.0]) * r.uniform(0.15, 0.6)
        place(y, c, tm)
    return reverb(y, 1.4 if heavy else 0.7, 0.14 if heavy else 0.1, r)


@sfx("crashMetalLight", -2.0)
def _crash_light(r):
    return _crash(r, False)


@sfx("crashMetalHeavy", -1.0)
def _crash_heavy(r):
    return _crash(r, True)


@sfx("crashGlass", -3.0)
def _crash_glass(r):
    n = nsamp(1.6)
    y = np.zeros(n)
    place(y, hp(noise(nsamp(0.06), r), 1800) * expdec(nsamp(0.06), 0.012), 0.0, 1.4)
    place(y, thump(nsamp(0.1), 320, 120, 0.02), 0.0, 0.5)
    for k in range(190):
        tm = r.exponential(0.22) + 0.005
        if tm > 1.4:
            continue
        m = nsamp(r.uniform(0.04, 0.2))
        f = r.uniform(2600, 9500)
        c = modal(m, [f, f * r.uniform(1.4, 2.2)], [r.uniform(0.01, 0.07)] * 2, [1.0, 0.4]) * r.uniform(0.15, 0.7) * np.exp(-tm * 1.4)
        place(y, c, tm)
    return reverb(y, 0.6, 0.12, r)


@sfx("scrape", -3.0)
def _scrape(r):
    n = nsamp(1.2)
    t = tt(n)
    fc = 1600 + 900 * np.sin(2 * np.pi * 1.7 * t) + 600 * np.sin(2 * np.pi * 5.3 * t + 1)
    w = M.tv_bq(noise(n, r), "bp", fc, 2.6)
    stick = 0.55 + 0.45 * (np.sin(2 * np.pi * 78 * t) > 0)
    tone = sine(1300 + 400 * np.sin(2 * np.pi * 3.1 * t), n) * 0.25 + sine(2600 + 500 * np.sin(2 * np.pi * 2.3 * t), n) * 0.12
    env = np.minimum(1.0, t / 0.06) * np.minimum(1.0, (1.2 - t) / 0.35)
    return (w * 0.9 + tone) * stick * env


@sfx("lampBend", -3.0)
def _lamp_bend(r):
    n = nsamp(1.1)
    t = tt(n)
    f = 210 - 90 * t + 6 * np.sin(2 * np.pi * 9 * t)
    ph = np.cumsum(f) / SR
    y = sum(np.sin(2 * np.pi * ph * k) / k for k in (1, 2, 3, 4, 6))
    y = M.tv_bq(y, "bp", 500 + 500 * np.sin(2 * np.pi * 2.2 * t), 3.5)
    env = np.minimum(1.0, t / 0.05) * np.minimum(1.0, (1.1 - t) / 0.3)
    out = y * env * 0.7
    place(out, S(bp(noise(nsamp(0.05), r), 300, 4000) * expdec(nsamp(0.05), 0.01), thump(nsamp(0.2), 100, 55, 0.05)), 0.0, 1.0)
    return reverb(out, 0.5, 0.1, r)


@sfx("lampFall", -2.0)
def _lamp_fall(r):
    n = nsamp(2.0)
    y = np.zeros(n)
    tones = [230, 617, 1190, 1930, 2760]
    for k, tm in enumerate([0.0, 0.3, 0.52, 0.68, 0.79, 0.86]):
        g = 1.0 / (1 + 1.6 * k)
        m = nsamp(1.4)
        c = modal(m, [f * r.uniform(0.98, 1.02) for f in tones], [1.1, 0.8, 0.55, 0.4, 0.25], [1.0, 0.6, 0.45, 0.3, 0.2]) * g
        place(y, c, tm)
        place(y, thump(nsamp(0.2), 110, 55, 0.05), tm, 0.7 * g)
    return reverb(y, 0.9, 0.12, r)


@sfx("treeCrack", -2.0)
def _tree_crack(r):
    n = nsamp(1.2)
    y = np.zeros(n)
    for tm, g in ((0.0, 1.0), (0.12, 0.8), (0.25, 0.5), (0.4, 0.4)):
        m = nsamp(0.15)
        c = bp(noise(m, r), 700, 6000) * expdec(m, 0.006) * 1.4 + modal(m, [r.uniform(800, 1100), r.uniform(1500, 2000)], [0.03, 0.02], [1.0, 0.5])
        place(y, c, tm, g)
    t = tt(n)
    creak = M.tv_bq(noise(n, r), "bp", 250 + 200 * np.sin(2 * np.pi * 3 * t), 4.0) * np.exp(-t / 0.5) * 0.5
    y += creak
    return reverb(y, 0.5, 0.1, r)


@sfx("treeFall", -1.0)
def _tree_fall(r):
    n = nsamp(3.0)
    t = tt(n)
    sw = M.tv_bq(noise(n, r), "bp", 500 + 2500 * np.minimum(1.0, t / 1.3), 0.9) * np.minimum(1.0, t / 0.9) * (t < 1.35) * 0.9
    y = sw
    for k in range(70):
        tm = r.uniform(0.0, 1.3)
        m = nsamp(r.uniform(0.01, 0.05))
        place(y, bp(noise(m, r), 1500, 6000) * expdec(m, 0.006) * r.uniform(0.1, 0.5), tm)
    place(y, thump(nsamp(0.9), 60, 32, 0.16) * 1.8, 1.32)
    place(y, lp(noise(nsamp(0.7), r), 500) * expdec(nsamp(0.7), 0.15), 1.32, 1.4)
    for k in range(40):
        tm = 1.34 + r.exponential(0.3)
        if tm > 2.6:
            continue
        m = nsamp(r.uniform(0.01, 0.04))
        place(y, bp(noise(m, r), 1000, 5000) * expdec(m, 0.005) * r.uniform(0.1, 0.4), tm)
    return reverb(y, 1.1, 0.13, r)


@sfx("leavesRustle", -5.0)
def _leaves(r):
    n = nsamp(1.6)
    t = tt(n)
    env = (0.35 + 0.65 * np.abs(np.sin(2 * np.pi * 1.7 * t + 0.5))) * np.sin(np.pi * t / 1.6) ** 1.2
    y = bp(noise(n, r), 2500, 9000) * env
    for k in range(180):
        tm = r.uniform(0.0, 1.5)
        m = nsamp(r.uniform(0.004, 0.02))
        place(y, bp(noise(m, r), 3000, 9000) * expdec(m, 0.003) * r.uniform(0.2, 1.2), tm, 0.6 * env[min(n - 1, int(tm * SR))])
    return y


@sfx("signClang", -3.0)
def _sign_clang(r):
    n = nsamp(1.4)
    y = modal(n, [483, 1131, 1873, 2903, 4120], [0.45, 0.32, 0.24, 0.18, 0.12], [1.0, 0.6, 0.45, 0.3, 0.2])
    place(y, thump(nsamp(0.15), 200, 90, 0.03), 0.0, 0.9)
    place(y, bp(noise(nsamp(0.03), r), 500, 6000) * expdec(nsamp(0.03), 0.004), 0.0, 1.0)
    place(y, modal(nsamp(0.6), [530, 1230, 2000], [0.25, 0.18, 0.1], [0.6, 0.3, 0.2]), 0.18, 0.7)
    return reverb(y, 0.6, 0.1, r)


@sfx("debrisTumble", -4.0)
def _debris(r):
    n = nsamp(1.6)
    y = np.zeros(n)
    for k in range(48):
        tm = r.exponential(0.35)
        if tm > 1.45:
            continue
        m = nsamp(r.uniform(0.02, 0.09))
        f = r.uniform(700, 3800)
        c = modal(m, [f, f * 1.51, f * 2.3], [0.02, 0.014, 0.01], [1.0, 0.5, 0.3]) * r.uniform(0.2, 0.9) * np.exp(-tm * 1.6)
        place(y, c, tm)
        place(y, thump(nsamp(0.05), r.uniform(150, 300), 90, 0.01), tm, 0.25 * np.exp(-tm))
    return reverb(y, 0.5, 0.1, r)


@sfx("carDoorOpen", -4.0)
def _door_open(r):
    n = nsamp(0.6)
    y = np.zeros(n)
    place(y, S(modal(nsamp(0.08), [2200, 3300, 4700], [0.012, 0.008, 0.006], [1.0, 0.6, 0.3]), click(nsamp(0.03), r, 3500, 0.002)), 0.0, 0.9)
    place(y, thump(nsamp(0.2), 130, 70, 0.04), 0.07, 0.8)
    place(y, bp(noise(nsamp(0.25), r), 300, 2000) * expdec(nsamp(0.25), 0.06), 0.06, 0.25)
    return reverb(y, 0.25, 0.08, r)


@sfx("carDoorClose", -2.0)
def _door_close(r):
    n = nsamp(0.8)
    y = np.zeros(n)
    place(y, thump(nsamp(0.3), 105, 55, 0.07) * 1.4, 0.0)
    place(y, bp(noise(nsamp(0.1), r), 200, 2500) * expdec(nsamp(0.1), 0.02), 0.0, 1.0)
    place(y, modal(nsamp(0.1), [2000, 3100, 4500], [0.014, 0.01, 0.006], [1.0, 0.5, 0.3]), 0.045, 0.7)
    place(y, thump(nsamp(0.15), 70, 45, 0.04), 0.06, 0.6)
    return reverb(y, 0.3, 0.1, r)


@sfx("seatbelt", -5.0)
def _seatbelt(r):
    n = nsamp(0.7)
    y = np.zeros(n)
    t = tt(nsamp(0.3))
    place(y, M.tv_bq(noise(len(t), r), "bp", 1500 + 4000 * t / 0.3, 2.0) * np.sin(np.pi * t / 0.3), 0.0, 0.35)
    place(y, S(modal(nsamp(0.1), [1900, 2800, 4200], [0.02, 0.012, 0.008], [1.0, 0.7, 0.4]), click(nsamp(0.03), r, 3000, 0.002)), 0.34, 0.9)
    place(y, click(nsamp(0.03), r, 1500, 0.002), 0.43, 0.5)
    return y


# ----------------------------------------------------------------------------------------------------------------------------
# FOOTSTEPS / HOUSE
# ----------------------------------------------------------------------------------------------------------------------------


def _foot_concrete(r, k):
    n = nsamp(0.3)
    y = np.zeros(n)
    place(y, bp(noise(nsamp(0.05), r), 1200 + 300 * k, 4500) * expdec(nsamp(0.05), 0.008), 0.0, 1.0)
    place(y, thump(nsamp(0.1), 150 - 12 * k, 80, 0.022), 0.0, 0.9)
    place(y, modal(nsamp(0.06), [2100 + 200 * k, 3300], [0.01, 0.006], [0.5, 0.3]), 0.0, 0.6)
    place(y, bp(noise(nsamp(0.06), r), 500, 2500) * expdec(nsamp(0.06), 0.02), 0.11 + 0.01 * k, 0.5)
    return reverb(y, 0.35, 0.08, r)


def _foot_grass(r, k):
    n = nsamp(0.3)
    m = nsamp(0.14)
    t = tt(m)
    y = np.zeros(n)
    sw = lp(noise(m, r), 2600 + 300 * k) * np.sin(np.pi * np.minimum(1, t / 0.14)) ** 2
    place(y, sw, 0.0, 0.8)
    for j in range(24):
        mm = nsamp(0.006)
        place(y, bp(noise(mm, r), 3500, 9000) * expdec(mm, 0.002) * r.uniform(0.1, 0.5), r.uniform(0, 0.12))
    place(y, thump(nsamp(0.08), 100, 60, 0.02), 0.0, 0.4)
    return y


def _foot_wood(r, k):
    n = nsamp(0.35)
    y = np.zeros(n)
    f = [190, 205, 180][k]
    place(y, modal(nsamp(0.25), [f, f * 1.8, f * 3.3, f * 5.1], [0.07, 0.05, 0.035, 0.02], [1.0, 0.5, 0.3, 0.15]), 0.0, 0.9)
    place(y, bp(noise(nsamp(0.03), r), 800, 3500) * expdec(nsamp(0.03), 0.005), 0.0, 1.0)
    place(y, thump(nsamp(0.1), 120, 70, 0.02), 0.0, 0.5)
    return reverb(y, 0.3, 0.07, r)


for _k in range(3):
    job("footConcrete%d" % (_k + 1), "sfx", -7.0, False, False, 96)(lambda r, k=_k: _foot_concrete(r, k))
    job("footWood%d" % (_k + 1), "sfx", -7.0, False, False, 96)(lambda r, k=_k: _foot_wood(r, k))
for _k in range(2):
    job("footGrass%d" % (_k + 1), "sfx", -9.0, False, False, 96)(lambda r, k=_k: _foot_grass(r, k))


@sfx("doorOpen", -4.0)
def _door_o(r):
    n = nsamp(1.0)
    t = tt(n)
    y = np.zeros(n)
    place(y, S(modal(nsamp(0.06), [1800, 2900], [0.01, 0.006], [1.0, 0.5]), click(nsamp(0.03), r, 2500, 0.002)), 0.0, 0.8)
    creak = M.tv_bq(noise(n, r), "bp", 380 + 320 * np.sin(np.pi * t / 0.7) ** 2, 5.0) * np.sin(np.pi * np.minimum(1, t / 0.7)) * (t < 0.7)
    y += creak * 0.35
    place(y, bp(noise(nsamp(0.4), r), 100, 800) * np.sin(np.pi * tt(nsamp(0.4)) / 0.4), 0.0, 0.2)
    return reverb(y, 0.4, 0.09, r)


@sfx("doorClose", -3.0)
def _door_c(r):
    n = nsamp(0.7)
    y = thump(n, 95, 50, 0.07) * 1.1
    place(y, bp(noise(nsamp(0.08), r), 200, 2000) * expdec(nsamp(0.08), 0.02), 0.0, 0.8)
    place(y, modal(nsamp(0.07), [2200, 3300], [0.012, 0.008], [1.0, 0.5]), 0.05, 0.6)
    return reverb(y, 0.4, 0.1, r)


@sfx("garageDoorMotor", -5.0)
def _garage_motor(r):
    n = nsamp(3.4)
    t = tt(n)
    env = np.minimum(1.0, t / 0.25) * np.minimum(1.0, (3.4 - t) / 0.35)
    hum = (sine(48, n) + 0.6 * sine(96, n) + 0.35 * sine(144, n) + 0.2 * sine(192, n)) * 0.5
    chain = np.zeros(n)
    for i in range(int(3.4 * 13)):
        tm = i / 13.0 + r.normal(0, 0.003)
        place(chain, S(modal(nsamp(0.05), [1600, 2700], [0.008, 0.005], [1.0, 0.5]), click(nsamp(0.02), r, 2000, 0.002) * 0.8), tm, 0.5)
    rolling = lp(noise(n, r), 400) * (0.5 + 0.5 * np.sin(2 * np.pi * 3.3 * t))
    y = (hum + chain * 0.6 + rolling * 0.5) * env
    place(y, thump(nsamp(0.2), 90, 50, 0.05), 3.15, 0.9)
    return reverb(y, 0.5, 0.08, r)


@sfx("liftMotor", -5.0)
def _lift(r):
    n = nsamp(2.6)
    t = tt(n)
    env = np.minimum(1.0, t / 0.3) * np.minimum(1.0, (2.6 - t) / 0.3)
    f = 62 + 6 * np.minimum(1.0, t / 0.4)
    ph = np.cumsum(f) / SR
    hum = sum(np.sin(2 * np.pi * ph * k) / k for k in (1, 2, 3, 4, 5, 7)) * 0.4
    hiss = bp(noise(n, r), 500, 2500) * 0.15 * (0.7 + 0.3 * np.sin(2 * np.pi * 5 * t))
    y = (hum + hiss) * env
    place(y, hp(noise(nsamp(0.4), r), 3000) * expdec(nsamp(0.4), 0.12), 2.4, 0.5)
    return reverb(y, 0.6, 0.08, r)


@sfx("bedRustle", -6.0)
def _bed(r):
    n = nsamp(1.4)
    t = tt(n)
    env = (0.4 + 0.6 * np.abs(np.sin(2 * np.pi * 1.3 * t + 0.4))) * np.sin(np.pi * t / 1.4)
    y = bp(pink(n, r), 300, 3500) * env
    for k in range(9):
        m = nsamp(r.uniform(0.05, 0.15))
        place(y, lp(noise(m, r), 500) * np.sin(np.pi * tt(m) / (m / SR)) * r.uniform(0.2, 0.6), r.uniform(0, 1.2))
    return y


@sfx("sleepChime", -4.0)
def _sleep_chime(r):
    n = nsamp(3.6)
    y = np.zeros(n)
    for tm, note in ((0.0, 76), (0.42, 83), (0.85, 88), (1.3, 91)):
        place(y, bell(float(mtof(note)), 2.4, r, 0.5, 1.2), tm, 0.7)
    return reverb(y, 1.8, 0.28, r)


@sfx("lightSwitch", -5.0)
def _light_switch(r):
    n = nsamp(0.2)
    y = click(n, r, 2400, 0.002) + modal(n, [1500, 2600], [0.01, 0.005], [1.0, 0.5])
    place(y, click(nsamp(0.06), r, 1800, 0.002) * 0.7, 0.06)
    return y


@sfx("cashRegister", -3.0)
def _cash(r):
    n = nsamp(1.5)
    y = np.zeros(n)
    place(y, S(click(nsamp(0.05), r, 1800, 0.003), thump(nsamp(0.15), 150, 80, 0.03) * 0.8), 0.0, 0.9)
    place(y, modal(nsamp(1.2), [2340, 3120, 4890, 6300], [0.6, 0.45, 0.3, 0.2], [1.0, 0.8, 0.5, 0.3]), 0.09, 0.8)
    place(y, modal(nsamp(1.0), [3140, 4700], [0.45, 0.3], [0.7, 0.4]), 0.2, 0.6)
    place(y, thump(nsamp(0.25), 110, 60, 0.05), 0.55, 0.6)
    return reverb(y, 0.5, 0.1, r)


@sfx("wrenchRatchet", -4.0)
def _wrench(r):
    n = nsamp(1.0)
    y = np.zeros(n)
    tm = 0.0
    gap = 0.14
    for k in range(9):
        f = r.uniform(0.93, 1.07)
        place(y, S(modal(nsamp(0.05), [2100 * f, 3300 * f, 5200 * f], [0.008, 0.006, 0.004], [1.0, 0.6, 0.4]), click(nsamp(0.02), r, 3000, 0.0015)), tm, 0.9)
        tm += gap
        gap = max(0.06, gap * 0.86)
    return reverb(y, 0.25, 0.06, r)


# ----------------------------------------------------------------------------------------------------------------------------
# UI + RACE
# ----------------------------------------------------------------------------------------------------------------------------


def _blip(freq, dur, gain=1.0, glide_to=None):
    n = nsamp(dur)
    f = glide(freq, glide_to, n) if glide_to else freq
    y = sine(f, n) + 0.3 * sine(np.asarray(f) * 2 if glide_to else freq * 2, n)
    return y * env_ad(n, 0.002, dur * 0.35) * gain


@sfx("uiTap", -8.0)
def _ui_tap(r):
    y = _blip(1450, 0.09) * 0.7
    place(y, click(nsamp(0.02), r, 3500, 0.0015), 0.0, 0.3)
    return y


@sfx("uiBack", -8.0)
def _ui_back(r):
    n = nsamp(0.2)
    y = np.zeros(n)
    place(y, _blip(880, 0.1), 0.0, 0.8)
    place(y, _blip(587, 0.13), 0.06, 0.8)
    return y


@sfx("uiConfirm", -6.0)
def _ui_confirm(r):
    n = nsamp(0.5)
    y = np.zeros(n)
    place(y, bell(float(mtof(76)), 0.35, r, 0.4, 0.5), 0.0, 0.6)
    place(y, bell(float(mtof(83)), 0.4, r, 0.4, 0.5), 0.09, 0.7)
    return reverb(y, 0.4, 0.1, r)


@sfx("uiSwipe", -10.0)
def _ui_swipe(r):
    n = nsamp(0.22)
    t = tt(n)
    y = M.tv_bq(noise(n, r), "bp", 500 + 2500 * (t / 0.22), 1.2) * np.sin(np.pi * t / 0.22) ** 1.5
    return y


@sfx("uiError", -7.0)
def _ui_error(r):
    n = nsamp(0.35)
    y = np.zeros(n)
    for tm in (0.0, 0.16):
        m = nsamp(0.13)
        place(y, lp(square(190, m), 1400) * env_ad(m, 0.004, 0.06), tm, 0.8)
    return y


@sfx("uiToggleOn", -8.0)
def _ui_on(r):
    return _blip(700, 0.12, 1.0, 1300)


@sfx("uiToggleOff", -8.0)
def _ui_off(r):
    return _blip(1100, 0.12, 1.0, 600)


@sfx("countdownBeep", -4.0)
def _beep(r):
    n = nsamp(0.4)
    y = (sine(1000, n) + 0.25 * sine(2000, n) + 0.1 * sine(3000, n)) * np.minimum(1.0, tt(n) / 0.004) * np.minimum(1.0, (0.4 - tt(n)) / 0.04)
    return reverb(y, 0.25, 0.06, r)


@sfx("raceGo", -3.0)
def _go(r):
    n = nsamp(0.9)
    y = (sine(1500, n) + 0.3 * sine(3000, n) + 0.12 * sine(4500, n)) * np.minimum(1.0, tt(n) / 0.004) * np.minimum(1.0, (0.9 - tt(n)) / 0.12)
    return reverb(y, 0.35, 0.08, r)


@sfx("lapComplete", -4.0)
def _lap(r):
    n = nsamp(1.3)
    y = np.zeros(n)
    for tm, note in ((0.0, 79), (0.1, 84), (0.2, 88), (0.3, 91)):
        place(y, bell(float(mtof(note)), 0.9, r, 0.6, 0.6), tm, 0.6)
    return reverb(y, 0.7, 0.12, r)


def _brass(f, dur, r, gain=1.0):
    n = nsamp(dur)
    t = tt(n)
    vib = 1 + 0.004 * np.sin(2 * np.pi * 5.2 * t) * np.minimum(1.0, t / 0.25)
    ph = np.cumsum(f * vib) / SR
    y = sum(np.sin(2 * np.pi * ph * k) / (k ** 0.9) for k in range(1, 16))
    fc = 500 + 3500 * np.minimum(1.0, t / 0.09)
    y = M.tv_bq(y, "lp", fc, 0.9)
    env = np.minimum(1.0, t / 0.035) * np.minimum(1.0, (dur - t) / 0.12)
    return y * env * gain


@sfx("raceWin", -3.0)
def _win(r):
    n = nsamp(3.2)
    y = np.zeros(n)
    notes = [(0.0, 60, 0.25), (0.22, 64, 0.25), (0.44, 67, 0.25), (0.66, 72, 0.5), (1.25, 67, 0.2), (1.45, 72, 1.4)]
    for tm, nt, d in notes:
        for ofs, g in ((0, 1.0), (4, 0.6), (7, 0.55)) if tm >= 1.45 else ((0, 1.0),):
            place(y, _brass(float(mtof(nt + ofs)), d, r), tm, 0.35 * g)
    place(y, hp(noise(nsamp(1.6), r), 5000) * env_ad(nsamp(1.6), 0.02, 0.5), 1.45, 0.25)
    for tm in (0.0, 0.44, 1.45):
        place(y, thump(nsamp(0.25), 120, 55, 0.07), tm, 0.7)
    return reverb(y, 1.4, 0.2, r)


@sfx("raceLose", -4.0)
def _lose(r):
    n = nsamp(2.2)
    y = np.zeros(n)
    for tm, nt, d in ((0.0, 62, 0.5), (0.5, 59, 0.5), (1.0, 55, 0.9)):
        place(y, _brass(float(mtof(nt)), d, r) * 0.7, tm, 0.4)
        place(y, lp(saw(float(mtof(nt - 12)), nsamp(d)), 500) * env_ad(nsamp(d), 0.01, d * 0.6), tm, 0.3)
    return reverb(y, 1.0, 0.16, r)


@sfx("purchase", -4.0)
def _purchase(r):
    n = nsamp(1.2)
    y = np.zeros(n)
    place(y, click(nsamp(0.05), r, 2000, 0.003), 0.0, 0.8)
    place(y, thump(nsamp(0.12), 140, 80, 0.03), 0.0, 0.6)
    for tm, note in ((0.05, 88), (0.16, 95)):
        place(y, bell(float(mtof(note)), 0.9, r, 0.8, 0.8), tm, 0.5)
    return reverb(y, 0.6, 0.1, r)


# ----------------------------------------------------------------------------------------------------------------------------
# EXTRAS (loops used by the audio manager's wind / road layers)
# ----------------------------------------------------------------------------------------------------------------------------


@job("wind_loop", "extra", -6.0, True, False, 96)
def _wind(r):
    L = nsamp(3.0)
    t = tt(L)
    y = pnoise(L, r, lambda f: (1.0 / (1.0 + (f / 900) ** 3)) * (1 + 1.2 * np.exp(-((f - 350) / 250) ** 2)))
    y *= 0.75 + 0.25 * np.sin(2 * np.pi * (1 / 3.0) * t + 0.7) + 0.1 * np.sin(2 * np.pi * (3 / 3.0) * t)
    return y


@job("road_loop", "extra", -6.0, True, False, 96)
def _road(r):
    L = nsamp(2.0)
    t = tt(L)
    y = pnoise(L, r, band(320, 260)) + 0.5 * pnoise(L, r, band(1300, 700)) + 0.7 * pnoise(L, r, lowshape(120))
    y *= 0.85 + 0.15 * np.sin(2 * np.pi * 2.0 * t)
    return y

# ----------------------------------------------------------------------------------------------------------------------------
# POLICE SIREN (six second "wail" then "yelp": one-shot, re-triggered by PoliceSystem while a unit with its siren on is close)
# ----------------------------------------------------------------------------------------------------------------------------


@sfx("policeSiren", -5.0)
def _police_siren(r):
    n = nsamp(6.0)
    t = tt(n)
    # frequency plan: slow wail 700 -> 1500 -> 700 (2 x 2.2 s), then a fast yelp (1.6 s)
    f = np.zeros(n)
    wail = 2.2
    for k in range(2):
        m = (t >= k * wail) & (t < (k + 1) * wail)
        ph = (t[m] - k * wail) / wail
        f[m] = 700 + 800 * (0.5 - 0.5 * np.cos(2 * np.pi * ph))
    m = t >= 2 * wail
    ph = (t[m] - 2 * wail) / 0.4
    f[m] = 850 + 600 * (ph % 1.0)
    phase = 2 * np.pi * np.cumsum(f) / SR
    y = np.sin(phase) + 0.45 * np.sin(2 * phase) + 0.25 * np.sin(3 * phase)
    y = np.tanh(y * 1.4)
    y = bq(y, "peak", 1300, 1.2, 4)
    y = bq(y, "lp", 5000)
    env = np.minimum(1.0, t / 0.08) * np.minimum(1.0, (6.0 - t) / 0.35)
    return reverb(y * env, 0.35, 0.08, r)
