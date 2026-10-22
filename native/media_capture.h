// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// Screenshot and video-capture helpers for the mirror window. Included by media.cpp.
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <shlobj.h>
#include <wincodec.h>
#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace mmcapture {

struct Image {
    std::vector<unsigned char> pixels; // top-down BGRA
    unsigned width = 0, height = 0;
};
using ImagePtr = std::shared_ptr<const Image>;

inline std::wstring timestampName() {
    SYSTEMTIME now{};
    GetLocalTime(&now);
    wchar_t text[48];
    swprintf(text, 48, L"MirrorMe-%04d%02d%02d-%02d%02d%02d", now.wYear, now.wMonth, now.wDay,
        now.wHour, now.wMinute, now.wSecond);
    return text;
}

// Returns <Pictures|Videos>\MirrorMe, creating it when needed.
inline bool outputFolder(const KNOWNFOLDERID &known, std::wstring &folder) {
    PWSTR base = nullptr;
    if (FAILED(SHGetKnownFolderPath(known, KF_FLAG_CREATE, nullptr, &base)) || !base) return false;
    folder = std::wstring(base) + L"\\MirrorMe";
    CoTaskMemFree(base);
    return CreateDirectoryW(folder.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS;
}

inline bool savePng(const std::wstring &path, const Image &image, std::string &error) {
    IWICImagingFactory *factory = nullptr;
    IWICBitmapEncoder *encoder = nullptr;
    IWICStream *stream = nullptr;
    IWICBitmapFrameEncode *frame = nullptr;
    IPropertyBag2 *options = nullptr;
    bool ok = false;
    HRESULT result = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&factory));
    if (SUCCEEDED(result)) result = factory->CreateStream(&stream);
    if (SUCCEEDED(result)) result = stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE);
    if (SUCCEEDED(result)) result = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(result)) result = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    if (SUCCEEDED(result)) result = encoder->CreateNewFrame(&frame, &options);
    if (SUCCEEDED(result)) result = frame->Initialize(options);
    if (SUCCEEDED(result)) result = frame->SetSize(image.width, image.height);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(result)) result = frame->SetPixelFormat(&format);
    if (SUCCEEDED(result) && format != GUID_WICPixelFormat32bppBGRA) result = E_FAIL;
    if (SUCCEEDED(result))
        result = frame->WritePixels(image.height, image.width * 4,
            UINT(image.pixels.size()), const_cast<BYTE *>(image.pixels.data()));
    if (SUCCEEDED(result)) result = frame->Commit();
    if (SUCCEEDED(result)) result = encoder->Commit();
    ok = SUCCEEDED(result);
    if (!ok) {
        char code[64];
        std::snprintf(code, sizeof(code), "Saving the screenshot failed (HRESULT 0x%08lX).", static_cast<unsigned long>(result));
        error = code;
    }
    if (options) options->Release();
    if (frame) frame->Release();
    if (encoder) encoder->Release();
    if (stream) stream->Release();
    if (factory) factory->Release();
    if (!ok) DeleteFileW(path.c_str());
    return ok;
}

inline bool copyToClipboard(HWND owner, const Image &image) {
    const size_t rowBytes = size_t(image.width) * 4;
    const size_t total = sizeof(BITMAPINFOHEADER) + rowBytes * image.height;
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, total);
    if (!memory) return false;
    auto *header = static_cast<BITMAPINFOHEADER *>(GlobalLock(memory));
    if (!header) { GlobalFree(memory); return false; }
    *header = {};
    header->biSize = sizeof(BITMAPINFOHEADER);
    header->biWidth = LONG(image.width);
    header->biHeight = LONG(image.height); // bottom-up for the widest compatibility
    header->biPlanes = 1;
    header->biBitCount = 32;
    header->biCompression = BI_RGB;
    auto *rows = reinterpret_cast<unsigned char *>(header + 1);
    for (unsigned y = 0; y < image.height; ++y)
        std::memcpy(rows + size_t(y) * rowBytes, image.pixels.data() + size_t(image.height - 1 - y) * rowBytes, rowBytes);
    GlobalUnlock(memory);
    if (!OpenClipboard(owner)) { GlobalFree(memory); return false; }
    EmptyClipboard();
    const bool ok = SetClipboardData(CF_DIB, memory) != nullptr;
    CloseClipboard();
    if (!ok) GlobalFree(memory);
    return ok;
}

