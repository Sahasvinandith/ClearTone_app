// evidence.h
//
// DSP evidence-collection primitives shared by the on-device engine
// (audio_engine.cpp) and the host verification harness (tools/dsp_harness).
// Platform-agnostic — no Oboe / Android dependencies.
//
// Real-time-safety contract for the audio-callback-facing API
// (EvidenceSession::pushFrameRow / pushBandRow / pushLimiterRow):
//   - Every row buffer is pre-allocated up front in start(), sized from the
//     requested session duration. No heap allocation happens after start().
//   - Writes use a single atomic fetch_add index into a fixed-capacity
//     vector — no mutex, no lock. If a session runs longer than its
//     pre-allocated capacity, further rows are silently dropped (never
//     reallocated) rather than blocking or growing.
//   - stop() only flips an atomic flag (checked with memory_order_relaxed on
//     the audio thread) and then sleeps briefly on the calling (non-RT)
//     thread so any in-flight callback finishes before flush() reads the
//     buffers. flush() itself performs file I/O and must only be called
//     from a non-audio thread, strictly after stop().
//
// Gain-update / mode-change logs are event-driven (fired from slider drags
// or mode switches on the UI/control thread, never from the audio
// callback), so they use a plain mutex-guarded vector — that's fine off the
// RT thread.

#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "dsp_core.h"

static inline int64_t evidenceNowEpochMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

static inline const char* evidenceExperimentTypeName(int32_t t) {
    switch (t) {
        case 0: return "live_microphone_test";
        case 1: return "pure_tone_test";
        case 2: return "sweep_test";
        case 3: return "mode_comparison_test";
        case 4: return "limiter_test";
        default: return "unknown";
    }
}

static inline const char* evidenceModeName(int32_t mode) {
    switch (mode) {
        case 0: return "Standard";
        case 1: return "Transit";
        case 2: return "Conversation";
        default: return "Unknown";
    }
}

static const char* kEvidenceBandLabels[6] = {
    "band1", "band2", "band3", "band4", "band5", "band6"
};
static const char* kEvidenceBandFreqRegions[6] = {
    "<500", "500-1000", "1000-2000", "2000-4000", "4000-8000", ">8000"
};

// ---- Row types --------------------------------------------------------

// `source` identifies which experiment/file a row came from (e.g.
// "live_mic", "pure_tone_1000Hz", "sweep", "mode_standard") — needed because
// a single evidence session folder can combine rows from several offline
// test-signal runs alongside one live-capture run.
struct FrameLogRow {
    int64_t timestampMs = 0;
    int64_t frameIndex = 0;
    float rawRms = 0.f, processedRms = 0.f;
    float rawPeak = 0.f, processedPeak = 0.f;
    float rawDbfs = 0.f, processedDbfs = 0.f;
    int32_t activeMode = 0;
    int32_t callbackDurationUs = 0;
    int32_t underrunOrMissingFrames = 0;
    int32_t zeroFillCount = 0;
    std::string source = "live_mic";
};

struct BandBlockRow {
    int64_t timestampMs = 0;
    int64_t frameIndex = 0;
    int32_t activeMode = 0;
    float inputRms[6] = {};
    float inputPeak[6] = {};
    float envelopeDb[6] = {};
    float thresholdDb[6] = {};
    float ratio[6] = {};
    float gainReductionDb[6] = {};
    float makeupGainDb[6] = {};
    float finalGainDb[6] = {};
    float outputRms[6] = {};
    float outputPeak[6] = {};
    std::string source = "live_mic";
};

struct LimiterLogRow {
    int64_t timestampMs = 0;
    int64_t frameIndex = 0;
    float preLimiterPeak = 0.f, postLimiterPeak = 0.f;
    float preLimiterRms = 0.f, postLimiterRms = 0.f;
    int32_t samplesAbove095Before = 0, samplesAbove095After = 0;
    int32_t samplesClippedBefore = 0, samplesClippedAfter = 0;
    float limiterGainReductionDb = 0.f;
    int32_t activeMode = 0;
    std::string source = "live_mic";
};

struct GainUpdateRow {
    int64_t timestampMs = 0;
    std::string source;   // hearing_profile / manual_slider / mode_adjustment / test_override
    float gainsDb[6] = {};
    float gainsLinear[6] = {};
    int32_t activeMode = 0;
};

