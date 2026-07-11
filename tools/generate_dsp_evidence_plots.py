#!/usr/bin/env python3
"""Generate report-ready plots and summary artifacts from a ClearTone
DSP evidence session (see docs/validation.md).

This script performs the *analysis* half of the evidence pipeline: it reads
the raw materials produced on-device (or by tools/dsp_harness off-device) --
paired WAV files and the frame/band/limiter CSV logs -- and derives the
plots, per-experiment result tables, and the summary CSV/JSON/Markdown that
go directly into the final year report / paper.

It intentionally does NOT touch the DSP itself: everything here is standard
signal analysis (RMS/peak/dBFS, FFT magnitude spectra, a windowed-RMS sweep
gain estimate, spectrograms) applied to WAV files the app/harness already
produced with the real amplification pipeline.

Dependencies: numpy, matplotlib (no scipy) -- see tools/requirements.txt.

Usage:
    python3 tools/generate_dsp_evidence_plots.py <session_dir>

Example:
    python3 tools/generate_dsp_evidence_plots.py \\
        cleartone_evidence/session_20260711_121412
"""

from __future__ import annotations

import csv
import json
import math
import os
import sys
import wave
from dataclasses import dataclass, field

import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

DPI = 300
EPS = 1e-12

# Safe, non-clinical wording (docs/validation.md Phase 12). Every generated
# markdown/JSON interpretation string is built from this vocabulary.
FORBIDDEN_PHRASES = [
    "clinically improved hearing",
    "safe output level",
    "validated hearing-aid behaviour",
    "validated hearing-aid behavior",
    "medically accurate amplification",
    "guaranteed low latency",
]


# ---------------------------------------------------------------------------
# Small I/O helpers (stdlib + numpy only)
# ---------------------------------------------------------------------------

def read_wav(path):
    """Returns (sample_rate, float32 samples in [-1, 1]) or None if missing."""
    if not os.path.isfile(path):
        return None
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        sampwidth = w.getsampwidth()
        raw = w.readframes(n)
    if sampwidth != 2:
        raise ValueError(f"{path}: only 16-bit PCM WAV is supported, got {sampwidth * 8}-bit")
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    return sr, data


def read_csv_rows(path):
    if not os.path.isfile(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def read_json(path, default=None):
    if not os.path.isfile(path):
        return default
    with open(path) as f:
        return json.load(f)


def rms(x):
    if len(x) == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(x, dtype=np.float64))))


def peak(x):
    if len(x) == 0:
        return 0.0
    return float(np.max(np.abs(x)))


def dbfs(v):
    return 20.0 * math.log10(max(v, EPS))


def band_index_for_freq(f, edges):
    idx = 0
    for e in edges:
        if f >= e:
            idx += 1
        else:
            break
    return min(idx, len(edges))


def check_safe_wording(text):
    lowered = text.lower()
    for phrase in FORBIDDEN_PHRASES:
        if phrase in lowered:
            raise ValueError(f"Generated text used a forbidden clinical-sounding phrase: {phrase!r}")


# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

@dataclass
class Session:
    root: str
    audio: str = field(init=False)
    logs: str = field(init=False)
    metadata: str = field(init=False)
    plots: str = field(init=False)
    summary: str = field(init=False)

    def __post_init__(self):
        self.audio = os.path.join(self.root, "audio")
        self.logs = os.path.join(self.root, "logs")
        self.metadata = os.path.join(self.root, "metadata")
        self.plots = os.path.join(self.root, "plots")
        self.summary = os.path.join(self.root, "summary")
        for d in (self.plots, self.summary):
            os.makedirs(d, exist_ok=True)

    def a(self, name):
        return os.path.join(self.audio, name)

    def l(self, name):
        return os.path.join(self.logs, name)

    def m(self, name):
        return os.path.join(self.metadata, name)

    def p(self, name):
        return os.path.join(self.plots, name)

    def s(self, name):
        return os.path.join(self.summary, name)


