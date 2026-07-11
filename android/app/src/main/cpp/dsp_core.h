// dsp_core.h
//
// Platform-agnostic DSP core for ClearTone's six-band amplification pipeline.
// This header contains no Oboe / Android dependencies so it can be compiled
// both into the on-device shared library (audio_engine.cpp) and into a host
// g++ command-line harness (tools/dsp_harness) used to generate and verify
// offline DSP evidence (pure-tone, sweep, and mode-comparison tests) without
// needing a phone or microphone.
//
// IMPORTANT: this is a behavior-preserving extraction from audio_engine.cpp.
// The per-sample math of process()/processDiag() is identical to the
// original process(); a diagnostic pointer is threaded through purely to
// expose intermediate values for evidence logging, computed in the same
// single pass so filter/envelope state is never advanced twice.

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// ---- helpers ---------------------------------------------------------------

static inline float clampf(float x, float lo, float hi) {
    return x < lo ? lo : (x > hi ? hi : x);
}
static inline float db_to_lin(float db)  { return std::pow(10.0f, db / 20.0f); }
static inline float lin_to_db(float lin) { return 20.0f * std::log10(std::max(lin, 1e-12f)); }

static constexpr float kClinicalInterceptDb = 15.70f;
static constexpr float kClinicalSlope = 0.866f;
static constexpr float kClinicalTargetDb = 10.0f;
static constexpr float kMaxMakeupGainDb = 25.0f;

static inline float appThresholdToClinicalDb(float appDb) {
    return kClinicalInterceptDb + kClinicalSlope * appDb;
}

static inline float appThresholdToMakeupGainDb(float appDb) {
    float clinicalDb = appThresholdToClinicalDb(appDb);
    return clampf(clinicalDb - kClinicalTargetDb, 0.f, kMaxMakeupGainDb);
}

// ---- Fast math for DSP hot path -------------------------------------------
// Replace std::log10/std::pow with bit-trick log2/exp2 (~10x faster).

static inline float fast_log2f(float x) {
    union { float f; int32_t i; } u;
    u.f = x;
    float e = (float)((u.i >> 23) - 127);
    u.i = (u.i & 0x007FFFFF) | 0x3F800000;
    // Minimax polynomial for log2 on [1,2)
    return e + (-1.3465551f + u.f * (2.2851935f + u.f * (-0.8543256f)));
}

static inline float fast_exp2f(float x) {
    float xi = std::floor(x);
    float xf = x - xi;
    union { float f; int32_t i; } u;
    u.i = ((int32_t)xi + 127) << 23;
    float p = 1.f + xf * (0.6931472f + xf * (0.2402265f + xf * 0.0555041f));
    return u.f * p;
}

// log10(x)*20  →  log2(x)*6.02060
static inline float fast_lin_to_db(float lin) {
    return fast_log2f(std::max(lin, 1e-12f)) * 6.02060f;
}
// 10^(db/20)  →  2^(db*0.16610)
static inline float fast_db_to_lin(float db) {
    return fast_exp2f(db * 0.16609640f);
}

// ---- Biquad (Butterworth 2nd order) ----------------------------------------

struct Biquad {
    float b0=1,b1=0,b2=0,a1=0,a2=0,z1=0,z2=0;
    void reset() { z1 = z2 = 0.f; }

    inline float process(float x) {
        float y = b0*x + z1;
        z1 = b1*x - a1*y + z2;
        z2 = b2*x - a2*y;
        return y;
    }

    void setLowpass(float fs, float fc, float Q) {
        fc = clampf(fc, 10.f, fs*0.45f);
        Q  = std::max(Q, 0.1f);
        const float PI = 3.14159265358979f;
        float w0 = 2.f*PI*(fc/fs), c=std::cos(w0), s=std::sin(w0);
        float alpha = s/(2.f*Q);
        float a0n = 1.f+alpha;
        b0 = (1.f-c)*0.5f / a0n;
        b1 = (1.f-c)       / a0n;
        b2 = b0;
        a1 = -2.f*c         / a0n;
        a2 = (1.f-alpha)    / a0n;
    }

    void setHighpass(float fs, float fc, float Q) {
        fc = clampf(fc, 10.f, fs*0.45f);
        Q  = std::max(Q, 0.1f);
        const float PI = 3.14159265358979f;
        float w0 = 2.f*PI*(fc/fs), c=std::cos(w0), s=std::sin(w0);
        float alpha = s/(2.f*Q);
        float a0n = 1.f+alpha;
        b0 = (1.f+c)*0.5f  / a0n;
        b1 = -(1.f+c)       / a0n;
        b2 = b0;
        a1 = -2.f*c          / a0n;
        a2 = (1.f-alpha)     / a0n;
    }
};

