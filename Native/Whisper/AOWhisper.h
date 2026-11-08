#ifndef AO_WHISPER_H
#define AO_WHISPER_H
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__)
#define AO_WHISPER_API __attribute__((visibility("default")))
#else
#define AO_WHISPER_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef int (*AOWhisperCancelCallback)(void *user_data);
// Synchronous, entirely offline. PCM must be finite mono float32 at 16,000 Hz.
// Returns 0 success, 1 failure, 2 cancelled. out_json is NULL on failure.
// Success JSON: {"text":"...","segments":[{"start":0.0,"end":1.0,"text":"..."}]}.
// Times are seconds relative to this PCM window. Free with ao_whisper_free_text.
// Caller must keep buffers/callback valid until return. Callback may run on a
// backend worker thread; it must be thread safe, quick, and never throw.
AO_WHISPER_API int ao_whisper_transcribe(
    const char *model_path, const float *pcm16k, int32_t sample_count,
    const char *language, const char *initial_prompt, int32_t threads,
    int32_t use_gpu, AOWhisperCancelCallback cancel, void *user_data,
    char **out_json, char *error_buffer, size_t error_capacity);
AO_WHISPER_API void ao_whisper_free_text(char *text);
#ifdef __cplusplus
}
#endif
#endif