// H.264/MP4 recorder. Frames are queued from the UI thread and encoded on a worker
// so painting never waits on the encoder. If the queue is full the frame is dropped.
class Recorder {
    struct Item { ImagePtr image; LONGLONG time; };
    std::thread worker;
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Item> queue;
    bool finishing = false, failed = false, active = false;
    std::string failure;
    unsigned width = 0, height = 0;
    uint64_t startTick = 0;
    std::wstring path;
    static constexpr size_t maxQueued = 6;
    static constexpr UINT32 fps = 30;

    static uint64_t nowTicks() {
        LARGE_INTEGER ticks{}, frequency{};
        QueryPerformanceCounter(&ticks);
        QueryPerformanceFrequency(&frequency);
        return uint64_t(ticks.QuadPart) * 10000000ULL / uint64_t(frequency.QuadPart);
    }

    static std::string hr(const char *what, HRESULT result) {
        char code[96];
        std::snprintf(code, sizeof(code), " (HRESULT 0x%08lX)", static_cast<unsigned long>(result));
        return std::string(what) + code;
    }

    void run() {
        HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        HRESULT started = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        IMFSinkWriter *writer = nullptr;
        DWORD stream = 0;
        std::string error;
        if (FAILED(started)) error = hr("Starting video recording failed", started);
        else error = open(&writer, stream);
        if (!error.empty()) {
            std::lock_guard<std::mutex> lock(mutex);
            failed = true;
            failure = error;
            queue.clear();
        }
        LONGLONG previous = -1;
        for (;;) {
            Item item;
            {
                std::unique_lock<std::mutex> lock(mutex);
                wake.wait(lock, [&] { return !queue.empty() || finishing; });
                if (queue.empty()) break;
                item = std::move(queue.front());
                queue.pop_front();
            }
            if (!writer) continue;
            if (item.time <= previous) item.time = previous + 1;
            previous = item.time;
            std::string problem = write(writer, stream, item);
            if (!problem.empty()) {
                std::lock_guard<std::mutex> lock(mutex);
                failed = true;
                failure = problem;
                queue.clear();
                finishing = true;
                break;
            }
        }
        if (writer) {
            HRESULT done = writer->Finalize();
            if (FAILED(done)) {
                std::lock_guard<std::mutex> lock(mutex);
                if (!failed) { failed = true; failure = hr("Finishing the recording failed", done); }
            }
            writer->Release();
        }
        if (SUCCEEDED(started)) MFShutdown();
        if (SUCCEEDED(com)) CoUninitialize();
    }