// ---- Linkwitz-Riley 4th order -----------------------------------------------

struct LR4 {
    Biquad s1, s2;
    void reset() { s1.reset(); s2.reset(); }
    inline float process(float x) { return s2.process(s1.process(x)); }
};

// ---- 6-band crossover -------------------------------------------------------

struct Crossover6 {
    LR4 lp[5], hp[5];

    void init(float fs, const float edges[5]) {
        const float Q = 0.70710678f;
        for (int i = 0; i < 5; i++) {
            lp[i].s1.setLowpass(fs,  edges[i], Q);
            lp[i].s2.setLowpass(fs,  edges[i], Q);
            hp[i].s1.setHighpass(fs, edges[i], Q);
            hp[i].s2.setHighpass(fs, edges[i], Q);
            lp[i].reset(); hp[i].reset();
        }
    }

    inline void split(float x, float b[6]) {
        float h1 = hp[0].process(x);
        float h2 = hp[1].process(h1);
        float h3 = hp[2].process(h2);
        float h4 = hp[3].process(h3);
        b[0] = lp[0].process(x);
        b[1] = lp[1].process(h1);
        b[2] = lp[2].process(h2);
        b[3] = lp[3].process(h3);
        b[4] = lp[4].process(h4);
        b[5] = hp[4].process(h4);
    }
};

// ---- Per-band compressor ----------------------------------------------------

struct Compressor {
    float fs=48000.f, thresholdDb=-25.f, ratio=4.f;
    float attackMs=20.f, releaseMs=250.f, env=0.f;
    float ac_=0.f, rc_=0.f;  // pre-computed per-sample coefficients

    void updateCoeffs() {
        ac_ = std::exp(-1.f / (fs * (attackMs  * 0.001f)));
        rc_ = std::exp(-1.f / (fs * (releaseMs * 0.001f)));
    }

    void init(float sampleRate) { fs = sampleRate; env = 0.f; updateCoeffs(); }

    // outEnvDb / outGainReductionDb are optional (pass nullptr to skip) —
    // used only by evidence/diagnostic capture, never by the plain process().
    inline float processDiag(float x, float* outEnvDb, float* outGainReductionDb) {
        float ax = std::fabs(x);
        env = ax > env ? ac_*env+(1-ac_)*ax : rc_*env+(1-rc_)*ax;
        float envDb = fast_lin_to_db(env);
        float gainDb = 0.f;
        if (envDb > thresholdDb) {
            float over = envDb - thresholdDb;
            gainDb = thresholdDb + over/ratio - envDb;
        }
        if (outEnvDb) *outEnvDb = envDb;
        if (outGainReductionDb) *outGainReductionDb = gainDb;
        return x * fast_db_to_lin(gainDb);
    }

    inline float process(float x) { return processDiag(x, nullptr, nullptr); }
};

// ---- Downward Expander ------------------------------------------------------

struct Expander {
    float fs=48000.f, thresholdDb=-40.f, ratio=2.f;
    float attackMs=5.f, releaseMs=100.f, env=0.f;
    float ac_=0.f, rc_=0.f;

    void updateCoeffs() {
        ac_ = std::exp(-1.f / (fs * (attackMs  * 0.001f)));
        rc_ = std::exp(-1.f / (fs * (releaseMs * 0.001f)));
    }

    void init(float sampleRate) { fs = sampleRate; env = 0.f; updateCoeffs(); }

    inline float process(float x) {
        float ax = std::fabs(x);
        env = ax > env ? ac_*env+(1-ac_)*ax : rc_*env+(1-rc_)*ax;
        float envDb = fast_lin_to_db(env);
        float gainDb = 0.f;
        if (envDb < thresholdDb) {
            float under = thresholdDb - envDb;
            gainDb = -under * (1.f - 1.f/ratio);
        }
        return x * fast_db_to_lin(gainDb);
    }
};

// ---- Conversation speech enhancer -----------------------------------------

struct ConversationEnhancer {
    static constexpr int kBands = 6;

    float fs=48000.f;
    float power_[kBands];
    float noise_[kBands];
    float gain_[kBands];
    float pAttack_=0.f, pRelease_=0.f;
    float noiseRise_=0.f, noiseFall_=0.f, noiseHoldRise_=0.f;
    float gainDown_=0.f, gainUp_=0.f;
    float ownVoiceGain_=1.f;
    bool enabled_=true;

