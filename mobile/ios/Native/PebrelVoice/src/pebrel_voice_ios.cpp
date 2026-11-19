#include "pebrel_voice_ios.h"

#include <whisper.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

struct Job {
    std::atomic<bool> cancelled{false};
};

std::mutex registry_mutex;
std::unordered_map<int64_t, std::shared_ptr<Job>> jobs;
int64_t next_id = 1;
std::once_flag logging;

std::shared_ptr<Job> find_job(int64_t id) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto found = jobs.find(id);
    return found == jobs.end() ? nullptr : found->second;
}

void set_failed(const char **out_error) {
    // Never include model paths, audio, or recognized text in diagnostics.
    if (out_error) *out_error = "local_transcription_failed";
}

bool abort_inference(void *data) {
    return static_cast<Job *>(data)->cancelled.load();
}

void discard_log(enum ggml_log_level, const char *, void *) {}

struct Samples {
    std::vector<float> value;
    ~Samples() { std::fill(value.begin(), value.end(), 0.f); }
};

char *alloc_cstr(const std::string &text) {
    auto *out = static_cast<char *>(std::malloc(text.size() + 1));
    if (!out) return nullptr;
    if (!text.empty()) std::memcpy(out, text.data(), text.size());
    out[text.size()] = '\0';
    return out;
}

}  // namespace

extern "C" {

int64_t pebrel_voice_create(const char **out_error) {
    if (out_error) *out_error = nullptr;
    try {
        std::lock_guard<std::mutex> lock(registry_mutex);
        if (jobs.size() >= 2) throw std::runtime_error("busy");
        const int64_t id = next_id++;
        jobs.emplace(id, std::make_shared<Job>());
        return id;
    } catch (...) {
        set_failed(out_error);
        return 0;
    }
}

void pebrel_voice_cancel(int64_t handle) {
    if (auto job = find_job(handle)) {
        job->cancelled = true;
    }
}

void pebrel_voice_destroy(int64_t handle) {
    std::lock_guard<std::mutex> lock(registry_mutex);
    const auto found = jobs.find(handle);
    if (found != jobs.end()) {
        found->second->cancelled = true;
        jobs.erase(found);
    }
}

bool pebrel_voice_transcribe(
    int64_t handle,
    const char *model_path,
    const float *samples_in,
    size_t sample_count,
    char **out_utf8,
    const char **out_error
) {
    if (out_error) *out_error = nullptr;
    if (out_utf8) *out_utf8 = nullptr;
    try {
        auto job = find_job(handle);
        if (!job || !model_path || !samples_in || !out_utf8) {
            throw std::runtime_error("invalid_job");
        }
        if (job->cancelled) {
            *out_utf8 = alloc_cstr("");
            return *out_utf8 != nullptr;
        }
        if (sample_count < 4800 || sample_count > 960000) {
            throw std::runtime_error("invalid_audio");
        }
        Samples samples;
        samples.value.assign(samples_in, samples_in + sample_count);
        for (float value : samples.value) {
            if (!std::isfinite(value) || value < -1.f || value > 1.f) {
                throw std::runtime_error("invalid_audio");
            }
        }
        std::string model(model_path);
        std::call_once(logging, [] { whisper_log_set(discard_log, nullptr); });

        auto context_params = whisper_context_default_params();
        context_params.use_gpu = false;
        std::unique_ptr<whisper_context, decltype(&whisper_free)> context(
            whisper_init_from_file_with_params(model.c_str(), context_params),
            whisper_free);
        if (job->cancelled) {
            *out_utf8 = alloc_cstr("");
            return *out_utf8 != nullptr;
        }
        if (!context) throw std::runtime_error("model_unavailable");

        auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = static_cast<int>(std::max(1u, std::min(4u, std::thread::hardware_concurrency())));
        params.language = "auto";
        params.translate = false;
        params.no_context = true;
        params.no_timestamps = true;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.print_special = false;
        params.suppress_blank = true;
        params.suppress_nst = true;
        params.abort_callback = abort_inference;
        params.abort_callback_user_data = job.get();

        const int result = whisper_full(
            context.get(),
            params,
            samples.value.data(),
            static_cast<int>(sample_count));
        if (job->cancelled) {
            *out_utf8 = alloc_cstr("");
            return *out_utf8 != nullptr;
        }
        if (result != 0) throw std::runtime_error("inference_failed");

        std::string text;
        const int segments = whisper_full_n_segments(context.get());
        for (int i = 0; i < segments; ++i) {
            if (whisper_full_get_segment_no_speech_prob(context.get(), i) > 0.8f) continue;
            const char *segment = whisper_full_get_segment_text(context.get(), i);
            if (segment) text += segment;
            if (text.size() > 32768) throw std::runtime_error("transcript_too_long");
        }
        *out_utf8 = alloc_cstr(text);
        if (!*out_utf8) throw std::runtime_error("out_of_memory");
        return true;
    } catch (...) {
        set_failed(out_error);
        return false;
    }
}

void pebrel_voice_free_string(char *ptr) {
    std::free(ptr);
}

}  // extern "C"