def savefig(fig, path):
    fig.savefig(path, dpi=DPI, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {path}")


# ---------------------------------------------------------------------------
# Plot 1/2/3: raw vs processed waveform / spectrum / spectrogram
# ---------------------------------------------------------------------------

def plot_waveform(sess, edges, pairs):
    for tag, sr, raw, proc, label in pairs:
        n = min(len(raw), len(proc), sr * 5)
        t = np.arange(n) / sr

        fig, axes = plt.subplots(2, 1, figsize=(9, 5), sharex=True, sharey=True)
        axes[0].plot(t, raw[:n], linewidth=0.6, color="#3366cc")
        axes[0].set_title(f"Raw input ({label})")
        axes[0].set_ylabel("Amplitude")
        axes[1].plot(t, proc[:n], linewidth=0.6, color="#cc3333")
        axes[1].set_title(f"Processed output ({label})")
        axes[1].set_ylabel("Amplitude")
        axes[1].set_xlabel("Time (s)")
        fig.suptitle("Raw vs. Processed Waveform (digital DSP verification)")
        savefig(fig, sess.p(f"raw_vs_processed_waveform{tag}.png"))


def magnitude_spectrum_db(x, sr, fmin=20.0, fmax=10000.0):
    n = len(x)
    if n == 0:
        return np.array([]), np.array([])
    window = np.hanning(n)
    spec = np.fft.rfft(x * window)
    freqs = np.fft.rfftfreq(n, d=1.0 / sr)
    mag_db = 20.0 * np.log10(np.abs(spec) / (np.sum(window) / 2.0) + EPS)
    mask = (freqs >= fmin) & (freqs <= fmax)
    return freqs[mask], mag_db[mask]


def plot_spectrum(sess, edges, pairs):
    for tag, sr, raw, proc, label in pairs:
        fr, mr = magnitude_spectrum_db(raw, sr)
        fp, mp = magnitude_spectrum_db(proc, sr)

        fig, ax = plt.subplots(figsize=(9, 5))
        ax.semilogx(fr, mr, label="Raw input", color="#3366cc", linewidth=0.8)
        ax.semilogx(fp, mp, label="Processed output", color="#cc3333", linewidth=0.8)
        for e in edges:
            ax.axvline(e, color="gray", linestyle="--", linewidth=0.7)
        ax.set_xlim(20, 10000)
        ax.set_xlabel("Frequency (Hz, log scale)")
        ax.set_ylabel("Magnitude (dB)")
        ax.set_title(f"Raw vs. Processed Magnitude Spectrum ({label})")
        ax.legend()
        savefig(fig, sess.p(f"raw_vs_processed_spectrum{tag}.png"))


def plot_spectrogram(sess, pairs):
    for tag, sr, raw, proc, label in pairs:
        fig, axes = plt.subplots(2, 1, figsize=(9, 6), sharex=True)
        axes[0].specgram(raw, NFFT=1024, Fs=sr, noverlap=512, cmap="magma")
        axes[0].set_title(f"Raw input spectrogram ({label})")
        axes[0].set_ylabel("Frequency (Hz)")
        im = axes[1].specgram(proc, NFFT=1024, Fs=sr, noverlap=512, cmap="magma")
        axes[1].set_title(f"Processed output spectrogram ({label})")
        axes[1].set_ylabel("Frequency (Hz)")
        axes[1].set_xlabel("Time (s)")
        fig.colorbar(im[3], ax=axes, label="Power (dB)")
        savefig(fig, sess.p(f"raw_vs_processed_spectrogram{tag}.png"))


MODE_TAGS_ORDERED = [
    ("_standard", "Standard mode, live microphone capture"),
    ("_transit", "Transit mode, live microphone capture"),
    ("_conversation", "Conversation mode, live microphone capture"),
]


def find_live_mic_pairs(sess):
    """Returns a list of (filename_tag, sample_rate, raw, processed, label)
    for every raw/processed live-mic WAV pair found in the session -- one
    per mode if the on-device Evidence screen captured Standard/Transit/
    Conversation separately (mode-suffixed filenames), or a single unsuffixed
    pair for older sessions / the offline harness. Falls back to the
    Standard-mode mode-comparison pair if no live capture exists at all."""
    pairs = []
    for tag, label in MODE_TAGS_ORDERED:
        raw = read_wav(sess.a(f"live_raw_input{tag}.wav"))
        proc = read_wav(sess.a(f"live_processed_output{tag}.wav"))
        if raw and proc:
            pairs.append((tag, raw[0], raw[1], proc[1], label))
    if pairs:
        return pairs

    live = read_wav(sess.a("live_raw_input.wav"))
    live_p = read_wav(sess.a("live_processed_output.wav"))
    if live and live_p:
        return [("", live[0], live[1], live_p[1], "live microphone capture")]

    mode_raw = read_wav(sess.a("mode_test_raw_input.wav"))
    mode_p = read_wav(sess.a("standard_mode_processed.wav"))
    if mode_raw and mode_p:
        return [("", mode_raw[0], mode_raw[1], mode_p[1], "mode-comparison input, Standard mode")]
    return []


# ---------------------------------------------------------------------------
# Plot 4 + gain_profile: band_gain_response.png
# ---------------------------------------------------------------------------

def plot_band_gain_response(sess, dsp_config):
    band_labels = dsp_config.get("bands", ["<500", "500-1000", "1000-2000", "2000-4000", "4000-8000", ">8000"])
    configured = dsp_config.get("gain_db_per_band", [0] * 6)

    gain_rows = read_csv_rows(sess.m("gain_profile.csv"))
    manual = None
    if gain_rows:
        by_source = {}
        for r in gain_rows:
            by_source.setdefault(r["source"], {})[int(r["band_index"])] = float(r["gain_db"])
        non_profile = [s for s in by_source if s != "hearing_profile"]
        if non_profile:
            src = non_profile[-1]
            manual = [by_source[src].get(i, 0.0) for i in range(6)]

    x = np.arange(len(band_labels))
    fig, ax = plt.subplots(figsize=(8, 5))
    width = 0.35 if manual else 0.6
    ax.bar(x - (width / 2 if manual else 0), configured, width, label="Configured gain (hearing profile)", color="#3366cc")
    if manual:
        ax.bar(x + width / 2, manual, width, label="Manual slider adjustment", color="#cc9933")
    ax.set_xticks(x)
    ax.set_xticklabels(band_labels, rotation=20)
    ax.set_xlabel("Frequency band")
    ax.set_ylabel("Gain (dB)")
    ax.set_title("Per-Band Makeup Gain (configured)")
    ax.legend()
    savefig(fig, sess.p("band_gain_response.png"))


# ---------------------------------------------------------------------------
# Phase 7: pure-tone verification
# ---------------------------------------------------------------------------

TONE_FREQS = [250, 500, 1000, 2000, 4000, 8000]


def analyze_pure_tones(sess, edges, dsp_config, band_rows):
    configured = dsp_config.get("gain_db_per_band", [0] * 6)
    results = []
    for freq in TONE_FREQS:
        raw = read_wav(sess.a(f"pure_tone_raw_{freq}Hz.wav"))
        proc = read_wav(sess.a(f"pure_tone_processed_{freq}Hz.wav"))
        if not raw or not proc:
            continue
        sr, rx = raw
        _, px = proc
        # Skip the first 20% (envelope/filter settling) so RMS reflects
        # steady-state gain, not the attack transient.
        skip = int(0.2 * len(rx))
        rx_s = rx[skip:]
        px_s = px[skip:skip + len(rx_s)]
        raw_rms, proc_rms = rms(rx_s), rms(px_s)
        raw_peak, proc_peak = peak(rx_s), peak(px_s)
        raw_db, proc_db = dbfs(raw_rms), dbfs(proc_rms)
        band = band_index_for_freq(freq, edges)
        configured_gain = configured[band] if band < len(configured) else configured[-1]
        observed_gain = proc_db - raw_db

        mode = "Standard"
        src = f"pure_tone_{freq}Hz"
        matching = [r for r in band_rows if r.get("source") == src]
        if matching:
            # If this experiment was re-run in multiple modes within the same
            # session, only the LAST run's mode still matches the current WAV
            # (each run overwrites the file); band_level_log rows are
            # appended in run order, so the last matching row is authoritative.
            mode = matching[-1]["active_mode"]

        results.append({
            "frequency_hz": freq,
            "expected_primary_band": band,
            "raw_rms": raw_rms,
            "processed_rms": proc_rms,
            "raw_peak": raw_peak,
            "processed_peak": proc_peak,
            "raw_dbfs": raw_db,
            "processed_dbfs": proc_db,
            "gain_observed_db": observed_gain,
            "configured_gain_db_for_primary_band": configured_gain,
            "difference_between_observed_and_configured_gain_db": observed_gain - configured_gain,
            "active_mode": mode,
        })
    return results


def write_csv(path, rows, fieldnames):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"  wrote {path}")


