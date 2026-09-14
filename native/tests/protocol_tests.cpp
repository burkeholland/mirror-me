// SPDX-License-Identifier: GPL-3.0-or-later
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <windns.h>
#include <iphlpapi.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include <plist/plist.h>
#include "mirrorme.h"
#include "dnssd.h"

extern "C" void mm_dnssd_set_stop_event(dnssd_t *, HANDLE);
extern "C" void mm_protocol_session(void *, uint64_t, int);
static void require(bool passed, const char *message) {
    if (!passed) { std::fprintf(stderr, "FAIL: %s\n", message); ExitProcess(1); }
}
struct Events {
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::atomic<int> ready_count{0}, connecting{0}, ended{0}, errors{0};
    std::atomic<int> callback_count{0};
    ~Events() { CloseHandle(ready); }
};
static void event(void *context, int kind, const char *message) {
    auto *events = static_cast<Events *>(context);
    events->callback_count++;
    if (kind == MM_EVENT_READY) { events->ready_count++; SetEvent(events->ready); }
    if (kind == MM_EVENT_CONNECTING) events->connecting++;
    if (kind == MM_EVENT_SESSION_ENDED) events->ended++;
    if (kind == MM_EVENT_ERROR) {
        events->errors++;
        std::fprintf(stderr, "Receiver error: %.240s\n", message ? message : "");
        SetEvent(events->ready);
    }
}
struct Resolve {
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    DWORD status = ERROR_IO_PENDING;
    PDNS_SERVICE_INSTANCE instance = nullptr;
    ~Resolve() { if (instance) DnsServiceFreeInstance(instance); CloseHandle(done); }
};
static void WINAPI resolved(DWORD status, void *context, PDNS_SERVICE_INSTANCE instance) {
    auto *result = static_cast<Resolve *>(context);
    result->status = status; result->instance = instance;
    SetEvent(result->done);
}
static unsigned short resolve_port(const std::wstring &name, bool pin) {
    Resolve result;
    DNS_SERVICE_RESOLVE_REQUEST request{};
    DNS_SERVICE_CANCEL cancel{};
    request.Version = DNS_QUERY_REQUEST_VERSION1;
    request.QueryName = const_cast<PWSTR>(name.c_str());
    request.pResolveCompletionCallback = resolved;
    request.pQueryContext = &result;
    require(DnsServiceResolve(&request, &cancel) == DNS_REQUEST_PENDING, "native DNS-SD resolve accepted");
    if (WaitForSingleObject(result.done, 10000) != WAIT_OBJECT_0) {
        DnsServiceResolveCancel(&cancel);
        require(WaitForSingleObject(result.done, 3000) == WAIT_OBJECT_0, "DNS-SD resolve cancellation drained");
        require(false, "native DNS-SD resolve deadline");
    }
    require(result.status == ERROR_SUCCESS && result.instance && result.instance->wPort, "registered service resolves locally");
    bool public_key = false, features = false, password_flag = false;
    for (DWORD i = 0; i < result.instance->dwPropertyCount; ++i) {
        if (!_wcsicmp(result.instance->keys[i], L"pk")) public_key = wcslen(result.instance->values[i]) == 64;
        if (!_wcsicmp(result.instance->keys[i], L"features") || !_wcsicmp(result.instance->keys[i], L"ft")) features = true;
        if (!_wcsicmp(result.instance->keys[i], L"pw"))
            password_flag = !_wcsicmp(result.instance->values[i], pin ? L"true" : L"false");
    }
    require(public_key && features && password_flag, "native DNS-SD preserves protocol TXT and PIN fields");
    return result.instance->wPort;
}
static bool multicast_discovery(const std::string &service, const std::string &instance_label) {
    SOCKET socket = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    require(socket != INVALID_SOCKET, "mDNS query socket");
    BOOL reuse = TRUE;
    setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char *>(&reuse), sizeof(reuse));
    sockaddr_in local{}; local.sin_family = AF_INET; local.sin_port = htons(5353);
    require(bind(socket, reinterpret_cast<sockaddr *>(&local), sizeof(local)) == 0, "mDNS query shared bind");
    std::vector<IN_ADDR> interfaces;
    ULONG adapter_bytes = 16384;
    std::vector<unsigned char> adapters(adapter_bytes);
    auto *adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES *>(adapters.data());
    if (GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                            GAA_FLAG_SKIP_DNS_SERVER, nullptr, adapter, &adapter_bytes) == NO_ERROR) {
        for (auto *item = adapter; item; item = item->Next) {
            if (item->OperStatus != IfOperStatusUp || item->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
            for (auto *address = item->FirstUnicastAddress; address; address = address->Next) {
                if (address->Address.lpSockaddr->sa_family != AF_INET) continue;
                auto ip = reinterpret_cast<sockaddr_in *>(address->Address.lpSockaddr)->sin_addr;
                ip_mreq membership{};
                inet_pton(AF_INET, "224.0.0.251", &membership.imr_multiaddr);
                membership.imr_interface = ip;
                if (!setsockopt(socket, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                                reinterpret_cast<const char *>(&membership), sizeof(membership)))
                    interfaces.push_back(ip);
            }
        }
    }
    DWORD timeout = 500;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    std::vector<unsigned char> query(12, 0);
    query[5] = 1;
    size_t start = 0;
    for (;;) {
        auto end = service.find('.', start);
        auto part = service.substr(start, end == std::string::npos ? end : end - start);
        query.push_back(static_cast<unsigned char>(part.size()));
        query.insert(query.end(), part.begin(), part.end());
        if (end == std::string::npos) break;
        start = end + 1;
    }
    query.insert(query.end(), {0, 0, 12, 0, 1}); // PTR, Internet, multicast response.
    sockaddr_in destination{}; destination.sin_family = AF_INET;
    destination.sin_port = htons(5353); inet_pton(AF_INET, "224.0.0.251", &destination.sin_addr);
    bool found = false;
    // DNS label matching is ASCII-case-insensitive, including UTF-8 instances.
    auto fold_ascii = [](std::string text) {
        for (char &byte : text) if (byte >= 'A' && byte <= 'Z') byte += 'a' - 'A';
        return text;
    };
    const std::string folded_name = fold_ascii(instance_label);
    ULONGLONG next_query = 0;
    ULONGLONG deadline = GetTickCount64() + 8000;
    while (!found && GetTickCount64() < deadline) {
        if (GetTickCount64() >= next_query) {
            next_query = GetTickCount64() + 500;
            for (auto ip : interfaces) {
                setsockopt(socket, IPPROTO_IP, IP_MULTICAST_IF, reinterpret_cast<const char *>(&ip), sizeof(ip));
                sendto(socket, reinterpret_cast<const char *>(query.data()), static_cast<int>(query.size()), 0,
                       reinterpret_cast<sockaddr *>(&destination), sizeof(destination));
            }
        }
        char buffer[9000];
        int count = recv(socket, buffer, sizeof(buffer), 0);
        if (count > 12) {
            std::string packet(buffer, count);
            found = (static_cast<unsigned char>(buffer[2]) & 0x80) &&
                    fold_ascii(packet).find(folded_name) != std::string::npos;
        }
    }
    closesocket(socket);
    return found;
}
static SOCKET connect_to(unsigned short port) {
    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    require(socket != INVALID_SOCKET, "RTSP socket");
    DWORD timeout = 3000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    require(connect(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0, "RTSP loopback connect");
    return socket;
}
static std::string exchange(SOCKET socket, const std::string &request, bool fragmented = false) {
    if (fragmented) {
        // Split method, URL and protocol across individual receive buffers.
        for (size_t i = 0; i < request.size(); ++i) {
            require(send(socket, request.data() + i, 1, 0) == 1, "send fragmented request byte");
            if (i < 20) Sleep(2);
        }
    } else {
        require(send(socket, request.data(), static_cast<int>(request.size()), 0) == static_cast<int>(request.size()), "send request");
    }
    std::string response;
    size_t expected = 0;
    ULONGLONG deadline = GetTickCount64() + 5000;
    while (GetTickCount64() < deadline) {
        char bytes[4096];
        int count = recv(socket, bytes, sizeof(bytes), 0);
        if (count <= 0) break;
        response.append(bytes, count);
        auto header_end = response.find("\r\n\r\n");
        if (header_end != std::string::npos) {
            expected = header_end + 4;
            auto length = response.find("Content-Length:");
            if (length != std::string::npos)
                expected += std::strtoul(response.c_str() + length + 15, nullptr, 10);
            if (response.size() >= expected) break;
        }
        require(response.size() < 1024 * 1024, "bounded RTSP response");
    }
    return response;
}
static void rejected_wire_request(unsigned short port, const std::string &request, bool truncated = false) {
    SOCKET socket = connect_to(port);
    DWORD timeout = 1000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    require(send(socket, request.data(), static_cast<int>(request.size()), 0) == static_cast<int>(request.size()),
            "send malformed wire request");
    if (truncated) shutdown(socket, SD_SEND);
    char bytes[128];
    int count = recv(socket, bytes, sizeof(bytes), 0);
    require(count == 0 || (count == SOCKET_ERROR && WSAGetLastError() == WSAECONNRESET),
            "invalid declared length/truncated request closes without dispatch");
    closesocket(socket);
}
static uint64_t integer(plist_t node, const char *key) {
    uint64_t value = 0; plist_get_uint_val(plist_dict_get_item(node, key), &value); return value;
}
static BOOL CALLBACK count_windows(HWND window, LPARAM parameter) {
    DWORD process = 0; GetWindowThreadProcessId(window, &process);
    if (process == GetCurrentProcessId() && IsWindowVisible(window))
        ++*reinterpret_cast<unsigned *>(parameter);
    return TRUE;
}
static std::wstring dns_label(const std::string &name) {
    std::string escaped;
    for (char byte : name) {
        if (byte == '.' || byte == '\\') escaped += '\\';
        escaped += byte;
    }
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, escaped.data(),
                                   static_cast<int>(escaped.size()), nullptr, 0);
    require(size > 0, "UTF-8 DNS query fixture");
    std::wstring result(size, L'\0');
    require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, escaped.data(),
                               static_cast<int>(escaped.size()), result.data(), size) == size,
            "UTF-8 DNS query conversion");
    return result;
}
static void configuration_validation() {
    mm_receiver_config config{};
    config.name = "MirrorMe automatic configuration";
    config.device_id = "02:4D:4D:00:00:01";
    config.key_path = "unused-configuration-test.key";
    auto accepted = [&](bool expected) {
        char error[256]{};
        mm_receiver *receiver = mm_receiver_create(&config, nullptr, nullptr, error, sizeof(error));
        require((receiver != nullptr) == expected, "public automatic configuration validation");
        if (receiver) mm_receiver_destroy(receiver);
    };
    accepted(true);
    config.width = 1280; accepted(false);
    config.width = 0; config.height = 720; accepted(false);
    config.width = 1280; accepted(true);
    config.width = 63; accepted(false);
    config.width = 8193; accepted(false);
    config.width = 1280; config.height = 63; accepted(false);
    config.height = 8193; accepted(false);
    config.height = 720; config.max_fps = 121; accepted(false);
    config.width = config.height = 0; config.max_fps = 30; accepted(true);
    std::string name(50, 'n');
    config.name = name.c_str(); accepted(true);
    name += 'n'; config.name = name.c_str(); accepted(false);
    name.clear();
    for (int i = 0; i < 25; ++i) name += "\xC3\xA9";
    config.name = name.c_str(); accepted(true);
    name += "\xC3\xA9"; config.name = name.c_str(); accepted(false);
    std::puts("PASS: paired automatic dimensions/FPS, mixed-zero rejection and unchanged UTF-8 name budget");
}
int main(int argc, char **argv) {
    const bool probe_escaped_name = argc == 2 && !std::strcmp(argv[1], "--probe-escaped-name");
    WSADATA winsock{}; require(WSAStartup(MAKEWORD(2, 2), &winsock) == 0, "Winsock startup");
    configuration_validation();
    DeleteFileW(L"protocol-\u2603-test.key");
    unsigned windows = 0; EnumWindows(count_windows, reinterpret_cast<LPARAM>(&windows));
    std::string expected_key;
    for (int round = 0; round < 3; ++round) {
        std::string name = "MirrorMe protocol test " + std::to_string(GetCurrentProcessId()) + " " + std::to_string(round);
        if (round == 2) {
            name = std::string(probe_escaped_name ? "MirrorMe.auto\\test " : "MirrorMe auto test ") +
                   std::to_string(GetCurrentProcessId()) + " \xE2\x98\x83";
            name.append(50 - name.size(), 'x');
        }
        mm_receiver_config config{};
        config.name = name.c_str(); config.device_id = "02:4D:4D:00:00:01";
        config.key_path = "protocol-\xE2\x98\x83-test.key"; config.width = 1280; config.height = 720; config.max_fps = 30;
        if (round == 2) config.width = config.height = config.max_fps = 0;
        config.idle_timeout_seconds = 10; config.prefer_newest = round != 1;
        config.require_pin = round == 1; config.pin = 0;
        Events events; char error[256]{};
        char *name_argument = _strdup(config.name);
        char *identity_argument = _strdup(config.device_id);
        char *key_argument = _strdup(config.key_path);
        require(name_argument && identity_argument && key_argument, "configuration string fixture allocation");
        config.name = name_argument; config.device_id = identity_argument; config.key_path = key_argument;
        mm_receiver *receiver = mm_receiver_create(&config, event, &events, error, sizeof(error));
        // Match cgo: caller-owned C strings are released immediately after create.
        std::free(name_argument); std::free(identity_argument); std::free(key_argument);
        require(receiver != nullptr, "receiver creation");
        int result = -1;
        std::thread runner([&] { result = mm_receiver_run(receiver); });
        require(WaitForSingleObject(events.ready, 15000) == WAIT_OBJECT_0, "receiver startup deadline");
        require(events.ready_count == 1 && events.errors == 0, "ready only after both native DNS registrations");
        std::wstring wide_name = dns_label(name);
        unsigned short port = resolve_port(wide_name + L"._airplay._tcp.local", config.require_pin);
        require(resolve_port(L"024D4D000001@" + wide_name + L"._raop._tcp.local", config.require_pin) == port, "both services use protocol listener");
        if (round != 1) {
            require(multicast_discovery("_airplay._tcp.local", name), "actual local-network AirPlay mDNS PTR response");
            require(multicast_discovery("_raop._tcp.local", "024D4D000001@" + name), "actual local-network RAOP mDNS PTR response");
        }
        SOCKET connection = connect_to(port);
        auto response = exchange(connection, "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n", true);
        require(response.find("RTSP/1.0 200") == 0 && response.find("SETUP") != std::string::npos, "fragmented RTSP OPTIONS handshake");
        SOCKET negotiation = connect_to(port);
        require(exchange(negotiation, "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n").find("RTSP/1.0 200") == 0,
                "parallel negotiation is not treated as an active device");
        closesocket(negotiation);
        response = exchange(connection, "GET /info RTSP/1.0\r\nCSeq: 2\r\n\r\n");
        require(response.find("RTSP/1.0 200") == 0, "new negotiation does not evict existing RTSP connection");
        auto header_end = response.find("\r\n\r\n");
        require(header_end != std::string::npos, "RTSP info body");
        plist_t info = nullptr;
        plist_from_bin(response.data() + header_end + 4, static_cast<uint32_t>(response.size() - header_end - 4), &info);
        require(PLIST_IS_DICT(info), "binary plist info");
        plist_t display = plist_array_get_item(plist_dict_get_item(info, "displays"), 0);
        require(integer(display, "width") == (round == 2 ? 1920U : 1280U) &&
                integer(display, "height") == (round == 2 ? 1080U : 720U) &&
                integer(display, "maxFPS") == (round == 2 ? 60U : 30U),
                "negotiated video limits match explicit or normalized automatic config");
        uint64_t features = integer(info, "features");
        require((features & (uint64_t{1} << 7)) && !(features & 0x11), "mirroring advertised, HLS not advertised");
        uint64_t key_size = 0;
        const char *key = plist_get_data_ptr(plist_dict_get_item(info, "pk"), &key_size);
        require(key && key_size == 32, "persistent public identity present");
        if (!round) expected_key.assign(key, key_size);
        else require(expected_key == std::string(key, key_size), "private identity survives repeated starts and Unicode key paths");
        plist_free(info);
        if (config.require_pin) {
            response = exchange(connection, "POST /pair-pin-start RTSP/1.0\r\nCSeq: 3\r\nContent-Length: 0\r\n\r\n");
            require(response.find("RTSP/1.0 200") == 0, "required PIN 0000 pairing starts");
        }
        response = exchange(connection, "SETUP /stream RTSP/1.0\r\nCSeq: 4\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: 3\r\n\r\nbad");
        require(response.find("RTSP/1.0 400") == 0, "malformed setup plist is rejected");
        response = exchange(connection, "POST /play HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
        require(response.find("HTTP/1.1 501") == 0, "URL/HLS playback explicitly rejected");
        if (!round) {
            for (const auto *length : {"1048577", "4294967295", "18446744073709551616", "-1"})
                rejected_wire_request(port, std::string("SETUP /stream RTSP/1.0\r\nCSeq: 6\r\nContent-Length: ") +
                                      length + "\r\n\r\n");
            rejected_wire_request(port, "SETUP /stream RTSP/1.0\r\nCSeq: 7\r\nContent-Length: 4096\r\n\r\nshort", true);
            require(exchange(connection, "OPTIONS * RTSP/1.0\r\nCSeq: 8\r\n\r\n").find("RTSP/1.0 200") == 0,
                    "listener survives malformed and truncated traffic");
        }
        closesocket(connection);
        Sleep(100);
        require(events.connecting == 0 && events.ended == 0, "negotiation socket closure is not a media session transition");
        mm_protocol_session(receiver, 100, 1);
        mm_protocol_session(receiver, 100, 2);
        mm_protocol_session(receiver, 100, 3);
        require(events.connecting == 1 && events.ended == 1, "synthetic identity ends once after producer drain");
        mm_protocol_session(receiver, 101, 1);
        mm_protocol_session(receiver, 100, 2);
        mm_protocol_session(receiver, 100, 3);
        mm_protocol_session(receiver, 100, 1);
        require(events.connecting == 2 && events.ended == 1, "stale lifecycle callbacks cannot terminate or revive a replacement");
        mm_protocol_session(receiver, 101, 3);
        require(events.ended == 2, "replacement session ends exactly once");
        unsigned idle_windows = 0; EnumWindows(count_windows, reinterpret_cast<LPARAM>(&idle_windows));
        require(idle_windows == windows, "no video/tray window appears at idle");
        SOCKET incomplete = connect_to(port);
        const std::string unfinished = round == 1 ?
            "SETUP /stream RTSP/1.0\r\nCSeq: 9\r\nContent-Length: 1048576\r\n\r\nshort" : "OP";
        require(send(incomplete, unfinished.data(), static_cast<int>(unfinished.size()), 0) ==
                static_cast<int>(unfinished.size()), "send unfinished request before stopping");
        Sleep(50);
        ULONGLONG stop_started = GetTickCount64();
        mm_receiver_request_stop(receiver);
        runner.join();
        require(GetTickCount64() - stop_started < 8000 && result == 0, "stop drains fragmented request and native DNS ownership");
        closesocket(incomplete);
        mm_receiver_destroy(receiver);
        int callbacks_after_destroy = events.callback_count;
        Sleep(50);
        require(events.callback_count == callbacks_after_destroy, "callback context is quiescent after destroy");
        std::printf("PASS: lifecycle/handshake/limits/malformed/PIN round %d\n", round + 1);
    }
    {
        int error = 0;
        char address[] = {2, 0x4d, 0x4d, 0, 0, 2};
        const char *name = "MirrorMe cancellation probe";
        dnssd_t *dns = dnssd_init(name, static_cast<int>(std::strlen(name)), address, 6, &error, 0);
        require(dns != nullptr, "DNS cancellation fixture");
        char key[65]; std::memset(key, 'a', 64); key[64] = 0; dnssd_set_pk(dns, key);
        HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, nullptr); mm_dnssd_set_stop_event(dns, stop);
        std::thread cancel([&] { Sleep(50); SetEvent(stop); });
        ULONGLONG started = GetTickCount64();
        int status = dnssd_register_airplay(dns, 45678);
        cancel.join();
        require(status == ERROR_CANCELLED || status == 0, "registration cancellation or completed-before-cancel");
        dnssd_destroy(dns); CloseHandle(stop);
        require(GetTickCount64() - started < 8000, "cancellation cleanup deadline");
        std::printf("PASS: native DNS registration %s; bounded cleanup\n",
                    status == ERROR_CANCELLED ? "cancelled" : "completed before cancellation");
    }
    {
        mm_receiver_config config{};
        config.name = "MirrorMe pre-cancel test"; config.device_id = "02:4D:4D:00:00:01";
        config.key_path = "protocol-unused.key"; config.width = 1280; config.height = 720; config.max_fps = 30;
        Events events; char error[256]{};
        mm_receiver *receiver = mm_receiver_create(&config, event, &events, error, sizeof(error));
        require(receiver != nullptr, "pre-cancel creation");
        mm_receiver_request_stop(receiver);
        require(mm_receiver_run(receiver) == 0 && !events.ready_count && !events.errors, "stop before run never announces readiness");
        mm_receiver_destroy(receiver);
        require(GetFileAttributesW(L"protocol-unused.key") == INVALID_FILE_ATTRIBUTES, "pre-cancel creates no identity");
        std::puts("PASS: pre-start cancellation");
    }
    {
        HANDLE file = CreateFileW(L"protocol-\u2603-test.key", GENERIC_WRITE, 0, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        require(file != INVALID_HANDLE_VALUE, "open private identity corruption fixture");
        DWORD written = 0;
        require(WriteFile(file, "invalid", 7, &written, nullptr) && written == 7 && SetEndOfFile(file),
                "write bounded malformed identity fixture");
        CloseHandle(file);
        mm_receiver_config config{};
        config.name = "MirrorMe identity failure test"; config.device_id = "02:4D:4D:00:00:01";
        config.key_path = "protocol-\xE2\x98\x83-test.key"; config.width = 1280; config.height = 720; config.max_fps = 30;
        Events events; char error[256]{};
        mm_receiver *receiver = mm_receiver_create(&config, event, &events, error, sizeof(error));
        require(receiver != nullptr, "malformed identity receiver fixture");
        require(mm_receiver_run(receiver) != 0 && events.errors == 1 && !events.ready_count,
                "malformed identity fails without speculative readiness");
        mm_receiver_destroy(receiver);
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        require(GetFileAttributesExW(L"protocol-\u2603-test.key", GetFileExInfoStandard, &attributes) &&
                attributes.nFileSizeHigh == 0 && attributes.nFileSizeLow == 7,
                "malformed identity is not silently overwritten");
        std::puts("PASS: invalid identity remains untouched and blocks readiness");
    }
    DeleteFileW(L"protocol-\u2603-test.key");
    DeleteFileW(L"protocol-test.key");
    WSACleanup();
#ifdef MM_PROTOCOL_TEST_STUB
    std::puts("PASS: protocol-only tests (explicit media stub; no physical iPhone or playback claim)");
#else
    std::puts("PASS: native receiver protocol tests (no physical iPhone claim)");
#endif
    return 0;
}
