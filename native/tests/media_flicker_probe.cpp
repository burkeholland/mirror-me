// SPDX-License-Identifier: GPL-3.0-or-later
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <atomic>

int WINAPI observeBackgroundPaint(HDC, const RECT *, HBRUSH);
// Inspect the real window between background drawing and video drawing.
#define FillRect observeBackgroundPaint
#undef NOMINMAX
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wsubobject-linkage"
#include "../media.cpp"
#pragma GCC diagnostic pop
#undef FillRect

#include <fstream>
#include <iterator>

namespace {
std::atomic<HWND> observedWindow{nullptr};
std::atomic<bool> observing{false};
std::atomic<unsigned> observations{0}, flashes{0}, errors{0};

bool isFixturePixel(COLORREF color) {
    return color != CLR_INVALID && std::abs(int(GetRValue(color)) - 21) <= 3 &&
        std::abs(int(GetGValue(color)) - 112) <= 3 &&
        std::abs(int(GetBValue(color)) - 195) <= 3;
}

COLORREF windowPixel(HWND window, bool corner = false) {
    RECT client{};
    GetClientRect(window, &client);
    HDC dc = GetDC(window);
    COLORREF color = GetPixel(dc, corner ? 2 : client.right / 2, corner ? 2 : client.bottom / 2);
    ReleaseDC(window, dc);
    return color;
}

void flickerEvent(void *, int kind, const char *message) {
    if (kind == MM_EVENT_ERROR) {
        ++errors;
        std::fprintf(stderr, "ERROR: %s\n", message);
    }
}
}

int WINAPI observeBackgroundPaint(HDC dc, const RECT *rect, HBRUSH brush) {
    const int result = ::FillRect(dc, rect, brush);
    if (observing) {
        GdiFlush();
        if (HWND window = observedWindow.load()) {
            ++observations;
            if (!isFixturePixel(windowPixel(window))) ++flashes;
        }
    }
    return result;
}

int main() {
    std::ifstream file("receiver\\tests\\blue-frame.h264", std::ios::binary);
    std::vector<unsigned char> fixture{std::istreambuf_iterator<char>(file), {}};
    if (fixture.empty()) return 1;
    mm_receiver_config config{};
    config.width = 1920;
    config.height = 1080;
    config.max_fps = 60;
    char error[512]{};
    mm_media *media = mm_media_create(&config, flickerEvent, nullptr, error, sizeof(error));
    if (!media) {
        std::fprintf(stderr, "CREATE ERROR: %s\n", error);
        return 1;
    }
    mm_media_test_stats stats{};
    mm_media_test_snapshot(media, &stats);
    HWND window = reinterpret_cast<HWND>(stats.window);
    SetWindowTextW(window, L"MirrorMe - generated display regression");
    observedWindow = window;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!mm_media_rendered_frames(media) && std::chrono::steady_clock::now() < deadline) {
        mm_media_push_video(media, fixture.data(), fixture.size(), 0);
        Sleep(20);
    }
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 720, 540, SWP_NOMOVE | SWP_NOACTIVATE);
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
    bool passed = mm_media_rendered_frames(media) && isFixturePixel(windowPixel(window));
    observing = true;
    const uint64_t before = mm_media_rendered_frames(media);
    for (unsigned i = 0; i < 60 && passed; ++i) {
        passed = mm_media_push_video(media, fixture.data(), fixture.size(), 0) == 0;
        RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
        Sleep(20);
    }
    observing = false;
    // Fence the window thread before inspecting the counters or resizing.
    SendMessageW(window, WM_NULL, 0, 0);
    std::printf("Mid-paint window samples: %u; incomplete/black frames: %u; new video frames: %llu\n",
        observations.load(), flashes.load(),
        static_cast<unsigned long long>(mm_media_rendered_frames(media) - before));
    passed = passed && observations >= 60 && flashes == 0 && mm_media_rendered_frames(media) >= before + 30;
    const DWORD handles = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
    for (unsigned i = 0; i < 40; ++i) {
        SetWindowPos(window, nullptr, 0, 0, 720 + (i % 4) * 20, 540 + (i % 3) * 20,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
        passed = passed && isFixturePixel(windowPixel(window)) && windowPixel(window, true) == RGB(0, 0, 0);
    }
    const DWORD after = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
    passed = passed && after <= handles + 1 && errors == 0;
    mm_media_destroy(media);
    passed = passed && !IsWindow(window);
    std::printf("%s: uninterrupted real-window pixels, retained letterboxing, bounded resize resources, teardown.\n",
        passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
