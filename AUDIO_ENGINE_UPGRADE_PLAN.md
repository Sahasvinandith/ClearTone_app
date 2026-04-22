# ClearTone Audio Engine Upgrade — Implementation Plan (V2)

> Production-grade real-time pipeline for the `master` branch

---

## Current State (found in repo)

| Component | Location | Issue |
|---|---|---|
| Offline WAV processor | `Audio_Engine_Clear_tone/.../main.cpp` | File-based only; has LR4 biquad crossover but no real-time use |
| Real-time Oboe engine | `Audio_Engine_Clear_tone/.../oboe_engine.cpp` | Input-driven (wrong), uses mutex in hot path, SVF crossover (not LR4) |
| Desktop PortAudio POC | `Audio_Engine_Clear_tone/.../realtime_multiband_stream.cpp` | Has correct LR4 — Android can't use it |
| Dart FFI bindings | `lib/audio_engine_ffi.dart` | Good — all 10 symbols must be preserved |
| Android build | `android/app/build.gradle.kts` | Points at untracked external POC dir — must be fixed |

### Critical Bugs in the Current Real-Time Engine

1. Input-callback-driven (blocking `playingStream->write()` inside input callback)
2. `std::mutex` locked on every callback — priority inversion risk
3. `SVF subtraction` crossover — not true LR4, causes band-sum errors
4. `exp()`, `pow()`, `log10()` called per-sample in the compressor
5. `captureBuffer.insert()` inside callback — heap allocation in hot path
6. No lock-free ring buffer — no input/output decoupling

---

## Target Architecture (NON-NEGOTIABLE)

### Single Integrated Engine

```
android/app/src/main/cpp/
├── audio_engine.cpp     ← single consolidated engine
├── audio_engine.h       ← FFI function declarations
└── CMakeLists.txt
```

- Remove dependency on external POC directory
- Build via CMake, expose via Dart FFI
- Preserve all existing FFI function signatures

### Target Pipeline

```
[Input Callback] — push only, no DSP
        ↓
Lock-free SPSC Ring Buffer (float, mono)
        ↓
[Output Callback]
        ↓
DC Blocker
        ↓
LR4 Crossover (biquad, pre-warped, TDF-II)
        ↓
6 Bands (sequential split: LP/HP chain)
        ↓
Per-band:
   - Envelope follower (linear domain)
   - Compressor (NO transcendentals in loop)
   - Gain (smoothed)
        ↓
Band Sum → × masterGain → Soft Limiter
        ↓
Output (mono → stereo duplication)
```

---

## Phase-by-Phase Plan

### Phase 1 — Scaffold: Move C++ Into the Android Source Tree

**Goal:** Eliminate POC directory dependency. Confirm build works.

**Files:**
- **Create:** `android/app/src/main/cpp/CMakeLists.txt`
- **Create:** `android/app/src/main/cpp/audio_engine.cpp` (initially a copy of oboe_engine.cpp)
- **Create:** `android/app/src/main/cpp/audio_engine.h`
- **Modify:** `android/app/build.gradle.kts` — point CMake path to `src/main/cpp/CMakeLists.txt`
- Keep `Audio_Engine_Clear_tone/` as read-only reference until Phase 9

**Validation:** `flutter build apk --debug` succeeds; app still works identically.

---

### Phase 2 — Lock-Free SPSC Ring Buffer + Output-Driven Callback

**Goal:** Decouple input/output streams. No blocking in any callback.

**Implementation:**
- Add SPSC (Single Producer, Single Consumer) ring buffer class
- Fixed size = next power-of-two ≥ 4× output burst frames (pre-allocated before stream start)
- Input callback: push raw mic samples into ring buffer only — no processing
- Output callback: pop from ring buffer → run DSP chain → write output
- Register `setDataCallback` on the **output stream only**
- Input stream has its own separate callback (push-only, no read/write between streams)

**Ring buffer definition (canonical — applies everywhere in this plan):**
```
The ring buffer is a lock-free SPSC circular buffer of raw float samples only.
It operates strictly on block-based API calls (push/pop with sample counts).
Internally it stores a contiguous circular float array with fixed capacity
allocated once at stream start. No frame structs exist inside the buffer.
Frame size is a callback concept handled by the DSP layer, not the buffer.

Frame boundaries exist only at DSP processing level, not inside buffer storage.

Explicit API:
  push(const float* samples, int numSamples)
  pop(float* outSamples, int numSamples)

- numSamples is determined by the Oboe callback; the buffer is agnostic to it
- No per-sample push/pop — always operate on full blocks
- Internal storage: std::unique_ptr<float[]> or static fixed array
- Forbidden internally: std::vector, any STL container with dynamic backing
- Fixed capacity for the entire stream lifetime — no resizing after init
```

