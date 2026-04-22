// ============================================================================
// ClearTone Production Audio Engine
// ============================================================================
// Lock-free real-time hearing amplification with:
//   DC blocker -> LR4 6-band crossover -> per-band compressor -> soft limiter
// ============================================================================

#include "audio_engine.h"

#include <oboe/Oboe.h>
#include <android/log.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#define LOG_TAG "ClearToneEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ============================================================================
// Constants
// ============================================================================

static constexpr int NUM_BANDS              = 6;
static constexpr int NUM_CROSSOVER_EDGES    = 5;
static constexpr float CROSSOVER_FREQS[NUM_CROSSOVER_EDGES] = {
    500.0f, 1000.0f, 2000.0f, 4000.0f, 8000.0f
};
static constexpr float BUTTERWORTH_Q        = 0.70710678118654752f; // 1/sqrt(2)
static constexpr float DC_BLOCKER_COEFF     = 0.995f;
static constexpr float SOFT_CLIP_K          = 0.7f;
static constexpr float PARAM_SMOOTH_COEFF   = 0.005f;
static constexpr float STARTUP_RAMP_SEC     = 0.05f;
static constexpr int   MAX_CAPTURE_SECONDS  = 10;
static constexpr float DENORMAL_GUARD       = 1e-15f;
static constexpr int   LOG_THROTTLE         = 200;

// Compressor defaults
static constexpr float DEFAULT_RATIO        = 4.0f;
static constexpr float DEFAULT_ATTACK_MS    = 20.0f;
static constexpr float DEFAULT_RELEASE_MS   = 250.0f;
static constexpr float DEFAULT_THRESHOLD_DB[NUM_BANDS] = {
    -18.0f, -22.0f, -26.0f, -30.0f, -34.0f, -36.0f
};

// Engine state enum
static constexpr int ENGINE_STOPPED              = 0;
static constexpr int ENGINE_RUNNING              = 1;
static constexpr int ENGINE_ERROR_NEEDS_RESTART  = 2;

// ============================================================================
// Utility
// ============================================================================

static inline uint32_t nextPow2(uint32_t v) {
    v--;
    v |= v >> 1;  v |= v >> 2;  v |= v >> 4;
    v |= v >> 8;  v |= v >> 16;
    return v + 1;
}

static inline float soft_clip(float x) {
    if (!std::isfinite(x)) return 0.0f;
    return x / (1.0f + SOFT_CLIP_K * fabsf(x));
}

static inline float dbToLin(float db) {
    return powf(10.0f, db / 20.0f);
}

static inline void flushDenormal(float& v) {
    if (fabsf(v) < DENORMAL_GUARD) v = 0.0f;
}

static inline void guardBiquadState(float& z) {
    if (!std::isfinite(z)) z = 0.0f;
    if (fabsf(z) < DENORMAL_GUARD) z = 0.0f;
}

// ============================================================================
// Lock-free SPSC Ring Buffer
// ============================================================================

class RingBuffer {
public:
    void allocate(int minSize) {
        mSize = nextPow2(static_cast<uint32_t>(minSize));
        mMask = mSize - 1;
        mBuf = std::make_unique<float[]>(mSize);
        std::memset(mBuf.get(), 0, mSize * sizeof(float));
        mHead.store(0, std::memory_order_relaxed);
        mTail.store(0, std::memory_order_relaxed);
        underrunCount.store(0, std::memory_order_relaxed);
        overflowCount.store(0, std::memory_order_relaxed);
    }

    // Producer: push n samples. On overflow, advance tail (drop oldest).
    void push(const float* in, int n) {
        uint32_t head = mHead.load(std::memory_order_relaxed);
        uint32_t tail = mTail.load(std::memory_order_acquire);

        for (int i = 0; i < n; ++i) {
            uint32_t nextHead = (head + 1) & mMask;
            if (nextHead == tail) {
                // Overflow: drop oldest sample by advancing tail
                tail = (tail + 1) & mMask;
                mTail.store(tail, std::memory_order_release);
                overflowCount.fetch_add(1, std::memory_order_relaxed);
            }
            mBuf[head] = in[i];
            head = nextHead;
        }
        mHead.store(head, std::memory_order_release);
    }

    // Consumer: pop n samples. Underrun fills zeros.
    void pop(float* out, int n) {
        uint32_t tail = mTail.load(std::memory_order_relaxed);
        uint32_t head = mHead.load(std::memory_order_acquire);

        for (int i = 0; i < n; ++i) {
            if (tail == head) {
                // Underrun
                out[i] = 0.0f;
                underrunCount.fetch_add(1, std::memory_order_relaxed);
            } else {
                out[i] = mBuf[tail];
                tail = (tail + 1) & mMask;
            }
        }
        mTail.store(tail, std::memory_order_release);
    }

    std::atomic<uint32_t> underrunCount{0};
    std::atomic<uint32_t> overflowCount{0};

private:
    std::unique_ptr<float[]> mBuf;
    uint32_t mSize = 0;
    uint32_t mMask = 0;
    std::atomic<uint32_t> mHead{0};
    std::atomic<uint32_t> mTail{0};
};