struct ModeChangeRow {
    int64_t timestampMs = 0;
    int32_t fromMode = 0;
    int32_t toMode = 0;
};

// ---- CSV writers --------------------------------------------------------
// `append`: when true, rows are appended to an existing file instead of
// overwriting it (header written only if the file is new/empty). This lets
// several offline experiment runs (e.g. one process_audio_file_full_ffi call
// per pure-tone frequency) accumulate into a single per-session
// band_level_log.csv / limiter_log.csv, matching the folder layout in
// docs/validation.md where one session combines multiple experiments.

static bool fileHasContent(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    return f.peek() != std::ifstream::traits_type::eof();
}

static bool writeFrameLogCsv(const std::string& path,
                              const std::vector<FrameLogRow>& rows, size_t count,
                              bool append = false) {
    const bool writeHeader = !append || !fileHasContent(path);
    std::ofstream f(path, append ? std::ios::app : std::ios::out);
    if (!f) return false;
    if (writeHeader) {
        f << "timestamp_ms,frame_index,raw_rms,processed_rms,raw_peak,processed_peak,"
             "raw_dbfs,processed_dbfs,active_mode,callback_duration_us,"
             "underrun_or_missing_frames,zero_fill_count,source\n";
    }
    count = std::min(count, rows.size());
    for (size_t i = 0; i < count; i++) {
        const auto& r = rows[i];
        f << r.timestampMs << ',' << r.frameIndex << ','
          << r.rawRms << ',' << r.processedRms << ','
          << r.rawPeak << ',' << r.processedPeak << ','
          << r.rawDbfs << ',' << r.processedDbfs << ','
          << evidenceModeName(r.activeMode) << ','
          << r.callbackDurationUs << ','
          << r.underrunOrMissingFrames << ','
          << r.zeroFillCount << ',' << r.source << '\n';
    }
    return true;
}

static bool writeBandLogCsv(const std::string& path,
                             const std::vector<BandBlockRow>& rows, size_t count,
                             bool append = false) {
    const bool writeHeader = !append || !fileHasContent(path);
    std::ofstream f(path, append ? std::ios::app : std::ios::out);
    if (!f) return false;
    if (writeHeader) {
        f << "timestamp_ms,frame_index,band_index,band_label,frequency_region,"
             "input_band_rms,input_band_peak,envelope_value,envelope_db,"
             "compression_threshold_db,compression_ratio,gain_reduction_db,"
             "makeup_gain_db,final_band_gain_db,output_band_rms,output_band_peak,"
             "active_mode,source\n";
    }
    count = std::min(count, rows.size());
    for (size_t i = 0; i < count; i++) {
        const auto& r = rows[i];
        for (int b = 0; b < 6; b++) {
            f << r.timestampMs << ',' << r.frameIndex << ',' << b << ','
              << kEvidenceBandLabels[b] << ',' << kEvidenceBandFreqRegions[b] << ','
              << r.inputRms[b] << ',' << r.inputPeak[b] << ','
              << db_to_lin(r.envelopeDb[b]) << ',' << r.envelopeDb[b] << ','
              << r.thresholdDb[b] << ',' << r.ratio[b] << ','
              << r.gainReductionDb[b] << ',' << r.makeupGainDb[b] << ','
              << r.finalGainDb[b] << ',' << r.outputRms[b] << ',' << r.outputPeak[b] << ','
              << evidenceModeName(r.activeMode) << ',' << r.source << '\n';
        }
    }
    return true;
}

