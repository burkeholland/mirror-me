// SPDX-License-Identifier: LGPL-2.1-or-later
// TXT keys/values follow libuxplay dnssd.c, Copyright 2011-2012 Juho Vaha-Herttua,
// modified by fduncanh 2022. Windows DNS-SD ownership/registration is MirrorMe code.
#include <winsock2.h>
#include <windows.h>
#include <windns.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>
#include "dnssd.h"
#include "dnssdint.h"

namespace {
using Properties = std::vector<std::pair<std::string, std::string>>;
constexpr DWORD registration_timeout_ms = 10000;

std::wstring wide(const std::string &value) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                   static_cast<int>(value.size()), nullptr, 0);
    if (!count) return {};
    std::wstring result(count, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), count);
    return result;
}

struct Operation {
    std::atomic<unsigned> references{2};
    std::mutex mutex;
    HANDLE complete = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    DNS_SERVICE_CANCEL cancel{};
    DNS_SERVICE_REGISTER_REQUEST request{};
    PDNS_SERVICE_INSTANCE input = nullptr;
    PDNS_SERVICE_INSTANCE result = nullptr;
    DWORD status = ERROR_IO_PENDING;
    bool abandoned = false;
    bool registering = true;
    ~Operation() {
        if (input) DnsServiceFreeInstance(input);
        if (result) DnsServiceFreeInstance(result);
        if (complete) CloseHandle(complete);
    }
    void release() { if (references.fetch_sub(1) == 1) delete this; }
};

DWORD deregister_instance(PDNS_SERVICE_INSTANCE instance);

void WINAPI registration_complete(DWORD status, void *context, PDNS_SERVICE_INSTANCE instance) {
    auto *operation = static_cast<Operation *>(context);
    PDNS_SERVICE_INSTANCE cleanup = nullptr;
    {
        std::lock_guard<std::mutex> lock(operation->mutex);
        operation->status = status;
        operation->result = instance;
        if (operation->abandoned && operation->registering && status == ERROR_SUCCESS) {
            cleanup = operation->result;
            operation->result = nullptr;
        }
        SetEvent(operation->complete);
    }
    // A successful late registration must also be removed after cancellation.
    if (cleanup) deregister_instance(cleanup);
    operation->release();
}

DWORD execute(Operation *operation, HANDLE stop, PDNS_SERVICE_INSTANCE *result) {
    if (!operation->complete) {
        operation->release();
        operation->release();
        return ERROR_NOT_ENOUGH_MEMORY;
    }
    operation->request.Version = DNS_QUERY_REQUEST_VERSION1;
    operation->request.pServiceInstance = operation->input;
    operation->request.pRegisterCompletionCallback = registration_complete;
    operation->request.pQueryContext = operation;
    operation->request.unicastEnabled = FALSE;
    DWORD status = operation->registering
        ? DnsServiceRegister(&operation->request, &operation->cancel)
        : DnsServiceDeRegister(&operation->request, &operation->cancel);
    if (status != DNS_REQUEST_PENDING) {
        // There is no callback ownership unless the API accepted an async request.
        operation->release();
        operation->release();
        return status == ERROR_SUCCESS ? ERROR_INVALID_STATE : status;
    }
    HANDLE handles[] = {operation->complete, stop};
    DWORD wait = WaitForMultipleObjects(stop ? 2 : 1, handles, FALSE, registration_timeout_ms);
    if (wait == WAIT_OBJECT_0) {
        std::lock_guard<std::mutex> lock(operation->mutex);
        status = operation->status;
        if (result && status == ERROR_SUCCESS) {
            *result = operation->result;
            operation->result = nullptr;
            if (!*result) status = ERROR_INVALID_DATA;
        }
    } else {
        {
            std::lock_guard<std::mutex> lock(operation->mutex);
            operation->abandoned = true;
        }
        DnsServiceRegisterCancel(&operation->cancel);
        status = wait == WAIT_OBJECT_0 + 1 ? ERROR_CANCELLED : ERROR_TIMEOUT;
        // Keep callback state alive independently of the receiver. Drain normal
        // cancellation promptly; a late completion retains its own reference.
        WaitForSingleObject(operation->complete, 2000);
        PDNS_SERVICE_INSTANCE cleanup = nullptr;
        {
            std::lock_guard<std::mutex> lock(operation->mutex);
            if (operation->registering && operation->status == ERROR_SUCCESS) {
                cleanup = operation->result;
                operation->result = nullptr;
            }
        }
        if (cleanup) deregister_instance(cleanup);
    }
    operation->release();
    return status;
}

