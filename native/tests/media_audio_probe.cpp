// SPDX-License-Identifier: GPL-3.0-or-later
// Real static audio decoder -> media worker -> actual WASAPI endpoint probe.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include "../media_internal.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
struct Watchdog {
    std::mutex mutex;
    std::condition_variable wake;
    bool done = false;
    std::thread thread;
    Watchdog() : thread([this] {
        std::unique_lock<std::mutex> lock(mutex);
        if (!wake.wait_for(lock, std::chrono::seconds(45), [this] { return done; })) {
            std::fprintf(stderr, "FAIL: audio integration exceeded its 45-second deadline.\n");
            TerminateProcess(GetCurrentProcess(), 124);
        }
    }) {}
    ~Watchdog() {
        { std::lock_guard<std::mutex> lock(mutex); done = true; }
        wake.notify_one();
        thread.join();
    }
};
struct Events {
    std::atomic<unsigned> errors{0}, streaming{0};
    static void callback(void *context, int kind, const char *message) {
        auto &events = *static_cast<Events *>(context);
        if (kind == MM_EVENT_ERROR) {
            ++events.errors;
            std::fprintf(stderr, "ERROR: %s\n", message);
        }
        if (kind == MM_EVENT_STREAMING) ++events.streaming;
    }
};
uint64_t now() {
    FILETIME value{};
    GetSystemTimePreciseAsFileTime(&value);
    ULARGE_INTEGER ticks{};
    ticks.LowPart = value.dwLowDateTime;
    ticks.HighPart = value.dwHighDateTime;
    return (ticks.QuadPart - 116444736000000000ULL) * 100;
}
struct Packet { std::vector<unsigned char> bytes; unsigned frames; };
struct Fixture {
    unsigned codec, spp, rate, channels;
    uint64_t format, frames;
    std::vector<Packet> packets;
};
bool load(const char *name, Fixture &fixture) {
    const std::string path = std::string("native\\tests\\audio_fixtures\\") + name + ".mma";
    std::ifstream file(path, std::ios::binary);
    std::vector<unsigned char> data{std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
    if (data.size() < 48 || std::memcmp(data.data(), "MMAUDIO1", 8)) return false;
    size_t offset = 8;
    bool valid = true;
    auto integer = [&](unsigned width) {
        uint64_t value = 0;
        if (offset + width > data.size()) { valid = false; return value; }
        for (unsigned i = 0; i < width; ++i) value |= uint64_t(data[offset++]) << (8 * i);
        return value;
    };
    fixture.codec = unsigned(integer(4));
    fixture.spp = unsigned(integer(4));
    fixture.rate = unsigned(integer(4));
    fixture.channels = unsigned(integer(4));
    fixture.format = integer(8);
    fixture.frames = integer(8);
    const size_t cookie = integer(4), count = integer(4);
    if (!valid || cookie > 128 || count > 1024 || offset + cookie > data.size()) return false;
    offset += cookie;
    for (size_t i = 0; i < count; ++i) {
        const size_t length = integer(4);
        const unsigned frames = unsigned(integer(4));
        if (!valid || length > 65536 || offset + length > data.size()) return false;
        fixture.packets.push_back({{data.begin() + offset, data.begin() + offset + length}, frames});
        offset += length;
    }
    return offset == data.size() && fixture.rate > 0;
}
}

int main() {
    Watchdog watchdog;
    Events events;
    mm_receiver_config config{};
    config.audio_enabled = 1;
    char error[512]{};
    mm_media *media = mm_media_create(&config, Events::callback, &events, error, sizeof(error));
    if (!media) { std::fprintf(stderr, "FAIL: %s\n", error); return 1; }
    mm_media_set_volume(media, -144);
    unsigned failures = 0;
    const char *names[] = {"alac-44100-16-352", "alac-48000-24", "aac-lc-44100",
        "aac-lc-48000-adts", "aac-eld-44100-480", "aac-eld-48000-512"};
    for (const char *name : names) {
        Fixture fixture{};
        if (!load(name, fixture)) { std::fprintf(stderr, "FAIL: read fixture %s\n", name); ++failures; continue; }
        mm_media_reset(media);
        mm_media_test_stats before{}, after{};
        mm_media_test_snapshot(media, &before);
        const unsigned errorCount = events.errors;
        if (mm_media_configure_audio(media, fixture.codec, fixture.spp, fixture.format) != 0) ++failures;
        for (const auto &packet : fixture.packets) {
            auto owned = packet.bytes;
            if (mm_media_push_audio(media, owned.data(), owned.size(), now()) != 0) ++failures;
            std::fill(owned.begin(), owned.end(), 0xff);
            Sleep(std::max(1U, (packet.frames * 1000 + fixture.rate - 1) / fixture.rate));
        }
        const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        do {
            mm_media_test_snapshot(media, &after);
            if (after.audio_submitted - before.audio_submitted >= fixture.frames || events.errors != errorCount) break;
            Sleep(5);
        } while (std::chrono::steady_clock::now() < end);
        const uint64_t submitted = after.audio_submitted - before.audio_submitted;
        const bool pass = submitted == fixture.frames && events.errors == errorCount;
        std::printf("%s: %s -> actual WASAPI S16 %u Hz/%u channels: %llu/%llu frames (muted)\n",
            pass ? "PASS" : "FAIL", name, fixture.rate, fixture.channels,
            static_cast<unsigned long long>(submitted), static_cast<unsigned long long>(fixture.frames));
        if (!pass) ++failures;
        mm_media_flush_audio(media);
    }
    if (events.streaming) { std::fprintf(stderr, "FAIL: audio alone must not claim video streaming.\n"); ++failures; }
    mm_media_destroy(media);
    std::printf("RESULT: %u failure(s); production static ALAC/AAC-LC/AAC-ELD decoder and real WASAPI, no stub.\n", failures);
    return failures ? 1 : 0;
}
