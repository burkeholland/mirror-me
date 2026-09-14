// SPDX-License-Identifier: GPL-3.0-or-later
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include "../include/media.h"
#include "../media_internal.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <fstream>
#include <functional>
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
        if (!wake.wait_for(lock, std::chrono::seconds(90), [this] { return done; })) {
            std::fprintf(stderr, "FAIL: probe exceeded the 90-second deadline.\n");
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
    std::atomic<unsigned> accepted{0}, streaming{0}, ended{0}, errors{0}, unexpected{0}, notices{0};
    std::atomic<unsigned> lateStreams{0};
    std::atomic<bool> expectError{false}, destroyOnStreaming{false}, selfDestroyReturned{false};
    std::atomic<bool> sessionEnded{false}, blockStreaming{false}, streamingEntered{false};
    std::atomic<mm_media *> media{nullptr};
    static void callback(void *context, int kind, const char *message) {
        auto &state = *static_cast<Events *>(context);
        switch (kind) {
        case MM_EVENT_VIDEO_RECEIVED: ++state.accepted; break;
        case MM_EVENT_STREAMING:
            if (state.sessionEnded) ++state.lateStreams;
            ++state.streaming;
            if (state.blockStreaming) {
                state.streamingEntered = true;
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
                while (state.blockStreaming && std::chrono::steady_clock::now() < deadline) Sleep(1);
            }
            if (state.destroyOnStreaming && state.media) {
                mm_media_destroy(state.media);
                state.selfDestroyReturned = true;
            }
            break;
        case MM_EVENT_SESSION_ENDED: state.sessionEnded = true; ++state.ended; break;
        case MM_EVENT_NOTICE: ++state.notices; std::printf("NOTICE: %s\n", message); break;
        case MM_EVENT_ERROR:
            ++state.errors;
            if (!state.expectError) ++state.unexpected;
            std::fprintf(stderr, "%s: %s\n", state.expectError ? "EXPECTED ERROR" : "ERROR", message);
            break;
        }
    }
};

unsigned failures = 0;
void check(bool pass, const char *name) {
    std::printf("%s: %s\n", pass ? "PASS" : "FAIL", name);
    if (!pass) ++failures;
}

uint64_t nowNs() {
    FILETIME time{};
    GetSystemTimePreciseAsFileTime(&time);
    ULARGE_INTEGER ticks{};
    ticks.LowPart = time.dwLowDateTime;
    ticks.HighPart = time.dwHighDateTime;
    return (ticks.QuadPart - 116444736000000000ULL) * 100;
}

bool waitFor(const std::function<bool()> &condition, unsigned milliseconds = 2000) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
    while (!condition() && std::chrono::steady_clock::now() < end) Sleep(5);
    return condition();
}

