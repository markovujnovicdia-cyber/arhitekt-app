#include "AOWhisper.h"
#include "../Common/BridgeSupport.hpp"
#include "whisper.h"
#include <memory>
#include <mutex>

namespace {
std::mutex engine_mutex;
void discard_log(enum ggml_log_level, const char *, void *) {}
}
extern "C" int ao_whisper_transcribe(
    const char *model_path, const float *pcm16k, int32_t sample_count,
    const char *language, const char *initial_prompt, int32_t threads,
    int32_t use_gpu, AOWhisperCancelCallback cancel, void *user_data,
    char **out_json, char *error_buffer, size_t error_capacity) {
    if (out_json) *out_json = nullptr;
    ao::error(error_buffer, error_capacity, "");
    ao::Cancellation<AOWhisperCancelCallback> cancellation{cancel, user_data};
    try {
        if (cancellation.cancelled()) return 2;
        if (!out_json || !model_path || !*model_path || !pcm16k || sample_count <= 0 ||
            sample_count > 16000 * 120 || threads < 1 || threads > 8 ||
            !language || std::strcmp(language, "hr") != 0 || (use_gpu != 0 && use_gpu != 1)) {
            ao::error(error_buffer, error_capacity, "Invalid Whisper arguments; expected Croatian PCM16k windows up to 120 seconds.");
            return 1;
        }
        for (int32_t i = 0; i < sample_count; ++i) {
            if (!std::isfinite(pcm16k[i])) {
                ao::error(error_buffer, error_capacity, "PCM contains a non-finite sample."); return 1;
            }
        }
        std::lock_guard<std::mutex> lock(engine_mutex);
        if (cancellation.cancelled()) return 2;
        whisper_log_set(discard_log, nullptr);
        auto context_params = whisper_context_default_params();
        context_params.use_gpu = use_gpu != 0;
        // Independent contexts ensure a cancelled/retried window never inherits
        // a decoder state from an earlier recording.
        std::unique_ptr<whisper_context, decltype(&whisper_free)> context(
            whisper_init_from_file_with_params(model_path, context_params), whisper_free);
        if (cancellation.cancelled()) return 2;
        if (!context) { ao::error(error_buffer, error_capacity, "Cannot load the local Whisper model."); return 1; }
        auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = threads;
        params.language = language;
        params.detect_language = false;
        params.translate = false;
        params.no_context = true;
        params.no_timestamps = false;
        params.single_segment = false;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.print_special = false;
        params.initial_prompt = initial_prompt;
        params.carry_initial_prompt = false;
        params.abort_callback = decltype(cancellation)::abort;
        params.abort_callback_user_data = &cancellation;
        const int status = whisper_full(context.get(), params, pcm16k, sample_count);
        if (cancellation.cancelled()) return 2;
        if (status != 0) { ao::error(error_buffer, error_capacity, "Local Whisper transcription failed."); return 1; }
        std::string text, segments;
        const double duration = static_cast<double>(sample_count) / 16000.0;
        const int count = whisper_full_n_segments(context.get());
        for (int i = 0; i < count; ++i) {
            const char *segment_text = whisper_full_get_segment_text(context.get(), i);
            const std::string segment = segment_text ? segment_text : "";
            text += segment;
            const double start = std::clamp(whisper_full_get_segment_t0(context.get(), i) * 0.01, 0.0, duration);
            const double end = std::clamp(whisper_full_get_segment_t1(context.get(), i) * 0.01, start, duration);
            if (i) segments += ',';
            segments += "{\"start\":" + std::to_string(start) + ",\"end\":" + std::to_string(end) +
                ",\"text\":" + ao::json_string(segment) + "}";
        }
        *out_json = ao::copy("{\"text\":" + ao::json_string(text) + ",\"segments\":[" + segments + "]}");
        return 0;
    } catch (const std::bad_alloc &) {
        ao::error(error_buffer, error_capacity, "Insufficient memory for local transcription."); return 1;
    } catch (...) {
        ao::error(error_buffer, error_capacity, "Unexpected local Whisper error."); return 1;
    }
}
extern "C" void ao_whisper_free_text(char *text) { std::free(text); }
