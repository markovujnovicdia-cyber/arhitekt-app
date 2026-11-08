#include "AOLlama.h"
#include "JSONGrammar.hpp"
#include "../Common/BridgeSupport.hpp"
#include "llama.h"
#include <chrono>
#include <climits>
#include <memory>
#include <mutex>
#include <vector>

namespace {
std::mutex engine_mutex;
std::once_flag backend_once;
void discard_log(enum ggml_log_level, const char *, void *) {}
}
extern "C" int ao_llama_generate(
    const char *model_path, const char *prompt, int32_t context_size,
    int32_t predict_tokens, int32_t threads, int32_t gpu_layers,
    AOLlamaCancelCallback cancel, void *user_data,
    char **out_json, char *error_buffer, size_t error_capacity) {
    if (out_json) *out_json = nullptr;
    ao::error(error_buffer, error_capacity, "");
    ao::Cancellation<AOLlamaCancelCallback> cancellation{cancel, user_data};
    try {
        if (cancellation.cancelled()) return 2;
        if (!out_json || !model_path || !*model_path || !prompt || !*prompt ||
            std::strlen(prompt) > 512 * 1024 || context_size < 512 || context_size > 8192 ||
            predict_tokens < 1 || predict_tokens >= context_size || threads < 1 || threads > 8 ||
            gpu_layers < 0 || gpu_layers > 100) {
            ao::error(error_buffer, error_capacity, "Invalid local LLM arguments."); return 1;
        }
        std::lock_guard<std::mutex> lock(engine_mutex);
        if (cancellation.cancelled()) return 2;
        std::call_once(backend_once, [] { llama_log_set(discard_log, nullptr); llama_backend_init(); });
        auto model_params = llama_model_default_params();
        model_params.n_gpu_layers = gpu_layers;
        model_params.progress_callback = decltype(cancellation)::progress;
        model_params.progress_callback_user_data = &cancellation;
        std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
            llama_model_load_from_file(model_path, model_params), llama_model_free);
        if (cancellation.cancelled()) return 2;
        if (!model) { ao::error(error_buffer, error_capacity, "Cannot load the local GGUF model."); return 1; }
        auto context_params = llama_context_default_params();
        context_params.n_ctx = context_size;
        context_params.n_batch = 256;
        context_params.n_ubatch = 128;
        context_params.n_threads = threads;
        context_params.n_threads_batch = threads;
        context_params.n_seq_max = 1;
        context_params.abort_callback = decltype(cancellation)::abort;
        context_params.abort_callback_data = &cancellation;
        context_params.no_perf = true;
        std::unique_ptr<llama_context, decltype(&llama_free)> context(
            llama_init_from_model(model.get(), context_params), llama_free);
        if (cancellation.cancelled()) return 2;
        if (!context) { ao::error(error_buffer, error_capacity, "Cannot allocate a local LLM context."); return 1; }
        const auto *vocab = llama_model_get_vocab(model.get());
        const int32_t length = static_cast<int32_t>(std::strlen(prompt));
        const int32_t needed = llama_tokenize(vocab, prompt, length, nullptr, 0, true, true);
        if (needed >= 0 || needed == INT32_MIN || -needed > context_size - predict_tokens) {
            ao::error(error_buffer, error_capacity, "Prompt and requested output exceed the context; split the transcript into smaller windows."); return 1;
        }
        std::vector<llama_token> tokens(static_cast<size_t>(-needed));
        const int32_t token_count = llama_tokenize(vocab, prompt, length, tokens.data(), static_cast<int32_t>(tokens.size()), true, true);
        if (token_count <= 0) { ao::error(error_buffer, error_capacity, "Local tokenization failed."); return 1; }
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
            llama_sampler_chain_init(llama_sampler_chain_default_params()), llama_sampler_free);
        if (!sampler) throw std::bad_alloc();
        auto *grammar = llama_sampler_init_grammar(vocab, ao::json_grammar, "root");
        if (!grammar) { ao::error(error_buffer, error_capacity, "Cannot initialize local JSON grammar."); return 1; }
        llama_sampler_chain_add(sampler.get(), grammar);
        auto *greedy = llama_sampler_init_greedy();
        if (!greedy) throw std::bad_alloc();
        llama_sampler_chain_add(sampler.get(), greedy);
        const auto began = std::chrono::steady_clock::now();
        for (int32_t offset = 0; offset < token_count; offset += 256) {
            if (cancellation.cancelled()) return 2;
            const int32_t batch_size = std::min<int32_t>(256, token_count - offset);
            if (llama_decode(context.get(), llama_batch_get_one(tokens.data() + offset, batch_size)) != 0) {
                if (cancellation.cancelled()) return 2;
                ao::error(error_buffer, error_capacity, "Local LLM prompt evaluation failed."); return 1;
            }
        }
        std::string text;
        int32_t emitted = 0;
        bool eos = false;
        for (int32_t i = 0; i < predict_tokens; ++i) {
            if (cancellation.cancelled()) return 2;
            llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
            if (llama_vocab_is_eog(vocab, token)) { eos = true; break; }
            char piece[256];
            const int32_t size = llama_token_to_piece(vocab, token, piece, sizeof piece, 0, false);
            if (size >= 0) text.append(piece, static_cast<size_t>(size));
            else {
                if (size == INT32_MIN) throw std::runtime_error("Invalid token");
                std::vector<char> large(static_cast<size_t>(-size));
                const int32_t actual = llama_token_to_piece(vocab, token, large.data(), static_cast<int32_t>(large.size()), 0, false);
                if (actual < 0) throw std::runtime_error("Invalid token");
                text.append(large.data(), static_cast<size_t>(actual));
            }
            ++emitted;
            if (i + 1 == predict_tokens) break;
            if (llama_decode(context.get(), llama_batch_get_one(&token, 1)) != 0) {
                if (cancellation.cancelled()) return 2;
                ao::error(error_buffer, error_capacity, "Local LLM generation failed."); return 1;
            }
        }
        if (cancellation.cancelled()) return 2;
        if (!eos) {
            ao::error(error_buffer, error_capacity, "Local output reached its token limit; retry with a smaller source window. Partial conclusions were not returned.");
            return 1;
        }
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - began).count();
        *out_json = ao::copy("{\"text\":" + ao::json_string(text) + ",\"generatedTokens\":" + std::to_string(emitted) +
            ",\"promptTokens\":" + std::to_string(token_count) + ",\"generationSeconds\":" + std::to_string(seconds) +
            ",\"stopReason\":\"" + (eos ? "eos" : "length") + "\"}");
        return 0;
    } catch (const std::bad_alloc &) {
        ao::error(error_buffer, error_capacity, "Insufficient memory for the local LLM."); return 1;
    } catch (...) {
        ao::error(error_buffer, error_capacity, "Unexpected local LLM error."); return 1;
    }
}
extern "C" void ao_llama_free_text(char *text) { std::free(text); }
