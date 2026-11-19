#ifndef PEBREL_VOICE_IOS_H
#define PEBREL_VOICE_IOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef PEBREL_EXPORT
#define PEBREL_EXPORT __attribute__((visibility("default")))
#endif

PEBREL_EXPORT int64_t pebrel_voice_create(const char **out_error);
PEBREL_EXPORT void pebrel_voice_cancel(int64_t handle);
PEBREL_EXPORT void pebrel_voice_destroy(int64_t handle);

PEBREL_EXPORT bool pebrel_voice_transcribe(
    int64_t handle,
    const char *model_path,
    const float *samples,
    size_t sample_count,
    char **out_utf8,
    const char **out_error
);

PEBREL_EXPORT void pebrel_voice_free_string(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* PEBREL_VOICE_IOS_H */