    void updateCoeffs() {
        pAttack_      = std::exp(-1.f / (fs * 0.004f));
        pRelease_     = std::exp(-1.f / (fs * 0.060f));
        noiseRise_    = std::exp(-1.f / (fs * 0.350f));
        noiseFall_    = std::exp(-1.f / (fs * 0.080f));
        noiseHoldRise_= std::exp(-1.f / (fs * 3.000f));
        gainDown_     = std::exp(-1.f / (fs * 0.008f));
        gainUp_       = std::exp(-1.f / (fs * 0.180f));
    }

    void reset() {
        for (int i = 0; i < kBands; i++) {
            power_[i] = 1e-8f;
            noise_[i] = 1e-7f;
            gain_[i] = 1.f;
        }
        ownVoiceGain_ = 1.f;
    }

    void init(float sampleRate) {
        fs = sampleRate;
        updateCoeffs();
        reset();
    }

    inline void process(float b[kBands]) {
        if (!enabled_) return;

        for (int i = 0; i < kBands; i++) {
            float p = b[i] * b[i] + 1e-12f;
            float c = p > power_[i] ? pAttack_ : pRelease_;
            power_[i] = c * power_[i] + (1.f - c) * p;
        }

        float voicePower = 0.60f * power_[1] + power_[2] + power_[3] + 0.55f * power_[4];
        float voiceNoise = 0.60f * noise_[1] + noise_[2] + noise_[3] + 0.55f * noise_[4] + 1e-12f;
        bool voicePresent = (voicePower / voiceNoise) > 2.2f;
        float voiceDb = fast_lin_to_db(std::sqrt(voicePower));
        float ownVoiceAmount = clampf((voiceDb + 36.f) / 16.f, 0.f, 1.f);
        float ownVoiceTarget = voicePresent ? (1.f - 0.72f * ownVoiceAmount) : 1.f;
        float ownVoiceCoeff = ownVoiceTarget < ownVoiceGain_ ? gainDown_ : gainUp_;
        ownVoiceGain_ = ownVoiceCoeff * ownVoiceGain_ + (1.f - ownVoiceCoeff) * ownVoiceTarget;

        static constexpr float minGain[kBands] = {
            0.12f, 0.22f, 0.30f, 0.30f, 0.24f, 0.16f
        };
        static constexpr float speechMinGain[kBands] = {
            0.12f, 0.55f, 0.68f, 0.68f, 0.58f, 0.16f
        };

        for (int i = 0; i < kBands; i++) {
            float n = noise_[i];
            float p = power_[i];
            bool speechBand = i >= 1 && i <= 4;
            bool bandSpeechPresent = speechBand && (voicePresent || (p / (n + 1e-12f)) > 3.5f);

            float nc;
            if (p < n) {
                nc = noiseFall_;
            } else {
                nc = bandSpeechPresent ? noiseHoldRise_ : noiseRise_;
            }
            noise_[i] = nc * n + (1.f - nc) * p;
            noise_[i] = clampf(noise_[i], 1e-10f, 0.25f);

            float postSnr = p / (noise_[i] + 1e-12f);
            float wiener = 1.f - (1.f / std::max(postSnr, 1.f));
            float target = std::sqrt(clampf(wiener, 0.f, 1.f));
            float floor = bandSpeechPresent ? speechMinGain[i] : minGain[i];
            target = clampf(target, floor, 1.f);

            float gc = target < gain_[i] ? gainDown_ : gainUp_;
            gain_[i] = gc * gain_[i] + (1.f - gc) * target;
            float appliedGain = gain_[i];
            if (speechBand) {
                appliedGain *= ownVoiceGain_;
            }
            b[i] *= appliedGain;
        }
    }
};

// ---- Soft limiter -----------------------------------------------------------

struct SoftLimiter {
    float thr=0.95f, strength=10.f;
    inline float process(float x) const {
        float ax=std::fabs(x);
        if (ax <= thr) return x;
        float s = x >= 0 ? 1.f : -1.f;
        float ex = ax - thr;
        return s*(thr + ex/(1.f+strength*ex));
    }
};

// ---- Real-time processor ----------------------------------------------------

enum EnvironmentMode {
    MODE_STANDARD = 0,
    MODE_TRANSIT = 1,
    MODE_CONVERSATION = 2
};

