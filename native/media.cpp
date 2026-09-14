// SPDX-License-Identifier: GPL-3.0-or-later
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <wmcodecdsp.h>
#include <codecapi.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <ks.h>
#include <ksmedia.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <system_error>
#include <thread>
#include <vector>
#include "include/media.h"
#include "include/audio_decode.h"
#ifdef MM_MEDIA_TESTING
#include "media_internal.h"
#endif

namespace {
constexpr size_t maxVideoPacket = 4 * 1024 * 1024;
constexpr size_t maxVideoBytes = 12 * 1024 * 1024;
constexpr size_t maxAudioPacket = 64 * 1024;
constexpr size_t maxAudioBytes = 512 * 1024;
constexpr uint64_t maxDecodedPixels = 33554432;
constexpr uint64_t maxDecodedNV12Bytes = 64 * 1024 * 1024;
constexpr uint64_t millisecond = 1000000;
constexpr uint64_t maxVideoQueueAge = 80 * millisecond;
constexpr UINT frameMessage = WM_APP + 31;
constexpr UINT clearMessage = WM_APP + 32;
constexpr UINT showMessage = WM_APP + 33;
constexpr UINT stopMessage = WM_APP + 34;
constexpr UINT hideMessage = WM_APP + 35;
constexpr wchar_t windowClass[] = L"MirrorMe.NativeVideo.1";
constexpr IID codecApiID = {0x901db4c7, 0x31ce, 0x41a2, {0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda}};

uint64_t clockNs() {
    LARGE_INTEGER ticks{}, frequency{};
    QueryPerformanceCounter(&ticks);
    QueryPerformanceFrequency(&frequency);
    return uint64_t(ticks.QuadPart / frequency.QuadPart) * 1000000000ULL +
        uint64_t(ticks.QuadPart % frequency.QuadPart) * 1000000000ULL / frequency.QuadPart;
}

uint64_t wallClockNs() {
    FILETIME time{};
    GetSystemTimePreciseAsFileTime(&time);
    ULARGE_INTEGER ticks{};
    ticks.LowPart = time.dwLowDateTime;
    ticks.HighPart = time.dwHighDateTime;
    return (ticks.QuadPart - 116444736000000000ULL) * 100;
}

bool videoLayoutAllowed(UINT32 width, UINT32 height, LONG stride) {
    return width && height && width <= 8192 && height <= 8192 && !(width & 1) && !(height & 1) &&
        uint64_t(width) * height <= maxDecodedPixels && stride >= LONG(width) &&
        uint64_t(stride) * height * 3 / 2 <= maxDecodedNV12Bytes;
}

void copyError(char *out, size_t capacity, const std::string &message) {
    if (out && capacity) {
        const size_t count = std::min(capacity - 1, message.size());
        std::memcpy(out, message.data(), count);
        out[count] = 0;
    }
}

std::string hrError(const char *operation, HRESULT result) {
    char code[32];
    std::snprintf(code, sizeof(code), " (HRESULT 0x%08lX)", static_cast<unsigned long>(result));
    return std::string(operation) + code;
}

template<class T> class Com {
    T *value = nullptr;
public:
    Com() = default;
    ~Com() { reset(); }
    Com(const Com &) = delete;
    Com &operator=(const Com &) = delete;
    T *get() const { return value; }
    T *operator->() const { return value; }
    T **put() { reset(); return &value; }
    void reset(T *next = nullptr) { if (value) value->Release(); value = next; }
    explicit operator bool() const { return value != nullptr; }
};

struct ComApartment {
    HRESULT result;
    explicit ComApartment(DWORD mode) : result(CoInitializeEx(nullptr, mode)) {}
    ~ComApartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};

struct Packet {
    std::vector<unsigned char> bytes;
    uint64_t timestamp = 0;
    uint64_t epoch = 0;
    uint64_t decoderEpoch = 0;
    uint64_t received = 0;
};

struct Frame {
    std::vector<unsigned char> pixels;
    unsigned width = 0, height = 0;
    uint64_t timestamp = 0, epoch = 0, id = 0;
    uint64_t received = 0;
};

struct Event {
    int kind;
    std::string message;
    uint64_t session, videoEpoch;
};

struct AudioConfig {
    unsigned codec = 0, samples = 0;
    uint64_t format = 0;
    bool configured = false;
};

class PaintBuffer {
    HDC memory = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ original = nullptr;
    LONG width = 0, height = 0;
public:
    PaintBuffer() = default;
    ~PaintBuffer() { reset(); }
    PaintBuffer(const PaintBuffer &) = delete;
    PaintBuffer &operator=(const PaintBuffer &) = delete;
    HDC dc() const { return memory; }
    bool prepare(HDC source, LONG nextWidth, LONG nextHeight) {
        if (nextWidth <= 0 || nextHeight <= 0 ||
            uint64_t(nextWidth) * uint64_t(nextHeight) > maxDecodedPixels) return false;
        if (bitmap && width == nextWidth && height == nextHeight) return true;
        if (!memory) memory = CreateCompatibleDC(source);
        if (!memory) return false;
        HBITMAP next = CreateCompatibleBitmap(source, nextWidth, nextHeight);
        if (!next) return false;
        HGDIOBJ previous = SelectObject(memory, next);
        if (!previous || previous == HGDI_ERROR) {
            DeleteObject(next);
            return false;
        }
        if (!original) original = previous;
        if (bitmap) DeleteObject(bitmap);
        bitmap = next;
        width = nextWidth;
        height = nextHeight;
        return true;
    }
    void reset() {
        if (memory) {
            if (original) SelectObject(memory, original);
            if (bitmap) DeleteObject(bitmap);
            DeleteDC(memory);
        }
        memory = nullptr;
        bitmap = nullptr;
        original = nullptr;
        width = height = 0;
    }
};
}

struct mm_media {
    mm_receiver_config config{};
    mm_event_callback callback = nullptr;
    void *context = nullptr;
    std::thread worker, windowThread;
    std::atomic<bool> stopping{false};
    std::atomic<bool> hevcAvailable{false};
    std::atomic<HWND> window{nullptr};
    std::atomic<uint64_t> rendered{0}, audioSubmitted{0}, clockResets{0}, dropped{0};
    std::atomic<uint64_t> converted{0}, skippedConversion{0}, outputAllocations{0}, receiveToPaint{0};
    std::atomic<unsigned> presentedWidth{0}, presentedHeight{0};
    std::atomic<uint64_t> videoEpoch{1}, decoderEpoch{1};
    std::atomic<uint64_t> presentationFloor{0};
    std::atomic<float> volume{1.0f};
    std::mutex mutex;
    std::condition_variable wake, initialized, resetDone;
    std::deque<Packet> videoPackets, audioPackets;
    std::deque<Event> events;
    size_t videoBytes = 0, audioBytes = 0;
    uint64_t audioEpoch = 1, codecVersion = 1, audioVersion = 1, session = 1;
    uint64_t resetRequested = 0, resetCompleted = 0;
    uint64_t lastClockReset = 0, lastVideoDropNotice = 0, clockWallAnchor = 0, clockMonoAnchor = 0;
    bool hevc = false, paused = false, accepted = false, sessionClosed = false;
    bool workerReady = false, windowReady = false;
    std::string workerError, windowError;
    AudioConfig audioConfig;
    std::mutex frameMutex;
    std::shared_ptr<Frame> pendingFrame, displayedFrame;
    bool framePosted = false;
    uint64_t presentedID = 0;
    std::atomic<uint64_t> streamingSession{0};
    unsigned lastWidth = 0, lastHeight = 0;
    PaintBuffer paintBuffer;