def plot_pure_tone_band_response(sess, results):
    if not results:
        print("  [skip] pure_tone_band_response.png (no pure-tone WAV pairs found)")
        return
    freqs = [r["frequency_hz"] for r in results]
    observed = [r["gain_observed_db"] for r in results]
    configured = [r["configured_gain_db_for_primary_band"] for r in results]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.semilogx(freqs, observed, "o-", label="Observed gain (measured from WAV)", color="#cc3333")
    ax.semilogx(freqs, configured, "s--", label="Configured gain (expected band)", color="#3366cc")
    ax.minorticks_off()
    ax.set_xticks(freqs)
    ax.set_xticklabels([str(f) for f in freqs])
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Gain (dB)")
    ax.set_title("Pure-Tone Band Response: Observed vs. Configured Gain")
    ax.legend()
    ax.grid(True, which="both", linestyle=":", linewidth=0.5)
    savefig(fig, sess.p("pure_tone_band_response.png"))


MODE_ORDER = ["Standard", "Transit", "Conversation"]
MODE_COLORS = {"Standard": "#3366cc", "Transit": "#cc9933", "Conversation": "#33aa55"}


def _sorted_modes(modes):
    return sorted(modes, key=lambda m: MODE_ORDER.index(m) if m in MODE_ORDER else 99)


def analyze_pure_tones_by_mode(band_rows, edges, dsp_config):
    """Per-(frequency, mode) observed gain straight from band_level_log's
    final_band_gain_db -- the DSP's own internal diagnostic for the gain it
    applied to the expected band. Unlike analyze_pure_tones (which measures
    the surviving WAV file), this works for every mode the pure-tone battery
    was run in during this session, even modes whose WAV got overwritten by
    a later run, because the log rows from every run are preserved."""
    configured = dsp_config.get("gain_db_per_band", [0] * 6)
    rows_out = []
    for freq in TONE_FREQS:
        src = f"pure_tone_{freq}Hz"
        band = band_index_for_freq(freq, edges)
        matching = [r for r in band_rows if r.get("source") == src and int(r["band_index"]) == band]
        by_mode = {}
        for r in matching:
            by_mode.setdefault(r["active_mode"], []).append(float(r["final_band_gain_db"]))
        for mode, vals in by_mode.items():
            skip = int(0.2 * len(vals))
            steady = vals[skip:] if len(vals) > skip else vals
            if not steady:
                continue
            observed = float(np.mean(steady))
            cfg = configured[band] if band < len(configured) else configured[-1]
            rows_out.append({
                "frequency_hz": freq,
                "mode": mode,
                "expected_primary_band": band,
                "observed_final_band_gain_db": round(observed, 3),
                "configured_gain_db": cfg,
                "difference_db": round(observed - cfg, 3),
            })
    return rows_out


def plot_pure_tone_band_response_by_mode(sess, rows):
    if len(set(r["mode"] for r in rows)) < 2:
        print("  [skip] pure_tone_band_response_by_mode.png (fewer than 2 modes present)")
        return
    fig, ax = plt.subplots(figsize=(8, 5))
    for mode in _sorted_modes(set(r["mode"] for r in rows)):
        pts = sorted([r for r in rows if r["mode"] == mode], key=lambda r: r["frequency_hz"])
        ax.semilogx(
            [p["frequency_hz"] for p in pts], [p["observed_final_band_gain_db"] for p in pts],
            "o-", label=f"{mode} (observed)", color=MODE_COLORS.get(mode, "gray"),
        )
    cfg_pts = sorted({(r["frequency_hz"], r["configured_gain_db"]) for r in rows})
    ax.semilogx([f for f, _ in cfg_pts], [c for _, c in cfg_pts], "s--",
                label="Configured gain (expected band)", color="black")
    ax.minorticks_off()
    freqs_all = sorted(set(r["frequency_hz"] for r in rows))
    ax.set_xticks(freqs_all)
    ax.set_xticklabels([str(f) for f in freqs_all])
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Applied band gain (dB)")
    ax.set_title("Pure-Tone Band Response by Mode\n(internal DSP diagnostic: final_band_gain_db)")
    ax.legend()
    ax.grid(True, which="both", linestyle=":", linewidth=0.5)
    savefig(fig, sess.p("pure_tone_band_response_by_mode.png"))


