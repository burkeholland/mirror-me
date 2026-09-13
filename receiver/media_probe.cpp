// SPDX-License-Identifier: GPL-3.0-or-later
#include <gst/gst.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <vector>
#include "renderers/video_renderer.h"
#include "media_fixture.h"

namespace {
std::atomic<bool> displayed{false};
std::atomic<bool> failed{false};
GPrintFunc previous_print = nullptr;

void probe_print(const gchar *text) {
    if (std::strstr(text, "MIRRORME_STREAMING\n")) displayed.store(true);
    if (std::strstr(text, "MIRRORME_RECEIVER_ERROR:")) failed.store(true);
    if (previous_print) previous_print(text);
    else std::fputs(text, stdout);
}

void probe_log(void *, int level, const char *text) {
    if (std::strstr(text, "MIRRORME_RECEIVER_ERROR:")) failed.store(true);
    std::fprintf(level <= LOGGER_WARNING ? stderr : stdout, "%s\n", text);
}

void dispatch() {
    while (g_main_context_pending(nullptr)) g_main_context_iteration(nullptr, FALSE);
}
}

int run_media_probe(bool window, bool software, bool broken) {
    GError *error = nullptr;
    if (!gst_init_check(nullptr, nullptr, &error)) {
        std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: media probe initialization failed: %s\n",
                     error ? error->message : "unknown error");
        g_clear_error(&error);
        return 1;
    }
    previous_print = g_set_print_handler(probe_print);
    auto *logger = logger_init();
    logger_set_level(logger, LOGGER_INFO);
    logger_set_callback(logger, probe_log, nullptr);
    videoflip_t flip[2] = {NONE, NONE};
    video_renderer_init(logger, "MirrorMe video check (generated test pattern)", flip,
        "h264parse", "", broken ? "avdec_h264 ! identity error-after=1" : software ? "avdec_h264" : "decodebin",
        "videoconvert", window ? "autovideosink" : "fakesink", "", false, false, false, false, 3, nullptr);
    video_renderer_start();
    GMainLoop *loop = g_main_loop_new(nullptr, FALSE);
    const guint bus_watch = video_renderer_listen(loop, 0);
    bool valid = video_renderer_choose_codec(false, false) == 0;
    const auto start = g_get_monotonic_time();
    // A selected codec or a PLAYING pipeline alone must not claim video.
    while (valid && g_get_monotonic_time() - start < 250000) {
        dispatch();
        g_usleep(10000);
    }
    valid = valid && !displayed.load();
    guint64 frames = 0;
    for (int index = 0; valid && !failed.load() && index < 120; ++index) {
        auto data = std::vector<unsigned char>(std::begin(media_fixture), std::end(media_fixture));
        int length = static_cast<int>(data.size());
        int nals = 1;
        uint64_t timestamp = static_cast<uint64_t>(g_get_real_time()) * 1000;
        video_renderer_render_buffer(data.data(), &length, &nals, &timestamp);
        dispatch();
        frames = video_renderer_frames_rendered();
        if (frames >= 3 && (!window || displayed.load())) break;
        g_usleep(33333);
    }
    dispatch();
    valid = valid && !failed.load() && frames >= 3 && (window ? displayed.load() : !displayed.load());
    g_source_remove(bus_watch);
    video_renderer_stop();
    video_renderer_destroy();
    dispatch();
    g_main_loop_unref(loop);
    logger_destroy(logger);
    g_set_print_handler(previous_print);
    if (valid) {
        std::printf("MIRRORME_MEDIA_TEST_OK frames=%llu output=%s decoder=%s\n",
            static_cast<unsigned long long>(frames), window ? "window" : "test-sink", software ? "software" : "automatic");
        std::puts("Generated video only; this does not test AirPlay pairing or a physical iPhone.");
    } else {
        std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: media test failed (frames=%llu, displayed=%d, pipeline_error=%d)\n",
            static_cast<unsigned long long>(frames), displayed.load(), failed.load());
    }
    gst_deinit();
    return valid ? 0 : 1;
}
