# ClearTone — Branch Difference Report
**`master`** vs **`daham/stable-v1`**
_Generated: 2026-04-29_

---

## 1. `android/app/src/main/cpp/audio_engine.cpp` — Complete rewrite

This is the only file that affects audio quality. Everything else is config.

---

### 1a. Audio I/O Architecture

| | master | daham/stable-v1 |
|---|---|---|
| **Approach** | Separate input + output streams, custom ring buffer between them | Single output stream; output callback directly reads from input stream |
| **Ring buffer** | Custom SPSC lock-free ring buffer, sized to `max(inBurst, outBurst) × 8` | None — Oboe handles internal buffering |
| **Sharing mode** | `Shared` | `Exclusive` |
| **Lines of code** | 1135 | 458 |

**master:** Input pushes samples into a ring buffer; output pops from it. More complex, more control, but the ring buffer mismatch (960-frame input vs 96-frame output) caused the overflow/underrun noise seen in communication mode.

**daham/stable-v1:** The output callback directly calls `inputStream_->read()` with `timeoutNs=0`. Much simpler. Oboe handles the internal FIFO. This is why it doesn't have the ring buffer overflow problem.

---

### 1b. Compressor Algorithm — Root cause of the quality difference

| | master | daham/stable-v1 |
|---|---|---|
| **Gain computation domain** | Linear | **dB (correct)** |
| **Gain formula** | `gain = 1 / (1 + ratio_factor × (r − 1))` | `gainDb = threshold + over/ratio − envDb` |

**master** computes gain entirely in the linear amplitude domain. The formula is a linear approximation that does not accurately model the dB-domain compression curve. It tends to under-compress loud signals and apply inconsistent gain reduction across levels, which partially cancels the makeup gain (hearing loss compensation).

**daham/stable-v1** implements the textbook compressor formula in dB:
```
output_dB = threshold + (input_dB − threshold) / ratio
gain_dB   = output_dB − input_dB
```
This is mathematically correct. The compressor holds back loud sounds proportionally, so the makeup gain (hearing loss compensation) has full effect. **This is the primary reason daham sounds better at amplification.**

---

### 1c. Compressor Attack/Release Coefficients

| | master | daham/stable-v1 |
|---|---|---|
| **When computed** | Once per `updateParams()` call, stored as coefficients | Recalculated every single sample inside the audio callback |

**master:** Precomputed, efficient — `exp()` called only on parameter updates.

**daham/stable-v1:** Recomputes `exp()` twice per sample per band (12 exp calls per sample). More CPU-intensive but functionally identical since parameters don't change mid-stream.

---

### 1d. Biquad / Crossover Filter Design

| | master | daham/stable-v1 |
|---|---|---|
| **Coefficient method** | Pre-warped bilinear: `K = tan(π × fc / fs)` | Standard bilinear: `w0 = 2π × fc / fs`, `alpha = sin(w0) / (2Q)` |
| **State storage** | Separate `BiquadCoeffs` + `BiquadState` structs | All in one `Biquad` struct |
| **Crossover structure** | Two separate `LR4Filter` arrays: `lpFilters[5]` + `hpFilters[5]` | Encapsulated in a `Crossover6` struct |

Both are LR4 (Linkwitz-Riley 4th order) crossovers at the same 5 frequencies: **500, 1000, 2000, 4000, 8000 Hz**.

The pre-warping in master is slightly more accurate at frequencies close to Nyquist. At these crossover frequencies the audible difference is negligible.

---

### 1e. Additional DSP in master (absent in daham/stable-v1)

| Feature | master | daham/stable-v1 |
|---|---|---|
| **DC blocker** | Yes — coefficient `0.995` | No |
| **Startup ramp** | Yes — 50 ms fade-in on engine start | No |
| **Denormal flush** | Yes — ARM64 FPCR bit + ARMv7 FPSCR bit | No |
| **Soft clipper formula** | `x / (1 + 0.7×|x|)` — smooth, no hard knee | Hard knee at 0.95: `thr + excess / (1 + strength×excess)` |
| **Engine state machine** | `STOPPED / RUNNING / ERROR_NEEDS_RESTART` | `atomic<bool> running_` only |
| **Double-buffered DSP params** | Yes — lock-free param swap | No — params mutated directly on `RealtimeProcessor` |

---

### 1f. Input Preset (AEC handling)

| | master | daham/stable-v1 |
|---|---|---|
| **Input preset** | `Unprocessed` (always — explicitly disables AEC/NS/AGC) | Not set — defaults to Android `Generic` |

**master:** After the fix on 2026-04-29, explicitly uses `Unprocessed` to prevent Android's Acoustic Echo Canceller from treating the amplified speaker output as "echo" and cancelling it from the mic signal. Previously this was set to `VoiceCommunication` in communication mode which caused noise.

**daham/stable-v1:** Does not set an input preset. On most devices Android defaults to `Generic` which does not apply AEC in non-call audio mode, so it works correctly in practice.

---

## 2. `android/app/build.gradle.kts`

| Setting | master | daham/stable-v1 |
|---|---|---|
| **applicationId** | `com.example.cleartone` | `com.example.cleartone.stable` |
| **namespace** | `com.example.cleartone` | `com.example.cleartone` (same — must match Kotlin source package) |
| **Oboe version** | `1.9.0` | `1.8.1` |
| **CMakeLists path** | `src/main/cpp/CMakeLists.txt` | `src/main/cpp/CMakeLists.txt` |
| **`ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES`** | `ON` | Not set |

The `applicationId` difference allows both builds to be installed simultaneously on the same device.

Oboe `1.9.0` (master) vs `1.8.1` (daham) — minor version difference, no breaking API changes between these.

---

## 3. `android/app/src/main/cpp/CMakeLists.txt`

**New file added in daham/stable-v1.** Previously the engine's CMakeLists.txt lived outside the repository at `../../Audio_Engine_Clear_tone/Multiband-hearing-loss-amplification-poc/CMakeLists.txt`. daham moved it inside the repo under `src/main/cpp/`, making the project fully self-contained.

---

## 4. `android/app/src/main/AndroidManifest.xml`

| | master | daham/stable-v1 |
|---|---|---|
| **App label** | `cleartone` | `ClearTone Stable` |

Changed to allow visual distinction when both apps are installed on the same device.

---

## 5. `android/gradle/wrapper/gradle-wrapper.properties`

Functionally identical — both use Gradle `8.12`. Only difference is a timestamp comment line added in daham/stable-v1. No impact.

---

## 6. `.gitignore`

daham/stable-v1 adds `.claude` to the ignore list. No functional impact.

---

## Summary Table

| Area | master | daham/stable-v1 | Winner |
|---|---|---|---|
| Compressor domain | Linear approximation | dB (correct) | **daham** |
| I/O architecture | Ring buffer (SPSC) | Direct stream read | **daham** (simpler, no overflow) |
| AEC handling | Explicitly disabled | Not set (default generic) | **master** (explicit) |
| Filter accuracy | Pre-warped bilinear | Standard bilinear | **master** (marginal) |
| Denormal protection | Yes (ARM FPCR) | No | **master** |
| DC blocker | Yes | No | **master** |
| Startup ramp | Yes | No | **master** |
| Code complexity | High (1135 lines) | Low (458 lines) | **daham** (maintainability) |
| Self-contained build | Yes | Yes (after daham moved CMakeLists) | Tie |

**The quality difference is dominated by the compressor algorithm (1b).** All other differences are either inaudible or relate to robustness/safety features that don't affect the core amplification path.