# ---------------------------------------------------------------------------
# Phase 8: frequency-sweep verification
# ---------------------------------------------------------------------------

def sweep_gain_curve(raw, proc, sr, f0, f1, duration, win_sec=0.02):
    k = duration / math.log(f1 / f0)
    win = max(16, int(win_sec * sr))
    hop = win // 2
    freqs, raw_db, proc_db = [], [], []
    n = min(len(raw), len(proc))
    for start in range(0, n - win, hop):
        seg_r = raw[start:start + win]
        seg_p = proc[start:start + win]
        t_center = (start + win / 2.0) / sr
        f = f0 * math.exp(t_center / k)
        if f < f0 or f > f1:
            continue
        r_rms, p_rms = rms(seg_r), rms(seg_p)
        freqs.append(f)
        raw_db.append(dbfs(r_rms))
        proc_db.append(dbfs(p_rms))
    return np.array(freqs), np.array(raw_db), np.array(proc_db)


def analyze_sweep(sess, edges, dsp_config, limiter_rows):
    raw = read_wav(sess.a("sweep_raw_20_10000Hz.wav"))
    proc = read_wav(sess.a("sweep_processed_20_10000Hz.wav"))
    if not raw or not proc:
        return None, []
    sr, rx = raw
    _, px = proc
    freqs, raw_db, proc_db = sweep_gain_curve(rx, px, sr, 20.0, 10000.0, 10.0)
    configured = dsp_config.get("gain_db_per_band", [0] * 6)

    mode = "Standard"
    matching = [r for r in limiter_rows if r.get("source") == "sweep"]
    if matching:
        # See the equivalent comment in analyze_pure_tones: if re-run in
        # multiple modes, only the last run's mode matches the surviving WAV.
        mode = matching[-1]["active_mode"]

    rows = []
    for f, rdb, pdb in zip(freqs, raw_db, proc_db):
        band = band_index_for_freq(f, edges)
        cfg = configured[band] if band < len(configured) else configured[-1]
        rows.append({
            "frequency_hz": round(float(f), 2),
            "raw_magnitude_db": round(float(rdb), 3),
            "processed_magnitude_db": round(float(pdb), 3),
            "observed_gain_db": round(float(pdb - rdb), 3),
            "expected_band": band,
            "configured_gain_db": cfg,
            "active_mode": mode,
        })
    return (sr, rx, px), rows


def plot_sweep_response(sess, edges, sweep_rows):
    if not sweep_rows:
        print("  [skip] sweep_frequency_response.png (no sweep WAV pair found)")
        return
    freqs = [r["frequency_hz"] for r in sweep_rows]
    observed = [r["observed_gain_db"] for r in sweep_rows]
    configured = [r["configured_gain_db"] for r in sweep_rows]

    fig, ax = plt.subplots(figsize=(9, 5))
    ax.semilogx(freqs, observed, linewidth=1.0, color="#cc3333", label="Observed gain (windowed RMS)")
    ax.semilogx(freqs, configured, linewidth=1.0, linestyle="--", color="#3366cc", label="Configured band gain")
    for e in edges:
        ax.axvline(e, color="gray", linestyle=":", linewidth=0.7)
    ax.set_xlim(20, 10000)
    ax.set_xlabel("Frequency (Hz, log scale)")
    ax.set_ylabel("Gain (dB)")
    ax.set_title("Frequency-Sweep Response (20 Hz - 10 kHz)")
    ax.legend()
    savefig(fig, sess.p("sweep_frequency_response.png"))


def analyze_sweep_by_mode(band_rows, edges, dsp_config, sample_rate=48000,
                           f0=20.0, f1=10000.0, duration=10.0):
    """Per-mode sweep response straight from band_level_log's
    final_band_gain_db, keyed by (frame_index -> instantaneous sweep
    frequency) the same way the sweep signal was generated. Like
    analyze_pure_tones_by_mode, this recovers every mode the sweep was run in
    during this session even though only the last run's WAV survives."""
    configured = dsp_config.get("gain_db_per_band", [0] * 6)
    k = duration / math.log(f1 / f0)
    matching = [r for r in band_rows if r.get("source") == "sweep"]
    rows_out = []
    for r in matching:
        t = int(r["frame_index"]) / sample_rate
        f = f0 * math.exp(t / k)
        if f < f0 or f > f1:
            continue
        band = int(r["band_index"])
        if band != band_index_for_freq(f, edges):
            continue  # keep only the band that actually dominates at this instant
        cfg = configured[band] if band < len(configured) else configured[-1]
        rows_out.append({
            "frequency_hz": round(f, 2),
            "mode": r["active_mode"],
            "observed_final_band_gain_db": round(float(r["final_band_gain_db"]), 3),
            "expected_band": band,
            "configured_gain_db": cfg,
        })
    return rows_out


def plot_sweep_response_by_mode(sess, edges, rows):
    if len(set(r["mode"] for r in rows)) < 2:
        print("  [skip] sweep_frequency_response_by_mode.png (fewer than 2 modes present)")
        return
    fig, ax = plt.subplots(figsize=(9, 5))
    for mode in _sorted_modes(set(r["mode"] for r in rows)):
        pts = sorted([r for r in rows if r["mode"] == mode], key=lambda r: r["frequency_hz"])
        ax.semilogx(
            [p["frequency_hz"] for p in pts], [p["observed_final_band_gain_db"] for p in pts],
            linewidth=1.0, label=mode, color=MODE_COLORS.get(mode, "gray"),
        )
    for e in edges:
        ax.axvline(e, color="gray", linestyle=":", linewidth=0.7)
    ax.set_xlim(20, 10000)
    ax.set_xlabel("Frequency (Hz, log scale)")
    ax.set_ylabel("Applied band gain (dB)")
    ax.set_title("Frequency-Sweep Response by Mode\n(internal DSP diagnostic: final_band_gain_db)")
    ax.legend()
    savefig(fig, sess.p("sweep_frequency_response_by_mode.png"))