    std::string open(IMFSinkWriter **writerOut, DWORD &stream) {
        IMFAttributes *attributes = nullptr;
        IMFMediaType *output = nullptr, *input = nullptr;
        std::string error;
        MFCreateAttributes(&attributes, 2);
        if (attributes) {
            attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
            attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
        }
        HRESULT result = MFCreateSinkWriterFromURL(path.c_str(), nullptr, attributes, writerOut);
        if (FAILED(result)) error = hr("Creating the video file failed", result);
        if (error.empty()) {
            result = MFCreateMediaType(&output);
            if (SUCCEEDED(result)) {
                const UINT32 bitrate = std::min<UINT64>(40000000ULL, std::max<UINT64>(4000000ULL, UINT64(width) * height * 6));
                output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
                output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
                output->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
                output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                MFSetAttributeSize(output, MF_MT_FRAME_SIZE, width, height);
                MFSetAttributeRatio(output, MF_MT_FRAME_RATE, fps, 1);
                MFSetAttributeRatio(output, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
                result = (*writerOut)->AddStream(output, &stream);
            }
            if (FAILED(result)) error = hr("Configuring the H.264 encoder failed", result);
        }
        if (error.empty()) {
            result = MFCreateMediaType(&input);
            if (SUCCEEDED(result)) {
                input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
                input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
                input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                MFSetAttributeSize(input, MF_MT_FRAME_SIZE, width, height);
                MFSetAttributeRatio(input, MF_MT_FRAME_RATE, fps, 1);
                MFSetAttributeRatio(input, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
                input->SetUINT32(MF_MT_DEFAULT_STRIDE, UINT32(-LONG(width * 4)));
                result = (*writerOut)->SetInputMediaType(stream, input, nullptr);
            }
            if (FAILED(result)) error = hr("Configuring the video encoder input failed", result);
        }
        if (error.empty()) {
            result = (*writerOut)->BeginWriting();
            if (FAILED(result)) error = hr("Starting the video file failed", result);
        }
        if (input) input->Release();
        if (output) output->Release();
        if (attributes) attributes->Release();
        if (!error.empty() && *writerOut) { (*writerOut)->Release(); *writerOut = nullptr; }
        return error;
    }

    std::string write(IMFSinkWriter *writer, DWORD stream, const Item &item) {
        const DWORD bytes = DWORD(item.image->pixels.size());
        IMFMediaBuffer *buffer = nullptr;
        IMFSample *sample = nullptr;
        HRESULT result = MFCreateMemoryBuffer(bytes, &buffer);
        BYTE *target = nullptr;
        if (SUCCEEDED(result)) result = buffer->Lock(&target, nullptr, nullptr);
        if (SUCCEEDED(result)) {
            std::memcpy(target, item.image->pixels.data(), bytes);
            buffer->Unlock();
            result = buffer->SetCurrentLength(bytes);
        }
        if (SUCCEEDED(result)) result = MFCreateSample(&sample);
        if (SUCCEEDED(result)) result = sample->AddBuffer(buffer);
        if (SUCCEEDED(result)) result = sample->SetSampleTime(item.time);
        if (SUCCEEDED(result)) result = sample->SetSampleDuration(10000000LL / fps);
        if (SUCCEEDED(result)) result = writer->WriteSample(stream, sample);
        if (sample) sample->Release();
        if (buffer) buffer->Release();
        return FAILED(result) ? hr("Encoding a video frame failed", result) : std::string();
    }

public:
    ~Recorder() { std::string ignored; stop(ignored); }
    bool recording() const { return active; }
    const std::wstring &file() const { return path; }
    unsigned frameWidth() const { return width; }
    unsigned frameHeight() const { return height; }

    bool start(const std::wstring &target, unsigned frameW, unsigned frameH, std::string &error) {
        if (active) return true;
        if (!frameW || !frameH || (frameW & 1) || (frameH & 1)) {
            error = "The video size is not supported for recording.";
            return false;
        }
        path = target;
        width = frameW;
        height = frameH;
        finishing = failed = false;
        failure.clear();
        queue.clear();
        startTick = nowTicks();
        active = true;
        worker = std::thread([this] { run(); });
        return true;
    }

    // Returns false once the worker has hit an error; message holds the reason.
    bool push(const unsigned char *pixels, unsigned frameW, unsigned frameH, std::string &message) {
        if (!active) return true;
        std::lock_guard<std::mutex> lock(mutex);
        if (failed) { message = failure; return false; }
        if (frameW != width || frameH != height) {
            message = "Recording stopped because the phone video size changed.";
            return false;
        }
        if (queue.size() < maxQueued) {
            auto image = std::make_shared<Image>();
            image->width = frameW;
            image->height = frameH;
            image->pixels.assign(pixels, pixels + size_t(frameW) * frameH * 4);
            queue.push_back({image, LONGLONG(nowTicks() - startTick)});
            wake.notify_one();
        }
        return true;
    }

    // Finalizes the file. Returns true when the recording completed without errors.
    bool stop(std::string &error) {
        if (!active) return true;
        {
            std::lock_guard<std::mutex> lock(mutex);
            finishing = true;
        }
        wake.notify_all();
        if (worker.joinable()) worker.join();
        active = false;
        std::lock_guard<std::mutex> lock(mutex);
        if (failed) error = failure;
        return !failed;
    }

    uint64_t elapsedSeconds() const { return active ? (nowTicks() - startTick) / 10000000ULL : 0; }
};

}
