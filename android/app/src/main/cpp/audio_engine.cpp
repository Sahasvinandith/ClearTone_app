#include <oboe/Oboe.h>
#include <android/log.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <time.h>
#include <vector>

#include "dsp_core.h"
#include "evidence.h"

#define LOG_TAG "ClearToneEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ---- Oboe engine ------------------------------------------------------------
// Two-stream design: separate input/output ManagedStreams.
// FullDuplexStream was attempted but is incompatible with MMAP Exclusive mode
// on Pixel 7 — its internal read() returns an error from the wrong thread,
// causing DataCallbackResult::Stop immediately. The two-stream approach handles
// short/empty reads gracefully by filling silence.

class OboeEngine : public oboe::AudioStreamDataCallback {
public:
    oboe::ManagedStream inputStream_;
    oboe::ManagedStream outputStream_;
    RealtimeProcessor   proc_;
    int32_t             audioUsage_ = (int32_t)oboe::Usage::VoiceCommunication;
    std::atomic<bool>   running_{false};
    int32_t             currentDeviceId_ = 0;
    EnvironmentMode     currentMode_ = MODE_STANDARD;
    std::atomic<int32_t> inputSampleRate_{0};
    std::atomic<int64_t> inputFramesRead_{0};
    std::atomic<int64_t> outputFramesWritten_{0};

    struct LatencyProbe {
        std::atomic<bool> armed{false};
        std::atomic<int32_t> status{0}; // 0 idle/armed, 1 measured, -1 timed out, -2 timestamp unavailable
        std::atomic<int64_t> armedOutputFrame{0};
        std::atomic<int64_t> inputFrame{-1};
        std::atomic<int64_t> outputFrame{-1};
        std::atomic<int64_t> inputTimeNs{0};
        std::atomic<int64_t> outputTimeNs{0};
        std::atomic<double> latencyMs{0.0};
        std::atomic<float> threshold{0.05f};
    } latencyProbe_;

    struct ChirpLatencyProbe {
        std::atomic<bool> capturing{false};
        std::atomic<int32_t> status{0}; // 0 idle/capturing, 1 measured, -1 no match, -2 timestamp unavailable
        std::vector<float> input;
        std::vector<float> output;
        std::mutex mu;
        int32_t sampleRate = 48000;
        int32_t maxFrames = 48000;
        int64_t inputStartFrame = 0;
        int64_t outputStartFrame = 0;
        int64_t inputStartTimeNs = 0;
        int64_t outputStartTimeNs = 0;
        int32_t inputPeak = -1;
        int32_t outputPeak = -1;
        float inputScore = 0.f;
        float outputScore = 0.f;
        double latencyMs = 0.0;
        float acousticScore = 0.f;
        double acousticLatencyMs = 0.0;
    } chirpProbe_;

    // Raw mic frames for environment detection. This is a single-producer
    // audio-callback / single-consumer FFI drain buffer.
    std::vector<float>  rawInputRing_;
    size_t              rawInputRead_ = 0;
    size_t              rawInputWrite_ = 0;
    size_t              rawInputCount_ = 0;
    std::mutex          rawInputMu_;

    // debug capture
    std::vector<float>  capIn_, capOut_;
    std::atomic<bool>   capturing_{false};
    std::mutex          capMu_;