// Optional per-sample diagnostic snapshot filled by RealtimeProcessor::process
// when a non-null pointer is passed. Only ever populated during an active
// evidence/diagnostic capture — the plain process(x) call path (used at all
// other times) never touches this struct and has zero added cost.
struct ProcessDiagSample {
    float bandIn[6];             // post-crossover, pre-gain band signal
    float bandEnvDb[6];          // compressor envelope level (dB)
    float bandGainReductionDb[6];// compressor gain reduction (dB, <= 0)
    float bandMakeupGainDb[6];   // configured makeup gain incl. mode multiplier (dB)
    float bandFinalGainDb[6];    // bandGainReductionDb + bandMakeupGainDb
    float bandOut[6];            // band signal after compressor + gain
    float preLimiter = 0.f;      // summed signal just before the soft limiter
    float postLimiter = 0.f;     // signal just after the soft limiter
};

class RealtimeProcessor {
public:
    static constexpr int kBands = 6;

    float thresholdDb[kBands] = {-10,-12,-14,-16,-18,-20};
    float ratio_    = 2.f;
    float attackMs_ = 5.f;
    float releaseMs_= 80.f;
    float makeupLin[kBands];
    float wet_      = 1.f;
    float dry_      = 0.f;
    float masterLin_= 1.f;

    Crossover6  xo_;
    Compressor  comp_[kBands];
    Expander    expander_;
    ConversationEnhancer conversation_;
    SoftLimiter lim_;
    EnvironmentMode currentMode_ = MODE_STANDARD;

    RealtimeProcessor() {
        for (int i = 0; i < kBands; i++) makeupLin[i] = 1.f;
    }

    void init(float fs) {
        const float edges[5] = {500,1000,2000,4000,8000};
        xo_.init(fs, edges);
        for (int i = 0; i < kBands; i++) {
            comp_[i].init(fs);
            comp_[i].ratio       = ratio_;
            comp_[i].attackMs    = attackMs_;
            comp_[i].releaseMs   = releaseMs_;
            comp_[i].thresholdDb = thresholdDb[i];
            comp_[i].updateCoeffs();
        }
        expander_.init(fs);
        conversation_.init(fs);
        setMode(currentMode_); // Apply current mode preset
    }

    void setMode(EnvironmentMode mode) {
        currentMode_ = mode;
        if (mode == MODE_TRANSIT) {
            ratio_ = 8.f;
            attackMs_ = 2.f;
            releaseMs_ = 100.f;
            for (int i = 0; i < kBands; i++) {
                comp_[i].ratio = ratio_;
                comp_[i].attackMs = attackMs_;
                comp_[i].releaseMs = releaseMs_;
                comp_[i].thresholdDb = -35.f; // more aggressive threshold for transit
                comp_[i].updateCoeffs();
            }
            expander_.ratio = 1.f; // disable expander
            expander_.updateCoeffs();
        } else if (mode == MODE_CONVERSATION) {
            ratio_ = 2.f;
            attackMs_ = 5.f;
            releaseMs_ = 80.f;
            for (int i = 0; i < kBands; i++) {
                comp_[i].ratio = ratio_;
                comp_[i].attackMs = attackMs_;
                comp_[i].releaseMs = releaseMs_;
                comp_[i].thresholdDb = thresholdDb[i];
                comp_[i].updateCoeffs();
            }
            expander_.ratio = 1.f; // conversation uses multiband suppression instead
            expander_.updateCoeffs();
            conversation_.reset();
        } else {
            // STANDARD
            ratio_ = 2.f;
            attackMs_ = 5.f;
            releaseMs_ = 80.f;
            for (int i = 0; i < kBands; i++) {
                comp_[i].ratio = ratio_;
                comp_[i].attackMs = attackMs_;
                comp_[i].releaseMs = releaseMs_;
                comp_[i].thresholdDb = thresholdDb[i];
                comp_[i].updateCoeffs();
            }
            expander_.ratio = 1.f; // disable expander
            expander_.updateCoeffs();
        }
    }

    // loss6 values are in-app threshold dB. Convert to clinical dB, then add
    // only the gain needed to bring the clinical threshold down to 10 dB.
    void updateLoss(const float loss6[kBands]) {
        for (int i = 0; i < kBands; i++) {
            float g = appThresholdToMakeupGainDb(loss6[i]);
            makeupLin[i] = db_to_lin(g);
        }
    }