**Overflow / underrun behaviour (strict):**
- **On overflow:** DROP OLDEST samples (ring overwrites — newer mic data is more valuable)
- **On underrun:** output zeros (silence)

**Expose diagnostic counters:**
```cpp
std::atomic<uint32_t> underrunCount{0};
std::atomic<uint32_t> overflowCount{0};
```

**Validation:** Audio passes through cleanly; ring buffer adds ≤2 burst periods of latency; underrun count near zero at steady state.

> Expected latency: ~2–3 × burst size (typically 10–30 ms depending on device)

---

### Phase 3 — LR4 Crossover with Cascaded Biquads (TDF-II, Pre-Warped)

**Goal:** Replace `ParallelCrossover6` / SVF subtraction with proper Linkwitz-Riley 4th-order crossover.

**Pre-warping (correct form — do NOT compute a separate warped frequency):**
```cpp
K = tan(M_PI * fc / fs);   // bilinear pre-warp, computed once at init
```
Then derive all biquad coefficients from `K` using the standard bilinear transform formulas.

**Biquad structure — Transposed Direct Form II (required):**
```cpp
y  = b0*x + z1;
z1 = b1*x - a1*y + z2;
z2 = b2*x - a2*y;
```

**Configuration:**
- 5 crossover frequencies → 6 bands
- Each LR4 crossover is implemented as a cascade of two identical 2nd-order Butterworth biquads (Q = 0.70710678). The Linkwitz-Riley response is achieved by cascading identical Butterworth stages, producing a squared magnitude response. No per-stage Q tuning beyond Butterworth design is allowed.
- Default crossover frequencies: 500 Hz, 1 kHz, 2 kHz, 4 kHz, 8 kHz

**Band construction (sequential splitting):**
```
band0 = LP(f1)
band1 = HP(f1) → LP(f2)
band2 = HP(f2) → LP(f3)
band3 = HP(f3) → LP(f4)
band4 = HP(f4) → LP(f5)
band5 = HP(f5)
```

**Safety on biquad state:**
```cpp
if (!std::isfinite(z1)) z1 = 0.0f;
if (fabs(z1) < 1e-15f)  z1 = 0.0f;
```

**Validation:** Feed white noise, sum all 6 bands → must be flat ±0.5 dB (20 Hz–20 kHz).

---

### Phase 4 — Linear-Domain Compressor (No log/exp in Hot Path)

**Goal:** Safe, CPU-efficient compressor with no transcendentals in the audio loop.

**Canonical transcendental function rule (single source of truth — applies everywhere):**
```
All transcendental functions (exp, log, pow, sin, cos, sqrt) are strictly
forbidden inside the audio callback.

They may only be used in parameter update or initialization threads before activation.

The audio callback must use only precomputed coefficients and basic arithmetic:
  Allowed per-sample: multiply, add, subtract, divide, fabs, fminf, fmaxf
  Forbidden per-sample: exp, log, pow, sin, cos, sqrt — and any function
                        that calls them internally
```

**Precompute on parameter update only (never per-sample):**
```cpp
attackCoeff  = exp(-1.0f / (attack  * fs));
releaseCoeff = exp(-1.0f / (release * fs));
thresholdLin = db_to_linear(thresholdDb);
ratio_factor = 1.0f - 1.0f / ratio;   // precomputed constant
```

**Envelope follower (linear domain, per-sample):**
```cpp
float absx = fabs(x);
env = (absx > env)
    ? attackCoeff  * env + (1.0f - attackCoeff)  * absx
    : releaseCoeff * env + (1.0f - releaseCoeff) * absx;
```

**Gain reduction (per-sample — multiply/add/divide only):**
```cpp
float x = env / thresholdLin;
float gain = (env > thresholdLin)
    ? 1.0f / (1.0f + ratio_factor * (x - 1.0f))
    : 1.0f;
gain = fminf(gain, 1.0f);
```

> `fminf(gain, 1.0f)` prevents numerical overshoot causing unintended gain > 1.0.
> **Do NOT use bit-cast log2/exp2 hacks** — they introduce audible artifacts at compression extremes.

**Validation:** Compare output of new compressor vs. reference on a 1 kHz sine sweep — max deviation < 0.1 dB.

---

### Phase 5 — Thread-Safe Parameter Updates

**Goal:** Replace `std::mutex paramMutex` with lock-free double-buffered parameter struct.