    // Diagnostic/evidence capture (Phase 1-6 of docs/validation.md). See
    // evidence.h for the real-time-safety contract of this member.
    EvidenceSession     evidence_;

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* /*stream*/,
                                          void* audioData,
                                          int32_t numFrames) override {
        const auto callbackStart = std::chrono::steady_clock::now();
        auto* out = static_cast<float*>(audioData);

        // Non-blocking read — fills zeros if input has no data yet (MMAP startup)
        int32_t got = 0;
        if (inputStream_) {
            auto res = inputStream_->read(out, numFrames, 0 /*timeoutNs*/);
            got = (res) ? res.value() : 0;
        }
        const int64_t inputStartFrame =
                inputFramesRead_.fetch_add(got, std::memory_order_relaxed);
        const int64_t outputStartFrame =
                outputFramesWritten_.load(std::memory_order_relaxed);
        // Feed environment detection only real input frames. The output path
        // still pads short reads with silence, but classifier timing should not
        // be polluted by Oboe startup/read underrun zeros.
        if (got > 0) pushRawInput(out, got);

        LatencyProbeSnapshot probe = inspectLatencyProbeInput(out, got, inputStartFrame);
        captureChirpProbeInput(out, got, inputStartFrame);

        if (got < numFrames)
            std::memset(out + got, 0, (numFrames - got) * sizeof(float));

        bool cap = capturing_.load(std::memory_order_relaxed);
        if (cap) {
            // Capture raw mic samples before processing
            std::lock_guard<std::mutex> lk(capMu_);
            capIn_.insert(capIn_.end(), out, out + numFrames);
        }

        // Evidence/diagnostic logging is fully opt-in and only active while
        // an evidence session is running (docs/validation.md Phase 4/6). All
        // work below is arithmetic-only on stack-local accumulators — no
        // allocation, no file I/O, no mutex/lock — and pushed into
        // pre-allocated buffers via EvidenceSession's lock-free API.
        const bool wantFrameLog = evidence_.isActive() && evidence_.wantsFrameLog();
        const bool wantBandLog = evidence_.isActive() && evidence_.wantsBandLog();
        const bool wantLimiterLog = evidence_.isActive() && evidence_.wantsLimiterLog();
        const bool wantDiag = wantBandLog || wantLimiterLog;

        float rawSumSq = 0.f, rawPeak = 0.f, processedSumSq = 0.f, processedPeak = 0.f;
        float bandInSumSq[6] = {}, bandInPeak[6] = {}, bandOutSumSq[6] = {}, bandOutPeak[6] = {};
        float lastEnvDb[6] = {}, lastGainRedDb[6] = {}, lastMakeupDb[6] = {}, lastFinalDb[6] = {};
        float preLimSumSq = 0.f, preLimPeak = 0.f, postLimSumSq = 0.f, postLimPeak = 0.f;
        int32_t above095Before = 0, above095After = 0, clippedBefore = 0, clippedAfter = 0;
        ProcessDiagSample diag;

        for (int i = 0; i < numFrames; i++) {
            const float x = out[i];
            if (wantFrameLog) {
                rawSumSq += x * x;
                const float ax = std::fabs(x);
                if (ax > rawPeak) rawPeak = ax;
            }

            const float y = wantDiag ? proc_.process(x, &diag) : proc_.process(x);
            out[i] = y;

            if (wantFrameLog) {
                processedSumSq += y * y;
                const float ay = std::fabs(y);
                if (ay > processedPeak) processedPeak = ay;
            }
            if (wantBandLog) {
                for (int b = 0; b < 6; b++) {
                    bandInSumSq[b] += diag.bandIn[b] * diag.bandIn[b];
                    const float ain = std::fabs(diag.bandIn[b]);
                    if (ain > bandInPeak[b]) bandInPeak[b] = ain;
                    bandOutSumSq[b] += diag.bandOut[b] * diag.bandOut[b];
                    const float aout = std::fabs(diag.bandOut[b]);
                    if (aout > bandOutPeak[b]) bandOutPeak[b] = aout;
                    lastEnvDb[b] = diag.bandEnvDb[b];
                    lastGainRedDb[b] = diag.bandGainReductionDb[b];
                    lastMakeupDb[b] = diag.bandMakeupGainDb[b];
                    lastFinalDb[b] = diag.bandFinalGainDb[b];
                }
            }
            if (wantLimiterLog) {
                const float pre = std::fabs(diag.preLimiter);
                const float post = std::fabs(diag.postLimiter);
                preLimSumSq += diag.preLimiter * diag.preLimiter;
                if (pre > preLimPeak) preLimPeak = pre;
                postLimSumSq += diag.postLimiter * diag.postLimiter;
                if (post > postLimPeak) postLimPeak = post;
                if (pre > 0.95f) above095Before++;
                if (post > 0.95f) above095After++;
                if (pre >= 1.f) clippedBefore++;
                if (post >= 1.f) clippedAfter++;
            }
        }

        inspectLatencyProbeOutput(out, numFrames, outputStartFrame, probe);
        captureChirpProbeOutput(out, numFrames, outputStartFrame);
        outputFramesWritten_.fetch_add(numFrames, std::memory_order_relaxed);

        // Lock once per callback for output capture
        if (cap) {
            std::lock_guard<std::mutex> lk(capMu_);
            capOut_.insert(capOut_.end(), out, out + numFrames);
        }

        if (wantFrameLog || wantBandLog || wantLimiterLog) {
            const int64_t tsMs = evidenceNowEpochMs();
            const int32_t modeNow = (int32_t)currentMode_;
            const int32_t missing = numFrames - got;
            if (wantFrameLog) {
                const auto elapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
                        std::chrono::steady_clock::now() - callbackStart).count();
                FrameLogRow row;
                row.timestampMs = tsMs;
                row.frameIndex = outputStartFrame;
                row.rawRms = std::sqrt(rawSumSq / numFrames);
                row.processedRms = std::sqrt(processedSumSq / numFrames);
                row.rawPeak = rawPeak;
                row.processedPeak = processedPeak;
                row.rawDbfs = lin_to_db(row.rawRms);
                row.processedDbfs = lin_to_db(row.processedRms);
                row.activeMode = modeNow;
                row.callbackDurationUs = (int32_t)elapsedUs;
                row.underrunOrMissingFrames = missing;
                row.zeroFillCount = missing;
                evidence_.pushFrameRow(row);
            }
            if (wantBandLog) {
                BandBlockRow row;
                row.timestampMs = tsMs;
                row.frameIndex = outputStartFrame;
                row.activeMode = modeNow;
                for (int b = 0; b < 6; b++) {
                    row.inputRms[b] = std::sqrt(bandInSumSq[b] / numFrames);
                    row.inputPeak[b] = bandInPeak[b];
                    row.envelopeDb[b] = lastEnvDb[b];
                    row.thresholdDb[b] = proc_.comp_[b].thresholdDb;
                    row.ratio[b] = proc_.comp_[b].ratio;
                    row.gainReductionDb[b] = lastGainRedDb[b];
                    row.makeupGainDb[b] = lastMakeupDb[b];
                    row.finalGainDb[b] = lastFinalDb[b];
                    row.outputRms[b] = std::sqrt(bandOutSumSq[b] / numFrames);
                    row.outputPeak[b] = bandOutPeak[b];
                }
                evidence_.pushBandRow(row);
            }
            if (wantLimiterLog) {
                LimiterLogRow row;
                row.timestampMs = tsMs;
                row.frameIndex = outputStartFrame;
                row.activeMode = modeNow;
                row.preLimiterPeak = preLimPeak;
                row.postLimiterPeak = postLimPeak;
                row.preLimiterRms = std::sqrt(preLimSumSq / numFrames);
                row.postLimiterRms = std::sqrt(postLimSumSq / numFrames);
                row.samplesAbove095Before = above095Before;
                row.samplesAbove095After = above095After;
                row.samplesClippedBefore = clippedBefore;
                row.samplesClippedAfter = clippedAfter;
                row.limiterGainReductionDb = lin_to_db(row.postLimiterRms) - lin_to_db(row.preLimiterRms);
                evidence_.pushLimiterRow(row);
            }
        }

        return oboe::DataCallbackResult::Continue;
    }

    int startEngine(int32_t inputDeviceId) {
        if (running_) stopEngine();
        currentDeviceId_ = inputDeviceId;

        oboe::InputPreset preset = oboe::InputPreset::VoicePerformance;
        if (currentMode_ == MODE_TRANSIT) {
            preset = oboe::InputPreset::Camcorder;
        }
        // Conversation mode intentionally uses VoicePerformance (not VoiceCommunication).
        // VoiceCommunication enables Android's system AGC + Noise Suppressor, which
        // creates "foggy" artifacts and gain ducking when speech is detected — exactly
        // the opposite of what a hearing aid needs. VoicePerformance provides raw mic
        // input with minimal system processing so our DSP handles everything.

        oboe::AudioStreamBuilder inB;
        inB.setDirection(oboe::Direction::Input)
           ->setDeviceId(inputDeviceId)
           ->setChannelCount(1)
           ->setFormat(oboe::AudioFormat::Float)
           ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
           ->setSharingMode(oboe::SharingMode::Exclusive)
           ->setInputPreset(preset);

        auto inRes = inB.openManagedStream(inputStream_);
        if (inRes != oboe::Result::OK) {
            LOGE("Failed to open input stream: %s", oboe::convertToText(inRes));
            return -1;
        }
        inputStream_->setBufferSizeInFrames(inputStream_->getFramesPerBurst() * 2);
        configureRawInputBuffer(inputStream_->getSampleRate());
        proc_.init((float)inputStream_->getSampleRate());

        oboe::AudioStreamBuilder outB;
        outB.setDirection(oboe::Direction::Output)
            ->setChannelCount(1)
            ->setFormat(oboe::AudioFormat::Float)
            ->setSampleRate(inputStream_->getSampleRate())
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setUsage(static_cast<oboe::Usage>(audioUsage_))
            ->setDataCallback(this);

        auto outRes = outB.openManagedStream(outputStream_);
        if (outRes != oboe::Result::OK) {
            LOGE("Failed to open output stream: %s", oboe::convertToText(outRes));
            inputStream_->close();
            return -2;
        }
        outputStream_->setBufferSizeInFrames(outputStream_->getFramesPerBurst() * 2);

        inputFramesRead_.store(0, std::memory_order_relaxed);
        outputFramesWritten_.store(0, std::memory_order_relaxed);

        inputStream_->requestStart();
        outputStream_->requestStart();
        running_ = true;
        LOGI("Streams started. SR=%d, inBurst=%d, outBurst=%d",
             inputStream_->getSampleRate(),
             inputStream_->getFramesPerBurst(),
             outputStream_->getFramesPerBurst());
        return 0;
    }

    int stopEngine() {
        // Stop output first to halt the callback before closing input
        if (outputStream_) outputStream_->requestStop();
        if (inputStream_)  inputStream_->requestStop();
        running_ = false;
        inputSampleRate_.store(0, std::memory_order_relaxed);
        latencyProbe_.armed.store(false, std::memory_order_relaxed);
        chirpProbe_.capturing.store(false, std::memory_order_relaxed);
        clearRawInput();
        LOGI("Streams stopped.");
        return 0;
    }

    void setEnvironmentMode(EnvironmentMode mode) {
        if (mode != currentMode_) {
            ModeChangeRow row;
            row.timestampMs = evidenceNowEpochMs();
            row.fromMode = (int32_t)currentMode_;
            row.toMode = (int32_t)mode;
            evidence_.logModeChange(row);
        }
        currentMode_ = mode;
        proc_.setMode(mode);
        if (running_) {
            // Restart to apply new InputPreset
            startEngine(currentDeviceId_);
        }
    }

    int32_t getInputSampleRate() const {
        return inputSampleRate_.load(std::memory_order_relaxed);
    }

    int32_t drainRawInput(float* out, int32_t maxFrames) {
        if (out == nullptr || maxFrames <= 0) return 0;
        std::lock_guard<std::mutex> lk(rawInputMu_);
        const int32_t frames =
                (int32_t)std::min(rawInputCount_, (size_t)maxFrames);
        for (int32_t i = 0; i < frames; i++) {
            out[i] = rawInputRing_[rawInputRead_];
            rawInputRead_ = (rawInputRead_ + 1) % rawInputRing_.size();
        }
        rawInputCount_ -= (size_t)frames;
        return frames;
    }

    void clearPendingRawInput() {
        clearRawInput();
    }

    void startLatencyProbe(float threshold) {
        latencyProbe_.threshold.store(clampf(threshold, 0.0001f, 1.f),
                                      std::memory_order_relaxed);
        latencyProbe_.status.store(0, std::memory_order_relaxed);
        latencyProbe_.inputFrame.store(-1, std::memory_order_relaxed);
        latencyProbe_.outputFrame.store(-1, std::memory_order_relaxed);
        latencyProbe_.inputTimeNs.store(0, std::memory_order_relaxed);
        latencyProbe_.outputTimeNs.store(0, std::memory_order_relaxed);
        latencyProbe_.latencyMs.store(0.0, std::memory_order_relaxed);
        latencyProbe_.armedOutputFrame.store(
                outputFramesWritten_.load(std::memory_order_relaxed),
                std::memory_order_relaxed);
        latencyProbe_.armed.store(true, std::memory_order_release);
    }

    void stopLatencyProbe() {
        latencyProbe_.armed.store(false, std::memory_order_release);
        if (latencyProbe_.status.load(std::memory_order_relaxed) == 0) {
            latencyProbe_.status.store(-1, std::memory_order_relaxed);
        }
    }

    double getLatencyProbeMs() const {
        if (latencyProbe_.status.load(std::memory_order_relaxed) != 1) return -1.0;
        return latencyProbe_.latencyMs.load(std::memory_order_relaxed);
    }

    int32_t getLatencyProbeStatus() const {
        return latencyProbe_.status.load(std::memory_order_relaxed);
    }

    void startChirpLatencyProbe(int32_t captureMs) {
        const int32_t sr = getInputSampleRate() > 0 ? getInputSampleRate() : 48000;
        const int32_t clampedMs = std::max(250, std::min(captureMs, 3000));
        const int32_t maxFrames = std::max(1, (int32_t)((int64_t)sr * clampedMs / 1000));

        std::lock_guard<std::mutex> lk(chirpProbe_.mu);
        chirpProbe_.input.clear();
        chirpProbe_.output.clear();
        chirpProbe_.input.reserve((size_t)maxFrames);
        chirpProbe_.output.reserve((size_t)maxFrames);
        chirpProbe_.sampleRate = sr;
        chirpProbe_.maxFrames = maxFrames;
        chirpProbe_.inputStartFrame =
                inputFramesRead_.load(std::memory_order_relaxed);
        chirpProbe_.outputStartFrame =
                outputFramesWritten_.load(std::memory_order_relaxed);
        chirpProbe_.inputStartTimeNs =
                frameTimeNs(inputStream_.get(), chirpProbe_.inputStartFrame);
        chirpProbe_.outputStartTimeNs =
                frameTimeNs(outputStream_.get(), chirpProbe_.outputStartFrame);
        chirpProbe_.inputPeak = -1;
        chirpProbe_.outputPeak = -1;
        chirpProbe_.inputScore = 0.f;
        chirpProbe_.outputScore = 0.f;
        chirpProbe_.latencyMs = 0.0;
        chirpProbe_.status.store(0, std::memory_order_relaxed);
        chirpProbe_.capturing.store(true, std::memory_order_release);
    }

    int32_t stopChirpLatencyProbe() {
        chirpProbe_.capturing.store(false, std::memory_order_release);
        return computeChirpLatencyProbe();
    }

    double getChirpLatencyMs() const {
        return chirpProbe_.status.load(std::memory_order_relaxed) == 1
                ? chirpProbe_.latencyMs
                : -1.0;
    }

    int32_t getChirpLatencyStatus() const {
        return chirpProbe_.status.load(std::memory_order_relaxed);
    }

    float getChirpInputScore() const {
        return chirpProbe_.inputScore;
    }

    float getChirpOutputScore() const {
        return chirpProbe_.outputScore;
    }

    int32_t computeAcousticChirpLatency(int64_t playbackStartNs) {
        return computeAcousticChirpLatencyProbe(playbackStartNs);
    }

    double getAcousticChirpLatencyMs() const {
        return chirpProbe_.status.load(std::memory_order_relaxed) == 1
                ? chirpProbe_.acousticLatencyMs
                : -1.0;
    }

    float getAcousticChirpScore() const {
        return chirpProbe_.acousticScore;
    }

