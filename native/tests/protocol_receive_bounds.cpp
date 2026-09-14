// SPDX-License-Identifier: GPL-3.0-or-later
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
extern "C" {
#include "http_request.h"
#include "raop_rtp_mirror.h"
#include "mirror_buffer.h"
}

static std::atomic<size_t> largest_allocation{0};
static void require(bool condition, const char *message) {
    if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); ExitProcess(1); }
}
static bool observe_allocation(size_t bytes) {
    size_t previous = largest_allocation.load();
    while (previous < bytes && !largest_allocation.compare_exchange_weak(previous, bytes)) {}
    // A regression must fail the probe, not attempt a peer-declared multi-GB allocation.
    return bytes <= 16 * 1024 * 1024;
}
extern "C" void *__real_malloc(size_t);
extern "C" void *__real_calloc(size_t, size_t);
extern "C" void *__real_realloc(void *, size_t);
extern "C" void *__wrap_malloc(size_t bytes) {
    return observe_allocation(bytes) ? __real_malloc(bytes) : nullptr;
}
extern "C" void *__wrap_calloc(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) { observe_allocation(SIZE_MAX); return nullptr; }
    return observe_allocation(count * size) ? __real_calloc(count, size) : nullptr;
}
extern "C" void *__wrap_realloc(void *pointer, size_t bytes) {
    return observe_allocation(bytes) ? __real_realloc(pointer, bytes) : nullptr;
}

static void reject_http(const std::string &wire, bool fragmented = false) {
    auto *request = http_request_init();
    require(request != nullptr, "HTTP parser fixture");
    largest_allocation = 0;
    for (size_t offset = 0; offset < wire.size() && !http_request_has_error(request);) {
        size_t bytes = fragmented ? 1 : wire.size() - offset;
        http_request_add_data(request, wire.data() + offset, static_cast<int>(bytes));
        offset += bytes;
    }
    int bytes = -1;
    const char *body = http_request_get_data(request, &bytes);
    require(http_request_has_error(request) && !http_request_is_complete(request), "invalid declared HTTP length is rejected");
    require(!body && bytes == 0, "invalid declared length rejected before any body allocation");
    require(largest_allocation <= 16385, "header allocations are independently bounded");
    http_request_destroy(request);
}
static void http_boundaries() {
    for (const auto *length : {"1048577", "2147483647", "4294967295", "18446744073709551615",
                              "18446744073709551616", "-1", "+1", "12junk"}) {
        auto wire = std::string("SETUP /stream RTSP/1.0\r\nCSeq: 1\r\nContent-Length: ") + length + "\r\n\r\nx";
        reject_http(wire);
        reject_http(wire, true);
    }
    reject_http("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n100001\r\nx");
    reject_http("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nabc");
    reject_http("OPTIONS /" + std::string(2048, 'a') + " RTSP/1.0\r\n\r\n", true);
    reject_http("OPTIONS * RTSP/1.0\r\nOversized: " + std::string(16385, 'a') + "\r\n\r\n", true);
    std::string fields = "OPTIONS * RTSP/1.0\r\n";
    for (int i = 0; i < 65; ++i) fields += "X-" + std::to_string(i) + ": a\r\n";
    reject_http(fields + "\r\n", true);
    auto *request = http_request_init();
    const std::string header = "SETUP / RTSP/1.0\r\nContent-Length: 1048576\r\n\r\n";
    require(http_request_add_data(request, header.data(), static_cast<int>(header.size())) == 0,
            "maximum supported content length accepted");
    int bytes = -1;
    require(!http_request_get_data(request, &bytes) && bytes == 0, "declared length does not preallocate a body");
    std::string block(1024, 'a');
    largest_allocation = 0;
    for (int i = 0; i < 1024; ++i)
        require(http_request_add_data(request, block.data(), static_cast<int>(block.size())) == 0, "bounded body fragment accepted");
    require(http_request_is_complete(request) && !http_request_has_error(request), "maximum body completes");
    require(http_request_get_data(request, &bytes) && bytes == 1024 * 1024 &&
            largest_allocation <= 1024 * 1024, "body allocation never exceeds the wire limit");
    http_request_destroy(request);
    request = http_request_init();
    const std::string chunked = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n100000\r\n";
    require(http_request_add_data(request, chunked.data(), static_cast<int>(chunked.size())) == 0,
            "maximum supported chunk length accepted");
    largest_allocation = 0;
    for (int i = 0; i < 1024; ++i)
        require(http_request_add_data(request, block.data(), static_cast<int>(block.size())) == 0,
                "bounded chunked body fragment accepted");
    const std::string excess = "\r\n1\r\nx";
    require(http_request_add_data(request, excess.data(), static_cast<int>(excess.size())) != 0 &&
            http_request_has_error(request), "cumulative chunks cannot bypass body budget");
    require(http_request_get_data(request, &bytes) && bytes == 1024 * 1024 &&
            largest_allocation <= 1024 * 1024, "excess chunk rejected before growing the body allocation");
    http_request_destroy(request);
    request = http_request_init();
    require(http_request_add_data(request, block.data(), -1) != 0 && http_request_has_error(request),
            "negative receive length cannot wrap size arithmetic");
    http_request_destroy(request);
    std::puts("PASS: declared HTTP/chunk/header limits before allocation, fragmented and exact-limit bodies");
}