    void emit(int kind, const std::string &message) {
        // Never hold a media lock over application callbacks.
        if (callback) callback(context, kind, message.c_str());
    }
    void eventLocked(int kind, const std::string &message, uint64_t epoch = 0) {
        if (events.size() == 16) {
            auto expendable = std::find_if(events.begin(), events.end(), [](const Event &event) {
                return event.kind != MM_EVENT_SESSION_ENDED && event.kind != MM_EVENT_VIDEO_RECEIVED &&
                    event.kind != MM_EVENT_STREAMING;
            });
            if (expendable == events.end()) return;
            events.erase(expendable);
        }
        events.push_back({kind, message, session, epoch});
        wake.notify_one();
    }
    void error(const std::string &message) {
        std::lock_guard<std::mutex> lock(mutex);
        eventLocked(MM_EVENT_ERROR, message);
    }
    void clearVideoLocked() {
        dropped += videoPackets.size();
        videoPackets.clear();
        videoBytes = 0;
        ++videoEpoch;
        ++decoderEpoch;
    }
    void clearAudioLocked() {
        dropped += audioPackets.size();
        audioPackets.clear();
        audioBytes = 0;
        ++audioEpoch;
    }
    uint64_t timestampLocked(uint64_t timestamp) {
        const uint64_t now = clockNs();
        const uint64_t wall = wallClockNs();
        if (!clockWallAnchor) {
            clockWallAnchor = wall;
            clockMonoAnchor = now;
        }
        const uint64_t expectedWall = clockWallAnchor + (now - clockMonoAnchor);
        const bool localJump = (wall > expectedWall ? wall - expectedWall : expectedWall - wall) > 250 * millisecond;
        if (!timestamp) return now;
        // The protocol has already mapped sender time to local UNIX nanoseconds.
        // Convert that local wall clock to one shared monotonic presentation
        // clock; never apply a sender/NTP offset here.
        const bool bad = timestamp > wall
            ? timestamp - wall > 250 * millisecond
            : wall - timestamp > 2000 * millisecond;
        if (bad || localJump) {
            if (localJump || !lastClockReset || now - lastClockReset > 500 * millisecond) {
                // Timing changes do not invalidate H.264 reference pictures.
                presentationFloor = now;
                clearAudioLocked();
                lastClockReset = now;
                clockWallAnchor = wall;
                clockMonoAnchor = now;
                ++clockResets;
                eventLocked(MM_EVENT_NOTICE,
                    "The sender's presentation clock jumped; the audio/video timeline was reset to local time.");
            }
            return now;
        }
        if (timestamp >= clockWallAnchor) return clockMonoAnchor + (timestamp - clockWallAnchor);
        const uint64_t delta = clockWallAnchor - timestamp;
        return delta < clockMonoAnchor ? clockMonoAnchor - delta : now;
    }
};

namespace {
void resetMedia(mm_media *media, bool closed = false) {
    uint64_t target;
    {
        std::lock_guard<std::mutex> lock(media->mutex);
        media->clearVideoLocked();
        media->clearAudioLocked();
        ++media->codecVersion;
        ++media->session;
        media->accepted = false;
        media->paused = false;
        media->presentationFloor = 0;
        media->sessionClosed = closed;
        media->lastClockReset = 0;
        media->clockWallAnchor = media->clockMonoAnchor = 0;
        media->events.clear();
        target = ++media->resetRequested;
        if (closed)
            media->eventLocked(MM_EVENT_SESSION_ENDED, "The iPhone video window was closed.");
    }
    if (HWND window = media->window.load()) PostMessageW(window, hideMessage, media->videoEpoch.load(), 0);
    media->wake.notify_one();
    const auto self = std::this_thread::get_id();
    if (self != media->worker.get_id() && self != media->windowThread.get_id()) {
        std::unique_lock<std::mutex> lock(media->mutex);
        media->resetDone.wait(lock, [&] { return media->resetCompleted >= target || media->stopping; });
    }
}

void resizeForFrame(mm_media *media, HWND window, const Frame &frame) {
    const bool first = !media->lastWidth;
    const bool orientation = (media->lastWidth > media->lastHeight) != (frame.width > frame.height);
    media->lastWidth = frame.width;
    media->lastHeight = frame.height;
    if (!first && !orientation) return;
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    if (GetWindowPlacement(window, &placement) && placement.showCmd == SW_SHOWMAXIMIZED) return;
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    RECT work{0, 0, 1280, 800};
    if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor))
        work = monitor.rcWork;
    double scale = std::min(1.0, std::min((work.right - work.left) * 0.8 / frame.width,
        (work.bottom - work.top) * 0.8 / frame.height));
    RECT bounds{0, 0, LONG(frame.width * scale), LONG(frame.height * scale)};
    AdjustWindowRectEx(&bounds, WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, FALSE, 0);
    SetWindowPos(window, nullptr, 0, 0, bounds.right - bounds.left, bounds.bottom - bounds.top,
        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

struct WindowIcons {
    HICON large = nullptr;
    HICON small = nullptr;
};

BOOL CALLBACK loadEmbeddedIcon(HMODULE module, LPCWSTR, LPWSTR name, LONG_PTR context) {
    auto &icons = *reinterpret_cast<WindowIcons *>(context);
    HICON large = static_cast<HICON>(LoadImageW(module, name, IMAGE_ICON,
        GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_SHARED));
    HICON small = static_cast<HICON>(LoadImageW(module, name, IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED));
    if (!large || !small) return TRUE;
    icons = {large, small};
    return FALSE;
}

LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto *media = reinterpret_cast<mm_media *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        media = static_cast<mm_media *>(reinterpret_cast<CREATESTRUCTW *>(lParam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(media));
    }
    if (!media) return DefWindowProcW(window, message, wParam, lParam);
    switch (message) {
    case frameMessage: {
        std::shared_ptr<Frame> frame;
        {
            std::lock_guard<std::mutex> lock(media->frameMutex);
            media->framePosted = false;
            frame = std::move(media->pendingFrame);
            if (frame && frame->epoch == media->videoEpoch.load()) media->displayedFrame = frame;
            else frame.reset();
        }
        if (frame) {
            resizeForFrame(media, window, *frame);
            if (!IsWindowVisible(window)) ShowWindow(window, SW_SHOWNOACTIVATE);
            InvalidateRect(window, nullptr, FALSE);
            UpdateWindow(window);
        }
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        HDC dc = BeginPaint(window, &paint);
        RECT client{};
        const bool haveClient = dc && GetClientRect(window, &client);
        std::shared_ptr<Frame> frame;
        {
            std::lock_guard<std::mutex> lock(media->frameMutex);
            frame = media->displayedFrame;
        }
        bool presented = false, failed = !haveClient;
        const bool drawable = haveClient && client.right > 0 && client.bottom > 0;
        if (drawable) {
            failed = !media->paintBuffer.prepare(dc, client.right, client.bottom);
            if (!failed)
                failed = !FillRect(media->paintBuffer.dc(), &client, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
        }
        const bool currentFrame = frame && frame->epoch == media->videoEpoch.load();
        if (drawable && !failed && currentFrame) {
            const double scale = std::min(double(client.right) / frame->width,
                double(client.bottom) / frame->height);
            const int width = std::max(1, int(frame->width * scale));
            const int height = std::max(1, int(frame->height * scale));
            BITMAPINFO bitmap{};
            bitmap.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            bitmap.bmiHeader.biWidth = frame->width;
            bitmap.bmiHeader.biHeight = -LONG(frame->height);
            bitmap.bmiHeader.biPlanes = 1;
            bitmap.bmiHeader.biBitCount = 32;
            bitmap.bmiHeader.biCompression = BI_RGB;
            HDC target = media->paintBuffer.dc();
            const bool stretchMode = SetStretchBltMode(target, COLORONCOLOR) != 0;
            const int result = StretchDIBits(target, (client.right - width) / 2, (client.bottom - height) / 2,
                width, height, 0, 0, frame->width, frame->height, frame->pixels.data(),
                &bitmap, DIB_RGB_COLORS, SRCCOPY);
            failed = !stretchMode || result == int(GDI_ERROR) || result == 0;
        }
        if (drawable && !failed) {
            // Publish the completed picture and letterboxing together. Erasing
            // the visible DC first exposes a black flash between video frames.
            failed = !BitBlt(dc, 0, 0, client.right, client.bottom,
                media->paintBuffer.dc(), 0, 0, SRCCOPY) || !GdiFlush();
            presented = !failed && currentFrame && frame->id != media->presentedID;
        }
        EndPaint(window, &paint);
        if (failed) media->error("Windows could not prepare or present the buffered video frame.");
        if (presented) {
            media->presentedID = frame->id;
            media->presentedWidth = frame->width;
            media->presentedHeight = frame->height;
            media->receiveToPaint = frame->received ? clockNs() - frame->received : 0;
            ++media->rendered;
            std::lock_guard<std::mutex> lock(media->mutex);
            if (!media->sessionClosed && frame->epoch == media->videoEpoch &&
                media->streamingSession != media->session)
                media->eventLocked(MM_EVENT_STREAMING,
                    "The first decoded iPhone video frame was presented.", frame->epoch);
        }
        return 0;
    }
    case WM_ERASEBKGND: return 1;
    case WM_SIZE:
        InvalidateRect(window, nullptr, FALSE);
        return 0;
    case clearMessage:
    case hideMessage:
        {
            std::lock_guard<std::mutex> lock(media->frameMutex);
            if (media->pendingFrame && media->pendingFrame->epoch < wParam) media->pendingFrame.reset();
            if (media->displayedFrame && media->displayedFrame->epoch < wParam) media->displayedFrame.reset();
            if (media->displayedFrame) return 0;
        }
        if (message == hideMessage) ShowWindow(window, SW_HIDE);
        else media->lastWidth = media->lastHeight = 0;
        InvalidateRect(window, nullptr, FALSE);
        return 0;
    case showMessage:
        {
            std::lock_guard<std::mutex> lock(media->mutex);
            if (media->paused || media->sessionClosed || !media->accepted) return 0;
        }
        ShowWindow(window, SW_RESTORE);
        SetForegroundWindow(window);
        return 0;
    case WM_CLOSE:
        if (!media->stopping) {
            ShowWindow(window, SW_HIDE);
            resetMedia(media, true);
        }
        return 0;
    case stopMessage:
        DestroyWindow(window);
        return 0;
    case WM_DESTROY:
        media->paintBuffer.reset();
        media->window = nullptr;
        PostQuitMessage(0);
        return 0;
    default: return DefWindowProcW(window, message, wParam, lParam);
    }
}

void windowMain(mm_media *media) {
    ComApartment apartment(COINIT_APARTMENTTHREADED);
    std::string error;
    HWND window = nullptr;
    HINSTANCE instance = GetModuleHandleW(nullptr);
    WindowIcons icons;
    loadEmbeddedIcon(instance, RT_GROUP_ICON, MAKEINTRESOURCEW(101), reinterpret_cast<LONG_PTR>(&icons));
    if (!icons.large)
        EnumResourceNamesW(instance, RT_GROUP_ICON, loadEmbeddedIcon, reinterpret_cast<LONG_PTR>(&icons));
    if (FAILED(apartment.result)) error = hrError("Video window COM initialization failed", apartment.result);
    else if (!icons.large || !icons.small) error = "The MirrorMe host is missing an embedded application icon resource.";
    else {
        WNDCLASSEXW windowType{};
        windowType.cbSize = sizeof(windowType);
        windowType.lpfnWndProc = windowProc;
        windowType.hInstance = instance;
        windowType.hIcon = icons.large;
        windowType.hIconSm = icons.small;
        windowType.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        windowType.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
        windowType.lpszClassName = windowClass;
        if (!RegisterClassExW(&windowType) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
            error = hrError("Registering the native video window failed", HRESULT_FROM_WIN32(GetLastError()));
        else {
            window = CreateWindowExW(0, windowClass, L"MirrorMe - iPhone screen",
                WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT, 720, 540,
                nullptr, nullptr, instance, media);
            if (!window) error = hrError("Creating the native video window failed", HRESULT_FROM_WIN32(GetLastError()));
            else {
                SendMessageW(window, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icons.large));
                SendMessageW(window, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icons.small));
                media->window = window;
            }
        }
    }
    {
        std::lock_guard<std::mutex> lock(media->mutex);
        media->windowError = error;
        media->windowReady = true;
    }
    media->initialized.notify_all();
    if (!window) return;
    MSG message{};
    int result;
    while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if (result == -1) {
        media->error(hrError("The native video message loop failed", HRESULT_FROM_WIN32(GetLastError())));
        DestroyWindow(window);
    }
}