**Implementation:**
```cpp
struct DspParams {
    float makeupLin[6];
    float thresholdLin[6];   // precomputed linear threshold
    float ratio_factor[6];   // precomputed (1 - 1/ratio) per band
    float attackCoeff[6];    // precomputed exp coefficient
    float releaseCoeff[6];   // precomputed exp coefficient
    float masterGain;
    float wet;
    float dry;
};

DspParams params[2];
std::atomic<int> activeIndex{0};
```

- UI thread writes to `params[1 - activeIndex.load(relaxed)]`, precomputes all coefficients there, then flips with `activeIndex.store(newIdx, memory_order_release)`
- Audio thread reads `params[activeIndex.load(memory_order_acquire)]` — never blocks, never skips a frame waiting

**Thread ownership rule (non-negotiable):**
```
The audio thread exclusively owns DSP execution.
The UI thread may only modify parameter buffers via atomic double buffering.
The UI thread must never directly access or modify DSP state variables.
```

**Parameter smoothing (to prevent audible clicks on parameter changes):**
```text
Smoothing runs in the audio thread only.
It operates on a local snapshot of DspParams (fetched via atomic read).
It MUST NOT modify the shared DspParams struct.
Smoothed values are stored in local DSP state, not in shared DspParams.

Smoothing must be applied PER BAND and PER PARAMETER
(e.g., gain, threshold, ratio) to avoid inter-band coupling:

  smoothedParam[band] += smoothingCoeff * (targetParam[band] - smoothedParam[band]);

Where smoothingCoeff is small (e.g., 0.01–0.001 depending on responsiveness).
Uses only multiply and add — no transcendentals.
```

**Validation:** Rapidly toggle sliders while streaming — no glitches, no `futex_wait` on audio thread in systrace.

---

### Phase 6 — Sample Rate Handling

**Goal:** Use the actual sample rate reported by Oboe, not a hardcoded assumption.

On stream start, after Oboe opens the streams:
```cpp
float fs = (float)outputStream->getSampleRate();
if (fs <= 0) {
    LOGE("Invalid sample rate on first open: %f — retrying stream init", fs);
    // Close and retry stream initialization once
    outputStream->close();
    result = tryOpenStream();  // single retry
    fs = (float)outputStream->getSampleRate();
    if (fs <= 0) {
        LOGE("Invalid sample rate after retry — aborting, surfacing error");
        engineState.store(STATE_ERROR, memory_order_release);
        return;  // DO NOT proceed; Dart layer must handle
    }
}
```
> Retry once before failing. Never silently substitute a default sample rate.
> Only transition to error state after retry failure.

Then recompute:
- All LR4 crossover biquad coefficients (via `K = tan(M_PI * fc / fs)`)
- All compressor `attackCoeff` and `releaseCoeff` (via `exp(-1/(t * fs))`)

**No hardcoded `fs = 48000`** anywhere in the DSP code.

**Validation:** Test on a device that negotiates 44100 Hz — bands and compression must behave identically.

---

### Phase 7 — Channel Handling

**Goal:** Explicit, consistent mono/stereo handling throughout the pipeline.

**Chosen approach: Option A (process mono, duplicate to stereo output)**

```
Input (mono mic)  →  ring buffer (mono float)
                  →  DSP chain (strictly mono — all intermediate stages)
                  →  stereo duplication at final output write only
```

- Input stream: request mono (`setChannelCount(1)`)
- Output stream: request stereo (`setChannelCount(2)`)
- Stereo duplication occurs only at the final output write stage — not earlier:
  ```cpp
  outBuf[i*2]   = processed;
  outBuf[i*2+1] = processed;
  ```
- Internal DSP processing is strictly mono. No stereo processing exists in any intermediate stage.
- If Oboe negotiates a different channel count, handle gracefully (downmix or upmix at the boundary)

**Validation:** Stereo meters on the device show equal L/R. No channel swap or silence on one channel.

---

### Phase 8 — Gain Staging + Soft Limiter

**Goal:** Correct gain staging to prevent the limiter from activating constantly. Ear-safe output.

**Pipeline order:**
```
Band Sum → × masterGain → Soft Limiter → Output
```

> Do NOT perform per-frame normalization. Gain staging must be controlled via per-band gain, master gain, and limiter only.

**DC blocker placement (single source of truth):**
```cpp
// DC blocker — runs immediately after pop(), before crossover
y = x - prev_x + R * prev_y;   // R ≈ 0.995
```
> DC blocking must occur exactly once per sample and only in the DSP chain
> immediately after ring buffer pop and before any crossover or filtering.
> Execution order: `pop()` → DC blocker → crossover → bands → sum → limiter.
> The input callback must remain completely DSP-free (push-only).