// ============================================================================
// Biquad Filter (Transposed Direct Form II)
// ============================================================================

struct BiquadCoeffs {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    float a1 = 0.0f, a2 = 0.0f;
};

struct BiquadState {
    float z1 = 0.0f;
    float z2 = 0.0f;

    inline float process(const BiquadCoeffs& c, float x) {
        float y = c.b0 * x + z1;
        z1 = c.b1 * x - c.a1 * y + z2;
        z2 = c.b2 * x - c.a2 * y;
        guardBiquadState(z1);
        guardBiquadState(z2);
        return y;
    }

    void reset() { z1 = 0.0f; z2 = 0.0f; }
};

// LR4 = two cascaded identical 2nd-order Butterworth biquads
struct LR4Filter {
    BiquadCoeffs coeffs;
    BiquadState  s1;
    BiquadState  s2;

    inline float process(float x) {
        float y = s1.process(coeffs, x);
        return s2.process(coeffs, y);
    }

    void reset() { s1.reset(); s2.reset(); }
};

// Compute Butterworth LP/HP biquad coefficients from pre-warped K
static void computeButterworthLP(BiquadCoeffs& c, float K) {
    float K2 = K * K;
    float D = 1.0f + K / BUTTERWORTH_Q + K2;
    c.b0 = K2 / D;
    c.b1 = 2.0f * K2 / D;
    c.b2 = K2 / D;
    c.a1 = 2.0f * (K2 - 1.0f) / D;
    c.a2 = (1.0f - K / BUTTERWORTH_Q + K2) / D;
}

static void computeButterworthHP(BiquadCoeffs& c, float K) {
    float K2 = K * K;
    float D = 1.0f + K / BUTTERWORTH_Q + K2;
    c.b0 = 1.0f / D;
    c.b1 = -2.0f / D;
    c.b2 = 1.0f / D;
    c.a1 = 2.0f * (K2 - 1.0f) / D;
    c.a2 = (1.0f - K / BUTTERWORTH_Q + K2) / D;
}

// ============================================================================
// DSP Parameters (double-buffered)
// ============================================================================

struct DspParams {
    float makeupLin[NUM_BANDS];
    float thresholdLin[NUM_BANDS];
    float ratio_factor[NUM_BANDS];
    float attackCoeff[NUM_BANDS];
    float releaseCoeff[NUM_BANDS];
    float masterGain;
    float wet;
    float dry;
};

// ============================================================================
// Input Callback (pushes mono samples into ring buffer)
// ============================================================================

class InputCallback : public oboe::AudioStreamDataCallback {
public:
    RingBuffer* ringBuf = nullptr;
    std::atomic<bool>* isCapturing = nullptr;
    std::mutex* captureMutex = nullptr;
    std::vector<float>* captureBuffer = nullptr;
    int maxCaptureSamples = 0;
    int logCounter = 0;

    oboe::DataCallbackResult onAudioReady(
            oboe::AudioStream* stream, void* audioData, int32_t numFrames) override {
        auto* data = static_cast<float*>(audioData);
        int channels = stream->getChannelCount();

        // Mono downmix if needed (should already be mono)
        if (channels == 1) {
            ringBuf->push(data, numFrames);
        } else {
            // Downmix to mono by averaging channels
            for (int i = 0; i < numFrames; ++i) {
                float sum = 0.0f;
                for (int ch = 0; ch < channels; ++ch) {
                    sum += data[i * channels + ch];
                }
                data[i] = sum / static_cast<float>(channels);
            }
            ringBuf->push(data, numFrames);
        }

        // Debug capture (input)
        if (isCapturing->load(std::memory_order_acquire)) {
            std::lock_guard<std::mutex> lock(*captureMutex);
            int space = maxCaptureSamples - static_cast<int>(captureBuffer->size());
            int toCopy = std::min(numFrames, space);
            if (toCopy > 0) {
                // Push mono samples
                if (channels == 1) {
                    captureBuffer->insert(captureBuffer->end(), data, data + toCopy);
                } else {
                    // Already downmixed in data[0..numFrames-1]
                    captureBuffer->insert(captureBuffer->end(), data, data + toCopy);
                }
            }
        }

        if (++logCounter % LOG_THROTTLE == 0) {
            LOGI("Input: frames=%d underruns=%u overflows=%u",
                 numFrames,
                 ringBuf->underrunCount.load(std::memory_order_relaxed),
                 ringBuf->overflowCount.load(std::memory_order_relaxed));
        }

        return oboe::DataCallbackResult::Continue;
    }
};

// ============================================================================
// Output Callback + DSP Pipeline
// ============================================================================