bool enumDecoder(bool hevc, Com<IMFTransform> *decoder = nullptr) {
    MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264};
    IMFActivate **activations = nullptr;
    UINT32 count = 0;
    HRESULT result = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
        &input, nullptr, &activations, &count);
    bool found = false;
    if (SUCCEEDED(result)) {
        for (UINT32 i = 0; i < count; ++i) {
            if (!found) {
                Com<IMFTransform> candidate;
                if (SUCCEEDED(activations[i]->ActivateObject(IID_PPV_ARGS(candidate.put())))) {
                    found = true;
                    if (decoder) {
                        candidate->AddRef();
                        decoder->reset(candidate.get());
                    }
                }
            }
            activations[i]->Release();
        }
    }
    CoTaskMemFree(activations);
    return found;
}

class VideoDecoder {
    Com<IMFTransform> transform;
    Com<IMFMediaType> outputType;
    Com<IMFMediaBuffer> outputBuffer;
    DWORD outputCapacity = 0, outputAlignment = 0;
    mm_media *owner = nullptr;
    UINT32 width = 0, height = 0;
    LONG stride = 0;
    bool fullRange = false, bt709 = false;
    unsigned cropX = 0, cropY = 0, visibleWidth = 0, visibleHeight = 0;
    uint64_t frameSequence = 0;