    // diag == nullptr on the live audio path (default): identical cost and
    // behaviour to the original single-purpose process(). When diag is
    // non-null (evidence/diagnostic capture only) the same single pass also
    // records per-band and limiter intermediate values — no second pass, so
    // filter/envelope state is never advanced twice.
    inline float process(float x, ProcessDiagSample* diag = nullptr) {
        float b[kBands];
        xo_.split(x, b);
        if (diag) {
            for (int i = 0; i < kBands; i++) diag->bandIn[i] = b[i];
        }
        if (currentMode_ == MODE_CONVERSATION) {
            conversation_.process(b);
        }
        float sumOn = 0.f;
        for (int i = 0; i < kBands; i++) {
            float gain = makeupLin[i];
            if (currentMode_ == MODE_CONVERSATION) {
                if (i == 0) gain *= 0.70f;
                if (i == 1) gain *= 1.18f;
                if (i == 2 || i == 3) gain *= 1.35f;
                if (i == 4) gain *= 1.22f;
                if (i == 5) gain *= 0.80f;
            }
            float compOut;
            if (diag) {
                float envDb = 0.f, gainRedDb = 0.f;
                compOut = comp_[i].processDiag(b[i], &envDb, &gainRedDb);
                diag->bandEnvDb[i] = envDb;
                diag->bandGainReductionDb[i] = gainRedDb;
                diag->bandMakeupGainDb[i] = lin_to_db(gain);
                diag->bandFinalGainDb[i] = gainRedDb + lin_to_db(gain);
                diag->bandOut[i] = compOut * gain;
            } else {
                compOut = comp_[i].process(b[i]);
            }
            sumOn += compOut * gain;
        }
        float out = (dry_*x + wet_*sumOn) * masterLin_;
        if (diag) diag->preLimiter = out;
        float limited = lim_.process(out);
        if (diag) diag->postLimiter = limited;
        return limited;
    }
};

// ---- WAV helpers (batch processing) ----------------------------------------

static uint32_t read_u32(std::ifstream& f) {
    uint32_t v; f.read(reinterpret_cast<char*>(&v), 4); return v;
}
static uint16_t read_u16(std::ifstream& f) {
    uint16_t v; f.read(reinterpret_cast<char*>(&v), 2); return v;
}

struct WavData { int sampleRate=48000; std::vector<float> x; };

static bool read_wav_mono16(const std::string& path, WavData& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    char riff[4]; f.read(riff,4);
    (void)read_u32(f);
    char wave[4]; f.read(wave,4);
    if (std::strncmp(riff,"RIFF",4)||std::strncmp(wave,"WAVE",4)) return false;

    uint16_t fmt=0, ch=0, bps=0; uint32_t sr=0, dataSz=0;
    std::streampos dataPos=0;
    while (f && !dataPos) {
        char id[4]; f.read(id,4); uint32_t sz=read_u32(f); if (!f) break;
        if (!std::strncmp(id,"fmt ",4)) {
            fmt=read_u16(f); ch=read_u16(f); sr=read_u32(f);
            (void)read_u32(f); (void)read_u16(f); bps=read_u16(f);
            if (sz>16) f.seekg(sz-16,std::ios::cur);
        } else if (!std::strncmp(id,"data",4)) {
            dataSz=sz; dataPos=f.tellg(); f.seekg(sz,std::ios::cur);
        } else f.seekg(sz,std::ios::cur);
    }
    if (!dataPos||fmt!=1||ch!=1||bps!=16) return false;
    out.sampleRate=(int)sr;
    f.clear(); f.seekg(dataPos);
    size_t n=dataSz/2; out.x.resize(n);
    for (size_t i=0;i<n;i++) {
        int16_t s=0; f.read(reinterpret_cast<char*>(&s),2);
        out.x[i]=(float)s/32768.f;
    }
    return true;
}

static bool write_wav_mono16(const std::string& path,
                              const std::vector<float>& x, int sr) {
    std::ofstream f(path,std::ios::binary); if (!f) return false;
    uint32_t dataSz=(uint32_t)(x.size()*2), riffSz=36+dataSz;
    f.write("RIFF",4); f.write(reinterpret_cast<const char*>(&riffSz),4);
    f.write("WAVE",4); f.write("fmt ",4);
    uint32_t fmtSz=16; f.write(reinterpret_cast<const char*>(&fmtSz),4);
    uint16_t af=1,nc=1,bps=16,ba=2; uint32_t sr32=(uint32_t)sr, br=sr32*2;
    f.write(reinterpret_cast<const char*>(&af),2);
    f.write(reinterpret_cast<const char*>(&nc),2);
    f.write(reinterpret_cast<const char*>(&sr32),4);
    f.write(reinterpret_cast<const char*>(&br),4);
    f.write(reinterpret_cast<const char*>(&ba),2);
    f.write(reinterpret_cast<const char*>(&bps),2);
    f.write("data",4); f.write(reinterpret_cast<const char*>(&dataSz),4);
    for (float s:x) {
        s=clampf(s,-1.f,1.f);
        int16_t v=(int16_t)std::lrintf(s*32767.f);
        f.write(reinterpret_cast<const char*>(&v),2);
    }
    return true;
}