class OutputCallback : public oboe::AudioStreamDataCallback,
                       public oboe::AudioStreamErrorCallback {
public:
    // Shared state pointers (set before stream start)
    RingBuffer* ringBuf = nullptr;
    std::atomic<int>* activeParamIdx = nullptr;
    DspParams* paramBuf = nullptr; // pointer to paramBuf[2]
    std::atomic<int>* engineState = nullptr;

    // Debug capture
    std::atomic<bool>* isCapturing = nullptr;
    std::mutex* captureMutex = nullptr;
    std::vector<float>* captureBufferOut = nullptr;
    int maxCaptureSamples = 0;

    // Per-sample DSP state (owned by audio thread, never touched elsewhere)
    // DC blocker
    float dcPrevX = 0.0f;
    float dcPrevY = 0.0f;

    // LR4 crossover: 5 LP + 5 HP
    LR4Filter lpFilters[NUM_CROSSOVER_EDGES];
    LR4Filter hpFilters[NUM_CROSSOVER_EDGES];

    // Compressor envelopes
    float env[NUM_BANDS] = {};

    // Smoothed makeup gains
    float smoothedGain[NUM_BANDS] = {};

    // Startup ramp
    float rampGain = 0.0f;
    float rampStep = 0.0f;

    int logCounter = 0;

    // Pre-allocated scratch buffer for mono input
    std::unique_ptr<float[]> monoScratch;
    int monoScratchSize = 0;

    void initCrossover(float sampleRate) {
        for (int i = 0; i < NUM_CROSSOVER_EDGES; ++i) {
            float K = tanf(static_cast<float>(M_PI) * CROSSOVER_FREQS[i] / sampleRate);
            computeButterworthLP(lpFilters[i].coeffs, K);
            computeButterworthHP(hpFilters[i].coeffs, K);
            lpFilters[i].reset();
            hpFilters[i].reset();
        }
    }

    void initRamp(float sampleRate) {
        rampGain = 0.0f;
        rampStep = 1.0f / (STARTUP_RAMP_SEC * sampleRate);
    }

    void resetDspState() {
        dcPrevX = 0.0f;
        dcPrevY = 0.0f;
        for (int i = 0; i < NUM_CROSSOVER_EDGES; ++i) {
            lpFilters[i].reset();
            hpFilters[i].reset();
        }
        for (int b = 0; b < NUM_BANDS; ++b) {
            env[b] = 0.0f;
            smoothedGain[b] = 1.0f;
        }
        rampGain = 0.0f;
    }

    void ensureScratch(int frames) {
        if (frames > monoScratchSize) {
            monoScratch = std::make_unique<float[]>(frames);
            monoScratchSize = frames;
        }
    }

    oboe::DataCallbackResult onAudioReady(
            oboe::AudioStream* stream, void* audioData, int32_t numFrames) override {
        auto* out = static_cast<float*>(audioData);

        ensureScratch(numFrames);
        float* mono = monoScratch.get();

        // Pop mono samples from ring buffer
        ringBuf->pop(mono, numFrames);

        // Read active DSP params (lock-free)
        int idx = activeParamIdx->load(std::memory_order_acquire);
        const DspParams& p = paramBuf[idx];

        for (int i = 0; i < numFrames; ++i) {
            float x = mono[i];

            // --- DC Blocker ---
            float dcOut = x - dcPrevX + DC_BLOCKER_COEFF * dcPrevY;
            dcPrevX = x;
            dcPrevY = dcOut;
            flushDenormal(dcPrevY);
            x = dcOut;

            // --- LR4 Crossover -> 6 bands ---
            float bands[NUM_BANDS];

            // Band 0: LP[0](x)
            bands[0] = lpFilters[0].process(x);

            // Residual from HP[0] feeds into subsequent splits
            float residual = hpFilters[0].process(x);

            // Band 1: LP[1](residual)
            bands[1] = lpFilters[1].process(residual);
            residual = hpFilters[1].process(residual);

            // Band 2: LP[2](residual)
            bands[2] = lpFilters[2].process(residual);
            residual = hpFilters[2].process(residual);

            // Band 3: LP[3](residual)
            bands[3] = lpFilters[3].process(residual);
            residual = hpFilters[3].process(residual);

            // Band 4: LP[4](residual)
            bands[4] = lpFilters[4].process(residual);

            // Band 5: HP[4](residual)
            bands[5] = hpFilters[4].process(residual);

            // --- Per-band: compressor + smoothed makeup gain ---
            float bandSum = 0.0f;
            for (int b = 0; b < NUM_BANDS; ++b) {
                float s = bands[b];

                // Envelope follower
                float absx = fabsf(s);
                if (absx > env[b]) {
                    env[b] = p.attackCoeff[b] * env[b] + (1.0f - p.attackCoeff[b]) * absx;
                } else {
                    env[b] = p.releaseCoeff[b] * env[b] + (1.0f - p.releaseCoeff[b]) * absx;
                }
                flushDenormal(env[b]);

                // Compressor gain
                float gain;
                if (env[b] > p.thresholdLin[b]) {
                    float r = env[b] / p.thresholdLin[b];
                    gain = 1.0f / (1.0f + p.ratio_factor[b] * (r - 1.0f));
                } else {
                    gain = 1.0f;
                }
                gain = fminf(gain, 1.0f);
                s *= gain;

                // Smoothed makeup gain
                smoothedGain[b] += PARAM_SMOOTH_COEFF * (p.makeupLin[b] - smoothedGain[b]);
                s *= smoothedGain[b];

                bandSum += s;
            }

            // Master gain
            float y = bandSum * p.masterGain;

            // Soft clip limiter
            y = soft_clip(y);

            // Startup ramp
            rampGain = fminf(1.0f, rampGain + rampStep);
            y *= rampGain;

            // Write stereo (L+R identical for mono source)
            out[i * 2]     = y;
            out[i * 2 + 1] = y;
        }

        // Debug capture (output, post-processing mono)
        if (isCapturing->load(std::memory_order_acquire)) {
            std::lock_guard<std::mutex> lock(*captureMutex);
            int space = maxCaptureSamples - static_cast<int>(captureBufferOut->size());
            int toCopy = std::min(static_cast<int>(numFrames), space);
            if (toCopy > 0) {
                // Store mono (left channel) from stereo interleaved output
                for (int i = 0; i < toCopy; ++i) {
                    captureBufferOut->push_back(out[i * 2]);
                }
            }
        }

        if (++logCounter % LOG_THROTTLE == 0) {
            LOGI("Output: frames=%d ramp=%.3f underruns=%u overflows=%u",
                 numFrames, rampGain,
                 ringBuf->underrunCount.load(std::memory_order_relaxed),
                 ringBuf->overflowCount.load(std::memory_order_relaxed));
        }

        return oboe::DataCallbackResult::Continue;
    }

    void onErrorBeforeClose(oboe::AudioStream* stream, oboe::Result error) override {
        LOGE("Output stream error before close: %s", oboe::convertToText(error));
        engineState->store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
    }

    void onErrorAfterClose(oboe::AudioStream* stream, oboe::Result error) override {
        LOGE("Output stream error after close: %s", oboe::convertToText(error));
        engineState->store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
    }
};

