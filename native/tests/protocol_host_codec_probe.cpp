// SPDX-License-Identifier: GPL-3.0-or-later
#include "../receiver.cpp"

namespace {
void check(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        ExitProcess(1);
    }
}
void discard_event(void *, int, const char *) {}
}

int main() {
    mm_receiver_config config{};
    config.name = "MirrorMe VIDEO codec boundary";
    config.device_id = "02:4D:4D:00:00:04";
    config.key_path = "unused-codec-boundary.key";
    config.allow_h265 = 0;
    char error[256]{};
    auto *receiver = mm_receiver_create(&config, discard_event, nullptr, error, sizeof(error));
    check(receiver != nullptr, "real host constructor");
    receiver->media = mm_media_create(&receiver->config, media_event, receiver, error, sizeof(error));
    check(receiver->media != nullptr, "real media initialization with embedded ID1 icon");

    check(mm_media_set_video_codec(receiver->media, 0) == 0, "actual VIDEO export returns zero for H264");
    check(mm_media_set_video_codec(receiver->media, 1) == -1, "actual VIDEO export rejects disabled HEVC with minus one");
    auto callbacks = ::callbacks(receiver);
    check(callbacks.video_set_codec(callbacks.cls, VIDEO_CODEC_H264) == 0,
          "real host-to-media H264 callback returns zero");
    check(callbacks.video_set_codec(callbacks.cls, VIDEO_CODEC_H265) == -1,
          "real host callback rejects disabled HEVC with minus one");
    check(callbacks.video_set_codec(callbacks.cls, VIDEO_CODEC_UNKNOWN) == -1,
          "real host callback rejects an unsupported codec");

    mm_media_destroy(receiver->media);
    receiver->media = nullptr;
    mm_receiver_destroy(receiver);
    std::puts("PASS: actual VIDEO export and host callback agree: H264=0, disabled HEVC=-1; no Boolean inversion.");
}