std::vector<unsigned char> read(const char *path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

bool render(mm_media *media, const std::vector<unsigned char> &fixture, unsigned count,
    uint64_t timestamp = 0) {
    const uint64_t target = mm_media_rendered_frames(media) + count;
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(4);
    while (mm_media_rendered_frames(media) < target && std::chrono::steady_clock::now() < end) {
        auto copy = fixture;
        if (mm_media_push_video(media, copy.data(), copy.size(), timestamp ? timestamp : nowNs()) != 0) return false;
        std::fill(copy.begin(), copy.end(), 0xff);
        Sleep(20);
    }
    return mm_media_rendered_frames(media) >= target;
}

HWND nativeWindow(mm_media *media) {
    mm_media_test_stats stats{};
    mm_media_test_snapshot(media, &stats);
    return reinterpret_cast<HWND>(stats.window);
}

COLORREF pixel(HWND window, bool corner = false) {
    RECT client{};
    GetClientRect(window, &client);
    HDC dc = GetDC(window);
    COLORREF color = GetPixel(dc, corner ? 3 : client.right / 2, corner ? 3 : client.bottom / 2);
    ReleaseDC(window, dc);
    return color;
}

bool blue(COLORREF color) {
    // The original fixture is RGB 21,112,195 according to independent FFmpeg
    // decoding; the landscape fixture is pure blue. Allow matrix rounding.
    const bool original = std::abs(int(GetRValue(color)) - 21) <= 3 &&
        std::abs(int(GetGValue(color)) - 112) <= 3 && std::abs(int(GetBValue(color)) - 195) <= 3;
    const bool landscape = GetBValue(color) > 245 && GetRValue(color) < 5 && GetGValue(color) < 5;
    return color != CLR_INVALID && (original || landscape);
}

bool capture(HWND window) {
    RECT client{};
    GetClientRect(window, &client);
    HDC source = GetDC(window);
    HDC memory = CreateCompatibleDC(source);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = client.right;
    info.bmiHeader.biHeight = -client.bottom;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(source, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    HGDIOBJ previous = bitmap ? SelectObject(memory, bitmap) : nullptr;
    bool result = bitmap && BitBlt(memory, 0, 0, client.right, client.bottom, source, 0, 0, SRCCOPY);
    if (result) {
        const DWORD bytes = DWORD(client.right) * DWORD(client.bottom) * 4;
        BITMAPFILEHEADER header{};
        header.bfType = 0x4d42;
        header.bfOffBits = sizeof(header) + sizeof(BITMAPINFOHEADER);
        header.bfSize = header.bfOffBits + bytes;
        std::ofstream file("build\\native-media-check\\window-readback.bmp", std::ios::binary);
        file.write(reinterpret_cast<const char *>(&header), sizeof(header));
        file.write(reinterpret_cast<const char *>(&info.bmiHeader), sizeof(info.bmiHeader));
        file.write(static_cast<const char *>(pixels), bytes);
        result = bool(file);
    }
    if (previous) SelectObject(memory, previous);
    if (bitmap) DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(window, source);
    return result;
}

std::vector<size_t> nalStarts(const std::vector<unsigned char> &bytes, unsigned type) {
    std::vector<size_t> starts;
    for (size_t i = 0; i + 3 < bytes.size(); ++i) {
        if (bytes[i] || bytes[i + 1]) continue;
        unsigned prefix = bytes[i + 2] == 1 ? 3 :
            i + 4 < bytes.size() && bytes[i + 2] == 0 && bytes[i + 3] == 1 ? 4 : 0;
        if (prefix && (bytes[i + prefix] & 31) == type) starts.push_back(i);
        if (prefix) i += prefix - 1;
    }
    return starts;
}

mm_media *create(Events &events, bool audio = true, bool hardware = false, bool hevc = false,
    unsigned width = 1080, unsigned height = 1920) {
    mm_receiver_config config{};
    config.width = width;
    config.height = height;
    config.max_fps = 60;
    config.audio_enabled = audio;
    config.hardware_decode = hardware;
    config.allow_h265 = hevc;
    char error[512]{};
    mm_media *media = mm_media_create(&config, Events::callback, &events, error, sizeof(error));
    if (!media) std::fprintf(stderr, "CREATE ERROR: %s\n", error);
    events.media = media;
    return media;
}
}

int main(int argc, char **argv) {
    Watchdog watchdog;
    const bool iconOnly = argc > 1 && std::string(argv[1]) == "--icon-only";
    const auto fixture = read(argc > 1 && !iconOnly ? argv[1] : "receiver\\tests\\blue-frame.h264");
    const auto landscape = read(argc > 2 && !iconOnly ? argv[2] : "build\\native-media-check\\landscape.h264");
    check(!fixture.empty() && !landscape.empty(), "original synthetic blue H.264 and generated landscape fixtures load");
    if (fixture.empty() || landscape.empty()) return 1;
    Events events;
    mm_media *media = create(events, true, true, false, 3840, 2160);
    check(media != nullptr, "native COM/window/MF decoder startup");
    if (!media) return 1;
    Sleep(100);
    check(events.streaming == 0 && mm_media_rendered_frames(media) == 0, "no streaming event before a real frame");
    check(events.notices > 0, "hardware preference has an honest software-fallback notice");
    HWND window = nativeWindow(media);
    wchar_t title[128]{};
    GetWindowTextW(window, title, 128);
    check(std::wstring(title) == L"MirrorMe - iPhone screen", "native window title is exact");
    HICON expected = static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101),
        IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_SHARED));
    if (!expected) expected = static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1),
        IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_SHARED));
    check(expected && reinterpret_cast<HICON>(SendMessageW(window, WM_GETICON, ICON_BIG, 0)) == expected,
        "window uses the genuine embedded app icon (ID101 or Wails ID1)");
    if (iconOnly) {
        mm_media_destroy(media);
        check(!IsWindow(window) && events.unexpected == 0, "app-icon fallback probe shuts down cleanly");
        return failures ? 1 : 0;
    }
    check(mm_media_test_video_layout(3840, 2160, 3840, 12441600) &&
        mm_media_test_video_layout(2160, 3840, 2160, 12441600),
        "4K allocation bounds accept both landscape and portrait independently of negotiated orientation");
    check(!mm_media_test_video_layout(8194, 2, 8194, 24582) &&
        !mm_media_test_video_layout(8192, 8192, 8192, 100663296) &&
        !mm_media_test_video_layout(3840, 2160, 0x7fffffff, 12441600) &&
        !mm_media_test_video_layout(3840, 2160, 3840, size_t(1) << 31),
        "dimension, total-pixel, stride and decoder-buffer limits reject before allocation");
    bool decoded = render(media, fixture, 30);
    check(decoded, "30 actual H.264 frames decode/render; input memory can immediately change");
    check(events.accepted == 1 && events.streaming == 1, "acceptance precedes one true presentation event");
    mm_media_show_window(media);
    Sleep(80);
    const COLORREF center = pixel(window);
    std::printf("READBACK: center RGB=%u,%u,%u; rendered=%llu\n",
        GetRValue(center), GetGValue(center), GetBValue(center),
        static_cast<unsigned long long>(mm_media_rendered_frames(media)));
    check(blue(center), "GDI readback is the fixture's blue decoded pixel, not a placeholder");
    SetWindowPos(window, HWND_TOP, 0, 0, 760, 430, SWP_NOMOVE);
    Sleep(100);
    check(blue(pixel(window)) && pixel(window, true) == RGB(0, 0, 0), "resize preserves aspect ratio with black letterboxing");
    check(capture(window), "actual native-window pixel evidence saved to build\\native-media-check\\window-readback.bmp");
    InvalidateRect(window, nullptr, TRUE);
    SendMessageW(window, WM_PAINT, 0, 0);
    check(blue(pixel(window)), "expose repaints the retained decoded frame");
    check(render(media, landscape, 3), "SPS resolution/orientation change decodes");
    RECT client{};
    GetClientRect(window, &client);
    check(client.right > client.bottom && blue(pixel(window)), "native window reorients to a landscape decoded frame");
    const auto idr = nalStarts(fixture, 5);
    check(!idr.empty(), "original fixture contains an actual IDR NAL");
    if (!idr.empty()) {
        std::vector<unsigned char> slices(fixture.begin() + idr.front(), fixture.end());
        mm_media_push_video(media, fixture.data(), idr.front(), nowNs());
        Sleep(20);
        check(render(media, slices, 2), "separate SPS/PPS update takes effect on the next IDR without a reset");
        GetClientRect(window, &client);
        check(client.bottom > client.right, "separately delivered SPS reorients the native window back to portrait");
        mm_media_flush_video(media);
        check(render(media, slices, 2), "video flush retains parameter sets for the next bare IDR");
    }
    for (const auto &size : std::vector<std::pair<unsigned, unsigned>>{{3840, 2160}, {2160, 3840}}) {
        const auto highResolution = read(size.first > size.second
            ? "build\\native-media-check\\landscape-4k.h264" : "build\\native-media-check\\portrait-4k.h264");
        mm_media_reset(media);
        const uint64_t baseline = mm_media_rendered_frames(media);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        mm_media_test_stats presented{};
        while (!highResolution.empty() && std::chrono::steady_clock::now() < deadline) {
            mm_media_push_video(media, highResolution.data(), highResolution.size(), nowNs());
            Sleep(80);
            mm_media_test_snapshot(media, &presented);
            if (presented.rendered >= baseline + 2 && presented.presented_width == size.first &&
                presented.presented_height == size.second) break;
        }
        const bool presentedSize = presented.rendered >= baseline + 2 && presented.presented_width == size.first &&
            presented.presented_height == size.second;
        check(presentedSize, size.first > size.second
            ? "actual 3840x2160 4K frames reach successful native presentation"
            : "actual 2160x3840 4K portrait frames reach successful native presentation");
        mm_media_show_window(media);
        Sleep(30);
        const COLORREF color = pixel(window);
        GetClientRect(window, &client);
        const bool orientation = size.first > size.second ? client.right > client.bottom : client.bottom > client.right;
        check(presentedSize && orientation && color != CLR_INVALID &&
            GetBValue(color) > 200 && GetRValue(color) < 30 && GetGValue(color) < 30,
            "4K evidence is native-window pixel readback with matching orientation, not decoder-output count");
    }
    mm_media_reset(media);
    check(render(media, fixture, 2), "session reset restores portrait video");

    mm_media_set_volume(media, -144.0f);
    mm_media_test_stats stats{};
    mm_media_test_snapshot(media, &stats);
    check(stats.volume == 0, "AirPlay -144 dB is exact mute");
    mm_media_set_volume(media, -6.0f);
    mm_media_test_snapshot(media, &stats);
    check(std::fabs(stats.volume - 0.501187f) < 0.0001f, "AirPlay decibels convert to linear amplitude");
    mm_media_set_volume(media, 10.0f);
    mm_media_test_snapshot(media, &stats);
    check(stats.volume == 1, "positive AirPlay volume clamps to unity");
    mm_media_set_volume(media, -144.0f);
    check(mm_media_configure_audio(media, 0x4d4d, 441, 0) == 0, "probe-only synthetic audio decoder configuration accepted");
    for (unsigned i = 0; i < 25; ++i) {
        unsigned char packet = 42;
        mm_media_push_audio(media, &packet, 1, nowNs());
        packet = 0;
        Sleep(10);
    }
    mm_media_test_snapshot(media, &stats);
    std::printf("AUDIO: %llu real WASAPI submitted silent PCM frames at 44100 Hz/stereo.\n",
        static_cast<unsigned long long>(stats.audio_submitted));
    check(stats.audio_submitted >= 4410, "actual WASAPI default output consumes copied S16 PCM with Windows rate conversion");
    mm_media_flush_audio(media);
    mm_media_pause(media, 1);
    check(mm_media_push_video(media, fixture.data(), fixture.size(), nowNs()) < 0, "paused media rejects video without accumulating latency");
    mm_media_pause(media, 0);
    check(render(media, fixture, 2), "pause/flush/resume recovers real video");

    const unsigned beforeClock = events.notices;
    check(render(media, fixture, 2, nowNs() + 3600ULL * 1000000000),
        "one-hour future timestamps cannot hold video indefinitely");
    Sleep(550);
    check(render(media, fixture, 2, 1), "ancient timestamps reset to local time instead of holding stale video");
    mm_media_test_snapshot(media, &stats);
    check(stats.clock_resets >= 2 && events.notices >= beforeClock + 2, "shared A/V timeline resets emit explicit clock notices");

    events.expectError = true;
    const unsigned beforeErrors = events.errors;
    check(mm_media_push_video(media, fixture.data(), 4 * 1024 * 1024 + 1, nowNs()) < 0,
        "oversized video packet rejects before reading caller memory");
    check(mm_media_push_audio(media, fixture.data(), 64 * 1024 + 1, nowNs()) < 0,
        "oversized audio packet rejects before reading caller memory");
    const unsigned char malformed[] = {0, 0, 0, 1, 0x80, 0x42, 0x01};
    mm_media_push_video(media, malformed, sizeof(malformed), nowNs());
    check(waitFor([&] { return events.errors >= beforeErrors + 3; }), "malformed/oversized video and audio produce explicit errors");
    check(mm_media_set_video_codec(media, 1) < 0, "disabled HEVC explicitly fails instead of claiming support");
    waitFor([&] { return events.errors >= beforeErrors + 4; });
    events.expectError = false;
    mm_media_reset(media);
    check(render(media, fixture, 2), "malformed input and reset do not poison subsequent valid decoding");

    const auto gop = read("build\\native-media-check\\inter-frames.h264");
    const auto accessUnits = nalStarts(gop, 9);
    check(accessUnits.size() >= 40, "synthetic H.264 inter-frame fixture contains 40 access units");
    if (accessUnits.size() >= 40) {
        mm_media_reset(media);
        const uint64_t baseline = mm_media_rendered_frames(media);
        mm_media_test_snapshot(media, &stats);
        const uint64_t allocationsBefore = stats.output_allocations;
        uint64_t maximumPaintDelay = 0;
        uint64_t sampledRendered = baseline;
        for (size_t i = 0; i < accessUnits.size(); ++i) {
            const size_t end = i + 1 == accessUnits.size() ? gop.size() : accessUnits[i + 1];
            mm_media_push_video(media, gop.data() + accessUnits[i], end - accessUnits[i], nowNs());
            Sleep(17);
            mm_media_test_snapshot(media, &stats);
            if (stats.rendered > sampledRendered) {
                maximumPaintDelay = std::max(maximumPaintDelay, stats.receive_to_paint_ns);
                sampledRendered = stats.rendered;
            }
        }
        check(waitFor([&] { return mm_media_rendered_frames(media) >= baseline + 35; }),
            "native MFT correctly decodes a real I/P-frame sequence, not just repeated IDRs");
        check(stats.output_allocations - allocationsBefore <= 3,
            "40-frame playback reuses decoded output storage instead of allocating it on every drain");
        check(maximumPaintDelay < 80 * 1000000ULL,
            "fresh generated frames reach the native paint operation within 80 ms of receiver input");
        std::printf("LATENCY: 1080x1920 at 60 FPS, maximum receive-to-paint %.2f ms; %llu decoded-output allocations for 40 inputs.\n",
            maximumPaintDelay / 1000000.0,
            static_cast<unsigned long long>(stats.output_allocations - allocationsBefore));

        mm_media_reset(media);
        auto pushUnit = [&](size_t i, uint64_t timestamp) {
            const size_t end = i + 1 == accessUnits.size() ? gop.size() : accessUnits[i + 1];
            mm_media_push_video(media, gop.data() + accessUnits[i], end - accessUnits[i], timestamp);
            Sleep(34);
        };
        const uint64_t beforePause = mm_media_rendered_frames(media);
        for (size_t i = 0; i < 8; ++i) pushUnit(i, nowNs());
        check(waitFor([&] { return mm_media_rendered_frames(media) >= beforePause + 6; }),
            "inter-frame pause regression starts with actual video");
        mm_media_pause(media, 1);
        mm_media_pause(media, 1);
        mm_media_test_snapshot(media, &stats);
        check(waitFor([&] { return !IsWindowVisible(reinterpret_cast<HWND>(stats.window)); }),
            "pause hides the last phone image rather than leaving a frozen live window");
        const uint64_t pausedFrames = mm_media_rendered_frames(media);
        Sleep(120);
        check(mm_media_rendered_frames(media) == pausedFrames, "paused presentation stays stopped");
        mm_media_pause(media, 0);
        for (size_t i = 8; i < 18; ++i) {
            pushUnit(i, nowNs());
            mm_media_pause(media, 0);
        }
        check(waitFor([&] { return mm_media_rendered_frames(media) >= pausedFrames + 8; }),
            "resume and repeated resume retain P-frame references without waiting for another IDR");
        check(IsWindowVisible(reinterpret_cast<HWND>(stats.window)), "fresh resumed frames restore the video window");
        const uint64_t beforeReanchor = mm_media_rendered_frames(media);
        for (size_t i = 18; i < 26; ++i)
            pushUnit(i, nowNs() + (i == 18 ? 3600ULL * 1000000000 : 0));
        check(waitFor([&] { return mm_media_rendered_frames(media) >= beforeReanchor + 6; }),
            "a wake-time clock correction retains decoder references");

        mm_media_reset(media);
        events.streamingEntered = false;
        events.blockStreaming = true;
        pushUnit(0, nowNs());
        check(waitFor([&] { return events.streamingEntered.load(); }), "error-fence fixture holds presentation");
        const unsigned errorsBeforePause = events.errors;
        events.expectError = true;
        mm_media_push_video(media, fixture.data(), 4, nowNs());
        std::atomic<bool> pauseFinished{false};
        std::thread pausing([&] { mm_media_pause(media, 1); pauseFinished = true; });
        Sleep(30);
        check(!pauseFinished, "pause waits for the in-flight presentation callback");
        events.blockStreaming = false;
        pausing.join();
        check(events.errors == errorsBeforePause + 1, "pause preserves queued errors instead of silently discarding them");
        events.expectError = false;

        mm_media_reset(media);
        events.streamingEntered = false;
        events.blockStreaming = true;
        pushUnit(0, nowNs());
        check(waitFor([&] { return events.streamingEntered.load(); }), "backlog fixture holds the real presentation callback");
        mm_media_test_snapshot(media, &stats);
        const uint64_t skippedBefore = stats.skipped_conversion;
        const uint64_t convertedBefore = stats.converted;
        for (size_t i = 1; i < 13; ++i) {
            const size_t end = accessUnits[i + 1];
            mm_media_push_video(media, gop.data() + accessUnits[i], end - accessUnits[i], nowNs());
        }
        Sleep(120);
        events.blockStreaming = false;
        check(waitFor([&] {
            mm_media_test_snapshot(media, &stats);
            return stats.video_packets == 0 && stats.skipped_conversion >= skippedBefore + 11 &&
                stats.converted == convertedBefore + 1;
        }), "outdated queued P-frames are decoded without unnecessary color conversion");
        check(stats.converted == convertedBefore + 1,
            "catch-up converts only the newest queued picture, preserving static-screen updates");
        const uint64_t caughtUp = mm_media_rendered_frames(media);
        for (size_t i = 13; i < 23; ++i) pushUnit(i, nowNs());
        check(waitFor([&] { return mm_media_rendered_frames(media) >= caughtUp + 8; }),
            "catch-up preserves the reference chain and immediately displays fresh P-frames");
    }
    mm_media_reset(media);
    for (unsigned i = 0; i < 2000; ++i)
        mm_media_push_video(media, fixture.data(), fixture.size(), nowNs());
    mm_media_test_snapshot(media, &stats);
    check(stats.video_packets <= 48 && stats.video_bytes <= 12 * 1024 * 1024 && stats.dropped > 0,
        "a 2000-packet burst drops old queued input instead of accumulating latency");
    mm_media_reset(media);

    std::atomic<bool> producing{true};
    std::thread producer([&] {
        while (producing) {
            mm_media_push_video(media, fixture.data(), fixture.size(), nowNs());
            unsigned char audio = 42;
            mm_media_push_audio(media, &audio, 1, nowNs());
            Sleep(1);
        }
    });
    bool bounded = true;
    for (unsigned i = 0; i < 40; ++i) {
        mm_media_flush_audio(media);
        mm_media_flush_video(media);
        if (i % 4 == 0) mm_media_reset(media);
        mm_media_test_snapshot(media, &stats);
        bounded &= stats.video_packets <= 48 && stats.video_bytes <= 12 * 1024 * 1024 &&
            stats.audio_packets <= 64 && stats.audio_bytes <= 512 * 1024;
        Sleep(3);
    }
    producing = false;
    producer.join();
    check(bounded, "concurrent input/reset/flush retains strict packet and byte bounds");
    mm_media_reset(media);
    check(render(media, fixture, 2), "decoder recovers after reset during packet traffic");

    mm_media_reset(media);
    events.streamingEntered = false;
    events.blockStreaming = true;
    mm_media_push_video(media, fixture.data(), fixture.size(), nowNs());
    check(waitFor([&] { return events.streamingEntered.load(); }), "generation-barrier probe enters a real streaming callback");
    std::vector<unsigned char> maximumPacket(4 * 1024 * 1024, 0xff);
    std::copy(fixture.begin(), fixture.end(), maximumPacket.begin());
    maximumPacket[fixture.size()] = maximumPacket[fixture.size() + 1] = 0;
    maximumPacket[fixture.size() + 2] = 1;
    maximumPacket[fixture.size() + 3] = 12;
    maximumPacket.back() = 0x80;
    mm_media_test_snapshot(media, &stats);
    const uint64_t previouslyDropped = stats.dropped;
    for (unsigned i = 0; i < 4; ++i)
        mm_media_push_video(media, maximumPacket.data(), maximumPacket.size(), nowNs());
    mm_media_test_snapshot(media, &stats);
    check(stats.video_packets == 1 && stats.video_bytes == maximumPacket.size() &&
        stats.dropped >= previouslyDropped + 3,
        "12 MiB byte limit flushes before the packet-count limit when four 4 MiB packets arrive");
    std::atomic<bool> resetReturned{false};
    std::thread resetting([&] { mm_media_reset(media); resetReturned = true; });
    Sleep(40);
    check(!resetReturned, "owner reset waits for the in-flight old-session callback to finish");
    events.blockStreaming = false;
    resetting.join();
    check(resetReturned, "owner reset completes after old callback and decoder work are quiescent");
    const unsigned streamedBeforeReplacement = events.streaming;
    mm_media_push_video(media, fixture.data(), fixture.size(), nowNs() + 180000000);
    Sleep(25);
    mm_media_reset(media);
    Sleep(220);
    check(events.streaming == streamedBeforeReplacement,
        "a delayed decoded old-session frame cannot announce streaming after replacement reset");
    check(render(media, fixture, 2), "replacement session only streams after its own new real frame");

    std::atomic<bool> closingTraffic{true};
    std::atomic<unsigned> closedRejections{0};
    std::thread closeProducer([&] {
        while (closingTraffic) {
            if (mm_media_push_video(media, fixture.data(), fixture.size(), nowNs()) < 0) ++closedRejections;
            Sleep(1);
        }
    });
    PostMessageW(window, WM_CLOSE, 0, 0);
    check(waitFor([&] { return events.ended == 1; }), "user window close emits session ended");
    Sleep(80);
    closingTraffic = false;
    closeProducer.join();
    check(closedRejections > 0 && events.lateStreams == 0,
        "old producer traffic after window close cannot resurrect streaming past session ended");
    check(!IsWindowVisible(window), "user-closed window stays hidden until a new decoded session");
    mm_media_reset(media);
    events.sessionEnded = false;
    check(render(media, fixture, 2), "owner reset reopens acceptance for a genuine replacement session");
    mm_media_destroy(media);
    check(!IsWindow(window), "destroy joins threads and destroys the owned native window");
    check(events.unexpected == 0, "normal playback has no hidden decoder/display/audio failures");

    bool cycles = true;
    for (unsigned cycle = 0; cycle < 10; ++cycle) {
        Events next;
        mm_media *instance = create(next, false);
        if (!instance) { cycles = false; break; }
        cycles &= next.streaming == 0 && render(instance, fixture, 1);
        mm_media_reset(instance);
        cycles &= render(instance, fixture, 1);
        mm_media_destroy(instance);
        cycles &= next.unexpected == 0;
    }
    check(cycles, "10 complete create/decode/reset/decode/destroy cycles finish without hangs");

    Events codecEvents;
    codecEvents.expectError = true;
    mm_media *codecInstance = create(codecEvents, false, false, true);
    if (codecInstance) {
        if (mm_media_set_video_codec(codecInstance, 1) == 0) {
            codecEvents.expectError = false;
            const auto hevc = read("build\\native-media-check\\hevc.h265");
            check(!hevc.empty() && render(codecInstance, hevc, 2),
                "installed Windows HEVC software decoder presents real synthetic HEVC");
            check(codecEvents.unexpected == 0, "enabled HEVC has no decoder errors");
        } else {
            check(waitFor([&] { return codecEvents.errors > 0 && codecEvents.notices > 0; }),
                "unavailable optional HEVC produces an actionable capability notice and error");
        }
        mm_media_destroy(codecInstance);
    } else check(false, "optional HEVC capability probe startup");

    Events reentrant;
    mm_media *instance = create(reentrant, false);
    if (instance) {
        reentrant.destroyOnStreaming = true;
        mm_media_push_video(instance, fixture.data(), fixture.size(), nowNs());
        check(waitFor([&] { return reentrant.selfDestroyReturned.load(); }),
            "destroy requested from presentation callback returns without joining itself");
        mm_media_destroy(instance);
        check(true, "owner subsequently reclaims callback-stopped instance without detached threads");
    } else check(false, "reentrant shutdown test startup");
    std::printf("RESULT: %u failure(s). Synthetic fixtures only; this does not establish physical iPhone compatibility.\n", failures);
    return failures ? 1 : 0;
}