    bool selectOutput(std::string &error, bool initial = false) {
        for (DWORD i = 0; i < 128; ++i) {
            Com<IMFMediaType> type;
            HRESULT result = transform->GetOutputAvailableType(0, i, type.put());
            if (initial && result == MF_E_TRANSFORM_TYPE_NOT_SET) return true;
            if (result == MF_E_NO_MORE_TYPES) break;
            if (FAILED(result)) { error = hrError("Enumerating decoded video formats failed", result); return false; }
            GUID subtype{};
            if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) || subtype != MFVideoFormat_NV12) continue;
            result = MFGetAttributeSize(type.get(), MF_MT_FRAME_SIZE, &width, &height);
            stride = static_cast<LONG>(MFGetAttributeUINT32(type.get(), MF_MT_DEFAULT_STRIDE, width));
            if (FAILED(result) || !videoLayoutAllowed(width, height, stride)) {
                error = "The decoded video format exceeds safe dimension, pixel-count, or row-storage limits. Reduce the sender resolution to 4K or lower.";
                return false;
            }
            // Validate metadata before SetOutputType can allocate decoder
            // surfaces, and before allocating any output or BGRA frame buffer.
            result = transform->SetOutputType(0, type.get(), 0);
            if (FAILED(result)) continue;
            fullRange = MFGetAttributeUINT32(type.get(), MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235) == MFNominalRange_0_255;
            bt709 = MFGetAttributeUINT32(type.get(), MF_MT_YUV_MATRIX,
                height > 576 ? MFVideoTransferMatrix_BT709 : MFVideoTransferMatrix_BT601) == MFVideoTransferMatrix_BT709;
            cropX = cropY = 0;
            visibleWidth = width;
            visibleHeight = height;
            MFVideoArea aperture{};
            UINT32 size = 0;
            if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE,
                reinterpret_cast<UINT8 *>(&aperture), sizeof(aperture), &size)) && size == sizeof(aperture) &&
                aperture.OffsetX.value >= 0 && aperture.OffsetY.value >= 0 &&
                aperture.Area.cx > 0 && aperture.Area.cy > 0 &&
                unsigned(aperture.OffsetX.value) + unsigned(aperture.Area.cx) <= width &&
                unsigned(aperture.OffsetY.value) + unsigned(aperture.Area.cy) <= height) {
                cropX = aperture.OffsetX.value;
                cropY = aperture.OffsetY.value;
                visibleWidth = aperture.Area.cx;
                visibleHeight = aperture.Area.cy;
            }
            type->AddRef();
            outputType.reset(type.get());
            return true;
        }
        error = "The Windows video decoder cannot produce NV12 frames. H.264 software decoding is required.";
        return false;
    }

    static unsigned char clamp(int value) { return static_cast<unsigned char>(std::max(0, std::min(255, value))); }

    std::shared_ptr<Frame> convert(IMFSample *sample, const Packet &packet,
        std::string &error) {
        DWORD total = 0;
        HRESULT result = sample->GetTotalLength(&total);
        if (FAILED(result) || !total || total > maxDecodedNV12Bytes) {
            error = "Windows returned an invalid or oversized decoded video buffer.";
            return {};
        }
        Com<IMFMediaBuffer> buffer;
        result = sample->ConvertToContiguousBuffer(buffer.put());
        if (FAILED(result)) { error = hrError("Reading the decoded video buffer failed", result); return {}; }
        BYTE *data = nullptr;
        DWORD length = 0;
        result = buffer->Lock(&data, nullptr, &length);
        if (FAILED(result)) { error = hrError("Locking the decoded video buffer failed", result); return {}; }
        if (uint64_t(stride) * height * 3 / 2 > length) {
            buffer->Unlock();
            error = "Windows returned a truncated decoded NV12 frame.";
            return {};
        }
        struct Unlock {
            IMFMediaBuffer *buffer;
            ~Unlock() { buffer->Unlock(); }
        } unlock{buffer.get()};
        auto frame = std::make_shared<Frame>();
        frame->width = visibleWidth;
        frame->height = visibleHeight;
        frame->pixels.resize(size_t(visibleWidth) * visibleHeight * 4);
        frame->epoch = packet.epoch;
        frame->received = packet.received;
        frame->id = ++frameSequence;
        LONGLONG time = 0;
        frame->timestamp = SUCCEEDED(sample->GetSampleTime(&time)) && time >= 0
            ? uint64_t(time) * 100 : packet.timestamp;
        const BYTE *uv = data + size_t(stride) * height;
        const int red = fullRange ? (bt709 ? 403 : 359) : (bt709 ? 459 : 409);
        const int blue = fullRange ? (bt709 ? 475 : 454) : (bt709 ? 541 : 516);
        const int greenU = fullRange ? (bt709 ? 48 : 88) : (bt709 ? 55 : 100);
        const int greenV = fullRange ? (bt709 ? 120 : 183) : (bt709 ? 136 : 208);
        for (unsigned y = 0; y < visibleHeight; ++y) {
            const BYTE *luma = data + size_t(y + cropY) * stride;
            const BYTE *chroma = uv + size_t((y + cropY) / 2) * stride;
            BYTE *pixel = frame->pixels.data() + size_t(y) * visibleWidth * 4;
            for (unsigned x = 0; x < visibleWidth; ++x, pixel += 4) {
                const unsigned sourceX = x + cropX;
                const int u = int(chroma[sourceX & ~1U]) - 128;
                const int v = int(chroma[(sourceX & ~1U) + 1]) - 128;
                const int base = fullRange ? 256 * luma[sourceX] : 298 * (int(luma[sourceX]) - 16);
                pixel[0] = clamp((base + blue * u + 128) >> 8);
                pixel[1] = clamp((base - greenU * u - greenV * v + 128) >> 8);
                pixel[2] = clamp((base + red * v + 128) >> 8);
                pixel[3] = 255;
            }
        }
        return frame;
    }

public:
    explicit VideoDecoder(mm_media *media = nullptr) : owner(media) {}
    void close() {
        if (transform) {
            transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
        }
        outputType.reset();
        outputBuffer.reset();
        outputCapacity = outputAlignment = 0;
        transform.reset();
    }
    ~VideoDecoder() { close(); }
    bool open(bool hevc, std::string &error) {
        close();
        if (!enumDecoder(hevc, &transform)) {
            error = hevc
                ? "No Windows software HEVC decoder is installed. Install Microsoft's HEVC Video Extensions or use H.264."
                : "The Windows H.264 decoder is unavailable. Install the Windows Media Feature Pack (Windows N), then restart MirrorMe.";
            return false;
        }
        Com<IMFAttributes> attributes;
        if (SUCCEEDED(transform->GetAttributes(attributes.put()))) attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
        Com<ICodecAPI> codec;
        if (SUCCEEDED(transform->QueryInterface(codecApiID, reinterpret_cast<void **>(codec.put())))) {
            VARIANT value;
            VariantInit(&value);
            value.vt = VT_BOOL;
            value.boolVal = VARIANT_TRUE;
            codec->SetValue(&CODECAPI_AVLowLatencyMode, &value);
        }
        Com<IMFMediaType> input;
        HRESULT result = MFCreateMediaType(input.put());
        if (SUCCEEDED(result)) result = input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        if (SUCCEEDED(result)) result = input->SetGUID(MF_MT_SUBTYPE, hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264);
        if (SUCCEEDED(result)) result = input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        if (SUCCEEDED(result)) result = transform->SetInputType(0, input.get(), 0);
        if (FAILED(result)) { error = hrError("Configuring the Windows video decoder failed", result); return false; }
        // H.264 learns dimensions from SPS. Output negotiation can legitimately
        // wait until its first MF_E_TRANSFORM_STREAM_CHANGE.
        if (!selectOutput(error, true)) return false;
        result = transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        if (SUCCEEDED(result)) result = transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        if (FAILED(result)) { error = hrError("Starting the Windows video decoder failed", result); return false; }
        return true;
    }
    bool flush(std::string &error) {
        if (transform) {
            HRESULT result = transform->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            if (SUCCEEDED(result)) result = transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
            if (FAILED(result)) { error = hrError("Flushing the Windows video decoder failed", result); return false; }
        }
        return true;
    }
    bool drain(const Packet &packet, bool present, std::deque<std::shared_ptr<Frame>> &frames, std::string &error) {
        for (unsigned iteration = 0; iteration < 64; ++iteration) {
            MFT_OUTPUT_STREAM_INFO info{};
            HRESULT result = transform->GetOutputStreamInfo(0, &info);
            if (FAILED(result)) { error = hrError("Reading Windows decoder output requirements failed", result); return false; }
            if (info.cbSize > maxDecodedNV12Bytes || info.cbAlignment > 65536 ||
                (info.cbAlignment && (info.cbAlignment & (info.cbAlignment - 1)))) {
                error = "The Windows decoder requested an unsafe output buffer size or alignment. Reduce the sender resolution to 4K or lower.";
                return false;
            }
            Com<IMFSample> sample;
            if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
                result = MFCreateSample(sample.put());
                const DWORD capacity = std::max<DWORD>(info.cbSize,
                    DWORD(uint64_t(std::max<LONG>(stride, width)) * height * 3 / 2));
                if (SUCCEEDED(result) && (!outputBuffer || capacity > outputCapacity || info.cbAlignment != outputAlignment)) {
                    result = MFCreateAlignedMemoryBuffer(capacity,
                        info.cbAlignment ? info.cbAlignment - 1 : 0, outputBuffer.put());
                    if (SUCCEEDED(result)) {
                        outputCapacity = capacity;
                        outputAlignment = info.cbAlignment;
                        if (owner) ++owner->outputAllocations;
                    }
                }
                if (SUCCEEDED(result)) result = outputBuffer->SetCurrentLength(0);
                if (SUCCEEDED(result)) result = sample->AddBuffer(outputBuffer.get());
                if (FAILED(result)) { error = hrError("Allocating Windows decoder output failed", result); return false; }
            }
            MFT_OUTPUT_DATA_BUFFER output{0, sample.get(), 0, nullptr};
            DWORD status = 0;
            result = transform->ProcessOutput(0, 1, &output, &status);
            if (output.pEvents) output.pEvents->Release();
            Com<IMFSample> supplied;
            if (output.pSample && output.pSample != sample.get()) supplied.reset(output.pSample);
            if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
            if (result == MF_E_TRANSFORM_STREAM_CHANGE) {
                if (!selectOutput(error)) return false;
                continue;
            }
            if (FAILED(result)) { error = hrError("Decoding the video frame failed", result); return false; }
            if (!output.pSample) { error = "The Windows decoder returned success without a video sample."; return false; }
            // Decode every reference picture, but avoid expensive BGRA work for
            // queued frames that cannot be shown. Sender/network age is separate.
            bool superseded = false;
            if (owner && clockNs() - packet.received > maxVideoQueueAge) {
                std::lock_guard<std::mutex> lock(owner->mutex);
                superseded = !owner->videoPackets.empty();
            }
            if (!present || superseded || (owner && packet.received < owner->presentationFloor.load())) {
                if (owner) ++owner->skippedConversion;
                continue;
            }
            auto frame = convert(output.pSample, packet, error);
            if (!frame) return false;
            if (owner) ++owner->converted;
            if (frames.size() == 3) frames.pop_front();
            frames.push_back(std::move(frame));
        }
        error = "The Windows video decoder produced too many frames from one bounded input packet.";
        return false;
    }
    bool decode(const Packet &packet, std::deque<std::shared_ptr<Frame>> &frames, std::string &error,
        bool present = true) {
        Com<IMFSample> sample;
        Com<IMFMediaBuffer> buffer;
        HRESULT result = MFCreateSample(sample.put());
        if (SUCCEEDED(result)) result = MFCreateMemoryBuffer(DWORD(packet.bytes.size()), buffer.put());
        BYTE *data = nullptr;
        if (SUCCEEDED(result)) result = buffer->Lock(&data, nullptr, nullptr);
        if (SUCCEEDED(result)) {
            std::memcpy(data, packet.bytes.data(), packet.bytes.size());
            buffer->Unlock();
            result = buffer->SetCurrentLength(DWORD(packet.bytes.size()));
        }
        if (SUCCEEDED(result)) result = sample->AddBuffer(buffer.get());
        if (SUCCEEDED(result)) result = sample->SetSampleTime(LONGLONG(packet.timestamp / 100));
        if (FAILED(result)) { error = hrError("Preparing the encoded video packet failed", result); return false; }
        result = transform->ProcessInput(0, sample.get(), 0);
        if (result == MF_E_NOTACCEPTING) {
            if (!drain(packet, present, frames, error)) return false;
            result = transform->ProcessInput(0, sample.get(), 0);
        }
        if (FAILED(result)) { error = hrError("The Windows decoder rejected an encoded video packet", result); return false; }
        if (!outputType && !selectOutput(error)) return false;
        return drain(packet, present, frames, error);
    }
};