private:
    struct LatencyProbeSnapshot {
        bool found = false;
        int64_t inputFrame = -1;
        int64_t inputTimeNs = 0;
    };

    void configureRawInputBuffer(int32_t sampleRate) {
        std::lock_guard<std::mutex> lk(rawInputMu_);
        inputSampleRate_.store(sampleRate, std::memory_order_relaxed);
        const size_t capacity = (size_t)std::max(sampleRate * 6, 1);
        rawInputRing_.assign(capacity, 0.f);
        rawInputRead_ = 0;
        rawInputWrite_ = 0;
        rawInputCount_ = 0;
    }

    void clearRawInput() {
        std::lock_guard<std::mutex> lk(rawInputMu_);
        rawInputRead_ = 0;
        rawInputWrite_ = 0;
        rawInputCount_ = 0;
    }

    void pushRawInput(const float* samples, int32_t numFrames) {
        if (samples == nullptr || numFrames <= 0) return;
        std::lock_guard<std::mutex> lk(rawInputMu_);
        if (rawInputRing_.empty()) return;
        for (int32_t i = 0; i < numFrames; i++) {
            rawInputRing_[rawInputWrite_] = samples[i];
            rawInputWrite_ = (rawInputWrite_ + 1) % rawInputRing_.size();
            if (rawInputCount_ == rawInputRing_.size()) {
                rawInputRead_ = (rawInputRead_ + 1) % rawInputRing_.size();
            } else {
                rawInputCount_++;
            }
        }
    }

    void captureChirpProbeInput(
            const float* samples,
            int32_t numFrames,
            int64_t inputStartFrame) {
        if (!chirpProbe_.capturing.load(std::memory_order_acquire) ||
            samples == nullptr ||
            numFrames <= 0) {
            return;
        }

        std::lock_guard<std::mutex> lk(chirpProbe_.mu);
        if (chirpProbe_.input.empty()) {
            chirpProbe_.inputStartFrame = inputStartFrame;
            chirpProbe_.inputStartTimeNs = frameTimeNs(inputStream_.get(), inputStartFrame);
        }
        appendLimited(chirpProbe_.input, samples, numFrames, chirpProbe_.maxFrames);
    }

    void captureChirpProbeOutput(
            const float* samples,
            int32_t numFrames,
            int64_t outputStartFrame) {
        if (!chirpProbe_.capturing.load(std::memory_order_acquire) ||
            samples == nullptr ||
            numFrames <= 0) {
            return;
        }

        std::lock_guard<std::mutex> lk(chirpProbe_.mu);
        if (chirpProbe_.output.empty()) {
            chirpProbe_.outputStartFrame = outputStartFrame;
            chirpProbe_.outputStartTimeNs = frameTimeNs(outputStream_.get(), outputStartFrame);
        }
        appendLimited(chirpProbe_.output, samples, numFrames, chirpProbe_.maxFrames);
    }

    static void appendLimited(
            std::vector<float>& dst,
            const float* src,
            int32_t numFrames,
            int32_t maxFrames) {
        const size_t remaining = (size_t)std::max(0, maxFrames - (int32_t)dst.size());
        const size_t toCopy = std::min((size_t)numFrames, remaining);
        if (toCopy > 0) dst.insert(dst.end(), src, src + toCopy);
    }

    int64_t frameTimeNs(oboe::AudioStream* stream, int64_t frameIndex) const {
        if (stream == nullptr) return 0;
        auto ts = stream->getTimestamp(CLOCK_MONOTONIC);
        if (!ts) return 0;
        const int32_t sampleRate = stream->getSampleRate();
        if (sampleRate <= 0) return 0;
        const int64_t deltaFrames = frameIndex - ts.value().position;
        const double deltaNs = (double)deltaFrames * 1000000000.0 / (double)sampleRate;
        return ts.value().timestamp + (int64_t)std::llround(deltaNs);
    }

    LatencyProbeSnapshot inspectLatencyProbeInput(
            const float* samples,
            int32_t numFrames,
            int64_t inputStartFrame) {
        LatencyProbeSnapshot snapshot;
        if (!latencyProbe_.armed.load(std::memory_order_acquire) || numFrames <= 0) {
            return snapshot;
        }
        if (latencyProbe_.inputFrame.load(std::memory_order_relaxed) >= 0) {
            snapshot.found = true;
            snapshot.inputFrame = latencyProbe_.inputFrame.load(std::memory_order_relaxed);
            snapshot.inputTimeNs = latencyProbe_.inputTimeNs.load(std::memory_order_relaxed);
            return snapshot;
        }

        const float threshold = latencyProbe_.threshold.load(std::memory_order_relaxed);
        for (int32_t i = 0; i < numFrames; i++) {
            if (std::fabs(samples[i]) >= threshold) {
                const int64_t frame = inputStartFrame + i;
                const int64_t timeNs = frameTimeNs(inputStream_.get(), frame);
                latencyProbe_.inputFrame.store(frame, std::memory_order_relaxed);
                latencyProbe_.inputTimeNs.store(timeNs, std::memory_order_relaxed);
                snapshot.found = true;
                snapshot.inputFrame = frame;
                snapshot.inputTimeNs = timeNs;
                break;
            }
        }
        return snapshot;
    }

    void inspectLatencyProbeOutput(
            const float* samples,
            int32_t numFrames,
            int64_t outputStartFrame,
            const LatencyProbeSnapshot& probe) {
        if (!latencyProbe_.armed.load(std::memory_order_acquire) || !probe.found) {
            return;
        }
        if (latencyProbe_.status.load(std::memory_order_relaxed) != 0) return;

        const float threshold = latencyProbe_.threshold.load(std::memory_order_relaxed);
        const int64_t armedFrame =
                latencyProbe_.armedOutputFrame.load(std::memory_order_relaxed);
        for (int32_t i = 0; i < numFrames; i++) {
            const int64_t outputFrame = outputStartFrame + i;
            if (outputFrame < armedFrame) continue;
            if (std::fabs(samples[i]) < threshold) continue;

            const int64_t outputTimeNs = frameTimeNs(outputStream_.get(), outputFrame);
            if (probe.inputTimeNs == 0 || outputTimeNs == 0) {
                latencyProbe_.status.store(-2, std::memory_order_relaxed);
            } else {
                const double latencyMs =
                        (double)(outputTimeNs - probe.inputTimeNs) / 1000000.0;
                latencyProbe_.outputFrame.store(outputFrame, std::memory_order_relaxed);
                latencyProbe_.outputTimeNs.store(outputTimeNs, std::memory_order_relaxed);
                latencyProbe_.latencyMs.store(latencyMs, std::memory_order_relaxed);
                latencyProbe_.status.store(1, std::memory_order_relaxed);
            }
            latencyProbe_.armed.store(false, std::memory_order_release);
            return;
        }
    }

    static std::vector<float> makeLatencyChirp(int32_t sampleRate) {
        const double durationSec = 0.040;
        const double f0 = 1800.0;
        const double f1 = 7600.0;
        const int32_t n = std::max(64, (int32_t)std::lrint(durationSec * sampleRate));
        const int32_t fade = std::max(1, (int32_t)std::lrint(0.004 * sampleRate));
        std::vector<float> ref((size_t)n);
        const double k = (f1 - f0) / durationSec;
        const double pi = 3.14159265358979323846;

        for (int32_t i = 0; i < n; i++) {
            const double t = (double)i / (double)sampleRate;
            const double phase = 2.0 * pi * (f0 * t + 0.5 * k * t * t);
            double env = 1.0;
            if (i < fade) {
                env = 0.5 - 0.5 * std::cos(pi * (double)i / (double)fade);
            } else if (i >= n - fade) {
                const int32_t j = n - 1 - i;
                env = 0.5 - 0.5 * std::cos(pi * (double)j / (double)fade);
            }
            ref[(size_t)i] = (float)(std::sin(phase) * env);
        }
        return ref;
    }

    static int32_t findBestCorrelation(
            const std::vector<float>& signal,
            const std::vector<float>& ref,
            float* bestScore) {
        if (bestScore) *bestScore = 0.f;
        if (signal.size() < ref.size() || ref.empty()) return -1;

        double refEnergy = 0.0;
        for (float v : ref) refEnergy += (double)v * (double)v;
        if (refEnergy <= 1e-12) return -1;

        std::vector<double> prefix(signal.size() + 1, 0.0);
        for (size_t i = 0; i < signal.size(); i++) {
            prefix[i + 1] = prefix[i] + (double)signal[i] * (double)signal[i];
        }

        float maxScore = 0.f;
        int32_t bestIndex = -1;
        const size_t maxLag = signal.size() - ref.size();
        for (size_t lag = 0; lag <= maxLag; lag++) {
            const double winEnergy = prefix[lag + ref.size()] - prefix[lag];
            if (winEnergy <= 1e-12) continue;

            double dot = 0.0;
            for (size_t i = 0; i < ref.size(); i++) {
                dot += (double)signal[lag + i] * (double)ref[i];
            }
            const float score =
                    (float)std::fabs(dot / std::sqrt(refEnergy * winEnergy));
            if (score > maxScore) {
                maxScore = score;
                bestIndex = (int32_t)lag;
            }
        }

        if (bestScore) *bestScore = maxScore;
        return bestIndex;
    }

    int32_t computeChirpLatencyProbe() {
        std::vector<float> input;
        std::vector<float> output;
        int32_t sr;
        int64_t inputStartTimeNs;
        int64_t outputStartTimeNs;

        {
            std::lock_guard<std::mutex> lk(chirpProbe_.mu);
            input = chirpProbe_.input;
            output = chirpProbe_.output;
            sr = chirpProbe_.sampleRate;
            inputStartTimeNs = chirpProbe_.inputStartTimeNs;
            outputStartTimeNs = chirpProbe_.outputStartTimeNs;
        }

        if (inputStartTimeNs == 0 || outputStartTimeNs == 0) {
            chirpProbe_.status.store(-2, std::memory_order_relaxed);
            return -2;
        }

        const std::vector<float> ref = makeLatencyChirp(sr);
        float inputScore = 0.f;
        float outputScore = 0.f;
        const int32_t inputPeak = findBestCorrelation(input, ref, &inputScore);
        const int32_t outputPeak = findBestCorrelation(output, ref, &outputScore);

        chirpProbe_.inputPeak = inputPeak;
        chirpProbe_.outputPeak = outputPeak;
        chirpProbe_.inputScore = inputScore;
        chirpProbe_.outputScore = outputScore;

        static constexpr float kMinCorrelationScore = 0.28f;
        if (inputPeak < 0 || outputPeak < 0 ||
            inputScore < kMinCorrelationScore ||
            outputScore < kMinCorrelationScore) {
            chirpProbe_.status.store(-1, std::memory_order_relaxed);
            return -1;
        }

        const double inputTimeNs =
                (double)inputStartTimeNs + (double)inputPeak * 1000000000.0 / (double)sr;
        const double outputTimeNs =
                (double)outputStartTimeNs + (double)outputPeak * 1000000000.0 / (double)sr;
        chirpProbe_.latencyMs = (outputTimeNs - inputTimeNs) / 1000000.0;
        chirpProbe_.status.store(1, std::memory_order_relaxed);
        return 1;
    }

    int32_t computeAcousticChirpLatencyProbe(int64_t playbackStartNs) {
        std::vector<float> input;
        int32_t sr;
        int64_t inputStartTimeNs;

        {
            std::lock_guard<std::mutex> lk(chirpProbe_.mu);
            input = chirpProbe_.input;
            sr = chirpProbe_.sampleRate;
            inputStartTimeNs = chirpProbe_.inputStartTimeNs;
        }

        if (inputStartTimeNs == 0 || playbackStartNs <= 0) {
            chirpProbe_.status.store(-2, std::memory_order_relaxed);
            return -2;
        }

        const std::vector<float> ref = makeLatencyChirp(sr);
        float inputScore = 0.f;
        const int32_t inputPeak = findBestCorrelation(input, ref, &inputScore);

        chirpProbe_.inputPeak = inputPeak;
        chirpProbe_.acousticScore = inputScore;

        static constexpr float kMinCorrelationScore = 0.28f;
        if (inputPeak < 0 || inputScore < kMinCorrelationScore) {
            chirpProbe_.status.store(-1, std::memory_order_relaxed);
            return -1;
        }

        const double inputTimeNs =
                (double)inputStartTimeNs + (double)inputPeak * 1000000000.0 / (double)sr;
        chirpProbe_.acousticLatencyMs =
                (inputTimeNs - (double)playbackStartNs) / 1000000.0;
        chirpProbe_.status.store(1, std::memory_order_relaxed);
        return 1;
    }
};