// ============================================================================
// Input Error Callback
// ============================================================================

class InputErrorCallback : public oboe::AudioStreamErrorCallback {
public:
    std::atomic<int>* engineState = nullptr;

    void onErrorBeforeClose(oboe::AudioStream* stream, oboe::Result error) override {
        LOGE("Input stream error before close: %s", oboe::convertToText(error));
        engineState->store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
    }

    void onErrorAfterClose(oboe::AudioStream* stream, oboe::Result error) override {
        LOGE("Input stream error after close: %s", oboe::convertToText(error));
        engineState->store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
    }
};

// ============================================================================
// Engine Singleton
// ============================================================================

class ClearToneEngine {
public:
    static ClearToneEngine& get() {
        static ClearToneEngine instance;
        return instance;
    }

    int start(int inputDeviceId) {
        if (mRunning.load(std::memory_order_acquire)) {
            LOGI("Engine already running, stopping first");
            stop();
        }

        mEngineState.store(ENGINE_STOPPED, std::memory_order_release);

        // Flush denormals on ARM64 (fpcr/mrs/msr are AArch64-only)
#if defined(__aarch64__)
        uint64_t fpcr;
        asm volatile("mrs %0, fpcr" : "=r"(fpcr));
        fpcr |= (1ULL << 24); // FZ bit
        asm volatile("msr fpcr, %0" : : "r"(fpcr));
        LOGI("ARM64 denormal flush enabled");
#elif defined(__arm__)
        // armeabi-v7a: enable FZ via FPSCR
        uint32_t fpscr;
        asm volatile("vmrs %0, fpscr" : "=r"(fpscr));
        fpscr |= (1U << 24); // FZ bit
        asm volatile("vmsr fpscr, %0" : : "r"(fpscr));
        LOGI("ARMv7 denormal flush enabled");
#endif

        // ---- Open output stream first to get actual sample rate ----
        oboe::AudioStreamBuilder outBuilder;
        outBuilder.setDirection(oboe::Direction::Output)
                  ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
                  ->setSharingMode(oboe::SharingMode::Shared)
                  ->setFormat(oboe::AudioFormat::Float)
                  ->setChannelCount(2)
                  ->setDataCallback(&mOutputCallback)
                  ->setErrorCallback(&mOutputCallback);

        // Set usage based on mUsage
        if (mUsage == 2) {
            outBuilder.setUsage(oboe::Usage::VoiceCommunication);
        } else {
            outBuilder.setUsage(oboe::Usage::Media);
        }

        oboe::Result result = outBuilder.openStream(mOutputStream);
        if (result != oboe::Result::OK) {
            LOGE("Failed to open output stream: %s", oboe::convertToText(result));
            mEngineState.store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
            return -1;
        }

        int32_t sampleRate = mOutputStream->getSampleRate();
        int32_t outBurst = mOutputStream->getFramesPerBurst();
        LOGI("Output stream opened: sr=%d burst=%d", sampleRate, outBurst);

        // ---- Allocate ring buffer: next power of 2 >= 4 * burst frames ----
        int ringSize = static_cast<int>(outBurst) * 4;
        mRingBuffer.allocate(ringSize);

        // ---- Open input stream at same sample rate ----
        oboe::AudioStreamBuilder inBuilder;
        inBuilder.setDirection(oboe::Direction::Input)
                 ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
                 ->setSharingMode(oboe::SharingMode::Shared)
                 ->setFormat(oboe::AudioFormat::Float)
                 ->setChannelCount(1)
                 ->setSampleRate(sampleRate)
                 ->setDataCallback(&mInputCallback)
                 ->setErrorCallback(&mInputErrorCallback);

        if (inputDeviceId > 0) {
            inBuilder.setDeviceId(inputDeviceId);
        }

        if (mUsage == 2) {
            inBuilder.setInputPreset(oboe::InputPreset::VoiceCommunication);
        } else {
            inBuilder.setInputPreset(oboe::InputPreset::Unprocessed);
        }

        result = inBuilder.openStream(mInputStream);
        if (result != oboe::Result::OK) {
            LOGE("Failed to open input stream: %s", oboe::convertToText(result));
            // Retry once without device ID
            if (inputDeviceId > 0) {
                LOGI("Retrying input stream without specific device ID");
                inBuilder.setDeviceId(oboe::kUnspecified);
                result = inBuilder.openStream(mInputStream);
            }
            if (result != oboe::Result::OK) {
                LOGE("Input stream retry failed: %s", oboe::convertToText(result));
                mOutputStream->close();
                mOutputStream.reset();
                mEngineState.store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
                return -2;
            }
        }

        // Verify sample rate match
        int32_t inputSr = mInputStream->getSampleRate();
        if (inputSr != sampleRate) {
            LOGE("Sample rate mismatch: output=%d input=%d, retrying", sampleRate, inputSr);
            mInputStream->close();
            mInputStream.reset();
            inBuilder.setSampleRate(sampleRate);
            result = inBuilder.openStream(mInputStream);
            if (result != oboe::Result::OK || mInputStream->getSampleRate() != sampleRate) {
                LOGE("Cannot match sample rates, aborting");
                mOutputStream->close();
                mOutputStream.reset();
                if (mInputStream) {
                    mInputStream->close();
                    mInputStream.reset();
                }
                mEngineState.store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
                return -3;
            }
        }

        LOGI("Input stream opened: sr=%d burst=%d", mInputStream->getSampleRate(),
             mInputStream->getFramesPerBurst());

        // ---- Wire up callbacks ----
        mInputCallback.ringBuf = &mRingBuffer;
        mInputCallback.isCapturing = &mIsCapturing;
        mInputCallback.captureMutex = &mCaptureMutex;
        mInputCallback.captureBuffer = &mCaptureBufferIn;
        mInputCallback.maxCaptureSamples = MAX_CAPTURE_SECONDS * sampleRate;

        mOutputCallback.ringBuf = &mRingBuffer;
        mOutputCallback.activeParamIdx = &mActiveParamIdx;
        mOutputCallback.paramBuf = mParamBuf;
        mOutputCallback.engineState = &mEngineState;
        mOutputCallback.isCapturing = &mIsCapturing;
        mOutputCallback.captureMutex = &mCaptureMutex;
        mOutputCallback.captureBufferOut = &mCaptureBufferOut;
        mOutputCallback.maxCaptureSamples = MAX_CAPTURE_SECONDS * sampleRate;

        // ---- Initialize DSP state ----
        mOutputCallback.resetDspState();
        mOutputCallback.initCrossover(static_cast<float>(sampleRate));
        mOutputCallback.initRamp(static_cast<float>(sampleRate));

        // Pre-allocate mono scratch to avoid allocation inside the callback.
        // 4× burst gives ample headroom for variable burst sizes on some devices.
        mOutputCallback.ensureScratch(outBurst * 4);

        mSampleRate = sampleRate;

        // Initialize default params
        initDefaultParams();

        mInputErrorCallback.engineState = &mEngineState;

        // ---- Start streams (output first for lower latency) ----
        result = mOutputStream->requestStart();
        if (result != oboe::Result::OK) {
            LOGE("Failed to start output stream: %s", oboe::convertToText(result));
            mInputStream->close();
            mOutputStream->close();
            mInputStream.reset();
            mOutputStream.reset();
            mEngineState.store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
            return -4;
        }

        result = mInputStream->requestStart();
        if (result != oboe::Result::OK) {
            LOGE("Failed to start input stream: %s", oboe::convertToText(result));
            mOutputStream->requestStop();
            mInputStream->close();
            mOutputStream->close();
            mInputStream.reset();
            mOutputStream.reset();
            mEngineState.store(ENGINE_ERROR_NEEDS_RESTART, std::memory_order_release);
            return -5;
        }

        mRunning.store(true, std::memory_order_release);
        mEngineState.store(ENGINE_RUNNING, std::memory_order_release);
        LOGI("Engine started: sr=%d, ringSize=%d", sampleRate, ringSize);
        return 0;
    }