struct Nal {
    size_t start, body, end;
    unsigned type;
};

bool scanAnnexB(const std::vector<unsigned char> &bytes, bool hevc, std::vector<Nal> &units) {
    size_t i = 0;
    while (i + 3 <= bytes.size()) {
        size_t prefix = 0;
        if (bytes[i] == 0 && bytes[i + 1] == 0) {
            if (bytes[i + 2] == 1) prefix = 3;
            else if (i + 4 <= bytes.size() && bytes[i + 2] == 0 && bytes[i + 3] == 1) prefix = 4;
        }
        if (!prefix) { ++i; continue; }
        if (units.empty()) {
            for (size_t j = 0; j < i; ++j) if (bytes[j]) return false;
        } else units.back().end = i;
        const size_t body = i + prefix;
        if (body + (hevc ? 2 : 1) > bytes.size() || (bytes[body] & 0x80)) return false;
        unsigned type = hevc ? (bytes[body] >> 1) & 63 : bytes[body] & 31;
        if ((!hevc && (type == 0 || type > 23)) || (hevc && !(bytes[body + 1] & 7))) return false;
        units.push_back({i, body, bytes.size(), type});
        if (units.size() > 4096) return false;
        i = body + (hevc ? 2 : 1);
    }
    for (const auto &unit : units) if (unit.end <= unit.body + (hevc ? 1 : 0)) return false;
    return !units.empty();
}

class AudioOutput {
    Com<IAudioClient> client;
    Com<IAudioRenderClient> render;
    Com<ISimpleAudioVolume> volume;
    UINT32 capacity = 0;
    unsigned rate = 0, channels = 0;
    bool started = false;
    float lastVolume = -1;
public:
    void close() {
        if (client && started) client->Stop();
        started = false;
        volume.reset();
        render.reset();
        client.reset();
        rate = channels = 0;
        lastVolume = -1;
    }
    ~AudioOutput() { close(); }
    bool matches(unsigned sampleRate, unsigned channelCount) const {
        return client && rate == sampleRate && channels == channelCount;
    }
    bool open(unsigned sampleRate, unsigned channelCount, std::string &error) {
        close();
        if (sampleRate < 8000 || sampleRate > 192000 || channelCount < 1 || channelCount > 8) {
            error = "The audio decoder returned an unsupported PCM sample rate or channel count.";
            return false;
        }
        Com<IMMDeviceEnumerator> enumerator;
        Com<IMMDevice> device;
        HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            IID_PPV_ARGS(enumerator.put()));
        if (SUCCEEDED(result)) result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, device.put());
        if (SUCCEEDED(result)) result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
            nullptr, reinterpret_cast<void **>(client.put()));
        WAVEFORMATEXTENSIBLE format{};
        format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
        format.Format.nChannels = WORD(channelCount);
        format.Format.nSamplesPerSec = sampleRate;
        format.Format.wBitsPerSample = 16;
        format.Format.nBlockAlign = WORD(channelCount * sizeof(int16_t));
        format.Format.nAvgBytesPerSec = sampleRate * format.Format.nBlockAlign;
        format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
        format.Samples.wValidBitsPerSample = 16;
        static const DWORD masks[] = {0, 0x4, 0x3, 0x7, 0x33, 0x37, 0x3f, 0x13f, 0x63f};
        format.dwChannelMask = masks[channelCount];
        format.SubFormat = KSDATAFORMAT_SUBTYPE_PCM;
        GUID session{};
        if (SUCCEEDED(result)) result = CoCreateGuid(&session);
        if (SUCCEEDED(result)) result = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            1000000, 0, &format.Format, &session);
        if (SUCCEEDED(result)) result = client->GetBufferSize(&capacity);
        if (SUCCEEDED(result)) result = client->GetService(IID_PPV_ARGS(render.put()));
        if (SUCCEEDED(result)) result = client->GetService(IID_PPV_ARGS(volume.put()));
        if (FAILED(result)) {
            error = hrError("Opening the Windows default audio output failed; check the selected output device", result);
            close();
            return false;
        }
        rate = sampleRate;
        channels = channelCount;
        return true;
    }
    bool flush(std::string &error) {
        if (!client) return true;
        HRESULT result = started ? client->Stop() : S_OK;
        started = false;
        if (SUCCEEDED(result)) result = client->Reset();
        if (FAILED(result)) { error = hrError("Resetting Windows audio playback failed", result); close(); return false; }
        return true;
    }
    bool setVolume(float value, std::string &error) {
        if (!volume || value == lastVolume) return true;
        HRESULT result = volume->SetMasterVolume(value, nullptr);
        if (FAILED(result)) { error = hrError("Changing Windows audio volume failed", result); return false; }
        lastVolume = value;
        return true;
    }
    bool available(UINT32 &frames, UINT32 &padding, std::string &error) {
        HRESULT result = client->GetCurrentPadding(&padding);
        if (FAILED(result) || padding > capacity) {
            error = hrError("Reading the Windows audio playback position failed", FAILED(result) ? result : E_UNEXPECTED);
            return false;
        }
        frames = capacity - padding;
        return true;
    }
    bool write(const int16_t *samples, UINT32 frames, std::string &error) {
        BYTE *buffer = nullptr;
        HRESULT result = render->GetBuffer(frames, &buffer);
        if (SUCCEEDED(result)) {
            std::memcpy(buffer, samples, size_t(frames) * channels * sizeof(int16_t));
            result = render->ReleaseBuffer(frames, 0);
        }
        if (SUCCEEDED(result) && !started) {
            result = client->Start();
            started = SUCCEEDED(result);
        }
        if (FAILED(result)) { error = hrError("Playing decoded audio on the Windows output device failed", result); return false; }
        return true;
    }
};

