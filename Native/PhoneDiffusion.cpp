#include "PhoneDiffusion.h"
#include "stable-diffusion.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <os/proc.h>
#include <atomic>
#include <mutex>
#include <string>
#include <cstring>
#include <cstdio>
#include <exception>
#include <algorithm>

namespace {
std::mutex context_mutex, message_mutex;
sd_ctx_t *context = nullptr;
std::atomic<int> progress{0};
std::atomic<bool> cancel_requested{false};
std::string message = "No image model loaded";
void status(const std::string &s) { std::lock_guard<std::mutex> lock(message_mutex); message = s; }
void log_callback(sd_log_level_t level, const char *text, void *) {
    if (level >= SD_LOG_INFO && text) status(text);
}
void progress_callback(int step, int steps, float, void *) {
    progress = steps > 0 ? step * 100 / steps : 0;
    status("Denoising " + std::to_string(step) + "/" + std::to_string(steps));
}
bool save_png(const sd_image_t &image, const char *path) {
    if (!image.data || (image.channel != 3 && image.channel != 4)) return false;
    auto provider = CGDataProviderCreateWithData(nullptr, image.data, size_t(image.width) * image.height * image.channel, nullptr);
    auto color = CGColorSpaceCreateDeviceRGB();
    auto bitmap = image.channel == 4 ? kCGImageAlphaLast : kCGImageAlphaNone;
    auto cg = CGImageCreate(image.width, image.height, 8, 8 * image.channel,
                            image.width * image.channel, color, bitmap, provider, nullptr, false, kCGRenderingIntentDefault);
    auto url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8 *)path, strlen(path), false);
    auto destination = url ? CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr) : nullptr;
    bool success = false;
    if (destination && cg) { CGImageDestinationAddImage(destination, cg, nullptr); success = CGImageDestinationFinalize(destination); }
    if (destination) CFRelease(destination);
    if (url) CFRelease(url);
    if (cg) CGImageRelease(cg);
    CGColorSpaceRelease(color);
    CGDataProviderRelease(provider);
    return success;
}
}

