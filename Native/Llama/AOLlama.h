#ifndef AO_LLAMA_H
#define AO_LLAMA_H
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__)
#define AO_LLAMA_API __attribute__((visibility("default")))
#else
#define AO_LLAMA_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef int (*AOLlamaCancelCallback)(void *user_data);
// Synchronous and offline. prompt is already formatted for the model's chat
// template (Qwen3 ChatML with /no_think). No tokenizer truncation is performed.
// Returns 0 success, 1 failure, 2 cancelled; out_json NULL on failure.
// JSON: text, generatedTokens (emitted non-EOS), promptTokens, generationSeconds
// (prefill + generation, excludes load/init/free), stopReason (eos).
// Reaching the output token limit returns failure, never partial conclusions.
// Free with ao_llama_free_text. Cancellation callback is thread safe and quick.
AO_LLAMA_API int ao_llama_generate(
    const char *model_path, const char *prompt, int32_t context_size,
    int32_t predict_tokens, int32_t threads, int32_t gpu_layers,
    AOLlamaCancelCallback cancel, void *user_data,
    char **out_json, char *error_buffer, size_t error_capacity);
AO_LLAMA_API void ao_llama_free_text(char *text);
#ifdef __cplusplus
}
#endif
#endif
