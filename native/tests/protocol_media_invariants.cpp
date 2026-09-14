// SPDX-License-Identifier: GPL-3.0-or-later
// Include the host implementation only in this test translation unit to invoke
// its real private RAOP callbacks without exposing test hooks in the public ABI.
#include "../receiver.cpp"
#include <fstream>
#include <functional>
#include <iterator>
#include <thread>

namespace {
void check(bool passed, const char *message) {
    if (!passed) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        ExitProcess(1);
    }
}
bool wait_until(const std::function<bool()> &ready, DWORD milliseconds = 5000) {
    const ULONGLONG deadline = GetTickCount64() + milliseconds;
    while (!ready() && GetTickCount64() < deadline) Sleep(2);
    return ready();
}
struct Observed {
    std::atomic<unsigned> received{0}, streaming{0}, ended{0}, connecting{0}, errors{0}, paused{0};
    std::atomic<bool> block_streaming{false}, streaming_entered{false};
    std::mutex mutex;
    std::vector<int> ordered;
};
void observed_event(void *context, int kind, const char *) {
    auto &observed = *static_cast<Observed *>(context);
    {
        std::lock_guard<std::mutex> lock(observed.mutex);
        observed.ordered.push_back(kind);
    }
    if (kind == MM_EVENT_CONNECTING) ++observed.connecting;
    if (kind == MM_EVENT_VIDEO_RECEIVED) ++observed.received;
    if (kind == MM_EVENT_SESSION_ENDED) ++observed.ended;
    if (kind == MM_EVENT_ERROR) ++observed.errors;
    if (kind == MM_EVENT_PAUSED) ++observed.paused;
    if (kind == MM_EVENT_STREAMING) {
        ++observed.streaming;
        if (observed.block_streaming) {
            observed.streaming_entered = true;
            check(wait_until([&] { return !observed.block_streaming; }),
                  "bounded application callback blocker");
        }
    }
}
}