    int stop() {
        if (!mRunning.load(std::memory_order_acquire)) {
            return 0;
        }

        mRunning.store(false, std::memory_order_release);

        if (mInputStream) {
            mInputStream->requestStop();
            mInputStream->close();
            mInputStream.reset();
        }

        if (mOutputStream) {
            mOutputStream->requestStop();
            mOutputStream->close();
            mOutputStream.reset();
        }

        mEngineState.store(ENGINE_STOPPED, std::memory_order_release);
        LOGI("Engine stopped");
        return 0;
    }

    int updateParams(const float* loss6) {
        if (mSampleRate <= 0) {
            LOGE("updateParams called before stream start");
            return -1;
        }

        // Write to inactive buffer
        int activeIdx = mActiveParamIdx.load(std::memory_order_acquire);
        int writeIdx = 1 - activeIdx;
        DspParams& p = mParamBuf[writeIdx];

        float fs = static_cast<float>(mSampleRate);

        for (int b = 0; b < NUM_BANDS; ++b) {
            // Half-gain rule: makeup dB = clamp(0.5 * lossDb, 0, 25)
            float lossDb = loss6[b];
            float makeupDb = fminf(fmaxf(0.5f * lossDb, 0.0f), 25.0f);
            p.makeupLin[b] = dbToLin(makeupDb);

            // Compressor parameters
            float thrDb = DEFAULT_THRESHOLD_DB[b];
            p.thresholdLin[b] = dbToLin(thrDb);
            p.ratio_factor[b] = 1.0f - 1.0f / DEFAULT_RATIO;
            p.attackCoeff[b]  = expf(-1.0f / (DEFAULT_ATTACK_MS * 0.001f * fs));
            p.releaseCoeff[b] = expf(-1.0f / (DEFAULT_RELEASE_MS * 0.001f * fs));
        }

        p.masterGain = 1.0f;
        p.wet = 1.0f;
        p.dry = 0.0f;

        // Flip active index
        mActiveParamIdx.store(writeIdx, std::memory_order_release);
        LOGI("Params updated: loss=[%.1f,%.1f,%.1f,%.1f,%.1f,%.1f]",
             loss6[0], loss6[1], loss6[2], loss6[3], loss6[4], loss6[5]);
        return 0;
    }