// ---- Offline test-signal generators (evidence collection only) ------------
// None of these run on the audio callback thread — they are one-shot
// utilities used to synthesize pure tones / sweeps / a mode-comparison input
// for DSP verification, called from the UI thread (on-device) or a host
// command-line harness (off-device).

static std::vector<float> generateToneSignal(double freqHz, double durationSec,
                                              int sampleRate, double amplitudeDbFs) {
    const int n = std::max(1, (int)std::lround(durationSec * sampleRate));
    std::vector<float> x((size_t)n);
    const double amp = std::pow(10.0, amplitudeDbFs / 20.0);
    const int fadeN = std::max(1, (int)(0.005 * sampleRate));
    const double twoPi = 2.0 * 3.14159265358979323846;
    for (int i = 0; i < n; i++) {
        const double t = (double)i / sampleRate;
        double env = 1.0;
        if (i < fadeN) env = (double)i / fadeN;
        else if (i >= n - fadeN) env = (double)(n - 1 - i) / fadeN;
        x[(size_t)i] = (float)(std::sin(twoPi * freqHz * t) * amp * env);
    }
    return x;
}

static std::vector<float> generateLogSweepSignal(double f0, double f1, double durationSec,
                                                   int sampleRate, double amplitudeDbFs) {
    const int n = std::max(1, (int)std::lround(durationSec * sampleRate));
    std::vector<float> x((size_t)n);
    const double amp = std::pow(10.0, amplitudeDbFs / 20.0);
    const double K = durationSec / std::log(f1 / f0);
    const double L = f0 * K;
    const int fadeN = std::max(1, (int)(0.01 * sampleRate));
    const double twoPi = 2.0 * 3.14159265358979323846;
    for (int i = 0; i < n; i++) {
        const double t = (double)i / sampleRate;
        const double phase = twoPi * L * (std::exp(t / K) - 1.0);
        double env = 1.0;
        if (i < fadeN) env = (double)i / fadeN;
        else if (i >= n - fadeN) env = (double)(n - 1 - i) / fadeN;
        x[(size_t)i] = (float)(std::sin(phase) * amp * env);
    }
    return x;
}

// Synthetic speech+noise input for mode-comparison evidence: a mid-band
// "speech-like" tone cluster, low-frequency rumble, high-frequency noise,
// and short transient clicks — same fixed input reused across all three
// environment modes so the DSP differences are attributable to the mode.
static std::vector<float> generateSyntheticSpeechNoiseSignal(double durationSec, int sampleRate) {
    const int n = std::max(1, (int)std::lround(durationSec * sampleRate));
    std::vector<float> x((size_t)n, 0.f);
    uint32_t seed = 12345u;
    auto rnd = [&]() {
        seed = seed * 1664525u + 1013904223u;
        return ((float)(seed >> 8) / (float)(1u << 24)) * 2.f - 1.f;
    };
    const double twoPi = 2.0 * 3.14159265358979323846;
    for (int i = 0; i < n; i++) {
        const double t = (double)i / sampleRate;
        const float speech = 0.35f * (float)std::sin(twoPi * 350.0 * t) +
                              0.25f * (float)std::sin(twoPi * 1200.0 * t * (1.0 + 0.02 * std::sin(twoPi * 3.0 * t)));
        const float rumble = 0.15f * (float)std::sin(twoPi * 60.0 * t);
        const float hiNoise = 0.05f * rnd();
        x[(size_t)i] = (speech + rumble) * 0.5f + hiNoise;
    }
    const int transientEvery = std::max(1, sampleRate / 2);
    for (int i = 0; i < n; i += transientEvery) {
        const int span = std::min(50, n - i);
        for (int k = 0; k < span; k++) {
            x[(size_t)(i + k)] += 0.3f * (1.f - (float)k / 50.f);
        }
    }
    float peak = 1e-6f;
    for (float v : x) peak = std::max(peak, std::fabs(v));
    const float scale = db_to_lin(-6.f) / peak;
    for (float& v : x) v *= scale;
    return x;
}