uint64_t cpd_available_memory() { return os_proc_available_memory(); }
int cpd_progress() { return progress.load(); }
void cpd_status(char *buffer, int capacity) {
    if (!buffer || capacity < 1) return;
    std::lock_guard<std::mutex> lock(message_mutex);
    snprintf(buffer, size_t(capacity), "%s", message.c_str());
}
int cpd_loaded() { std::lock_guard<std::mutex> lock(context_mutex); return context != nullptr; }
void cpd_cancel() {
    cancel_requested = true;
    std::lock_guard<std::mutex> lock(context_mutex);
    if (context) sd_cancel_generation(context, SD_CANCEL_ALL);
}
void cpd_unload() {
    std::lock_guard<std::mutex> lock(context_mutex);
    if (context) free_sd_ctx(context);
    context = nullptr;
    progress = 0;
    status("Image model unloaded");
}
int cpd_load(const char *denoiser, const char *encoder, const char *vae, int cpu_only) {
    cpd_unload();
    cancel_requested = false;
    const uint64_t available = cpd_available_memory();
    // This is a conservative minimum, NOT a claim that the model will fit. The actual iOS
    // process allowance is queried, not the phone's advertised physical RAM.
    if (available < (uint64_t(3) << 30)) { status("Not enough current app memory: need at least 3 GiB free. Close other apps and unload chat."); return 0; }
    sd_set_log_callback(log_callback, nullptr);
    sd_set_progress_callback(progress_callback, nullptr);
    sd_ctx_params_t params;
    sd_ctx_params_init(&params);
    params.diffusion_model_path = denoiser;
    params.llm_path = encoder;
    params.vae_path = vae;
    params.n_threads = 4;
    params.enable_mmap = true;
    params.flash_attn = true;
    params.diffusion_flash_attn = true;
    params.conditioning_cache_size = 0;
    params.disable_prefetch = true;
    params.eager_load = false;
    params.auto_fit = false;
    params.backend = cpu_only ? "cpu" : "metal";
    // Both GGUFs together exceed a typical iOS process budget. Never eagerly retain all
    // weights: segment execution reloads them from app-local files on demand.
    params.params_backend = "disk";
    params.model_args = "qwen_image_2_1_prefix_cache=false";
    params.rng_type = CPU_RNG;
    params.sampler_rng_type = CPU_RNG;
    char budget[32];
    const double gib = std::min(3.0, double(available - (uint64_t(1) << 30)) / double(uint64_t(1) << 30));
    snprintf(budget, sizeof(budget), "%.2f", gib);
    params.max_vram = budget;
    try {
        status("Loading Qwen Image 2.1 components (disk-offloaded weights)…");
        auto loaded = new_sd_ctx(&params);
        if (!loaded) { status("Native model load failed. Check all three components and runtime diagnostics."); return 0; }
        const char *version = sd_get_model_version_name(loaded);
        if (!version || std::string(version).find("2.1") == std::string::npos || !sd_ctx_supports_image_generation(loaded)) {
            free_sd_ctx(loaded); status("Wrong diffusion architecture: expected Qwen Image 2.1"); return 0;
        }
        if (cancel_requested) { free_sd_ctx(loaded); status("Load cancelled after native loader returned"); return 0; }
        { std::lock_guard<std::mutex> lock(context_mutex); context = loaded; }
        status("Qwen Image 2.1 Turbo loaded · weights streamed from disk");
        return 1;
    } catch (const std::exception &e) { status(std::string("Native load error: ") + e.what()); return 0; }
}
int cpd_generate(const char *prompt, int width, int height, int64_t seed, const char *png_path) {
    sd_ctx_t *ctx;
    { std::lock_guard<std::mutex> lock(context_mutex); ctx = context; }
    if (!ctx) { status("Load the three image components first"); return 0; }
    if (!prompt || !*prompt || width < 256 || height < 256 || width > 768 || height > 768 || width % 32 || height % 32) {
        status("Use a prompt and 256–768 pixel dimensions divisible by 32"); return 0;
    }
    if (cpd_available_memory() < (uint64_t(1) << 30)) { status("Low memory before generation; unload and close other apps"); return 0; }
    progress = 0;
    cancel_requested = false;
    sd_cancel_generation(ctx, SD_CANCEL_RESET);
    sd_img_gen_params_t params;
    sd_img_gen_params_init(&params);
    params.prompt = prompt;
    params.negative_prompt = "";
    params.width = width; params.height = height; params.seed = seed; params.batch_count = 1;
    params.sample_params.sample_method = EULER_SAMPLE_METHOD;
    params.sample_params.sample_steps = 8;
    params.sample_params.guidance.txt_cfg = 1.0f;
    params.sample_params.guidance.distilled_guidance = 1.0f;
    params.sample_params.flow_shift = 1.0f;
    float sigmas[] = {1.f, .978453f, .95418f, .926626f, .89508f, .845148f, .704534f, .414568f, 0.f};
    params.sample_params.custom_sigmas = sigmas;
    params.sample_params.custom_sigmas_count = 9;
    params.vae_tiling_params.enabled = true;
    params.vae_tiling_params.tile_size_w = 256;
    params.vae_tiling_params.tile_size_h = 256;
    params.vae_tiling_params.target_overlap = .25f;
    sd_image_t *images = nullptr;
    int count = 0;
    try {
        const bool generated = generate_image(ctx, &params, &images, &count);
        const bool saved = generated && !cancel_requested && count > 0 && save_png(images[0], png_path);
        if (images) free_sd_images(images, count);
        if (cancel_requested) { status("Cancelled · no partial result saved"); return 0; }
        if (!saved) { status("Generation or PNG encoding failed. See runtime diagnostics; smaller sizes may reduce memory."); return 0; }
        progress = 100;
        status("Saved PNG · entirely on iPhone");
        return 1;
    } catch (const std::exception &e) {
        if (images) free_sd_images(images, count);
        status(std::string("Native generation error: ") + e.what()); return 0;
    }
}
