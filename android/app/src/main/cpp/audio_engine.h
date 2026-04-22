#pragma once
// ============================================================================
// ClearTone Audio Engine — Public FFI Header
// ============================================================================

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

int   start_rt_stream_ffi(int inputDeviceId);
int   stop_rt_stream_ffi(void);
int   update_rt_params_ffi(const float* loss6);
void  debug_start_capture_ffi(void);
void  debug_stop_capture_ffi(void);
int   debug_save_capture_ffi(const char* filePath, int source);
int   debug_get_capture_size_ffi(void);
void  set_audio_usage_ffi(int usage);
uint8_t is_playing_ffi(void);
int   get_engine_state_ffi(void);

// Offline file processing (existing symbol kept for backward compat)
int process_audio_file_ffi(
    const char* inPath,
    const char* outPath,
    const float* loss6,
    float ratio,
    float attackMs,
    float releaseMs,
    const float* thrDb,
    float masterDb,
    float wet,
    float dry
);

#ifdef __cplusplus
}
#endif