struct AudioChunk {
    std::vector<int16_t> samples;
    size_t cursor = 0;
    unsigned rate = 0, channels = 0;
    uint64_t timestamp = 0, epoch = 0;
};
struct AudioDecoderDelete {
    void operator()(mm_audio_decoder *decoder) const { mm_audio_decoder_destroy(decoder); }
};

void workerRun(mm_media *media) {
    ComApartment apartment(COINIT_MULTITHREADED);
    HRESULT startup = FAILED(apartment.result) ? apartment.result : MFStartup(MF_VERSION, MFSTARTUP_FULL);
    struct MFShutdownGuard {
        bool active;
        ~MFShutdownGuard() { if (active) MFShutdown(); }
    } shutdown{SUCCEEDED(startup)};
    VideoDecoder video(media);
    std::string error;
    bool videoOK = SUCCEEDED(startup) && video.open(false, error);
    if (FAILED(startup)) error = hrError("Starting Windows Media Foundation failed", startup);
    if (videoOK && media->config.allow_h265) {
        VideoDecoder candidate;
        std::string capabilityError;
        media->hevcAvailable = candidate.open(true, capabilityError);
    }
    {
        std::lock_guard<std::mutex> lock(media->mutex);
        if (!videoOK) media->workerError = error;
        media->workerReady = true;
    }
    media->initialized.notify_all();
    if (!videoOK) return;
    if (media->config.hardware_decode)
        media->emit(MM_EVENT_NOTICE,
            "This native GDI renderer uses the Windows software video decoder; hardware/DXVA decoding is not available in this renderer.");
    if (media->config.allow_h265 && !media->hevcAvailable)
        media->emit(MM_EVENT_NOTICE,
            "HEVC is unavailable: no Windows software HEVC decoder is installed. H.264 remains supported; Microsoft HEVC Video Extensions may enable HEVC.");
    uint64_t videoEpoch = 1, decoderEpoch = 1, audioEpoch = 1, codecVersion = 1, audioVersion = 0;
    bool hevc = false, needKeyframe = true;
    std::vector<unsigned char> parameters[3];
    std::deque<std::shared_ptr<Frame>> frames;
    std::deque<AudioChunk> pcm;
    std::unique_ptr<mm_audio_decoder, AudioDecoderDelete> audio;
    AudioOutput output;
    bool takeVideo = true;
    while (!media->stopping) {
        Packet packet;
        bool havePacket = false, isVideo = false, flushVideo = false, flushAudio = false;
        bool changeCodec = false, changeAudio = false, changePresentation = false, paused;
        uint64_t resetTarget = 0;
        AudioConfig audioConfig;
        std::deque<Event> events;
        {
            std::unique_lock<std::mutex> lock(media->mutex);
            if (media->videoPackets.empty() && media->audioPackets.empty() && media->events.empty())
                media->wake.wait_for(lock, std::chrono::milliseconds(4));
            if (media->stopping) break;
            events.swap(media->events);
            paused = media->paused;
            changePresentation = videoEpoch != media->videoEpoch;
            flushVideo = decoderEpoch != media->decoderEpoch;
            decoderEpoch = media->decoderEpoch;
            flushAudio = audioEpoch != media->audioEpoch;
            videoEpoch = media->videoEpoch;
            audioEpoch = media->audioEpoch;
            changeCodec = codecVersion != media->codecVersion;
            codecVersion = media->codecVersion;
            hevc = media->hevc;
            changeAudio = audioVersion != media->audioVersion;
            audioVersion = media->audioVersion;
            audioConfig = media->audioConfig;
            resetTarget = media->resetRequested;
            if (!paused || !media->videoPackets.empty()) {
                isVideo = !media->videoPackets.empty() && (paused || takeVideo || media->audioPackets.empty());
                auto &queue = isVideo ? media->videoPackets : media->audioPackets;
                auto &bytes = isVideo ? media->videoBytes : media->audioBytes;
                if (!queue.empty()) {
                    packet = std::move(queue.front());
                    queue.pop_front();
                    bytes -= packet.bytes.size();
                    havePacket = true;
                    takeVideo = !isVideo;
                }
            }
        }
        for (const auto &event : events) {
            bool current;
            {
                std::lock_guard<std::mutex> lock(media->mutex);
                current = event.session == media->session && (!event.videoEpoch || event.videoEpoch == media->videoEpoch);
                if (event.kind == MM_EVENT_STREAMING) {
                    current = current && !media->sessionClosed && media->streamingSession != event.session;
                    if (current) media->streamingSession = event.session;
                }
            }
            if (!current) continue;
            media->emit(event.kind, event.message);
            if (media->stopping) break;
        }
        if (media->stopping) break;
        error.clear();
        if (changePresentation) frames.clear();
        if (flushVideo || changeCodec) {
            frames.clear();
            needKeyframe = true;
            if (changeCodec) {
                for (auto &parameter : parameters) parameter.clear();
                videoOK = video.open(hevc, error);
                if (!videoOK) media->emit(MM_EVENT_ERROR, error);
            } else if (!video.flush(error)) {
                videoOK = false;
                media->emit(MM_EVENT_ERROR, error);
            }
        }
        if (flushAudio || changeAudio) {
            pcm.clear();
            if (audio) mm_audio_decoder_flush(audio.get());
            if (!output.flush(error)) media->emit(MM_EVENT_ERROR, error);
        }
        if (changeAudio && media->config.audio_enabled && audioConfig.configured) {
            audio.reset();
            output.close();
            char detail[512]{};
            audio.reset(mm_audio_decoder_create(audioConfig.codec, audioConfig.samples,
                audioConfig.format, detail, sizeof(detail)));
            if (!audio) media->emit(MM_EVENT_ERROR, std::string("Creating the audio decoder failed: ") + detail);
        }
        {
            std::lock_guard<std::mutex> lock(media->mutex);
            media->resetCompleted = std::max(media->resetCompleted, resetTarget);
        }
        media->resetDone.notify_all();
        if (havePacket && isVideo && videoOK && packet.decoderEpoch == media->decoderEpoch.load()) {
            std::vector<Nal> units;
            if (!scanAnnexB(packet.bytes, hevc, units)) {
                media->emit(MM_EVENT_ERROR, "The sender supplied a malformed Annex-B video packet.");
                if (!video.flush(error)) { videoOK = false; media->emit(MM_EVENT_ERROR, error); }
                needKeyframe = true;
            } else {
                bool key = false, vcl = false;
                bool hasParameters[3]{};
                for (const auto &unit : units) {
                    key |= hevc ? (unit.type >= 16 && unit.type <= 21) : unit.type == 5;
                    vcl |= hevc ? unit.type <= 31 : (unit.type >= 1 && unit.type <= 5);
                    int index = hevc ? (unit.type >= 32 && unit.type <= 34 ? int(unit.type - 32) : -1)
                        : (unit.type == 7 ? 0 : unit.type == 8 ? 1 : -1);
                    if (index >= 0 && unit.end - unit.start <= 65536) {
                        parameters[index].assign(packet.bytes.begin() + unit.start, packet.bytes.begin() + unit.end);
                        hasParameters[index] = true;
                    }
                }
                if (vcl && (!needKeyframe || key)) {
                    if (key) {
                        std::vector<unsigned char> complete;
                        for (unsigned i = 0; i < 3; ++i)
                            if (!hasParameters[i]) complete.insert(complete.end(), parameters[i].begin(), parameters[i].end());
                        complete.insert(complete.end(), packet.bytes.begin(), packet.bytes.end());
                        packet.bytes.swap(complete);
                    }
                    needKeyframe = false;
                    if (!video.decode(packet, frames, error, !paused && packet.epoch == media->videoEpoch.load())) {
                        media->emit(MM_EVENT_ERROR, error);
                        if (!video.flush(error)) { videoOK = false; media->emit(MM_EVENT_ERROR, error); }
                        frames.clear();
                        needKeyframe = true;
                    }
                }
            }
        } else if (havePacket && !isVideo && audio) {
            bool current;
            { std::lock_guard<std::mutex> lock(media->mutex); current = packet.epoch == media->audioEpoch; }
            const uint64_t now = clockNs();
            if (!current || (now > packet.timestamp && now - packet.timestamp > 150 * millisecond)) {
                ++media->dropped;
                mm_audio_decoder_flush(audio.get());
            } else {
                mm_audio_frame frame{};
                char detail[512]{};
                const int result = mm_audio_decoder_decode(audio.get(), packet.bytes.data(), packet.bytes.size(),
                    &frame, detail, sizeof(detail));
                if (result != 0) {
                    media->emit(MM_EVENT_ERROR, std::string("Decoding an audio packet failed: ") + detail);
                    mm_audio_decoder_flush(audio.get());
                } else if (!frame.frames) {
                    // Some decoders need another access unit before returning PCM.
                } else if (!frame.samples || frame.channels < 1 || frame.channels > 8 ||
                    frame.sample_rate < 8000 || frame.sample_rate > 192000 || frame.frames > frame.sample_rate / 5) {
                    media->emit(MM_EVENT_ERROR, "The audio decoder returned an invalid or oversized PCM frame.");
                } else {
                    if (!output.matches(frame.sample_rate, frame.channels)) {
                        pcm.clear();
                        if (!output.open(frame.sample_rate, frame.channels, error)) {
                            media->emit(MM_EVENT_ERROR, error);
                            audio.reset();
                        }
                    }
                    if (audio) {
                        size_t pendingFrames = 0;
                        for (const auto &chunk : pcm) pendingFrames += chunk.samples.size() / chunk.channels - chunk.cursor;
                        if (pendingFrames + frame.frames > frame.sample_rate / 5) {
                            pcm.clear();
                            ++media->dropped;
                            if (!output.flush(error)) media->emit(MM_EVENT_ERROR, error);
                        }
                        AudioChunk chunk;
                        chunk.samples.assign(frame.samples, frame.samples + frame.frames * frame.channels);
                        chunk.rate = frame.sample_rate;
                        chunk.channels = frame.channels;
                        chunk.timestamp = packet.timestamp;
                        chunk.epoch = packet.epoch;
                        pcm.push_back(std::move(chunk));
                    }
                }
            }
        }
        if (paused || media->stopping) continue;
        if (!output.setVolume(media->volume, error)) {
            media->emit(MM_EVENT_ERROR, error);
            pcm.clear();
            output.close();
            audio.reset();
        }
        if (!frames.empty()) {
            const uint64_t now = clockNs();
            while (!frames.empty() && (frames.front()->epoch != media->videoEpoch.load() ||
                (frames.size() > 1 && frames[1]->timestamp <= now))) {
                frames.pop_front();
                ++media->dropped;
            }
            if (!frames.empty() && frames.front()->timestamp <= now + 2 * millisecond) {
                auto frame = std::move(frames.front());
                frames.pop_front();
                bool post = false;
                {
                    std::lock_guard<std::mutex> lock(media->frameMutex);
                    media->pendingFrame = std::move(frame);
                    if (!media->framePosted) { media->framePosted = true; post = true; }
                }
                if (post) {
                    HWND window = media->window.load();
                    if (!window || !PostMessageW(window, frameMessage, 0, 0))
                        media->emit(MM_EVENT_ERROR, "The native video window is unavailable; the decoded frame could not be presented.");
                }
            }
        }
        if (!pcm.empty()) {
            auto &chunk = pcm.front();
            uint64_t currentEpoch;
            { std::lock_guard<std::mutex> lock(media->mutex); currentEpoch = media->audioEpoch; }
            const uint64_t now = clockNs();
            const uint64_t position = chunk.timestamp + chunk.cursor * 1000000000ULL / chunk.rate;
            if (chunk.epoch != currentEpoch || (now > position && now - position > 150 * millisecond)) {
                pcm.pop_front();
                ++media->dropped;
            } else {
                UINT32 available = 0, padding = 0;
                if (!output.available(available, padding, error)) {
                    media->emit(MM_EVENT_ERROR, error);
                    pcm.clear();
                    output.close();
                    audio.reset();
                } else if (position <= now + uint64_t(padding) * 1000000000ULL / chunk.rate + 2 * millisecond && available) {
                    const UINT32 count = UINT32(std::min<size_t>(available, chunk.samples.size() / chunk.channels - chunk.cursor));
                    if (!output.write(chunk.samples.data() + chunk.cursor * chunk.channels, count, error)) {
                        media->emit(MM_EVENT_ERROR, error);
                        pcm.clear();
                        output.close();
                        audio.reset();
                    } else {
                        media->audioSubmitted += count;
                        chunk.cursor += count;
                        if (chunk.cursor == chunk.samples.size() / chunk.channels) pcm.pop_front();
                    }
                }
            }
        }
    }
}