**Debug bypass mode:**
```cpp
if (bypass) {
    output = input;
    return;
}
```
> Used to isolate DSP issues during testing.

**Soft limiter (canonical definition — fixed, do not vary):**
```cpp
inline float soft_clip(float x) {
    if (!std::isfinite(x)) return 0.0f;  // NaN/Inf guard — must come first
    return x / (1.0f + 0.7f * fabs(x));
}
```
> The coefficient 0.7 is fixed and must not be tuned per device or runtime condition.
> It is part of perceptual loudness calibration for this hearing aid application.

**Safety hardening:**
- Enable ARM FTZ (Flush-To-Zero) at stream start to hardware-suppress denormals
- NaN gate after limiter: `if (!std::isfinite(out)) out = 0.0f;`
- Denormal gate on every filter state variable: `if (fabs(z) < 1e-15f) z = 0.0f;`
- Clamp raw input samples to `[-1.0f, 1.0f]` before entering the ring buffer to prevent overflow, NaN propagation, and unstable amplification

**Startup click prevention (50 ms ramp):**
```cpp
float rampGain = 0.0f;
const float rampStep = 1.0f / (0.05f * fs);  // precomputed
// in callback:
rampGain = fminf(1.0f, rampGain + rampStep);
out *= rampGain;
```

**Validation:** Feed +6 dBFS signal → output never exceeds 0 dBFS. No audible click on stream start.

---

### Phase 9 — Stream Error Handling and Reconnection

**Goal:** Automatic restart on Bluetooth disconnect.

**Implementation:**
- `onError` sets `std::atomic<int> engineState = 2` (ERROR_NEEDS_RESTART) — **never restarts inside the callback** (Oboe restriction)
- Expose via FFI:
  ```cpp
  // returns: 0 = STOPPED, 1 = RUNNING, 2 = ERROR_NEEDS_RESTART
  int get_engine_state_ffi();
  ```
- Dart reconnect timer queries state → calls `stop_rt_stream_ffi()` then `start_rt_stream_ffi()`
- On restart: `DspParams` double buffer survives (no re-initialisation needed); crossover and compressor coefficients recomputed from actual stream sample rate

**Files to modify:**
- `lib/audio_engine_ffi.dart` — add `getEngineState()` binding
- `lib/Pages/amplification_screen.dart` — update reconnect timer to use the state enum

**Validation:** Unplug BT headset mid-stream → app recovers automatically within one timer cycle (≤2 seconds).

---

### Phase 10 — Pre-Allocation Audit and Hot-Path Cleanup

**Goal:** Zero allocations, zero mutexes, zero heavy calls anywhere in audio callbacks.

**Checklist:**
- [ ] Ring buffer allocated before stream start, never resized
- [ ] Debug capture (`captureBuffer`) guarded by atomic check — no mutex cost on the common (non-capturing) path
- [ ] No `std::vector::push_back`, `new`, or `malloc` in any callback
- [ ] All `__android_log_print` calls behind `++counter % 200 == 0` throttle
- [ ] All hot-path math is `float`, not `double`
- [ ] `outDataBuffer` from old engine removed (replaced by ring buffer)
- [ ] Sharing mode: `SharingMode::Shared` (default); optional `Exclusive` path for low latency

**Validation:** `simpleperf` 30-second profile — zero `malloc`/`free`, zero `futex_wait`, target CPU usage: <10% on a mid-range device.

---

### Phase 11 — Remove POC Directory and Finalize

**Goal:** Clean repository, confirmed standalone build.

**Actions:**
- Remove or gitignore `Audio_Engine_Clear_tone/`
- Verify `build.gradle.kts` no longer references the old CMake path
- Confirm `git status` shows no unintended untracked files
- Confirm clean clone + `flutter build apk --debug` succeeds end-to-end

---

## File Change Map

| File | Phase | Action |
|---|---|---|
| `android/app/src/main/cpp/CMakeLists.txt` | 1 | **Create** |
| `android/app/src/main/cpp/audio_engine.cpp` | 1–10 | **Create → iterative rewrite** |
| `android/app/src/main/cpp/audio_engine.h` | 1 | **Create** |
| `android/app/build.gradle.kts` | 1 | **Modify** CMake path |
| `lib/audio_engine_ffi.dart` | 9 | **Modify** — add `getEngineState()` |
| `lib/Pages/amplification_screen.dart` | 9 | **Modify** — update reconnect logic |
| `android/app/src/main/kotlin/.../MainActivity.kt` | — | **No changes** |
| `Audio_Engine_Clear_tone/` | 11 | **Remove / gitignore** |

---

## Real-Time Safety Rules (STRICT)