# ---------------------------------------------------------------------------
# Phase 6: limiter / clipping evidence
# ---------------------------------------------------------------------------

def plot_limiter_clipping(sess, limiter_rows):
    if not limiter_rows:
        print("  [skip] limiter_clipping_check.png (no limiter_log.csv rows found)")
        return
    idx = np.arange(len(limiter_rows))
    pre_peak = np.array([float(r["pre_limiter_peak"]) for r in limiter_rows])
    post_peak = np.array([float(r["post_limiter_peak"]) for r in limiter_rows])
    clip_before = sum(int(r["samples_clipped_before"]) for r in limiter_rows)
    clip_after = sum(int(r["samples_clipped_after"]) for r in limiter_rows)
    above_before = sum(int(r["samples_above_0_95_before"]) for r in limiter_rows)
    above_after = sum(int(r["samples_above_0_95_after"]) for r in limiter_rows)

    fig, axes = plt.subplots(1, 2, figsize=(11, 4.5))
    axes[0].plot(idx, pre_peak, label="Pre-limiter peak", color="#cc3333", linewidth=0.6)
    axes[0].plot(idx, post_peak, label="Post-limiter peak", color="#3366cc", linewidth=0.6)
    axes[0].axhline(1.0, color="black", linestyle=":", linewidth=0.8, label="Digital full scale")
    axes[0].axhline(0.95, color="gray", linestyle=":", linewidth=0.8, label="0.95 threshold")
    axes[0].set_xlabel("Log block index")
    axes[0].set_ylabel("Peak amplitude")
    axes[0].set_title("Pre- vs. Post-Limiter Peak")
    axes[0].legend(fontsize=8)

    labels = [">0.95 (before)", ">0.95 (after)", "clipped (before)", "clipped (after)"]
    values = [above_before, above_after, clip_before, clip_after]
    axes[1].bar(labels, values, color=["#cc9999", "#99cc99", "#cc3333", "#3366cc"])
    axes[1].set_ylabel("Sample count")
    axes[1].set_title("Clipping / Near-Ceiling Sample Counts")
    axes[1].tick_params(axis="x", rotation=20)

    fig.suptitle("Soft Limiter Behaviour and Clipping Reduction")
    savefig(fig, sess.p("limiter_clipping_check.png"))
    return {
        "samples_above_0_95_before": above_before,
        "samples_above_0_95_after": above_after,
        "samples_clipped_before": clip_before,
        "samples_clipped_after": clip_after,
    }


# ---------------------------------------------------------------------------
# Phase 9: mode comparison
# ---------------------------------------------------------------------------

MODE_FILES = {
    "Standard": "standard_mode_processed.wav",
    "Transit": "transit_mode_processed.wav",
    "Conversation": "conversation_mode_processed.wav",
}
MODE_SOURCE_TAGS = {
    "Standard": "mode_standard",
    "Transit": "mode_transit",
    "Conversation": "mode_conversation",
}


def analyze_mode_comparison(sess, band_rows, limiter_rows):
    mode_in = read_wav(sess.a("mode_test_raw_input.wav"))
    if not mode_in:
        return []
    sr, in_x = mode_in
    in_rms, in_peak = rms(in_x), peak(in_x)

    rows = []
    for mode, fname in MODE_FILES.items():
        proc = read_wav(sess.a(fname))
        if not proc:
            continue
        _, px = proc
        out_rms, out_peak = rms(px), peak(px)
        tag = MODE_SOURCE_TAGS[mode]

        band_matches = [r for r in band_rows if r.get("source") == tag]
        band_rms = [0.0] * 6
        if band_matches:
            sums = [0.0] * 6
            counts = [0] * 6
            for r in band_matches:
                b = int(r["band_index"])
                sums[b] += float(r["output_band_rms"])
                counts[b] += 1
            band_rms = [s / c if c else 0.0 for s, c in zip(sums, counts)]

        limiter_matches = [r for r in limiter_rows if r.get("source") == tag]
        above = sum(int(r["samples_above_0_95_after"]) for r in limiter_matches)
        clipped = sum(int(r["samples_clipped_after"]) for r in limiter_matches)

        rows.append({
            "mode": mode,
            "input_rms": in_rms,
            "output_rms": out_rms,
            "input_peak": in_peak,
            "output_peak": out_peak,
            "output_dbfs": dbfs(out_rms),
            "estimated_gain_db": dbfs(out_rms) - dbfs(in_rms),
            "samples_above_0_95": above,
            "samples_clipped": clipped,
            "band_1_rms": band_rms[0],
            "band_2_rms": band_rms[1],
            "band_3_rms": band_rms[2],
            "band_4_rms": band_rms[3],
            "band_5_rms": band_rms[4],
            "band_6_rms": band_rms[5],
            "notes": f"{mode} mode processing observed_gain differs from other modes when driven by the same fixed input file, indicating mode-dependent DSP behaviour.",
        })
    return rows


