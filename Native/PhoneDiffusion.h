#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// All load/generate/unload calls must use a single serial worker. Cancel and status are thread-safe.
int cpd_load(const char *denoiser, const char *encoder, const char *vae, int cpu_only);
int cpd_generate(const char *prompt, int width, int height, int64_t seed, const char *png_path);
void cpd_unload(void);
void cpd_cancel(void);
int cpd_progress(void);
void cpd_status(char *buffer, int capacity);
uint64_t cpd_available_memory(void);
int cpd_loaded(void);
#ifdef __cplusplus
}
#endif
