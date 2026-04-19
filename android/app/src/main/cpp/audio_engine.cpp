#include <oboe/Oboe.h>
#include <android/log.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

#define LOG_TAG "ClearToneEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ---- helpers ---------------------------------------------------------------

static inline float clampf(float x, float lo, float hi) {
    return x < lo ? lo : (x > hi ? hi : x);
}
static inline float db_to_lin(float db)  { return std::pow(10.0f, db / 20.0f); }
static inline float lin_to_db(float lin) { return 20.0f * std::log10(std::max(lin, 1e-12f)); }

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

    void init(float sampleRate) { fs = sampleRate; env = 0.f; }

    inline float process(float x) {
        float ax = std::fabs(x);
        float ac = std::exp(-1.f/(fs*(attackMs*0.001f)));
        float rc = std::exp(-1.f/(fs*(releaseMs*0.001f)));
        env = ax > env ? ac*env+(1-ac)*ax : rc*env+(1-rc)*ax;
        float envDb = lin_to_db(env);
        float gainDb = 0.f;
        if (envDb > thresholdDb) {
            float over = envDb - thresholdDb;
            gainDb = thresholdDb + over/ratio - envDb;
        }
        return x * db_to_lin(gainDb);
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

class RealtimeProcessor {
public:
    static constexpr int kBands = 6;

    float thresholdDb[kBands] = {-18,-22,-26,-30,-34,-36};
    float ratio_    = 4.f;
    float attackMs_ = 20.f;
    float releaseMs_= 250.f;
    float makeupLin[kBands];
    float wet_      = 1.f;
    float dry_      = 0.f;
    float masterLin_= 1.f;

    Crossover6  xo_;
    Compressor  comp_[kBands];
    SoftLimiter lim_;

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
        }
    }

    // loss6 values are hearing-loss dB (0-60 typical)
    void updateLoss(const float loss6[kBands]) {
        for (int i = 0; i < kBands; i++) {
            float g = clampf(0.5f * loss6[i], 0.f, 25.f);
            makeupLin[i] = db_to_lin(g);
        }
    }

    inline float process(float x) {
        float b[kBands];
        xo_.split(x, b);
        float sumOn = 0.f;
        for (int i = 0; i < kBands; i++)
            sumOn += comp_[i].process(b[i]) * makeupLin[i];
        return lim_.process((dry_*x + wet_*sumOn) * masterLin_);
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

// ---- Oboe engine ------------------------------------------------------------

class OboeEngine : public oboe::AudioStreamDataCallback {
public:
    oboe::ManagedStream inputStream_;
    oboe::ManagedStream outputStream_;
    RealtimeProcessor   proc_;
    int32_t             audioUsage_ = (int32_t)oboe::Usage::VoiceCommunication;
    std::atomic<bool>   running_{false};

    // debug capture
    std::vector<float>  capIn_, capOut_;
    std::atomic<bool>   capturing_{false};
    std::mutex          capMu_;

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* /*stream*/,
                                          void* audioData,
                                          int32_t numFrames) override {
        auto* out = static_cast<float*>(audioData);

        // Non-blocking read from input stream
        if (inputStream_) {
            auto res = inputStream_->read(out, numFrames, 0 /*timeoutNs*/);
            int32_t got = (res) ? res.value() : 0;
            if (got < numFrames)
                std::memset(out + got, 0, (numFrames - got) * sizeof(float));
        } else {
            std::memset(out, 0, numFrames * sizeof(float));
        }

        bool cap = capturing_.load(std::memory_order_relaxed);
        for (int i = 0; i < numFrames; i++) {
            float in  = out[i];
            float processed = proc_.process(in);
            out[i] = processed;
            if (cap) {
                std::lock_guard<std::mutex> lk(capMu_);
                capIn_.push_back(in);
                capOut_.push_back(processed);
            }
        }
        return oboe::DataCallbackResult::Continue;
    }

    int start(int32_t inputDeviceId) {
        if (running_) stop();

        oboe::AudioStreamBuilder inB;
        inB.setDirection(oboe::Direction::Input)
           ->setDeviceId(inputDeviceId)
           ->setChannelCount(1)
           ->setFormat(oboe::AudioFormat::Float)
           ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
           ->setSharingMode(oboe::SharingMode::Exclusive);

        auto inRes = inB.openManagedStream(inputStream_);
        if (inRes != oboe::Result::OK) {
            LOGE("Failed to open input stream: %s", oboe::convertToText(inRes));
            return -1;
        }

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

        inputStream_->requestStart();
        outputStream_->requestStart();
        running_ = true;
        LOGI("Streams started. SR=%d", inputStream_->getSampleRate());
        return 0;
    }

    int stop() {
        if (outputStream_) outputStream_->requestStop();
        if (inputStream_)  inputStream_->requestStop();
        running_ = false;
        LOGI("Streams stopped.");
        return 0;
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
    for (int i=0;i<6;i++) makeupDb[i]=clampf(0.5f*loss6[i],0.f,25.f);

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
    return gEngine.start(inputDeviceId);
}

int32_t stop_rt_stream_ffi() {
    return gEngine.stop();
}

int32_t update_rt_params_ffi(const float* loss6) {
    gEngine.proc_.updateLoss(loss6);
    return 0;
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
    std::ofstream f(filePath, std::ios::binary);
    if (!f) return -1;
    f.write(reinterpret_cast<const char*>(buf.data()),
            (std::streamsize)(buf.size()*sizeof(float)));
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

} // extern "C"