static OboeEngine gEngine;

// ---- FFI exports ------------------------------------------------------------

extern "C" {

int32_t process_audio_file_ffi(
        const char* inPath, const char* outPath,
        const float* loss6,
        float ratio, float attackMs, float releaseMs,
        const float* thrDb,
        float masterDb, float wet, float dry) {

    WavData wav;
    if (!read_wav_mono16(inPath, wav)) {
        LOGE("process_audio_file_ffi: cannot read %s", inPath);
        return 1;
    }

    const float fs = (float)wav.sampleRate;
    const float edges[5] = {500,1000,2000,4000,8000};
    Crossover6 xo; xo.init(fs, edges);

    float makeupDb[6];
    for (int i=0;i<6;i++) makeupDb[i]=appThresholdToMakeupGainDb(loss6[i]);

    Compressor comp[6];
    for (int i=0;i<6;i++) {
        comp[i].init(fs);
        comp[i].ratio       = std::max(1.f,ratio);
        comp[i].attackMs    = std::max(1.f,attackMs);
        comp[i].releaseMs   = std::max(10.f,releaseMs);
        comp[i].thresholdDb = thrDb[i];
    }

    float masterLin = db_to_lin(masterDb);
    wet = clampf(wet,0.f,1.5f); dry = clampf(dry,0.f,1.f);
    SoftLimiter lim;

    std::vector<float> yOn(wav.x.size());
    for (size_t n=0; n<wav.x.size(); n++) {
        float x=wav.x[n], b[6];
        xo.split(x,b);
        float sumOn=0.f;
        for (int i=0;i<6;i++)
            sumOn += comp[i].process(b[i]) * db_to_lin(makeupDb[i]);
        yOn[n] = lim.process((dry*x + wet*sumOn)*masterLin);
    }

    if (!write_wav_mono16(outPath, yOn, wav.sampleRate)) {
        LOGE("process_audio_file_ffi: cannot write %s", outPath);
        return 2;
    }
    return 0;
}

int32_t start_rt_stream_ffi(int32_t inputDeviceId) {
    return gEngine.startEngine(inputDeviceId);
}

int32_t stop_rt_stream_ffi() {
    return gEngine.stopEngine();
}

int32_t update_rt_params_ffi(const float* loss6) {
    gEngine.proc_.updateLoss(loss6);
    return 0;
}

int32_t get_rt_input_sample_rate_ffi() {
    return gEngine.getInputSampleRate();
}

int32_t drain_rt_input_frames_ffi(float* out, int32_t maxFrames) {
    return gEngine.drainRawInput(out, maxFrames);
}

void clear_rt_input_frames_ffi() {
    gEngine.clearPendingRawInput();
}

void start_latency_probe_ffi(float threshold) {
    gEngine.startLatencyProbe(threshold);
}

void stop_latency_probe_ffi() {
    gEngine.stopLatencyProbe();
}

double get_latency_probe_ms_ffi() {
    return gEngine.getLatencyProbeMs();
}

int32_t get_latency_probe_status_ffi() {
    return gEngine.getLatencyProbeStatus();
}

void start_chirp_latency_probe_ffi(int32_t captureMs) {
    gEngine.startChirpLatencyProbe(captureMs);
}

int32_t stop_chirp_latency_probe_ffi() {
    return gEngine.stopChirpLatencyProbe();
}

double get_chirp_latency_ms_ffi() {
    return gEngine.getChirpLatencyMs();
}

int32_t get_chirp_latency_status_ffi() {
    return gEngine.getChirpLatencyStatus();
}

float get_chirp_input_score_ffi() {
    return gEngine.getChirpInputScore();
}

float get_chirp_output_score_ffi() {
    return gEngine.getChirpOutputScore();
}

int32_t compute_acoustic_chirp_latency_ffi(int64_t playbackStartNs) {
    return gEngine.computeAcousticChirpLatency(playbackStartNs);
}

double get_acoustic_chirp_latency_ms_ffi() {
    return gEngine.getAcousticChirpLatencyMs();
}

float get_acoustic_chirp_score_ffi() {
    return gEngine.getAcousticChirpScore();
}

void debug_start_capture_ffi() {
    std::lock_guard<std::mutex> lk(gEngine.capMu_);
    gEngine.capIn_.clear();
    gEngine.capOut_.clear();
    gEngine.capturing_ = true;
}

void debug_stop_capture_ffi() {
    gEngine.capturing_ = false;
}

int32_t debug_save_capture_ffi(const char* filePath, int32_t source) {
    std::lock_guard<std::mutex> lk(gEngine.capMu_);
    const std::vector<float>& buf = (source == 0) ? gEngine.capIn_ : gEngine.capOut_;
    
    int sr = 48000;
    if (gEngine.inputStream_) {
        sr = gEngine.inputStream_->getSampleRate();
    } else if (gEngine.outputStream_) {
        sr = gEngine.outputStream_->getSampleRate();
    }

    if (!write_wav_mono16(filePath, buf, sr)) {
        return -1;
    }
    return (int32_t)buf.size();
}

int32_t debug_get_capture_size_ffi() {
    std::lock_guard<std::mutex> lk(gEngine.capMu_);
    return (int32_t)gEngine.capIn_.size();
}

void set_audio_usage_ffi(int32_t usage) {
    gEngine.audioUsage_ = usage;
}

uint8_t is_playing_ffi() {
    return gEngine.running_.load() ? 1 : 0;
}

int32_t set_environment_mode_ffi(int32_t mode) {
    gEngine.setEnvironmentMode(static_cast<EnvironmentMode>(mode));
    return 0;
}

int32_t set_expander_enabled_ffi(int32_t enabled) {
    gEngine.proc_.conversation_.enabled_ = (enabled != 0);
    if (enabled != 0) {
        gEngine.proc_.conversation_.reset();
    }
    return 0;
}

// ---- Evidence / diagnostic capture FFI (docs/validation.md) ---------------
// experimentType: 0 live_microphone_test, 1 pure_tone_test, 2 sweep_test,
//                 3 mode_comparison_test, 4 limiter_test
// mode: 0 Standard, 1 Transit, 2 Conversation

int32_t evidence_start_ffi(const char* sessionId, int32_t experimentType, int32_t mode,
                            int32_t durationSeconds, int32_t captureRawProcessed,
                            int32_t captureBandLog, int32_t captureLimiterLog,
                            int32_t captureFrameLog) {
    EvidenceSession::Config cfg;
    cfg.sessionId = sessionId ? sessionId : "";
    cfg.experimentType = experimentType;
    cfg.activeMode = mode;
    const int32_t sr = gEngine.getInputSampleRate();
    cfg.sampleRate = sr > 0 ? sr : 48000;
    cfg.durationSeconds = durationSeconds;
    cfg.captureBandLog = captureBandLog != 0;
    cfg.captureLimiterLog = captureLimiterLog != 0;
    cfg.captureFrameLog = captureFrameLog != 0;
    gEngine.evidence_.start(cfg);

    if (captureRawProcessed != 0) {
        std::lock_guard<std::mutex> lk(gEngine.capMu_);
        gEngine.capIn_.clear();
        gEngine.capOut_.clear();
        gEngine.capturing_ = true;
    }
    LOGI("Evidence session started: id=%s type=%d mode=%d duration=%ds",
         cfg.sessionId.c_str(), experimentType, mode, durationSeconds);
    return 0;
}

int32_t evidence_stop_ffi() {
    gEngine.evidence_.stop();
    gEngine.capturing_ = false;
    return 0;
}

// Writes whichever CSVs (into logsDir) and live-capture WAVs (into audioDir)
// were captured. Both directories must already exist. Only ever performs
// file I/O on the calling (non-audio) thread. Returns the number of files
// written, or a negative value on failure.
int32_t evidence_flush_ffi(const char* logsDir, const char* audioDir) {
    if (logsDir == nullptr || audioDir == nullptr) return -1;
    int32_t written = gEngine.evidence_.flush(std::string(logsDir));

    std::lock_guard<std::mutex> lk(gEngine.capMu_);
    int sr = 48000;
    if (gEngine.inputStream_) {
        sr = gEngine.inputStream_->getSampleRate();
    } else if (gEngine.outputStream_) {
        sr = gEngine.outputStream_->getSampleRate();
    }
    const std::string dir(audioDir);
    if (!gEngine.capIn_.empty() &&
        write_wav_mono16(dir + "/live_raw_input.wav", gEngine.capIn_, sr)) {
        written++;
    }
    if (!gEngine.capOut_.empty() &&
        write_wav_mono16(dir + "/live_processed_output.wav", gEngine.capOut_, sr)) {
        written++;
    }
    return written;
}

// source: "hearing_profile" / "manual_slider" / "mode_adjustment" / "test_override"
void evidence_log_gain_update_ffi(const char* source, const float* gainsDb6) {
    if (gainsDb6 == nullptr) return;
    GainUpdateRow row;
    row.timestampMs = evidenceNowEpochMs();
    row.source = source ? source : "unknown";
    row.activeMode = (int32_t)gEngine.currentMode_;
    for (int i = 0; i < 6; i++) {
        row.gainsDb[i] = gainsDb6[i];
        row.gainsLinear[i] = db_to_lin(gainsDb6[i]);
    }
    gEngine.evidence_.logGainUpdate(row);
}

// Current per-band makeup gain (dB), derived from the active hearing profile
// / slider values, for session_config.json / dsp_config.json / gain_profile.csv.
void get_band_gains_db_ffi(float* outGainsDb6) {
    if (outGainsDb6 == nullptr) return;
    for (int i = 0; i < 6; i++) {
        outGainsDb6[i] = lin_to_db(gEngine.proc_.makeupLin[i]);
    }
}

// Current compressor/limiter configuration, for dsp_config.json.
void get_dsp_params_ffi(float* outThrDb6, float* outRatio, float* outAttackMs,
                         float* outReleaseMs, float* outLimiterThr,
                         float* outWet, float* outDry) {
    if (outThrDb6 != nullptr) {
        for (int i = 0; i < 6; i++) outThrDb6[i] = gEngine.proc_.comp_[i].thresholdDb;
    }
    if (outRatio) *outRatio = gEngine.proc_.ratio_;
    if (outAttackMs) *outAttackMs = gEngine.proc_.attackMs_;
    if (outReleaseMs) *outReleaseMs = gEngine.proc_.releaseMs_;
    if (outLimiterThr) *outLimiterThr = gEngine.proc_.lim_.thr;
    if (outWet) *outWet = gEngine.proc_.wet_;
    if (outDry) *outDry = gEngine.proc_.dry_;
}

// Deterministic dsp_config.json / gain_profile.csv source for a given
// (loss6, mode) pair, independent of gEngine's live/global state. Builds a
// fresh RealtimeProcessor exactly like process_audio_file_full_ffi does, so
// the metadata always matches what the offline experiments actually ran
// with -- unlike get_band_gains_db_ffi/get_dsp_params_ffi, which read the
// live engine and are wrong if it was never started or is in a different
// mode than the one an experiment used.
void get_dsp_config_for_profile_ffi(
        const float* loss6, int32_t mode, int32_t sampleRate,
        float* outGainsDb6, float* outThrDb6,
        float* outRatio, float* outAttackMs, float* outReleaseMs,
        float* outLimiterThr, float* outWet, float* outDry) {
    RealtimeProcessor proc;
    proc.init((float)(sampleRate > 0 ? sampleRate : 48000));
    proc.setMode(static_cast<EnvironmentMode>(mode));
    if (loss6 != nullptr) proc.updateLoss(loss6);

    if (outGainsDb6 != nullptr) {
        for (int i = 0; i < 6; i++) outGainsDb6[i] = lin_to_db(proc.makeupLin[i]);
    }
    if (outThrDb6 != nullptr) {
        for (int i = 0; i < 6; i++) outThrDb6[i] = proc.comp_[i].thresholdDb;
    }
    if (outRatio) *outRatio = proc.ratio_;
    if (outAttackMs) *outAttackMs = proc.attackMs_;
    if (outReleaseMs) *outReleaseMs = proc.releaseMs_;
    if (outLimiterThr) *outLimiterThr = proc.lim_.thr;
    if (outWet) *outWet = proc.wet_;
    if (outDry) *outDry = proc.dry_;
}

// Offline pure-tone / sweep / mode-comparison verification (Phase 7-9): runs
// inPath through a freshly-constructed RealtimeProcessor — the exact same
// class the live Oboe engine uses — with the given loss profile and mode,
// writes outPath, and (if the paths are non-null) writes band_level_log.csv
// / limiter_log.csv aggregated over ~10ms blocks. No microphone or Oboe
// stream involved, so this also runs from a host command-line harness.
int32_t process_audio_file_full_ffi(
        const char* inPath, const char* outPath,
        const float* loss6, int32_t mode,
        const char* bandLogCsvPath, const char* limiterLogCsvPath,
        const char* sourceLabel) {
    WavData wav;
    if (!read_wav_mono16(inPath, wav)) {
        return 1;
    }

    RealtimeProcessor proc;
    proc.init((float)wav.sampleRate);
    proc.setMode(static_cast<EnvironmentMode>(mode));
    if (loss6 != nullptr) proc.updateLoss(loss6);

    const bool wantBand = bandLogCsvPath != nullptr;
    const bool wantLimiter = limiterLogCsvPath != nullptr;
    const std::string source = sourceLabel ? sourceLabel : "offline";
    auto result = processWavWithDiagnostics(proc, wav, wantBand, wantLimiter, mode, source);

    if (!write_wav_mono16(outPath, result.processed, wav.sampleRate)) return 2;
    // append=true: several offline experiment calls (one per pure-tone
    // frequency, the sweep, each mode) accumulate into the same per-session
    // band_level_log.csv / limiter_log.csv rather than overwriting each other.
    if (wantBand) writeBandLogCsv(bandLogCsvPath, result.bandRows, result.bandRows.size(), true);
    if (wantLimiter) writeLimiterLogCsv(limiterLogCsvPath, result.limiterRows, result.limiterRows.size(), true);
    return 0;
}

// Offline test-signal generators (Phase 7-9). One-shot, not called from the
// audio callback — safe to allocate/write files here.
int32_t generate_tone_wav_ffi(const char* path, float freqHz, float durationSec,
                               int32_t sampleRate, float amplitudeDbFs) {
    auto x = generateToneSignal(freqHz, durationSec, sampleRate, amplitudeDbFs);
    return write_wav_mono16(path, x, sampleRate) ? 0 : 1;
}

int32_t generate_sweep_wav_ffi(const char* path, float f0Hz, float f1Hz, float durationSec,
                                int32_t sampleRate, float amplitudeDbFs) {
    auto x = generateLogSweepSignal(f0Hz, f1Hz, durationSec, sampleRate, amplitudeDbFs);
    return write_wav_mono16(path, x, sampleRate) ? 0 : 1;
}

int32_t generate_synthetic_test_wav_ffi(const char* path, float durationSec, int32_t sampleRate) {
    auto x = generateSyntheticSpeechNoiseSignal(durationSec, sampleRate);
    return write_wav_mono16(path, x, sampleRate) ? 0 : 1;
}

} // extern "C"
