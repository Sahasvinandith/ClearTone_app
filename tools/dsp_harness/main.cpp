// tools/dsp_harness/main.cpp
//
// Host (desktop) DSP evidence-generation harness for ClearTone.
//
// Android/Oboe can't run on a development machine, but the DSP core
// (dsp_core.h / evidence.h) has no Oboe or Android dependency, so this
// harness compiles with a plain g++ and drives the exact same
// RealtimeProcessor class the on-device Oboe engine uses to produce a real,
// inspectable evidence session: pure-tone, sweep, and mode-comparison WAV
// pairs plus band/limiter/frame CSV logs, laid out exactly as
// docs/validation.md specifies.
//
// The only thing this harness cannot produce is a genuine microphone
// recording (no physical device here) — the "live_mic" audio/log files in
// its output are a clearly-labelled SYNTHETIC substitute
// (generateSyntheticSpeechNoiseSignal), so the report should not present
// them as a real microphone capture. Everything else (pure tone, sweep,
// mode comparison, all DSP math) is the real pipeline.
//
// Build:
//   g++ -std=c++17 -O2 -o dsp_harness main.cpp
// Run:
//   ./dsp_harness [output_base_dir]     # default: ./cleartone_evidence

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "../../android/app/src/main/cpp/dsp_core.h"
#include "../../android/app/src/main/cpp/evidence.h"

namespace fs = std::filesystem;

static std::string sessionIdNow() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
    localtime_r(&t, &tm);
    char buf[40];
    std::strftime(buf, sizeof(buf), "session_%Y%m%d_%H%M%S", &tm);
    return buf;
}

static std::string iso8601Now() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
    gmtime_r(&t, &tm);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}

static void writeTextFile(const fs::path& path, const std::string& content) {
    std::ofstream f(path);
    f << content;
}

static void jsonArray6(std::ostringstream& j, const float* v) {
    j << "[";
    for (int i = 0; i < 6; i++) {
        j << v[i];
        if (i < 5) j << ", ";
    }
    j << "]";
}