DWORD deregister_instance(PDNS_SERVICE_INSTANCE instance) {
    if (!instance) return ERROR_SUCCESS;
    auto *operation = new (std::nothrow) Operation;
    if (!operation) { DnsServiceFreeInstance(instance); return ERROR_NOT_ENOUGH_MEMORY; }
    operation->input = instance;
    operation->registering = false;
    return execute(operation, nullptr, nullptr);
}

void encode_txt(const Properties &properties, std::string &out) {
    out.clear();
    for (const auto &item : properties) {
        auto entry = item.first + "=" + item.second;
        if (entry.size() > 255) continue;
        out.push_back(static_cast<char>(entry.size()));
        out += entry;
    }
}

std::string label(const std::string &name) {
    std::string out;
    for (char c : name) {
        if (c == '.' || c == '\\') out += '\\';
        out += c;
    }
    return out;
}
}

struct dnssd_s {
    std::string name, address, public_key, raop_txt, airplay_txt;
    uint64_t features = std::strtoull(FEATURES_1, nullptr, 16);
    unsigned char pin = 0;
    HANDLE stop = nullptr;
    PDNS_SERVICE_INSTANCE raop = nullptr;
    PDNS_SERVICE_INSTANCE airplay = nullptr;
};

extern "C" void mm_dnssd_set_stop_event(dnssd_t *service, HANDLE stop) { service->stop = stop; }

static Properties properties(dnssd_t *service, bool airplay) {
    char feature[32], address[18];
    std::snprintf(feature, sizeof(feature), "0x%X,0x%X",
        static_cast<unsigned>(service->features), static_cast<unsigned>(service->features >> 32));
    auto *hw = reinterpret_cast<const unsigned char *>(service->address.data());
    std::snprintf(address, sizeof(address), "%02X:%02X:%02X:%02X:%02X:%02X",
                  hw[0], hw[1], hw[2], hw[3], hw[4], hw[5]);
    if (airplay) {
        return {{"deviceid", address}, {"features", feature}, {"pw", service->pin ? "true" : "false"},
            {"flags", "0x4"}, {"model", GLOBAL_MODEL}, {"pk", service->public_key},
            {"pi", AIRPLAY_PI}, {"srcvers", AIRPLAY_SRCVERS}, {"vv", AIRPLAY_VV}};
    }
    return {{"ch", RAOP_CH}, {"cn", RAOP_CN}, {"da", RAOP_DA}, {"et", RAOP_ET},
        {"vv", RAOP_VV}, {"ft", feature}, {"am", GLOBAL_MODEL}, {"md", RAOP_MD},
        {"rhd", RAOP_RHD}, {"pw", service->pin ? "true" : "false"},
        {"sf", service->pin ? "0x8c" : RAOP_SF}, {"sr", RAOP_SR}, {"ss", RAOP_SS},
        {"sv", RAOP_SV}, {"tp", RAOP_TP}, {"txtvers", RAOP_TXTVERS},
        {"vs", RAOP_VS}, {"vn", RAOP_VN}, {"pk", service->public_key}};
}

static void refresh_txt(dnssd_t *service) {
    encode_txt(properties(service, false), service->raop_txt);
    encode_txt(properties(service, true), service->airplay_txt);
}