static bool writeLimiterLogCsv(const std::string& path,
                                const std::vector<LimiterLogRow>& rows, size_t count,
                                bool append = false) {
    const bool writeHeader = !append || !fileHasContent(path);
    std::ofstream f(path, append ? std::ios::app : std::ios::out);
    if (!f) return false;
    if (writeHeader) {
        f << "timestamp_ms,frame_index,pre_limiter_peak,post_limiter_peak,"
             "pre_limiter_rms,post_limiter_rms,samples_above_0_95_before,"
             "samples_above_0_95_after,samples_clipped_before,samples_clipped_after,"
             "limiter_gain_reduction_db,active_mode,source\n";
    }
    count = std::min(count, rows.size());
    for (size_t i = 0; i < count; i++) {
        const auto& r = rows[i];
        f << r.timestampMs << ',' << r.frameIndex << ','
          << r.preLimiterPeak << ',' << r.postLimiterPeak << ','
          << r.preLimiterRms << ',' << r.postLimiterRms << ','
          << r.samplesAbove095Before << ',' << r.samplesAbove095After << ','
          << r.samplesClippedBefore << ',' << r.samplesClippedAfter << ','
          << r.limiterGainReductionDb << ',' << evidenceModeName(r.activeMode) << ','
          << r.source << '\n';
    }
    return true;
}

static bool writeGainUpdateLogCsv(const std::string& path,
                                   const std::vector<GainUpdateRow>& rows) {
    std::ofstream f(path);
    if (!f) return false;
    f << "timestamp_ms,source,"
         "band_1_gain_db,band_2_gain_db,band_3_gain_db,band_4_gain_db,band_5_gain_db,band_6_gain_db,"
         "band_1_linear,band_2_linear,band_3_linear,band_4_linear,band_5_linear,band_6_linear,"
         "active_mode\n";
    for (const auto& r : rows) {
        f << r.timestampMs << ',' << r.source << ',';
        for (int b = 0; b < 6; b++) f << r.gainsDb[b] << ',';
        for (int b = 0; b < 6; b++) f << r.gainsLinear[b] << ',';
        f << evidenceModeName(r.activeMode) << '\n';
    }
    return true;
}

static bool writeModeChangeLogCsv(const std::string& path,
                                   const std::vector<ModeChangeRow>& rows) {
    std::ofstream f(path);
    if (!f) return false;
    f << "timestamp_ms,from_mode,to_mode\n";
    for (const auto& r : rows) {
        f << r.timestampMs << ',' << evidenceModeName(r.fromMode) << ','
          << evidenceModeName(r.toMode) << '\n';
    }
    return true;
}

// ---- Offline block-diagnostic processing ---------------------------------
// Shared by process_audio_file_full_ffi (on-device / Dart-triggered offline
// tests) and tools/dsp_harness (host verification build) so both run the
// exact same aggregation logic over the exact same RealtimeProcessor code
// path used by the live Oboe engine. Not used from the audio callback.

struct WavDiagnosticResult {
    std::vector<float> processed;
    std::vector<BandBlockRow> bandRows;
    std::vector<LimiterLogRow> limiterRows;
};