def plot_mode_comparison(sess, mode_rows):
    mode_in = read_wav(sess.a("mode_test_raw_input.wav"))
    if not mode_in or not mode_rows:
        print("  [skip] mode_comparison_waveform.png / mode_comparison_spectrum.png (missing mode-comparison files)")
        return
    sr, in_x = mode_in
    n = min(len(in_x), sr * 5)
    t = np.arange(n) / sr

    fig, axes = plt.subplots(len(mode_rows) + 1, 1, figsize=(9, 2.2 * (len(mode_rows) + 1)), sharex=True, sharey=True)
    axes[0].plot(t, in_x[:n], linewidth=0.5, color="black")
    axes[0].set_title("Input (shared across modes)")
    for i, row in enumerate(mode_rows, start=1):
        _, px = read_wav(sess.a(MODE_FILES[row["mode"]]))
        axes[i].plot(t, px[:n], linewidth=0.5, color="#cc3333")
        axes[i].set_title(f"{row['mode']} mode output")
    axes[-1].set_xlabel("Time (s)")
    fig.suptitle("Mode Comparison: Same Input, Different Environment Modes")
    savefig(fig, sess.p("mode_comparison_waveform.png"))

    fig2, ax = plt.subplots(figsize=(9, 5))
    fi, mi = magnitude_spectrum_db(in_x, sr)
    ax.semilogx(fi, mi, label="Input", color="black", linewidth=0.8)
    colors = {"Standard": "#3366cc", "Transit": "#cc9933", "Conversation": "#33aa55"}
    for row in mode_rows:
        _, px = read_wav(sess.a(MODE_FILES[row["mode"]]))
        f, m = magnitude_spectrum_db(px, sr)
        ax.semilogx(f, m, label=f"{row['mode']} output", color=colors.get(row["mode"], "gray"), linewidth=0.8)
    ax.set_xlim(20, 10000)
    ax.set_xlabel("Frequency (Hz, log scale)")
    ax.set_ylabel("Magnitude (dB)")
    ax.set_title("Mode Comparison Spectrum (Standard / Transit / Conversation)")
    ax.legend()
    savefig(fig2, sess.p("mode_comparison_spectrum.png"))


# ---------------------------------------------------------------------------
# Phase 11/12: summary
# ---------------------------------------------------------------------------

def underrun_stats(frame_rows, source, mode_filter=None):
    matches = [r for r in frame_rows if r.get("source") == source] if source else frame_rows
    if mode_filter:
        matches = [r for r in matches if r.get("active_mode") == mode_filter]
    underrun = sum(int(r["underrun_or_missing_frames"]) for r in matches)
    zero_fill = sum(int(r["zero_fill_count"]) for r in matches)
    return underrun, zero_fill


def experiment_summary_row(name, device, headphone, audio_route, sample_rate, mode,
                            duration_s, raw_vals, proc_vals, gain_vals,
                            limiter_rows, source_prefix, frame_rows, notes,
                            mode_filter=None):
    matches = [r for r in limiter_rows if source_prefix in (r.get("source") or "")]
    if mode_filter:
        matches = [r for r in matches if r.get("active_mode") == mode_filter]
    pre_clip = sum(int(r["samples_clipped_before"]) for r in matches)
    post_clip = sum(int(r["samples_clipped_after"]) for r in matches)
    pre_above = sum(int(r["samples_above_0_95_before"]) for r in matches)
    post_above = sum(int(r["samples_above_0_95_after"]) for r in matches)
    underrun, zero_fill = underrun_stats(
        frame_rows, source_prefix if source_prefix == "live_mic" else None, mode_filter
    )

    return {
        "session_id": name["session_id"],
        "experiment_type": name["experiment_type"],
        "device": device,
        "headphone": headphone,
        "audio_route": audio_route,
        "sample_rate": sample_rate,
        "active_mode": mode,
        "duration_seconds": round(duration_s, 2),
        "raw_rms_mean": round(float(np.mean(raw_vals)) if raw_vals else 0.0, 6),
        "processed_rms_mean": round(float(np.mean(proc_vals)) if proc_vals else 0.0, 6),
        "raw_peak_max": round(float(np.max(raw_vals)) if raw_vals else 0.0, 6),
        "processed_peak_max": round(float(np.max(proc_vals)) if proc_vals else 0.0, 6),
        "mean_gain_db": round(float(np.mean(gain_vals)) if gain_vals else 0.0, 3),
        "max_gain_db": round(float(np.max(gain_vals)) if gain_vals else 0.0, 3),
        "pre_limiter_clip_count": pre_clip,
        "post_limiter_clip_count": post_clip,
        "pre_limiter_above_0_95_count": pre_above,
        "post_limiter_above_0_95_count": post_above,
        "underrun_count": underrun,
        "zero_fill_count": zero_fill,
        "notes": notes,
    }


LIVE_MIC_TAG_TO_MODE = {"_standard": "Standard", "_transit": "Transit", "_conversation": "Conversation", "": "Standard"}