    void setAudioUsage(int usage) {
        mUsage = usage;
        LOGI("Audio usage set to %d", usage);
    }

    bool isPlaying() const {
        return mRunning.load(std::memory_order_acquire);
    }

    int getEngineState() const {
        return mEngineState.load(std::memory_order_acquire);
    }

    // ---- Debug Capture ----

    void startCapture() {
        std::lock_guard<std::mutex> lock(mCaptureMutex);
        int maxSamples = MAX_CAPTURE_SECONDS * mSampleRate;
        mCaptureBufferIn.clear();
        mCaptureBufferIn.reserve(maxSamples);
        mCaptureBufferOut.clear();
        mCaptureBufferOut.reserve(maxSamples);
        mIsCapturing.store(true, std::memory_order_release);
        LOGI("Debug capture started (max %d samples)", maxSamples);
    }

    void stopCapture() {
        mIsCapturing.store(false, std::memory_order_release);
        LOGI("Debug capture stopped: in=%zu out=%zu samples",
             mCaptureBufferIn.size(), mCaptureBufferOut.size());
    }

    int saveCapture(const char* filePath, int source) {
        std::lock_guard<std::mutex> lock(mCaptureMutex);
        const std::vector<float>& buf = (source == 0) ? mCaptureBufferIn : mCaptureBufferOut;
        if (buf.empty()) {
            LOGE("saveCapture: buffer empty for source %d", source);
            return -1;
        }

        FILE* f = fopen(filePath, "wb");
        if (!f) {
            LOGE("saveCapture: cannot open %s", filePath);
            return -2;
        }
        size_t written = fwrite(buf.data(), sizeof(float), buf.size(), f);
        fclose(f);

        LOGI("saveCapture: wrote %zu samples to %s (source=%d)",
             written, filePath, source);
        return 0;
    }

    int getCaptureSize() {
        std::lock_guard<std::mutex> lock(mCaptureMutex);
        return static_cast<int>(mCaptureBufferIn.size());
    }

private:
    ClearToneEngine() {
        initDefaultParams();
    }

    void initDefaultParams() {
        for (int buf = 0; buf < 2; ++buf) {
            DspParams& p = mParamBuf[buf];
            float fs = (mSampleRate > 0) ? static_cast<float>(mSampleRate) : 48000.0f;
            for (int b = 0; b < NUM_BANDS; ++b) {
                p.makeupLin[b] = 1.0f;
                p.thresholdLin[b] = dbToLin(DEFAULT_THRESHOLD_DB[b]);
                p.ratio_factor[b] = 1.0f - 1.0f / DEFAULT_RATIO;
                p.attackCoeff[b]  = expf(-1.0f / (DEFAULT_ATTACK_MS * 0.001f * fs));
                p.releaseCoeff[b] = expf(-1.0f / (DEFAULT_RELEASE_MS * 0.001f * fs));
            }
            p.masterGain = 1.0f;
            p.wet = 1.0f;
            p.dry = 0.0f;
        }
        mActiveParamIdx.store(0, std::memory_order_release);
    }

    // Streams
    std::shared_ptr<oboe::AudioStream> mInputStream;
    std::shared_ptr<oboe::AudioStream> mOutputStream;

    // Callbacks
    InputCallback       mInputCallback;
    OutputCallback      mOutputCallback;
    InputErrorCallback  mInputErrorCallback;