struct MirrorEvents {
    HANDLE exited = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::atomic<unsigned> paused{0}, resumed{0}, frames{0};
    ~MirrorEvents() { CloseHandle(exited); }
};
extern "C" void mm_protocol_session(void *context, uint64_t, int phase) {
    if (phase == 2) SetEvent(static_cast<MirrorEvents *>(context)->exited);
}
// This standalone low-level fixture never creates a receiver identity or media.
struct evp_pkey_st;
extern "C" evp_pkey_st *mm_protocol_load_identity(const char *) {
    require(false, "unexpected identity loading in receive-boundary fixture");
    return nullptr;
}
static void discard_log(void *, int, const char *) {}
struct Mirror {
    MirrorEvents events;
    logger_t *logger = logger_init();
    raop_ntp_t *ntp = nullptr;
    raop_rtp_mirror_t *receiver = nullptr;
    mirror_buffer_t *encoder = nullptr;
    SOCKET socket = INVALID_SOCKET;
    Mirror() {
        require(logger != nullptr, "mirror logger fixture");
        logger_set_level(logger, LOGGER_ERR);
        logger_set_callback(logger, discard_log, nullptr);
        raop_callbacks_t callbacks{};
        callbacks.cls = &events;
        callbacks.video_pause = [](void *context) { ++static_cast<MirrorEvents *>(context)->paused; };
        callbacks.video_resume = [](void *context) { ++static_cast<MirrorEvents *>(context)->resumed; };
        callbacks.video_set_codec = [](void *, video_codec_t) { return 0; };
        callbacks.video_process = [](void *context, raop_ntp_t *, video_decode_struct *) {
            ++static_cast<MirrorEvents *>(context)->frames;
        };
        timing_protocol_t timing = TP_NONE;
        const char remote[] = "127.0.0.1";
        ntp = raop_ntp_init(logger, &callbacks, remote, 4, 0, &timing);
        require(ntp != nullptr, "local NTP state without a timing producer");
        unsigned char key[16]{};
        receiver = raop_rtp_mirror_init(logger, &callbacks, ntp, remote, 4, key);
        require(receiver != nullptr, "real protocol TCP mirror fixture");
        encoder = mirror_buffer_init(logger, key);
        require(encoder != nullptr, "synthetic mirror cipher");
        uint64_t stream = 42;
        mirror_buffer_init_aes(encoder, &stream);
        raop_rtp_mirror_init_aes(receiver, &stream);
        unsigned short port = 0;
        raop_rtp_mirror_start(receiver, &port, 0);
        require(port != 0, "mirror TCP listener started");
        socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        require(socket != INVALID_SOCKET, "mirror probe socket");
        DWORD timeout = 500;
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
        require(connect(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0, "mirror loopback connection");
    }
    ~Mirror() {
        raop_rtp_mirror_destroy(receiver);
        mirror_buffer_destroy(encoder);
        closesocket(socket);
        raop_ntp_destroy(ntp);
        logger_destroy(logger);
    }
    void send_bytes(const void *data, size_t bytes) {
        require(send(socket, static_cast<const char *>(data), static_cast<int>(bytes), 0) == static_cast<int>(bytes),
                "bounded mirror fixture send");
    }
    void header(uint32_t bytes, unsigned char type = 0, unsigned char flags = 0) {
        unsigned char packet[128]{};
        packet[0] = static_cast<unsigned char>(bytes);
        packet[1] = static_cast<unsigned char>(bytes >> 8);
        packet[2] = static_cast<unsigned char>(bytes >> 16);
        packet[3] = static_cast<unsigned char>(bytes >> 24);
        packet[4] = type;
        packet[6] = flags;
        send_bytes(packet, sizeof(packet));
    }
    void frame() {
        unsigned char plain[]{0, 0, 0, 1, 0x65};
        unsigned char encrypted[sizeof(plain)]{};
        mirror_buffer_decrypt(encoder, plain, encrypted, sizeof(plain));
        header(sizeof(encrypted));
        send_bytes(encrypted, sizeof(encrypted));
    }
    void expect_exit(DWORD timeout) {
        require(WaitForSingleObject(events.exited, timeout) == WAIT_OBJECT_0, "malformed/truncated mirror traffic rejected before deadline");
        ULONGLONG started = GetTickCount64();
        raop_rtp_mirror_stop(receiver);
        require(GetTickCount64() - started < 1000, "already-exited mirror worker is joined promptly");
    }
};
static void mirror_pause_resume() {
    Mirror mirror;
    // Minimal configuration exercises the real wire parser, not a media decoder.
    const unsigned char codec[]{1, 0x42, 0, 0x1f, 0xff, 0xe1, 0, 2, 0x67, 1, 1, 0, 1, 0x68};
    mirror.header(sizeof(codec), 1, 0x16);
    mirror.send_bytes(codec, sizeof(codec));
    mirror.frame();
    mirror.header(0, 1, 0x56);
    mirror.header(0, 1, 0x56);
    mirror.header(0, 1, 0x16);
    mirror.header(0, 1, 0x5e);
    mirror.frame(); // Valid encrypted video also resumes when no resume header arrives.
    mirror.header(0, 1, 0x56);
    mirror.frame();
    const ULONGLONG deadline = GetTickCount64() + 1000;
    while (mirror.events.frames < 3 && GetTickCount64() < deadline) Sleep(5);
    require(mirror.events.frames == 3 && mirror.events.paused == 3 && mirror.events.resumed == 3,
            "real TCP pause/resume markers are idempotent and new encrypted video resumes");
    require(WaitForSingleObject(mirror.events.exited, 0) == WAIT_TIMEOUT,
            "zero-payload pause/resume preserves the negotiated mirror transport");
    shutdown(mirror.socket, SD_SEND);
    mirror.expect_exit(1000);
    std::puts("PASS: real encrypted TCP video, duplicate pause, empty markers, implicit resume and subsequent pauses");
}
static void mirror_boundaries() {
    for (uint32_t size : {8U * 1024U * 1024U + 1, 0x7fffffffU, 0x80000000U, 0xffffffffU, 4U}) {
        Mirror mirror;
        largest_allocation = 0;
        mirror.header(size);
        mirror.expect_exit(1000);
        require(largest_allocation < 65536, "invalid mirror header rejected before payload allocation");
    }
    {
        Mirror mirror;
        largest_allocation = 0;
        mirror.header(8 * 1024 * 1024);
        ULONGLONG deadline = GetTickCount64() + 1000;
        while (largest_allocation < 8 * 1024 * 1024 && GetTickCount64() < deadline) Sleep(5);
        require(largest_allocation == 8 * 1024 * 1024, "maximum supported mirror payload has a bounded allocation");
        ULONGLONG started = GetTickCount64();
        raop_rtp_mirror_stop(mirror.receiver);
        require(GetTickCount64() - started < 1000, "stop drains an unfinished maximum-size payload");
    }
    for (bool body : {false, true}) {
        Mirror mirror;
        if (body) mirror.header(65536);
        mirror.send_bytes("short", 5);
        shutdown(mirror.socket, SD_SEND);
        mirror.expect_exit(1000);
    }
    for (bool body : {false, true}) {
        Mirror mirror;
        if (body) mirror.header(65536);
        mirror.send_bytes("short", 5);
        mirror.expect_exit(3500);
    }
    {
        Mirror mirror;
        unsigned char packet[128]{};
        packet[4] = 2; // Supported zero-payload heartbeat, fragmented across a recv timeout.
        mirror.send_bytes(packet, 7);
        Sleep(100);
        mirror.send_bytes(packet + 7, sizeof(packet) - 7);
        require(WaitForSingleObject(mirror.events.exited, 150) == WAIT_TIMEOUT, "valid fragmented heartbeat remains connected");
        shutdown(mirror.socket, SD_SEND);
        mirror.expect_exit(1000);
    }
    for (bool body : {false, true}) {
        Mirror mirror;
        if (body) mirror.header(1024 * 1024);
        std::atomic<bool> finished{false};
        std::thread trickle([&] {
            ULONGLONG deadline = GetTickCount64() + 8000;
            while (!finished && GetTickCount64() < deadline) {
                if (send(mirror.socket, "x", 1, 0) != 1) break;
                Sleep(20);
            }
        });
        Sleep(100);
        ULONGLONG started = GetTickCount64();
        raop_rtp_mirror_stop(mirror.receiver);
        ULONGLONG elapsed = GetTickCount64() - started;
        finished = true;
        trickle.join();
        require(elapsed < 1000, "stop preempts continuous partial header/payload receives");
    }
    std::puts("PASS: real TCP mirror preallocation limits, truncated EOF/deadlines, fragmentation and trickle-stop");
}
int main() {
    WSADATA winsock{};
    require(WSAStartup(MAKEWORD(2, 2), &winsock) == 0, "Winsock startup");
    http_boundaries();
    mirror_boundaries();
    mirror_pause_resume();
    WSACleanup();
    return 0;
}