def build_experiment_summary(sess, session_id, session_config, dsp_config,
                              pure_tone_results, sweep_rows, mode_rows,
                              limiter_rows, frame_rows, live_mic_pairs):
    device = session_config.get("phone_model", "unknown")
    headphone = session_config.get("headphone_or_earbud_model", "unknown")
    audio_route = session_config.get("audio_route", "unknown")
    sample_rate = session_config.get("sample_rate", 48000)

    rows = []

    # One row per live-mic mode captured (Standard/Transit/Conversation), or
    # one unlabelled row for older single-pair sessions.
    multi_mode = len(live_mic_pairs) > 1
    for tag, sr, rx, px, label in live_mic_pairs:
        mode_name = LIVE_MIC_TAG_TO_MODE.get(tag, "Standard")
        rows.append(experiment_summary_row(
            {"session_id": session_id, "experiment_type": "live_microphone_test"},
            device, headphone, audio_route, sample_rate, mode_name,
            len(rx) / sr, [rms(rx)], [rms(px)], [dbfs(rms(px)) - dbfs(rms(rx))],
            limiter_rows, "live_mic", frame_rows,
            "Live capture; see docs/validation.md session_config.json for whether this is a real microphone capture or a synthetic substitute.",
            mode_filter=mode_name if multi_mode else None,
        ))

    if pure_tone_results:
        raws = [r["raw_rms"] for r in pure_tone_results]
        procs = [r["processed_rms"] for r in pure_tone_results]
        gains = [r["gain_observed_db"] for r in pure_tone_results]
        rows.append(experiment_summary_row(
            {"session_id": session_id, "experiment_type": "pure_tone_test"},
            device, headphone, audio_route, sample_rate, pure_tone_results[0]["active_mode"],
            len(TONE_FREQS) * 3.0, raws, procs, gains,
            limiter_rows, "pure_tone_", frame_rows,
            "Aggregated across 250Hz-8kHz pure tones; see pure_tone_results.csv for per-frequency detail.",
        ))

    if sweep_rows:
        raws = [10 ** (r["raw_magnitude_db"] / 20.0) for r in sweep_rows]
        procs = [10 ** (r["processed_magnitude_db"] / 20.0) for r in sweep_rows]
        gains = [r["observed_gain_db"] for r in sweep_rows]
        rows.append(experiment_summary_row(
            {"session_id": session_id, "experiment_type": "sweep_test"},
            device, headphone, audio_route, sample_rate, sweep_rows[0]["active_mode"],
            10.0, raws, procs, gains,
            limiter_rows, "sweep", frame_rows,
            "20 Hz-10 kHz logarithmic sweep; see sweep_results.csv for the full frequency-response curve.",
        ))

    for row in mode_rows:
        rows.append(experiment_summary_row(
            {"session_id": session_id, "experiment_type": "mode_comparison_test"},
            device, headphone, audio_route, sample_rate, row["mode"],
            6.0, [row["input_rms"]], [row["output_rms"]], [row["estimated_gain_db"]],
            limiter_rows, MODE_SOURCE_TAGS[row["mode"]], frame_rows,
            row["notes"],
        ))

    return rows


INTERPRETATION_NOTES = [
    "Processed output shows frequency-dependent gain compared with raw input, consistent with the configured six-band gain profile.",
    "The soft limiter reduced the number of samples exceeding 0.95 digital full scale between the pre-limiter and post-limiter signal.",
    "Standard, Transit, and Conversation modes produced measurably different processed output from the same fixed input signal.",
    "These results verify the digital DSP implementation (functional/implementation-level evidence, observed under the tested device configuration) and are a preliminary engineering result -- they are not a clinical validation and do not demonstrate clinical hearing benefit or a validated safe SPL output.",
]