static WavDiagnosticResult processWavWithDiagnostics(
        RealtimeProcessor& proc, const WavData& wav,
        bool wantBand, bool wantLimiter, int32_t modeForLog,
        const std::string& source = "offline",
        size_t blockSize = 480) {
    WavDiagnosticResult result;
    result.processed.resize(wav.x.size());
    const bool wantDiag = wantBand || wantLimiter;
    const size_t n = wav.x.size();
    ProcessDiagSample diag;

    for (size_t blockStart = 0; blockStart < n; blockStart += blockSize) {
        const size_t blockEnd = std::min(n, blockStart + blockSize);
        const size_t blockLen = blockEnd - blockStart;

        float bandInSumSq[6] = {}, bandInPeak[6] = {}, bandOutSumSq[6] = {}, bandOutPeak[6] = {};
        float lastEnvDb[6] = {}, lastGainRedDb[6] = {}, lastMakeupDb[6] = {}, lastFinalDb[6] = {};
        float preLimSumSq = 0.f, preLimPeak = 0.f, postLimSumSq = 0.f, postLimPeak = 0.f;
        int32_t above095Before = 0, above095After = 0, clippedBefore = 0, clippedAfter = 0;

        for (size_t i = blockStart; i < blockEnd; i++) {
            const float yv = wantDiag ? proc.process(wav.x[i], &diag) : proc.process(wav.x[i]);
            result.processed[i] = yv;
            if (wantBand) {
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
            if (wantLimiter) {
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

        const int64_t frameIdx = (int64_t)blockStart;
        const int64_t tMs = (int64_t)(blockStart * 1000 / (size_t)wav.sampleRate);
        if (wantBand) {
            BandBlockRow row;
            row.timestampMs = tMs;
            row.frameIndex = frameIdx;
            row.activeMode = modeForLog;
            row.source = source;
            for (int b = 0; b < 6; b++) {
                row.inputRms[b] = std::sqrt(bandInSumSq[b] / (float)blockLen);
                row.inputPeak[b] = bandInPeak[b];
                row.envelopeDb[b] = lastEnvDb[b];
                row.thresholdDb[b] = proc.comp_[b].thresholdDb;
                row.ratio[b] = proc.comp_[b].ratio;
                row.gainReductionDb[b] = lastGainRedDb[b];
                row.makeupGainDb[b] = lastMakeupDb[b];
                row.finalGainDb[b] = lastFinalDb[b];
                row.outputRms[b] = std::sqrt(bandOutSumSq[b] / (float)blockLen);
                row.outputPeak[b] = bandOutPeak[b];
            }
            result.bandRows.push_back(row);
        }
        if (wantLimiter) {
            LimiterLogRow row;
            row.timestampMs = tMs;
            row.frameIndex = frameIdx;
            row.activeMode = modeForLog;
            row.source = source;
            row.preLimiterPeak = preLimPeak;
            row.postLimiterPeak = postLimPeak;
            row.preLimiterRms = std::sqrt(preLimSumSq / (float)blockLen);
            row.postLimiterRms = std::sqrt(postLimSumSq / (float)blockLen);
            row.samplesAbove095Before = above095Before;
            row.samplesAbove095After = above095After;
            row.samplesClippedBefore = clippedBefore;
            row.samplesClippedAfter = clippedAfter;
            row.limiterGainReductionDb = lin_to_db(row.postLimiterRms) - lin_to_db(row.preLimiterRms);
            result.limiterRows.push_back(row);
        }
    }
    return result;
}

// ---- EvidenceSession ------------------------------------------------------

class EvidenceSession {
public:
    struct Config {
        std::string sessionId;
        int32_t experimentType = 0;   // 0 live_mic,1 pure_tone,2 sweep,3 mode_comparison,4 limiter_test
        int32_t activeMode = 0;
        int32_t sampleRate = 48000;
        bool captureBandLog = false;
        bool captureLimiterLog = false;
        bool captureFrameLog = true;
        int32_t durationSeconds = 10;
    };

    // Control-plane call (UI/FFI thread). Pre-allocates all RT-facing
    // buffers so the audio callback never allocates.
    void start(const Config& cfg) {
        std::lock_guard<std::mutex> lk(controlMu_);
        cfg_ = cfg;
        const int32_t clampedDuration =
                std::max(1, std::min(cfg.durationSeconds, kMaxDurationSeconds));
        const int64_t estBlocks =
                (int64_t)cfg.sampleRate * clampedDuration / kMinBurstFrames + 64;
        capacity_ = (size_t)std::min<int64_t>(estBlocks, kHardRowCap);

        frameRows_.assign(cfg.captureFrameLog ? capacity_ : 0, FrameLogRow{});
        bandRows_.assign(cfg.captureBandLog ? capacity_ : 0, BandBlockRow{});
        limiterRows_.assign(cfg.captureLimiterLog ? capacity_ : 0, LimiterLogRow{});

        frameWriteIdx_.store(0, std::memory_order_relaxed);
        bandWriteIdx_.store(0, std::memory_order_relaxed);
        limiterWriteIdx_.store(0, std::memory_order_relaxed);

        {
            std::lock_guard<std::mutex> lk(eventMu_);
            gainLog_.clear();
            modeLog_.clear();
        }

        active_.store(true, std::memory_order_release);
    }

    // Control-plane call. Stops new RT-side writes and waits briefly so any
    // in-flight callback finishes before the caller reads the buffers.
    void stop() {
        active_.store(false, std::memory_order_release);
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }

    bool isActive() const { return active_.load(std::memory_order_acquire); }
    bool wantsBandLog() const { return cfg_.captureBandLog; }
    bool wantsLimiterLog() const { return cfg_.captureLimiterLog; }
    bool wantsFrameLog() const { return cfg_.captureFrameLog; }
    const Config& config() const { return cfg_; }

    // ---- RT-safe: audio callback thread only -----------------------------
    inline void pushFrameRow(const FrameLogRow& row) {
        if (frameRows_.empty() || !active_.load(std::memory_order_relaxed)) return;
        const size_t idx = frameWriteIdx_.fetch_add(1, std::memory_order_relaxed);
        if (idx < frameRows_.size()) frameRows_[idx] = row;
    }
    inline void pushBandRow(const BandBlockRow& row) {
        if (bandRows_.empty() || !active_.load(std::memory_order_relaxed)) return;
        const size_t idx = bandWriteIdx_.fetch_add(1, std::memory_order_relaxed);
        if (idx < bandRows_.size()) bandRows_[idx] = row;
    }
    inline void pushLimiterRow(const LimiterLogRow& row) {
        if (limiterRows_.empty() || !active_.load(std::memory_order_relaxed)) return;
        const size_t idx = limiterWriteIdx_.fetch_add(1, std::memory_order_relaxed);
        if (idx < limiterRows_.size()) limiterRows_[idx] = row;
    }

    // ---- Not RT: UI/control thread only -----------------------------------
    // Guarded by isActive(): the live engine calls these unconditionally on
    // every slider drag / mode switch during normal app use (not just
    // evidence sessions), so without this guard the logs would grow
    // unbounded for the lifetime of the process. Only actually record while
    // an evidence session is running.
    void logGainUpdate(const GainUpdateRow& row) {
        if (!isActive()) return;
        std::lock_guard<std::mutex> lk(eventMu_);
        gainLog_.push_back(row);
    }
    void logModeChange(const ModeChangeRow& row) {
        if (!isActive()) return;
        std::lock_guard<std::mutex> lk(eventMu_);
        modeLog_.push_back(row);
    }

    // Writes whichever CSVs were enabled for the session into outDir.
    // Read-only with respect to the RT buffers (never resizes/clears them),
    // so it's safe even if called shortly after stop(). Must be called from
    // a non-audio thread. Returns the number of files written.
    // append=true (default) so a live-capture flush accumulates into the same
    // per-session band_level_log.csv / limiter_log.csv / frame_level_log.csv
    // that offline experiment runs (process_audio_file_full_ffi) may have
    // already written to, rather than clobbering them.
    int32_t flush(const std::string& outDir, bool append = true) {
        int32_t written = 0;
        if (cfg_.captureFrameLog) {
            const size_t n = std::min(frameWriteIdx_.load(std::memory_order_acquire),
                                       frameRows_.size());
            if (writeFrameLogCsv(outDir + "/frame_level_log.csv", frameRows_, n, append)) written++;
        }
        if (cfg_.captureBandLog) {
            const size_t n = std::min(bandWriteIdx_.load(std::memory_order_acquire),
                                       bandRows_.size());
            if (writeBandLogCsv(outDir + "/band_level_log.csv", bandRows_, n, append)) written++;
        }
        if (cfg_.captureLimiterLog) {
            const size_t n = std::min(limiterWriteIdx_.load(std::memory_order_acquire),
                                       limiterRows_.size());
            if (writeLimiterLogCsv(outDir + "/limiter_log.csv", limiterRows_, n, append)) written++;
        }
        {
            std::lock_guard<std::mutex> lk(eventMu_);
            if (writeGainUpdateLogCsv(outDir + "/gain_update_log.csv", gainLog_)) written++;
            if (writeModeChangeLogCsv(outDir + "/mode_change_log.csv", modeLog_)) written++;
        }
        return written;
    }

private:
    static constexpr int32_t kMinBurstFrames = 32;
    static constexpr int32_t kMaxDurationSeconds = 300;
    static constexpr int64_t kHardRowCap = 400000;

    std::mutex controlMu_;
    std::mutex eventMu_;
    Config cfg_;
    std::atomic<bool> active_{false};
    size_t capacity_ = 0;

    std::vector<FrameLogRow> frameRows_;
    std::vector<BandBlockRow> bandRows_;
    std::vector<LimiterLogRow> limiterRows_;
    std::atomic<size_t> frameWriteIdx_{0};
    std::atomic<size_t> bandWriteIdx_{0};
    std::atomic<size_t> limiterWriteIdx_{0};

    std::vector<GainUpdateRow> gainLog_;
    std::vector<ModeChangeRow> modeLog_;
};