int main() {
    std::ifstream input(PROTOCOL_VIDEO_FIXTURE, std::ios::binary);
    std::vector<unsigned char> fixture((std::istreambuf_iterator<char>(input)), {});
    check(fixture.size() > 20, "real H.264 fixture");
    mm_receiver_config config{};
    config.name = "MirrorMe host lifecycle test";
    config.device_id = "02:4D:4D:00:00:03";
    config.key_path = "unused-host-media-test.key";
    config.width = 0; config.height = 0; config.max_fps = 0;
    Observed observed;
    char error[256]{};
    mm_receiver *receiver = mm_receiver_create(&config, observed_event, &observed, error, sizeof(error));
    check(receiver != nullptr, "host creation");
    check(receiver->config.width == 1920 && receiver->config.height == 1080 &&
          receiver->config.max_fps == 60, "automatic configuration normalized before real media creation");
    check(config.width == 0 && config.height == 0 && config.max_fps == 0,
          "automatic normalization does not mutate caller-owned configuration");
    receiver->media = mm_media_create(&receiver->config, media_event, receiver, error, sizeof(error));
    if (!receiver->media) std::fprintf(stderr, "Media startup: %.255s\n", error);
    check(receiver->media != nullptr, "real media initialization");
    auto c = callbacks(receiver);
    auto push = [&](uint64_t timestamp) {
        video_decode_struct packet{};
        packet.data = fixture.data();
        packet.data_len = static_cast<int>(fixture.size());
        packet.ntp_time_local = timestamp;
        c.video_process(c.cls, nullptr, &packet);
    };

    mm_protocol_session(receiver, 1, 1);
    check(c.video_set_codec(c.cls, VIDEO_CODEC_H264) == 0,
          "host correctly maps the real media zero-success codec ABI");
    observed.block_streaming = true;
    push(get_local_time());
    check(wait_until([&] { return observed.streaming_entered.load(); }),
          "a real decoded frame enters the host STREAMING callback");
    std::atomic<bool> reset_returned{false};
    std::thread ending([&] { mm_protocol_session(receiver, 1, 3); reset_returned = true; });
    Sleep(50);
    check(!reset_returned && observed.ended == 0,
          "session end waits for the old in-flight media callback");
    observed.block_streaming = false;
    check(wait_until([&] { return reset_returned.load(); }), "owner reset fence completes");
    ending.join();
    check(observed.streaming == 1 && observed.ended == 1,
          "old callback completes before SESSION_ENDED");

    mm_protocol_session(receiver, 2, 1);
    check(c.video_set_codec(c.cls, VIDEO_CODEC_H264) == 0, "replacement codec setup");
    push(get_local_time() + 180000000ULL);
    mm_protocol_session(receiver, 2, 3);
    mm_protocol_session(receiver, 3, 1);
    Sleep(250);
    check(observed.streaming == 1 && observed.ended == 2 && observed.connecting == 3,
          "delayed old decode/render cannot publish after end or replacement connecting");
    check(c.video_set_codec(c.cls, VIDEO_CODEC_H264) == 0, "new session codec setup");
    for (int i = 0; i < 4 && observed.streaming == 1; ++i) {
        push(get_local_time());
        Sleep(35);
    }
    check(wait_until([&] { return observed.streaming == 2; }),
          "replacement only streams after its own newly decoded frame");
    mm_protocol_session(receiver, 3, 3);
    check(observed.errors == 0, "no codec ABI mismatch or media errors");
    const unsigned accepted_before_rejection = observed.received;
    mm_protocol_session(receiver, 4, 1);
    unsigned char truncated[] = {0, 0, 0, 1};
    video_decode_struct rejected{};
    rejected.data = truncated;
    rejected.data_len = sizeof(truncated);
    rejected.ntp_time_local = get_local_time();
    c.video_process(c.cls, nullptr, &rejected);
    check(wait_until([&] { return observed.errors == 1; }), "media rejects the truncated packet");
    check(observed.received == accepted_before_rejection && observed.streaming == 2,
          "rejected first packet never announces VIDEO_RECEIVED or STREAMING");
    mm_protocol_session(receiver, 4, 3);
    {
        std::lock_guard<std::mutex> lock(observed.mutex);
        int last_lifecycle = 0;
        unsigned stream_count = 0;
        for (int kind : observed.ordered) {
            if (kind == MM_EVENT_CONNECTING || kind == MM_EVENT_SESSION_ENDED) last_lifecycle = kind;
            if (kind == MM_EVENT_STREAMING) {
                check(last_lifecycle == MM_EVENT_CONNECTING, "STREAMING never follows an ended session");
                ++stream_count;
            }
        }
        check(stream_count == 2, "exact real presentation event count");
    }
    mm_protocol_session(receiver, 5, 1);
    check(c.video_set_codec(c.cls, VIDEO_CODEC_H264) == 0, "pause session codec setup");
    observed.streaming_entered = false;
    observed.block_streaming = true;
    push(get_local_time());
    check(wait_until([&] { return observed.streaming_entered.load(); }), "pause fence starts with real presentation");
    std::atomic<bool> pause_returned{false};
    std::thread pausing([&] { c.video_pause(c.cls); pause_returned = true; });
    Sleep(50);
    check(!pause_returned && observed.paused == 0, "PAUSED waits for the old in-flight presentation callback");
    observed.block_streaming = false;
    check(wait_until([&] { return pause_returned.load(); }), "pause presentation fence completes");
    pausing.join();
    c.video_pause(c.cls);
    check(observed.paused == 1 && !receiver->first_video && receiver->paused,
          "duplicate pause emits once and clears live presentation state");
    const unsigned received_before_resume = observed.received;
    c.video_resume(c.cls);
    c.video_resume(c.cls);
    Sleep(40);
    check(observed.streaming == 3 && observed.received == received_before_resume,
          "resume alone does not claim new video or streaming");
    push(get_local_time());
    check(wait_until([&] { return observed.streaming == 4; }) &&
          observed.received == received_before_resume + 1,
          "same protocol session resumes through new acceptance and actual presentation");
    mm_protocol_session(receiver, 5, 3);
    c.video_pause(c.cls);
    check(observed.paused == 1, "ended sessions cannot publish a stale pause");
    check(observed.errors == 1, "pause and resume introduce no media errors");
    mm_media_destroy(receiver->media);
    receiver->media = nullptr;
    mm_receiver_destroy(receiver);
    std::puts("PASS: host/media generation fence, delayed-frame/rejected-packet suppression, zero-success codec ABI");
    std::puts("PASS: pause presentation fence, idempotent callbacks and same-session resume");
    std::puts("Synthetic local H.264 injection only; no physical AirPlay-device claim.");
}