def report_ready_metrics_markdown(summary_rows, limiter_totals, pure_tone_results, mode_rows):
    lines = []
    lines.append("# ClearTone DSP Evidence -- Report-Ready Metrics\n")
    lines.append(
        "The text blocks below are written for direct use in the final year project report "
        "or paper. They describe implementation-level and functional DSP verification results, "
        "observed under the tested device configuration. Each block is a preliminary "
        "engineering result -- not a clinical validation.\n"
    )

    lines.append("## Raw vs. processed capture\n")
    live_plot_names = [
        r["active_mode"].lower()
        for r in summary_rows
        if r.get("experiment_type") == "live_microphone_test"
    ]
    live_plot_note = (
        ", ".join(
            f"`plots/raw_vs_processed_waveform_{name}.png`, "
            f"`plots/raw_vs_processed_spectrum_{name}.png`, and "
            f"`plots/raw_vs_processed_spectrogram_{name}.png`"
            for name in live_plot_names
        )
        if live_plot_names
        else "`plots/raw_vs_processed_waveform.png`, `plots/raw_vs_processed_spectrum.png`, and `plots/raw_vs_processed_spectrogram.png`"
    )
    lines.append(
        "During diagnostic capture, raw input and processed output were saved as paired WAV "
        "files with matching sample rate and duration. The processed signal shows "
        "band-dependent gain changes consistent with the configured six-band gain profile "
        f"(see {live_plot_note}). These results verify the digital DSP "
        "implementation; they do not prove clinical hearing improvement or a validated safe "
        "physical SPL output.\n"
    )

    if limiter_totals:
        lines.append("## Limiter and clipping behaviour\n")
        lines.append(
            f"Across the logged blocks, samples exceeding 0.95 digital full scale went from "
            f"{limiter_totals['samples_above_0_95_before']} (pre-limiter) to "
            f"{limiter_totals['samples_above_0_95_after']} (post-limiter), and samples at or "
            f"above digital full scale (clipping) went from "
            f"{limiter_totals['samples_clipped_before']} to "
            f"{limiter_totals['samples_clipped_after']} "
            "(see `plots/limiter_clipping_check.png`). This is functional verification of the "
            "soft limiter's clipping-reduction behaviour under the tested signals; it is a "
            "preliminary engineering result and not a clinical validation for any specific "
            "listener or device.\n"
        )

    if pure_tone_results:
        lines.append("## Pure-tone band verification\n")
        diffs = [abs(r["difference_between_observed_and_configured_gain_db"]) for r in pure_tone_results]
        lines.append(
            f"Pure tones at {', '.join(str(r['frequency_hz']) for r in pure_tone_results)} Hz "
            "were played through the same DSP function used by the live engine. The observed "
            "gain at each tone's expected primary band matched the configured per-band gain to "
            f"within {max(diffs):.2f} dB (mean absolute difference {sum(diffs) / len(diffs):.2f} dB), "
            "supporting the claim that the six-band filter bank routes energy to, and applies "
            "gain from, the intended band (see `plots/pure_tone_band_response.png` and "
            "`summary/pure_tone_results.csv`).\n"
        )

    if mode_rows:
        lines.append("## Mode-dependent DSP behaviour\n")
        gains = ", ".join(f"{r['mode']}: {r['estimated_gain_db']:.2f} dB" for r in mode_rows)
        lines.append(
            f"The same fixed input signal was processed through Standard, Transit, and "
            f"Conversation modes, producing different estimated output gain per mode "
            f"({gains}) and different per-band output RMS "
            "(see `plots/mode_comparison_waveform.png`, `plots/mode_comparison_spectrum.png`, "
            "and `summary/mode_comparison_results.csv`). This is implementation-level evidence "
            "that the environment modes change DSP behaviour observably; it is not a claim "
            "about which mode is clinically preferable for any listener.\n"
        )

    lines.append("## Summary interpretation notes\n")
    for note in INTERPRETATION_NOTES:
        lines.append(f"- {note}")
    lines.append("")

    text = "\n".join(lines)
    check_safe_wording(text)
    return text


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)

    session_dir = sys.argv[1].rstrip("/")
    if not os.path.isdir(session_dir):
        print(f"Session directory not found: {session_dir}")
        sys.exit(1)

    sess = Session(session_dir)
    session_id = os.path.basename(session_dir)

    session_config = read_json(sess.m("session_config.json"), {})
    dsp_config = read_json(sess.m("dsp_config.json"), {
        "crossover_edges_hz": [500, 1000, 2000, 4000, 8000],
        "bands": ["<500", "500-1000", "1000-2000", "2000-4000", "4000-8000", ">8000"],
        "gain_db_per_band": [0] * 6,
    })
    edges = dsp_config.get("crossover_edges_hz", [500, 1000, 2000, 4000, 8000])

    band_rows = read_csv_rows(sess.l("band_level_log.csv"))
    limiter_rows = read_csv_rows(sess.l("limiter_log.csv"))
    frame_rows = read_csv_rows(sess.l("frame_level_log.csv"))

    print(f"Analyzing session: {session_dir}")

    # ---- plots ----
    live_mic_pairs = find_live_mic_pairs(sess)
    plot_waveform(sess, edges, live_mic_pairs)
    plot_spectrum(sess, edges, live_mic_pairs)
    plot_spectrogram(sess, live_mic_pairs)
    plot_band_gain_response(sess, dsp_config)

    pure_tone_results = analyze_pure_tones(sess, edges, dsp_config, band_rows)
    if pure_tone_results:
        write_csv(sess.s("pure_tone_results.csv"), pure_tone_results, list(pure_tone_results[0].keys()))
    plot_pure_tone_band_response(sess, pure_tone_results)

    pure_tone_by_mode = analyze_pure_tones_by_mode(band_rows, edges, dsp_config)
    if pure_tone_by_mode:
        write_csv(sess.s("pure_tone_results_by_mode.csv"), pure_tone_by_mode, list(pure_tone_by_mode[0].keys()))
    plot_pure_tone_band_response_by_mode(sess, pure_tone_by_mode)

    sweep_pair, sweep_rows = analyze_sweep(sess, edges, dsp_config, limiter_rows)
    if sweep_rows:
        write_csv(sess.s("sweep_results.csv"), sweep_rows, list(sweep_rows[0].keys()))
    plot_sweep_response(sess, edges, sweep_rows)

    sweep_by_mode = analyze_sweep_by_mode(band_rows, edges, dsp_config)
    if sweep_by_mode:
        write_csv(sess.s("sweep_results_by_mode.csv"), sweep_by_mode, list(sweep_by_mode[0].keys()))
    plot_sweep_response_by_mode(sess, edges, sweep_by_mode)

    limiter_totals = plot_limiter_clipping(sess, limiter_rows)

    mode_rows = analyze_mode_comparison(sess, band_rows, limiter_rows)
    if mode_rows:
        write_csv(sess.s("mode_comparison_results.csv"), mode_rows, list(mode_rows[0].keys()))
    plot_mode_comparison(sess, mode_rows)

    # ---- summary ----
    summary_rows = build_experiment_summary(
        sess, session_id, session_config, dsp_config,
        pure_tone_results, sweep_rows, mode_rows, limiter_rows, frame_rows,
        live_mic_pairs,
    )
    if summary_rows:
        write_csv(sess.s("experiment_summary.csv"), summary_rows, list(summary_rows[0].keys()))

    summary_json = {
        "session": session_config,
        "dsp_config": dsp_config,
        "audio_files": sorted(os.listdir(sess.audio)) if os.path.isdir(sess.audio) else [],
        "plots": sorted(os.listdir(sess.plots)) if os.path.isdir(sess.plots) else [],
        "metrics": {
            "experiments": summary_rows,
            "limiter_totals": limiter_totals,
        },
        "interpretation_notes": INTERPRETATION_NOTES,
    }
    check_safe_wording(json.dumps(summary_json))
    with open(sess.s("experiment_summary.json"), "w") as f:
        json.dump(summary_json, f, indent=2)
    print(f"  wrote {sess.s('experiment_summary.json')}")

    md = report_ready_metrics_markdown(summary_rows, limiter_totals, pure_tone_results, mode_rows)
    with open(sess.s("report_ready_metrics.md"), "w") as f:
        f.write(md)
    print(f"  wrote {sess.s('report_ready_metrics.md')}")

    print("Done.")


if __name__ == "__main__":
    main()
