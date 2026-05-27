# Environment-Based Amplification Modes

This document outlines the problems and proposed solutions for implementing environment-based audio amplification modes (Transit Mode and Conversation Mode) into the ClearTone real-time DSP engine.

## Problem Statement

The current audio engine provides a generic amplification pipeline based on a user's static hearing loss profile. It lacks contextual awareness of the user's environment, leading to two specific scenarios that require distinct signal processing approaches:

1. **Transit Mode (Environmental Awareness)**
   * **Scenario:** The user is on the road or in a transit environment.
   * **Goal:** Amplify distant/quiet sounds (like an approaching car) so they are audible, while suppressing dangerously loud transient noises (like a bus honk or loud engine) to a comfortable level.

2. **Conversation Mode (Speech Isolation)**
   * **Scenario:** The user is talking to one or more people in a noisy environment.
   * **Goal:** Enhance human speech clarity while actively reducing background noise and ambient hums.

## Proposed Solutions

To solve these problems, we propose implementing a **Mode Preset System** within the C++ DSP engine. This system will dynamically adjust both custom DSP parameters and hardware-level Android audio presets depending on the active mode.

### 1. Transit Mode Implementation
**Approach: Wide Dynamic Range Compression (WDRC) & Fast Limiting**

* **High Makeup Gain & Low Threshold:** Ensure quiet sounds are aggressively brought up to the user's hearing level.
* **High Compression Ratio (e.g., 8:1):** Any sound crossing the threshold will be aggressively squashed.
* **Fast Attack / Medium Release:** Set compressor attack times very fast (1-5ms) to clamp sudden loud noises instantly. A medium release (100-200ms) prevents the background audio from fluctuating wildly.
* **Unprocessed Hardware Input:** Switch the Android `oboe::InputPreset` to `Camcorder` or `Unprocessed`. Built-in smartphone noise cancellation often attempts to remove traffic noise; in Transit Mode, we explicitly *want* the user to hear these environmental cues.

### 2. Conversation Mode Implementation
**Approach: Band-Specific EQ, Downward Expansion, and Hardware NS**

* **Downward Expansion (Noise Gating):** Add an Expander to the DSP pipeline. Unlike a compressor that makes loud sounds quiet, an expander makes quiet sounds *quieter*. When no one is speaking, the expander drops the background noise floor.
* **Speech-Banana Equalization:** Human speech occupies the 500Hz - 4000Hz frequency bands. We will dynamically reduce the makeup gain on the lowest band (<500Hz, e.g., AC rumble) and highest band (>8000Hz, e.g., hiss).
* **Hardware Noise Suppression (NS):** Switch the Android `oboe::InputPreset` to `VoiceCommunication`. This instructs the Android OS to utilize its internal multi-microphone array for Acoustic Echo Cancellation (AEC) and directional beamforming (focusing on the speaker directly in front of the phone).

## Open Questions

> [!WARNING]
> **Android Hardware Limitations**
> Android devices handle `VoiceCommunication` presets differently depending on the manufacturer. Do we want to rely solely on the hardware noise suppression for Conversation Mode, or should we also implement a custom lightweight noise-gating algorithm in our C++ code to guarantee consistent behavior across all devices?

> [!NOTE]
> **User Interface Integration**
> How should these modes be presented in the Flutter UI? Should it be a toggle switch, or a selection of "Environment" cards on the `AmplificationScreen`?

## Proposed Code Changes

### [MODIFY] audio_engine.cpp
* Introduce a `Mode` enum (`MODE_STANDARD`, `MODE_TRANSIT`, `MODE_CONVERSATION`).
* Add a Downward Expander class to process low-level signals.
* Modify the `RealtimeProcessor` to accept a mode and dynamically update `ratio`, `attackMs`, `releaseMs`, and band-specific EQ gains.

### [MODIFY] OboeEngine implementation (audio_engine.cpp)
* Allow re-initializing the `oboe::AudioStream` with different `InputPreset` configurations on the fly when the mode changes.

### [MODIFY] MainActivity.kt / FFI Bridge
* Expose a new FFI function `set_environment_mode_ffi(int32_t mode)` to allow Flutter to control the C++ engine's state.

### [MODIFY] amplification_screen.dart
* Update the UI to include mode selection toggles.
* Connect the UI to the new FFI mode-switching function.