static int register_service(dnssd_t *service, unsigned short port, bool airplay) {
    if (service->stop && WaitForSingleObject(service->stop, 0) == WAIT_OBJECT_0) return ERROR_CANCELLED;
    if (service->public_key.size() != 64 || !port) return ERROR_INVALID_PARAMETER;
    auto &registered = airplay ? service->airplay : service->raop;
    if (registered) return ERROR_ALREADY_EXISTS;
    auto values = properties(service, airplay);
    std::vector<std::wstring> keys, texts;
    for (auto &entry : values) { keys.push_back(wide(entry.first)); texts.push_back(wide(entry.second)); }
    std::vector<PCWSTR> key_ptrs, text_ptrs;
    for (size_t i = 0; i < keys.size(); ++i) {
        key_ptrs.push_back(keys[i].c_str()); text_ptrs.push_back(texts[i].c_str());
    }
    std::string instance = label(service->name);
    if (!airplay) {
        char prefix[14];
        auto *hw = reinterpret_cast<const unsigned char *>(service->address.data());
        std::snprintf(prefix, sizeof(prefix), "%02X%02X%02X%02X%02X%02X@",
                      hw[0], hw[1], hw[2], hw[3], hw[4], hw[5]);
        instance.insert(0, prefix);
    }
    auto name = wide(instance + (airplay ? "._airplay._tcp.local" : "._raop._tcp.local"));
    wchar_t host[256]{};
    DWORD length = 250;
    if (!GetComputerNameExW(ComputerNameDnsHostname, host, &length)) return GetLastError();
    std::wstring hostname = std::wstring(host) + L".local";
    auto *operation = new (std::nothrow) Operation;
    if (!operation) return ERROR_NOT_ENOUGH_MEMORY;
    operation->input = DnsServiceConstructInstance(name.c_str(), hostname.c_str(), nullptr, nullptr,
        port, 0, 0, static_cast<DWORD>(values.size()), key_ptrs.data(), text_ptrs.data());
    if (!operation->input) {
        operation->release(); operation->release();
        return ERROR_NOT_ENOUGH_MEMORY;
    }
    return static_cast<int>(execute(operation, service->stop, &registered));
}

extern "C" {
dnssd_t *dnssd_init(const char *name, int name_len, const char *hw, int hw_len, int *error, unsigned char pin) {
    if (error) *error = 0;
    if (!name || name_len < 1 || name_len > 50 || !hw || hw_len != 6) {
        if (error) *error = ERROR_INVALID_PARAMETER;
        return nullptr;
    }
    try {
        auto service = std::make_unique<dnssd_t>();
        service->name.assign(name, name_len);
        service->address.assign(hw, hw_len);
        service->pin = pin;
        return service.release();
    } catch (...) { if (error) *error = ERROR_NOT_ENOUGH_MEMORY; return nullptr; }
}
int dnssd_register_raop(dnssd_t *s, unsigned short port) {
    try { return register_service(s, port, false); } catch (...) { return ERROR_NOT_ENOUGH_MEMORY; }
}
int dnssd_register_airplay(dnssd_t *s, unsigned short port) {
    try { return register_service(s, port, true); } catch (...) { return ERROR_NOT_ENOUGH_MEMORY; }
}
void dnssd_unregister_raop(dnssd_t *s) { auto p = s->raop; s->raop = nullptr; deregister_instance(p); }
void dnssd_unregister_airplay(dnssd_t *s) { auto p = s->airplay; s->airplay = nullptr; deregister_instance(p); }
const char *dnssd_get_raop_txt(dnssd_t *s, int *len) { *len = static_cast<int>(s->raop_txt.size()); return s->raop_txt.data(); }
const char *dnssd_get_airplay_txt(dnssd_t *s, int *len) { *len = static_cast<int>(s->airplay_txt.size()); return s->airplay_txt.data(); }
const char *dnssd_get_name(dnssd_t *s, int *len) { *len = static_cast<int>(s->name.size()); return s->name.data(); }
const char *dnssd_get_hw_addr(dnssd_t *s, int *len) { *len = 6; return s->address.data(); }
uint64_t dnssd_get_airplay_features(dnssd_t *s) { return s->features; }
void dnssd_set_airplay_features(dnssd_t *s, int bit, int value) {
    if (bit < 0 || bit > 63 || (value != 0 && value != 1)) return;
    uint64_t mask = uint64_t{1} << bit;
    s->features = value ? s->features | mask : s->features & ~mask;
    refresh_txt(s);
}
void dnssd_set_pk(dnssd_t *s, char *pk) { s->public_key = pk ? pk : ""; refresh_txt(s); }
int mm_dnssd_close(dnssd_t *s) {
    if (!s) return ERROR_SUCCESS;
    auto airplay = s->airplay, raop = s->raop;
    s->airplay = s->raop = nullptr;
    DWORD first = deregister_instance(airplay);
    DWORD second = deregister_instance(raop);
    return static_cast<int>(first ? first : second);
}
void dnssd_destroy(dnssd_t *s) {
    if (!s) return;
    mm_dnssd_close(s);
    delete s;
}
}