    // Ring buffer
    RingBuffer mRingBuffer;

    // Double-buffered DSP params
    DspParams mParamBuf[2];
    std::atomic<int> mActiveParamIdx{0};

    // State
    std::atomic<bool> mRunning{false};
    std::atomic<int>  mEngineState{ENGINE_STOPPED};
    int mSampleRate = 0;
    int mUsage = 2; // default: VoiceCommunication

    // Debug capture
    std::atomic<bool> mIsCapturing{false};
    std::mutex mCaptureMutex;
    std::vector<float> mCaptureBufferIn;
    std::vector<float> mCaptureBufferOut;
};

// ============================================================================
// Offline File Processing (backward-compatible stub preserved)
// ============================================================================

// Full offline processor: reads WAV, applies DSP, writes WAV.
// Kept for the existing processAudio() Dart binding.
static int processAudioFileImpl(
        const char* inPath, const char* outPath,
        const float* loss6, float ratio, float attackMs, float releaseMs,
        const float* thrDb, float masterDb, float wet, float dry) {
    // Open input WAV
    FILE* fin = fopen(inPath, "rb");
    if (!fin) {
        LOGE("processAudioFile: cannot open input %s", inPath);
        return 1;
    }

    // Read WAV header (44 bytes standard)
    uint8_t header[44];
    if (fread(header, 1, 44, fin) != 44) {
        LOGE("processAudioFile: bad WAV header");
        fclose(fin);
        return 2;
    }

    // Parse WAV header fields
    uint16_t numChannels = *reinterpret_cast<uint16_t*>(&header[22]);
    uint32_t sampleRate  = *reinterpret_cast<uint32_t*>(&header[24]);
    uint16_t bitsPerSample = *reinterpret_cast<uint16_t*>(&header[34]);
    uint32_t dataSize    = *reinterpret_cast<uint32_t*>(&header[40]);

    if (bitsPerSample != 16) {
        LOGE("processAudioFile: only 16-bit WAV supported, got %d", bitsPerSample);
        fclose(fin);
        return 3;
    }

    int totalSamples = static_cast<int>(dataSize / (bitsPerSample / 8) / numChannels);
    LOGI("processAudioFile: %d samples, %d ch, %d Hz", totalSamples, numChannels, sampleRate);

    // Read all samples as 16-bit, convert to float mono
    std::vector<float> monoData(totalSamples);
    for (int i = 0; i < totalSamples; ++i) {
        float sum = 0.0f;
        for (int ch = 0; ch < numChannels; ++ch) {
            int16_t s16;
            if (fread(&s16, sizeof(int16_t), 1, fin) != 1) {
                s16 = 0;
            }
            sum += static_cast<float>(s16) / 32768.0f;
        }
        monoData[i] = sum / static_cast<float>(numChannels);
    }
    fclose(fin);

    float fs = static_cast<float>(sampleRate);

    // Precompute per-band params
    float makeupLin[NUM_BANDS];
    float thresholdLin[NUM_BANDS];
    float ratio_factor_arr[NUM_BANDS];
    float attackCoeff[NUM_BANDS];
    float releaseCoeff[NUM_BANDS];

    for (int b = 0; b < NUM_BANDS; ++b) {
        float makeupDb = fminf(fmaxf(0.5f * loss6[b], 0.0f), 25.0f);
        makeupLin[b] = dbToLin(makeupDb);
        thresholdLin[b] = dbToLin(thrDb[b]);
        ratio_factor_arr[b] = 1.0f - 1.0f / ratio;
        attackCoeff[b]  = expf(-1.0f / (attackMs * 0.001f * fs));
        releaseCoeff[b] = expf(-1.0f / (releaseMs * 0.001f * fs));
    }

    float masterGain = dbToLin(masterDb);

    // Init crossover filters
    LR4Filter lpF[NUM_CROSSOVER_EDGES], hpF[NUM_CROSSOVER_EDGES];
    for (int i = 0; i < NUM_CROSSOVER_EDGES; ++i) {
        float K = tanf(static_cast<float>(M_PI) * CROSSOVER_FREQS[i] / fs);
        computeButterworthLP(lpF[i].coeffs, K);
        computeButterworthHP(hpF[i].coeffs, K);
        lpF[i].reset();
        hpF[i].reset();
    }

    // DC blocker state
    float dcPX = 0.0f, dcPY = 0.0f;
    float envArr[NUM_BANDS] = {};

    // Startup ramp
    float rampG = 0.0f;
    float rampS = 1.0f / (STARTUP_RAMP_SEC * fs);

    // Process
    std::vector<float> output(totalSamples);
    for (int i = 0; i < totalSamples; ++i) {
        float x = monoData[i];

        // DC blocker
        float dcOut = x - dcPX + DC_BLOCKER_COEFF * dcPY;
        dcPX = x;
        dcPY = dcOut;
        flushDenormal(dcPY);
        x = dcOut;

        // Crossover
        float bands[NUM_BANDS];
        bands[0] = lpF[0].process(x);
        float residual = hpF[0].process(x);
        bands[1] = lpF[1].process(residual);
        residual = hpF[1].process(residual);
        bands[2] = lpF[2].process(residual);
        residual = hpF[2].process(residual);
        bands[3] = lpF[3].process(residual);
        residual = hpF[3].process(residual);
        bands[4] = lpF[4].process(residual);
        bands[5] = hpF[4].process(residual);

        // Per-band compression + makeup
        float bandSum = 0.0f;
        for (int b = 0; b < NUM_BANDS; ++b) {
            float s = bands[b];
            float absx = fabsf(s);
            if (absx > envArr[b]) {
                envArr[b] = attackCoeff[b] * envArr[b] + (1.0f - attackCoeff[b]) * absx;
            } else {
                envArr[b] = releaseCoeff[b] * envArr[b] + (1.0f - releaseCoeff[b]) * absx;
            }
            flushDenormal(envArr[b]);

            float gain;
            if (envArr[b] > thresholdLin[b]) {
                float r = envArr[b] / thresholdLin[b];
                gain = 1.0f / (1.0f + ratio_factor_arr[b] * (r - 1.0f));
            } else {
                gain = 1.0f;
            }
            gain = fminf(gain, 1.0f);
            s *= gain;
            s *= makeupLin[b];
            bandSum += s;
        }

        float y = bandSum * masterGain;

        // Wet/dry mix
        y = wet * y + dry * monoData[i];

        // Soft clip
        y = soft_clip(y);

        // Startup ramp
        rampG = fminf(1.0f, rampG + rampS);
        y *= rampG;

        output[i] = y;
    }

    // Write output WAV (16-bit mono)
    FILE* fout = fopen(outPath, "wb");
    if (!fout) {
        LOGE("processAudioFile: cannot open output %s", outPath);
        return 4;
    }

    uint32_t outDataSize = totalSamples * sizeof(int16_t);
    uint32_t outFileSize = 36 + outDataSize;

    // WAV header
    uint8_t outHeader[44];
    std::memcpy(outHeader, "RIFF", 4);
    *reinterpret_cast<uint32_t*>(&outHeader[4]) = outFileSize;
    std::memcpy(&outHeader[8], "WAVE", 4);
    std::memcpy(&outHeader[12], "fmt ", 4);
    *reinterpret_cast<uint32_t*>(&outHeader[16]) = 16; // PCM fmt chunk size
    *reinterpret_cast<uint16_t*>(&outHeader[20]) = 1;  // PCM format
    *reinterpret_cast<uint16_t*>(&outHeader[22]) = 1;  // mono
    *reinterpret_cast<uint32_t*>(&outHeader[24]) = sampleRate;
    *reinterpret_cast<uint32_t*>(&outHeader[28]) = sampleRate * 2; // byte rate
    *reinterpret_cast<uint16_t*>(&outHeader[32]) = 2;  // block align
    *reinterpret_cast<uint16_t*>(&outHeader[34]) = 16; // bits per sample
    std::memcpy(&outHeader[36], "data", 4);
    *reinterpret_cast<uint32_t*>(&outHeader[40]) = outDataSize;

    fwrite(outHeader, 1, 44, fout);

    // Write samples
    for (int i = 0; i < totalSamples; ++i) {
        float clamped = fmaxf(-1.0f, fminf(1.0f, output[i]));
        int16_t s16 = static_cast<int16_t>(clamped * 32767.0f);
        fwrite(&s16, sizeof(int16_t), 1, fout);
    }

    fclose(fout);
    LOGI("processAudioFile: wrote %d samples to %s", totalSamples, outPath);
    return 0;
}

