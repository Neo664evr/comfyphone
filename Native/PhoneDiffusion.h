#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// All load/generate/unload calls must use a single serial worker. Cancel and status are thread-safe.
#define CPD_API __attribute__((visibility("default")))
CPD_API int cpd_load(const char *denoiser, const char *encoder, const char *vae, int cpu_only);
CPD_API int cpd_generate(const char *prompt, int width, int height, int64_t seed, const char *png_path);
CPD_API void cpd_unload(void);
CPD_API void cpd_cancel(void);
CPD_API int cpd_progress(void);
CPD_API void cpd_status(char *buffer, int capacity);
CPD_API uint64_t cpd_available_memory(void);
CPD_API int cpd_loaded(void);
#ifdef __cplusplus
}
#endif