void workerMain(mm_media *media) {
    try {
        workerRun(media);
    } catch (const std::bad_alloc &) {
        {
            std::lock_guard<std::mutex> lock(media->mutex);
            media->workerError = "Native media playback ran out of memory.";
            media->workerReady = true;
        }
        media->initialized.notify_all();
        media->emit(MM_EVENT_ERROR, "Native media playback ran out of memory.");
        media->stopping = true;
        media->resetDone.notify_all();
    }
}

void requestStop(mm_media *media) {
    media->stopping = true;
    media->wake.notify_all();
    media->resetDone.notify_all();
    if (HWND window = media->window.load()) PostMessageW(window, stopMessage, 0, 0);
}
}

extern "C" {
mm_media *mm_media_create(const mm_receiver_config *config, mm_event_callback callback,
    void *context, char *error, size_t error_capacity) {
    if (!config) { copyError(error, error_capacity, "Missing native media configuration."); return nullptr; }
    std::unique_ptr<mm_media> media;
    try {
        media = std::make_unique<mm_media>();
        media->config = *config;
        // The module only keeps numeric preferences, never caller-owned strings.
        media->config.name = media->config.device_id = media->config.key_path = nullptr;
        media->callback = callback;
        media->context = context;
        media->windowThread = std::thread(windowMain, media.get());
        {
            std::unique_lock<std::mutex> lock(media->mutex);
            media->initialized.wait(lock, [&] { return media->windowReady; });
            if (!media->windowError.empty()) {
                copyError(error, error_capacity, media->windowError);
                lock.unlock();
                media->windowThread.join();
                return nullptr;
            }
        }
        media->worker = std::thread(workerMain, media.get());
        {
            std::unique_lock<std::mutex> lock(media->mutex);
            media->initialized.wait(lock, [&] { return media->workerReady; });
            if (!media->workerError.empty()) {
                copyError(error, error_capacity, media->workerError);
                lock.unlock();
                requestStop(media.get());
                media->worker.join();
                media->windowThread.join();
                return nullptr;
            }
        }
        copyError(error, error_capacity, "");
        return media.release();
    } catch (const std::bad_alloc &) {
        copyError(error, error_capacity, "Not enough memory to start native media playback.");
    } catch (const std::system_error &failure) {
        copyError(error, error_capacity, std::string("Could not start native media threads: ") + failure.what());
    }
    if (media) {
        requestStop(media.get());
        if (media->worker.joinable()) media->worker.join();
        if (media->windowThread.joinable()) media->windowThread.join();
    }
    return nullptr;
}

int mm_media_set_video_codec(mm_media *media, int hevc) {
    if (!media || media->stopping) return -1;
    std::lock_guard<std::mutex> lock(media->mutex);
    if (hevc && (!media->config.allow_h265 || !media->hevcAvailable)) {
        media->eventLocked(MM_EVENT_ERROR, "HEVC was requested but is unavailable. Enable/install a Windows software HEVC decoder or select H.264 on the sender.");
        return -1;
    }
    if (media->hevc != bool(hevc)) {
        media->hevc = hevc != 0;
        media->clearVideoLocked();
        ++media->codecVersion;
    }
    media->wake.notify_one();
    return 0;
}

int mm_media_push_video(mm_media *media, const unsigned char *data, size_t length, uint64_t timestamp) {
    if (!media || media->stopping) return -1;
    if (!data || length < 5 || length > maxVideoPacket) {
        media->error("Rejected an empty, truncated, or oversized video packet (maximum 4 MiB).");
        return -1;
    }
    try {
        Packet packet;
        packet.received = clockNs();
        packet.bytes.assign(data, data + length);
        std::lock_guard<std::mutex> lock(media->mutex);
        if (media->paused || media->sessionClosed || media->stopping) return -1;
        packet.timestamp = media->timestampLocked(timestamp);
        if (media->videoPackets.size() >= 48 || media->videoBytes + length > maxVideoBytes) {
            media->clearVideoLocked();
            const uint64_t now = clockNs();
            if (!media->lastVideoDropNotice || now - media->lastVideoDropNotice > 1000 * millisecond) {
                media->lastVideoDropNotice = now;
                media->eventLocked(MM_EVENT_NOTICE, "The video packet queue fell behind and was flushed; waiting for a fresh keyframe.");
            }
        }
        packet.epoch = media->videoEpoch;
        packet.decoderEpoch = media->decoderEpoch;
        media->videoPackets.push_back(std::move(packet));
        media->videoBytes += length;
        if (!media->accepted) {
            media->accepted = true;
            media->eventLocked(MM_EVENT_VIDEO_RECEIVED, "An encoded video packet was accepted.", packet.epoch);
        }
        media->wake.notify_one();
        return 0;
    } catch (const std::bad_alloc &) {
        media->error("Not enough memory to copy an incoming video packet.");
        return -1;
    }
}

int mm_media_configure_audio(mm_media *media, unsigned codec, unsigned samples, uint64_t format) {
    if (!media || media->stopping) return -1;
    if (!media->config.audio_enabled) return 0;
    std::lock_guard<std::mutex> lock(media->mutex);
    media->audioConfig = {codec, samples, format, true};
    media->clearAudioLocked();
    ++media->audioVersion;
    media->wake.notify_one();
    return 0;
}

int mm_media_push_audio(mm_media *media, const unsigned char *data, size_t length, uint64_t timestamp) {
    if (!media || media->stopping) return -1;
    if (!media->config.audio_enabled) return 0;
    if (!data || !length || length > maxAudioPacket) {
        media->error("Rejected an empty or oversized audio packet (maximum 64 KiB).");
        return -1;
    }
    try {
        Packet packet;
        packet.bytes.assign(data, data + length);
        std::lock_guard<std::mutex> lock(media->mutex);
        if (media->paused || media->sessionClosed || media->stopping || !media->audioConfig.configured) return -1;
        packet.timestamp = media->timestampLocked(timestamp);
        if (media->audioPackets.size() >= 64 || media->audioBytes + length > maxAudioBytes) media->clearAudioLocked();
        packet.epoch = media->audioEpoch;
        media->audioPackets.push_back(std::move(packet));
        media->audioBytes += length;
        media->wake.notify_one();
        return 0;
    } catch (const std::bad_alloc &) {
        media->error("Not enough memory to copy an incoming audio packet.");
        return -1;
    }
}

void mm_media_set_volume(mm_media *media, float decibels) {
    if (!media || !std::isfinite(decibels)) return;
    media->volume = decibels <= -144.0f ? 0.0f : std::pow(10.0f, std::max(-144.0f, std::min(0.0f, decibels)) / 20.0f);
    media->wake.notify_one();
}
void mm_media_pause(mm_media *media, int paused) {
    if (!media || media->stopping) return;
    uint64_t target, epoch;
    {
        std::lock_guard<std::mutex> lock(media->mutex);
        if (media->paused == bool(paused) || media->sessionClosed) return;
        media->paused = paused != 0;
        // Pause presentation, not decoding history. Pending encoded references
        // are still consumed; flushing them can make unlock wait forever for IDR.
        epoch = ++media->videoEpoch;
        media->presentationFloor = clockNs();
        media->clearAudioLocked();
        media->accepted = false;
        media->streamingSession = 0;
        target = ++media->resetRequested;
    }
    if (paused)
        if (HWND window = media->window.load()) PostMessageW(window, hideMessage, epoch, 0);
    media->wake.notify_one();
    const auto self = std::this_thread::get_id();
    if (self != media->worker.get_id() && self != media->windowThread.get_id()) {
        std::unique_lock<std::mutex> lock(media->mutex);
        media->resetDone.wait(lock, [&] { return media->resetCompleted >= target || media->stopping; });
    }
}
void mm_media_flush_audio(mm_media *media) {
    if (!media) return;
    { std::lock_guard<std::mutex> lock(media->mutex); media->clearAudioLocked(); }
    media->wake.notify_one();
}
void mm_media_flush_video(mm_media *media) {
    if (!media) return;
    { std::lock_guard<std::mutex> lock(media->mutex); media->clearVideoLocked(); }
    if (HWND window = media->window.load()) PostMessageW(window, clearMessage, media->videoEpoch.load(), 0);
    media->wake.notify_one();
}
void mm_media_reset(mm_media *media) { if (media) resetMedia(media); }
void mm_media_show_window(mm_media *media) {
    if (media && !media->stopping)
        if (HWND window = media->window.load()) PostMessageW(window, showMessage, 0, 0);
}
uint64_t mm_media_rendered_frames(mm_media *media) { return media ? media->rendered.load() : 0; }
void mm_media_destroy(mm_media *media) {
    if (!media) return;
    requestStop(media);
    // A callback can request shutdown but cannot join its own media thread.
    // Its owner must call destroy again after returning from that callback.
    const auto self = std::this_thread::get_id();
    if ((media->worker.joinable() && self == media->worker.get_id()) ||
        (media->windowThread.joinable() && self == media->windowThread.get_id())) return;
    if (media->worker.joinable()) media->worker.join();
    if (media->windowThread.joinable()) media->windowThread.join();
    delete media;
}

#ifdef MM_MEDIA_TESTING
void mm_media_test_snapshot(mm_media *media, mm_media_test_stats *stats) {
    if (!media || !stats) return;
    std::lock_guard<std::mutex> lock(media->mutex);
    stats->window = reinterpret_cast<uintptr_t>(media->window.load());
    stats->video_packets = media->videoPackets.size();
    stats->audio_packets = media->audioPackets.size();
    stats->video_bytes = media->videoBytes;
    stats->audio_bytes = media->audioBytes;
    stats->rendered = media->rendered;
    stats->audio_submitted = media->audioSubmitted;
    stats->clock_resets = media->clockResets;
    stats->dropped = media->dropped;
    stats->converted = media->converted;
    stats->skipped_conversion = media->skippedConversion;
    stats->output_allocations = media->outputAllocations;
    stats->receive_to_paint_ns = media->receiveToPaint;
    stats->volume = media->volume;
    stats->presented_width = media->presentedWidth;
    stats->presented_height = media->presentedHeight;
}
int mm_media_test_video_layout(unsigned width, unsigned height, long stride, size_t outputBytes) {
    return videoLayoutAllowed(width, height, stride) && outputBytes <= maxDecodedNV12Bytes;
}
#endif
}