// ============================================================================
// FFI Exports
// ============================================================================

extern "C" {

int start_rt_stream_ffi(int inputDeviceId) {
    return ClearToneEngine::get().start(inputDeviceId);
}

int stop_rt_stream_ffi(void) {
    return ClearToneEngine::get().stop();
}

int update_rt_params_ffi(const float* loss6) {
    return ClearToneEngine::get().updateParams(loss6);
}

void debug_start_capture_ffi(void) {
    ClearToneEngine::get().startCapture();
}

void debug_stop_capture_ffi(void) {
    ClearToneEngine::get().stopCapture();
}

int debug_save_capture_ffi(const char* filePath, int source) {
    return ClearToneEngine::get().saveCapture(filePath, source);
}

int debug_get_capture_size_ffi(void) {
    return ClearToneEngine::get().getCaptureSize();
}

void set_audio_usage_ffi(int usage) {
    ClearToneEngine::get().setAudioUsage(usage);
}

uint8_t is_playing_ffi(void) {
    return ClearToneEngine::get().isPlaying() ? 1 : 0;
}

int get_engine_state_ffi(void) {
    return ClearToneEngine::get().getEngineState();
}

int process_audio_file_ffi(
        const char* inPath, const char* outPath,
        const float* loss6, float ratio, float attackMs, float releaseMs,
        const float* thrDb, float masterDb, float wet, float dry) {
    return processAudioFileImpl(inPath, outPath, loss6, ratio, attackMs, releaseMs,
                                thrDb, masterDb, wet, dry);
}

} // extern "C"