Inside audio callbacks, **NEVER**:
- Allocate memory (`new`, `malloc`, vector resize)
- Call any transcendental math functions (`exp`, `pow`, `log`, `sin`, etc.) inside the audio callback
- Use locks or blocking calls
- Log without a throttle counter (`++counter % 200 == 0`)
- Use bit-cast hacks for log2/exp2 — they cause audible artifacts at extremes

**DSP memory safety — strict C-style only:**
```
DSP code must be C-style only or fixed-size plain structs.

Allowed in DSP path:
  float[]          — fixed-size arrays
  struct           — plain structs, no constructors with allocation
  std::atomic      — for cross-thread state flags and indices only

Forbidden everywhere in DSP path:
  std::vector      — dynamic allocation
  std::string      — dynamic allocation
  std::function    — heap closure allocation
  any allocator    — no new, malloc, delete, free
  virtual methods  — vtable dispatch incompatible with real-time constraints
  STL containers   — any with dynamic backing store
```

**Latency constraint:**
```
Total end-to-end processing latency must remain ≤ 30 ms under all configurations.
Any architectural change must preserve this constraint.
```

**Determinism rule:**
```
DSP must be sample-deterministic: identical input always produces identical output
regardless of thread scheduling or timing variations.
No randomness, no time-dependent state, no OS-dependent behavior in the DSP path.
```

---

## Key Design Decisions (Rationale)

| Decision | Choice | Reason |
|---|---|---|
| Pre-warping formula | `K = tan(π·fc/fs)` directly | Bilinear transform — no separate "warped fc" step needed |
| Compressor domain | Linear (no log/exp per sample) | Real-time safe; exp approximations introduce audible errors |
| Limiter type | `x / (1 + 0.7·\|x\|)` rational soft clip | Fixed coefficient for perceptual loudness calibration; bounded output; NaN-guarded |
| Channel strategy | Mono process → stereo out | Simplest and lowest CPU; hearing aid mic is always mono |
| Overflow handling | Drop oldest | Newer mic data is more valuable for real-time hearing aid |
| Sample rate source | From Oboe `getSampleRate()` | Device may negotiate 44100; never assume 48000 |

---

## Risk Register

| Risk | Severity | Mitigation |
|---|---|---|
| Ring buffer underrun causes audio gaps | Medium | Size at 4× burst; fill silence on underrun; expose `underrunCount` for tuning |
| Ring buffer overflow wastes mic data | Low | Drop oldest; expose `overflowCount`; size 4× burst gives ample headroom |
| LR4 coefficient error causes phase/amplitude anomaly | Medium | Validate band sum = flat with white noise before integrating into callback |
| Compressor gain approximation inaccuracy | Low | Rational approximation `1/(1+ratio_factor*(x-1))` is real-time safe; validate against reference with max 0.1 dB deviation |
| `std::atomic` memory ordering bug causes stale params | Low | Simple flip with acquire/release is well-proven; unit-testable offline |
| CMake migration breaks the build | Medium | Phase 1 is purely structural — validate build before any DSP changes |
| Bluetooth SCO regression from engine rewrite | High | SCO control plane (Kotlin) is NOT touched; FFI symbol names preserved; test SCO explicitly after each phase |
| Wrong sample rate assumption | Medium | Coefficient recomputation on stream open (Phase 6) eliminates this entirely |

---

## Validation Checklist (Final)

- [ ] No crackling under load
- [ ] No memory allocation during callback
- [ ] Stable CPU usage (<10% on mid-range device)
- [ ] Band sum ≈ original signal (±0.5 dB) — white noise test
- [ ] No NaN / Inf values in output
- [ ] Works with Bluetooth SCO devices
- [ ] No silence gaps; underrun count near zero
- [ ] Compressor output deviation < 0.1 dB vs. reference
- [ ] Auto-reconnect on BT disconnect within 2 seconds
- [ ] No click on stream start (50 ms ramp)
- [ ] Correct stereo output (equal L/R)
- [ ] End-to-end latency ≤ 30 ms measured on device
- [ ] DSP output is sample-deterministic (same input → same output across runs)

---

## Sprint Allocation

| Sprint | Phases | Focus |
|---|---|---|
| Sprint 1 | 1–3 | Scaffold + ring buffer + LR4 crossover — highest risk/value |
| Sprint 2 | 4–7 | Compressor + thread-safe params + sample rate + channel handling |
| Sprint 3 | 8–11 | Limiter + gain staging + error handling + audit + cleanup |

**Minimum viable milestone:** After Phase 3 the engine has the correct architecture and production-quality DSP. Phases 4–10 are correctness, safety, and robustness hardening.