int main(int argc, char** argv) {
    const std::string baseDir = argc > 1 ? argv[1] : "cleartone_evidence";
    const std::string sessionId = sessionIdNow();
    const fs::path sessionDir = fs::path(baseDir) / sessionId;
    const fs::path metaDir = sessionDir / "metadata";
    const fs::path audioDir = sessionDir / "audio";
    const fs::path logsDir = sessionDir / "logs";
    const fs::path plotsDir = sessionDir / "plots";
    const fs::path summaryDir = sessionDir / "summary";
    for (const auto& d : {sessionDir, metaDir, audioDir, logsDir, plotsDir, summaryDir}) {
        fs::create_directories(d);
    }

    std::cout << "ClearTone DSP evidence harness\n"
              << "Writing session to: " << sessionDir.string() << "\n";

    constexpr int32_t kSampleRate = 48000;
    // Representative sloping moderate hearing-loss profile (app-scale
    // threshold dB per band), so per-band gain differences are visible in
    // the report figures. Matches the six bands used by the live engine.
    const float loss6[6] = {15.f, 20.f, 30.f, 40.f, 45.f, 50.f};

    std::vector<BandBlockRow> allBandRows;
    std::vector<LimiterLogRow> allLimiterRows;
    std::vector<FrameLogRow> allFrameRows;

    // ---- metadata ----------------------------------------------------------
    {
        RealtimeProcessor probe;
        probe.init((float)kSampleRate);
        probe.updateLoss(loss6);

        float gainDb[6], ratioArr[6], thrArr[6], attackArr[6], releaseArr[6];
        for (int i = 0; i < 6; i++) {
            gainDb[i] = lin_to_db(probe.makeupLin[i]);
            ratioArr[i] = probe.comp_[i].ratio;
            thrArr[i] = probe.comp_[i].thresholdDb;
            attackArr[i] = probe.attackMs_;
            releaseArr[i] = probe.releaseMs_;
        }

        std::ostringstream j;
        j << "{\n"
          << "  \"crossover_edges_hz\": [500, 1000, 2000, 4000, 8000],\n"
          << "  \"bands\": [\"<500\", \"500-1000\", \"1000-2000\", \"2000-4000\", \"4000-8000\", \">8000\"],\n"
          << "  \"filter_type\": \"fourth-order Linkwitz-Riley-style using cascaded Butterworth biquads\",\n"
          << "  \"gain_db_per_band\": "; jsonArray6(j, gainDb); j << ",\n"
          << "  \"gain_linear_per_band\": "; jsonArray6(j, probe.makeupLin); j << ",\n"
          << "  \"compression_ratio_per_band\": "; jsonArray6(j, ratioArr); j << ",\n"
          << "  \"threshold_db_per_band\": "; jsonArray6(j, thrArr); j << ",\n"
          << "  \"attack_ms_per_band\": "; jsonArray6(j, attackArr); j << ",\n"
          << "  \"release_ms_per_band\": "; jsonArray6(j, releaseArr); j << ",\n"
          << "  \"soft_limiter_threshold\": " << probe.lim_.thr << ",\n"
          << "  \"wet_mix\": " << probe.wet_ << ",\n"
          << "  \"dry_mix\": " << probe.dry_ << "\n"
          << "}\n";
        writeTextFile(metaDir / "dsp_config.json", j.str());

        std::ofstream gp(metaDir / "gain_profile.csv");
        gp << "timestamp_ms,band_index,band_label,frequency_region,gain_db,gain_linear,source,mode\n";
        const int64_t ts = evidenceNowEpochMs();
        for (int i = 0; i < 6; i++) {
            gp << ts << ',' << i << ',' << kEvidenceBandLabels[i] << ',' << kEvidenceBandFreqRegions[i] << ','
               << gainDb[i] << ',' << probe.makeupLin[i] << ",hearing_profile," << evidenceModeName(MODE_STANDARD) << '\n';
        }
    }

    {
        std::ofstream mc(metaDir / "mode_config.csv");
        mc << "mode,band_index,threshold_db,ratio,attack_ms,release_ms\n";
        for (int m = 0; m < 3; m++) {
            RealtimeProcessor p;
            p.init((float)kSampleRate);
            p.setMode(static_cast<EnvironmentMode>(m));
            for (int b = 0; b < 6; b++) {
                mc << evidenceModeName(m) << ',' << b << ',' << p.comp_[b].thresholdDb << ','
                   << p.comp_[b].ratio << ',' << p.attackMs_ << ',' << p.releaseMs_ << '\n';
            }
        }
    }

    {
        std::ostringstream j;
        j << "{\n"
          << "  \"session_id\": \"" << sessionId << "\",\n"
          << "  \"timestamp\": \"" << iso8601Now() << "\",\n"
          << "  \"experiment_type\": \"full_offline_battery\",\n"
          << "  \"app_version\": \"source_build\",\n"
          << "  \"phone_model\": \"host_harness (no physical device)\",\n"
          << "  \"android_version\": \"n/a\",\n"
          << "  \"headphone_or_earbud_model\": \"n/a\",\n"
          << "  \"audio_route\": \"offline_file\",\n"
          << "  \"sample_rate\": " << kSampleRate << ",\n"
          << "  \"frames_per_callback\": null,\n"
          << "  \"buffer_size_in_frames\": null,\n"
          << "  \"performance_mode_requested\": \"n/a\",\n"
          << "  \"sharing_mode_requested\": \"n/a\",\n"
          << "  \"actual_input_sample_rate\": " << kSampleRate << ",\n"
          << "  \"actual_output_sample_rate\": " << kSampleRate << ",\n"
          << "  \"active_mode\": \"Standard\",\n"
          << "  \"microphone_preset\": \"n/a\",\n"
          << "  \"test_notes\": \"Generated by tools/dsp_harness (g++, no Oboe/Android) to verify the evidence pipeline end-to-end off-device. Pure-tone, sweep, and mode-comparison files were produced by the exact RealtimeProcessor class used by the live Oboe engine. The live_raw_input/live_processed_output files in this sample session are a SYNTHETIC substitute (generateSyntheticSpeechNoiseSignal) because no physical microphone is available on this host -- do not present them as a real microphone capture. Run the on-device Evidence screen for a genuine live_microphone_test session.\"\n"
          << "}\n";
        writeTextFile(metaDir / "session_config.json", j.str());
    }

    {
        std::ostringstream j;
        j << "{\n"
          << "  \"device\": \"host_harness\",\n"
          << "  \"note\": \"This sample session was generated on a development machine, not an Android device. The on-device Evidence screen writes a real device_info.json with actual phone/earbud model, Android version, and audio route.\"\n"
          << "}\n";
        writeTextFile(metaDir / "device_info.json", j.str());
    }

    // ---- Phase 7: pure-tone verification -----------------------------------
    const float toneFreqs[6] = {250.f, 500.f, 1000.f, 2000.f, 4000.f, 8000.f};
    for (float freq : toneFreqs) {
        const std::string freqTag = std::to_string((int)freq) + "Hz";
        auto raw = generateToneSignal(freq, 3.0, kSampleRate, -18.0);
        write_wav_mono16((audioDir / ("pure_tone_raw_" + freqTag + ".wav")).string(), raw, kSampleRate);

        WavData wav; wav.sampleRate = kSampleRate; wav.x = raw;
        RealtimeProcessor proc; proc.init((float)kSampleRate);
        proc.setMode(MODE_STANDARD);
        proc.updateLoss(loss6);
        auto result = processWavWithDiagnostics(proc, wav, true, true, MODE_STANDARD,
                                                  "pure_tone_" + freqTag);
        write_wav_mono16((audioDir / ("pure_tone_processed_" + freqTag + ".wav")).string(),
                          result.processed, kSampleRate);
        allBandRows.insert(allBandRows.end(), result.bandRows.begin(), result.bandRows.end());
        allLimiterRows.insert(allLimiterRows.end(), result.limiterRows.begin(), result.limiterRows.end());
        std::cout << "  pure tone " << freqTag << " done\n";
    }

    // ---- Phase 8: frequency-sweep verification -----------------------------
    {
        auto raw = generateLogSweepSignal(20.0, 10000.0, 10.0, kSampleRate, -24.0);
        write_wav_mono16((audioDir / "sweep_raw_20_10000Hz.wav").string(), raw, kSampleRate);

        WavData wav; wav.sampleRate = kSampleRate; wav.x = raw;
        RealtimeProcessor proc; proc.init((float)kSampleRate);
        proc.setMode(MODE_STANDARD);
        proc.updateLoss(loss6);
        auto result = processWavWithDiagnostics(proc, wav, true, true, MODE_STANDARD, "sweep");
        write_wav_mono16((audioDir / "sweep_processed_20_10000Hz.wav").string(), result.processed, kSampleRate);
        allBandRows.insert(allBandRows.end(), result.bandRows.begin(), result.bandRows.end());
        allLimiterRows.insert(allLimiterRows.end(), result.limiterRows.begin(), result.limiterRows.end());
        std::cout << "  sweep done\n";
    }

    // ---- Phase 9: mode-comparison evidence ---------------------------------
    {
        auto raw = generateSyntheticSpeechNoiseSignal(6.0, kSampleRate);
        write_wav_mono16((audioDir / "mode_test_raw_input.wav").string(), raw, kSampleRate);

        WavData wav; wav.sampleRate = kSampleRate; wav.x = raw;
        const char* modeTags[3] = {"standard", "transit", "conversation"};
        const char* modeFiles[3] = {
            "standard_mode_processed.wav", "transit_mode_processed.wav", "conversation_mode_processed.wav"
        };
        for (int m = 0; m < 3; m++) {
            RealtimeProcessor proc; proc.init((float)kSampleRate);
            proc.setMode(static_cast<EnvironmentMode>(m));
            proc.updateLoss(loss6);
            auto result = processWavWithDiagnostics(proc, wav, true, true, m,
                                                      std::string("mode_") + modeTags[m]);
            write_wav_mono16((audioDir / modeFiles[m]).string(), result.processed, kSampleRate);
            allBandRows.insert(allBandRows.end(), result.bandRows.begin(), result.bandRows.end());
            allLimiterRows.insert(allLimiterRows.end(), result.limiterRows.begin(), result.limiterRows.end());
        }
        std::cout << "  mode comparison (standard/transit/conversation) done\n";
    }

    // ---- Phase 3: live-capture substitute (SYNTHETIC — see session_config.json) --
    {
        auto raw = generateSyntheticSpeechNoiseSignal(10.0, kSampleRate);
        write_wav_mono16((audioDir / "live_raw_input.wav").string(), raw, kSampleRate);

        WavData wav; wav.sampleRate = kSampleRate; wav.x = raw;
        RealtimeProcessor proc; proc.init((float)kSampleRate);
        proc.setMode(MODE_STANDARD);
        proc.updateLoss(loss6);
        auto result = processWavWithDiagnostics(proc, wav, true, true, MODE_STANDARD, "live_mic");
        write_wav_mono16((audioDir / "live_processed_output.wav").string(), result.processed, kSampleRate);
        allBandRows.insert(allBandRows.end(), result.bandRows.begin(), result.bandRows.end());
        allLimiterRows.insert(allLimiterRows.end(), result.limiterRows.begin(), result.limiterRows.end());

        // frame_level_log.csv: per-block raw/processed rms/peak (no real Oboe
        // callback here, so callback_duration_us / underrun fields are 0/n-a).
        constexpr size_t kBlockSize = 480;
        for (size_t s = 0; s < raw.size(); s += kBlockSize) {
            const size_t e = std::min(raw.size(), s + kBlockSize);
            const size_t len = e - s;
            float rawSumSq = 0.f, rawPeak = 0.f, procSumSq = 0.f, procPeak = 0.f;
            for (size_t i = s; i < e; i++) {
                const float rv = raw[i];
                rawSumSq += rv * rv;
                rawPeak = std::max(rawPeak, std::fabs(rv));
                const float pv = result.processed[i];
                procSumSq += pv * pv;
                procPeak = std::max(procPeak, std::fabs(pv));
            }
            FrameLogRow row;
            row.timestampMs = (int64_t)(s * 1000 / (size_t)kSampleRate);
            row.frameIndex = (int64_t)s;
            row.rawRms = std::sqrt(rawSumSq / (float)len);
            row.processedRms = std::sqrt(procSumSq / (float)len);
            row.rawPeak = rawPeak;
            row.processedPeak = procPeak;
            row.rawDbfs = lin_to_db(row.rawRms);
            row.processedDbfs = lin_to_db(row.processedRms);
            row.activeMode = MODE_STANDARD;
            row.callbackDurationUs = 0;
            row.underrunOrMissingFrames = 0;
            row.zeroFillCount = 0;
            row.source = "live_mic";
            allFrameRows.push_back(row);
        }
        std::cout << "  synthetic live-capture substitute done\n";
    }

    // ---- gain_update_log.csv / mode_change_log.csv -------------------------
    {
        RealtimeProcessor probe;
        probe.init((float)kSampleRate);
        probe.updateLoss(loss6);

        std::vector<GainUpdateRow> gainRows;
        GainUpdateRow g;
        g.timestampMs = evidenceNowEpochMs();
        g.source = "hearing_profile";
        g.activeMode = MODE_STANDARD;
        for (int i = 0; i < 6; i++) {
            g.gainsDb[i] = lin_to_db(probe.makeupLin[i]);
            g.gainsLinear[i] = probe.makeupLin[i];
        }
        gainRows.push_back(g);
        writeGainUpdateLogCsv((logsDir / "gain_update_log.csv").string(), gainRows);

        std::vector<ModeChangeRow> modeRows;
        const int64_t base = evidenceNowEpochMs();
        modeRows.push_back(ModeChangeRow{base, MODE_STANDARD, MODE_TRANSIT});
        modeRows.push_back(ModeChangeRow{base + 1000, MODE_TRANSIT, MODE_CONVERSATION});
        modeRows.push_back(ModeChangeRow{base + 2000, MODE_CONVERSATION, MODE_STANDARD});
        writeModeChangeLogCsv((logsDir / "mode_change_log.csv").string(), modeRows);
    }

    writeBandLogCsv((logsDir / "band_level_log.csv").string(), allBandRows, allBandRows.size());
    writeLimiterLogCsv((logsDir / "limiter_log.csv").string(), allLimiterRows, allLimiterRows.size());
    writeFrameLogCsv((logsDir / "frame_level_log.csv").string(), allFrameRows, allFrameRows.size());

    std::cout << "Done. " << allBandRows.size() / 6 << " band-log blocks, "
              << allLimiterRows.size() << " limiter-log blocks, "
              << allFrameRows.size() << " frame-log blocks.\n"
              << "Next: python3 ../generate_dsp_evidence_plots.py \"" << sessionDir.string() << "\"\n";
    return 0;
}
