// SPDX-License-Identifier: GPL-3.0-or-later
#include "../media_capture.h"
#include <cstdlib>

static void check(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}

static std::wstring tempRecording() {
    wchar_t directory[MAX_PATH], path[MAX_PATH];
    check(GetTempPathW(MAX_PATH, directory) != 0, "temporary directory");
    check(GetTempFileNameW(directory, L"mmc", 0, path) != 0, "temporary recording");
    check(DeleteFileW(path) != 0, "remove temporary placeholder");
    return std::wstring(path) + L".mp4";
}

static void checkStillScreen() {
    const unsigned width = 64, height = 64;
    std::vector<unsigned char> pixels(size_t(width) * height * 4, 128);
    std::string error;
    {
        const std::wstring file = tempRecording();
        mmcapture::Recorder recorder;
        check(recorder.start(file, width, height, error), error.c_str());
        check(recorder.push(pixels.data(), width, height, error), error.c_str());
        Sleep(800);
        check(recorder.stop(error), "a single unchanged frame still produces a recording");
        IMFSourceReader *reader = nullptr;
        check(SUCCEEDED(MFCreateSourceReaderFromURL(file.c_str(), nullptr, &reader)), "open still recording");
        PROPVARIANT duration;
        PropVariantInit(&duration);
        check(SUCCEEDED(reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &duration)),
            "still recording duration");
        check(duration.uhVal.QuadPart >= 6000000, "the last frame is held until Stop");
        PropVariantClear(&duration);
        reader->Release();
        check(DeleteFileW(file.c_str()) != 0, "remove still recording");
    }
    {
        const std::wstring file = tempRecording();
        mmcapture::Recorder recorder;
        check(recorder.start(file, width, height, error), error.c_str());
        error.clear();
        check(!recorder.stop(error) && !error.empty(), "a frameless recording reports a clear error");
        check(GetFileAttributesW(file.c_str()) == INVALID_FILE_ATTRIBUTES, "a frameless recording leaves no empty file");
    }
}

static void checkOrientation(unsigned width, unsigned height) {
    const std::wstring file = tempRecording();
    std::vector<unsigned char> pixels(size_t(width) * height * 4);
    for (unsigned y = 0; y < height; ++y) {
        for (unsigned x = 0; x < width; ++x) {
            auto *pixel = pixels.data() + (size_t(y) * width + x) * 4;
            pixel[0] = y < height / 2 ? 0 : 255;
            pixel[1] = 0;
            pixel[2] = y < height / 2 ? 255 : 0;
            pixel[3] = 255;
        }
    }
    mmcapture::Recorder recorder;
    std::string error;
    check(recorder.start(file, width, height, error), error.c_str());
    for (unsigned i = 0; i < 6; ++i) {
        check(recorder.push(pixels.data(), width, height, error), error.c_str());
        Sleep(35);
    }
    check(recorder.stop(error), error.c_str());

    IMFAttributes *attributes = nullptr;
    IMFSourceReader *reader = nullptr;
    IMFMediaType *type = nullptr;
    check(SUCCEEDED(MFCreateAttributes(&attributes, 1)), "reader attributes");
    check(SUCCEEDED(attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE)),
        "enable RGB decoding");
    check(SUCCEEDED(MFCreateSourceReaderFromURL(file.c_str(), attributes, &reader)), "open recorded MP4");
    attributes->Release();
    check(SUCCEEDED(MFCreateMediaType(&type)), "decoded media type");
    check(SUCCEEDED(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video)), "decoded video");
    check(SUCCEEDED(type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32)), "decoded RGB32");
    check(SUCCEEDED(reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, type)),
        "configure RGB decoding");
    type->Release();
    check(SUCCEEDED(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &type)),
        "decoded layout");
    UINT32 decodedWidth = 0, decodedHeight = 0;
    check(SUCCEEDED(MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &decodedWidth, &decodedHeight)) &&
        decodedWidth == width && decodedHeight == height, "recording preserves dimensions");
    LONG stride = LONG(MFGetAttributeUINT32(type, MF_MT_DEFAULT_STRIDE, UINT32(-LONG(width * 4))));
    type->Release();
    IMFSample *sample = nullptr;
    for (unsigned i = 0; i < 20 && !sample; ++i) {
        DWORD flags = 0;
        check(SUCCEEDED(reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr,
            &flags, nullptr, &sample)), "decode recorded frame");
        check(!(flags & MF_SOURCE_READERF_ENDOFSTREAM), "recording contains video");
    }
    check(sample != nullptr, "decoded frame available");
    IMFMediaBuffer *buffer = nullptr;
    check(SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer)), "decoded frame buffer");
    BYTE *base = nullptr;
    check(SUCCEEDED(buffer->Lock(&base, nullptr, nullptr)), "lock decoded pixels");
    const BYTE *top = stride < 0 ? base + size_t(-stride) * (height - 1) : base;
    const BYTE *upper = top + ptrdiff_t(stride) * (height / 4) + (width / 2) * 4;
    const BYTE *lower = top + ptrdiff_t(stride) * (height * 3 / 4) + (width / 2) * 4;
    const bool upright = upper[2] > 180 && upper[0] < 75 &&
        lower[0] > 180 && lower[2] < 75;
    buffer->Unlock();
    buffer->Release();
    sample->Release();
    reader->Release();
    check(DeleteFileW(file.c_str()) != 0, "remove test recording");
    check(upright, "recorded MP4 keeps red above blue, matching top-down source pixels");
}

int main() {
    check(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)), "COM startup");
    check(SUCCEEDED(MFStartup(MF_VERSION)), "Media Foundation startup");
    checkOrientation(160, 96);
    checkOrientation(96, 160);
    checkStillScreen();
    MFShutdown();
    CoUninitialize();
    std::puts("PASS: MP4 orientation, still-screen duration and frameless-recording cleanup");
}
