// SPDX-License-Identifier: GPL-3.0-or-later
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <gst/gst.h>
#include <openssl/crypto.h>
#include <plist/plist.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <exception>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "uxplay_api.h"

int run_media_probe(bool window, bool software, bool broken);

namespace {

std::string utf8(const wchar_t* value) {
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
    if (!size) {
        throw std::runtime_error("Invalid UTF-16 command line or executable path");
    }
    std::string result(size, '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result.data(), size, nullptr, nullptr)) {
        throw std::runtime_error("Cannot convert command line to UTF-8");
    }
    result.pop_back();
    return result;
}

std::wstring executable_directory() {
    std::vector<wchar_t> path(32768);
    const DWORD size = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (!size || size >= path.size()) {
        throw std::runtime_error("Cannot determine receiver executable directory");
    }
    const std::wstring filename(path.data(), size);
    const auto separator = filename.find_last_of(L"\\");
    if (separator == std::wstring::npos) {
        throw std::runtime_error("Receiver executable path has no directory");
    }
    return filename.substr(0, separator);
}

void configure_runtime(const std::wstring& directory) {
    if (!SetDllDirectoryW(directory.c_str())) {
        throw std::runtime_error("Cannot configure the bundled DLL directory");
    }
    const auto path = utf8(directory.c_str());
    const char* inherited_path = g_getenv("PATH");
    const auto search_path = path + ";" + (inherited_path ? inherited_path : "");
    if (!g_setenv("PATH", search_path.c_str(), TRUE) ||
        !g_setenv("GST_PLUGIN_PATH", (path + "\\lib\\gstreamer-1.0").c_str(), FALSE) ||
        !g_setenv("GST_PLUGIN_PATH_1_0", g_getenv("GST_PLUGIN_PATH"), TRUE) ||
        !g_setenv("GST_PLUGIN_SYSTEM_PATH", "", TRUE) ||
        !g_setenv("GST_PLUGIN_SYSTEM_PATH_1_0", "", TRUE) ||
        !g_setenv("GST_REGISTRY_FORK", "no", FALSE)) {
        throw std::runtime_error("Cannot configure the bundled GStreamer environment");
    }
}

int self_test(const std::wstring& directory) {
    const auto dnssd_path = directory + L"\\dnssd.dll";
    HMODULE dnssd = LoadLibraryW(dnssd_path.c_str());
    if (!dnssd) {
        std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: Cannot load bundled dnssd.dll (Windows error %lu)\n", GetLastError());
        return 1;
    }
    const char* dns_functions[] = {
        "DNSServiceRegister", "DNSServiceRefDeallocate", "DNSServiceRefSockFD", "DNSServiceProcessResult",
        "TXTRecordCreate", "TXTRecordDeallocate", "TXTRecordSetValue",
        "TXTRecordGetLength", "TXTRecordGetBytesPtr"
    };
    bool valid = true;
    for (const auto function : dns_functions) {
        if (!GetProcAddress(dnssd, function)) {
            std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: dnssd.dll is missing %s\n", function);
            valid = false;
        }
    }
    FreeLibrary(dnssd);
    if (!valid) {
        return 1;
    }

    GError* error = nullptr;
    if (!gst_init_check(nullptr, nullptr, &error)) {
        std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: GStreamer initialization failed: %s\n",
                     error ? error->message : "unknown error");
        g_clear_error(&error);
        return 1;
    }
    const char* required_elements[] = {
        "appsrc", "h264parse", "decodebin", "videoconvert", "autovideosink",
        "d3d11videosink", "avdec_h264", "avdec_aac", "avdec_alac", "audioconvert",
        "audioresample", "autoaudiosink", "wasapi2sink"
    };
    for (const auto element : required_elements) {
        GstElementFactory* factory = gst_element_factory_find(element);
        if (!factory) {
            std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: Missing GStreamer element: %s\n", element);
            valid = false;
        } else {
            GstPluginFeature* loaded = gst_plugin_feature_load(GST_PLUGIN_FEATURE(factory));
            if (!loaded) {
                std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: Cannot load GStreamer plugin for: %s\n", element);
                valid = false;
            } else {
                gst_object_unref(loaded);
            }
            gst_object_unref(factory);
        }
    }
    plist_t dictionary = plist_new_dict();
    if (!dictionary) {
        std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: libplist initialization failed\n");
        valid = false;
    }
    plist_free(dictionary);
    if (valid) {
        gchar* version = gst_version_string();
        std::printf("MIRRORME_RECEIVER_SELF_TEST_OK: %s; %s; Bonjour API and required plugins available\n",
                    version, OpenSSL_version(OPENSSL_VERSION));
        g_free(version);
        std::puts("Self-test does not bind a listener, register a service, or prove device connectivity.");
    }
    gst_deinit();
    return valid ? 0 : 1;
}

// Only redirected input is supervised. Interactive console launches use Ctrl-C.
// PeekNamedPipe keeps shutdown of the input monitor nonblocking on startup errors.
class InputMonitor {
public:
    InputMonitor() {
        const HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
        if (input && input != INVALID_HANDLE_VALUE && GetFileType(input) == FILE_TYPE_PIPE) {
            worker_ = std::thread([this, input] { watch(input); });
        }
    }

    ~InputMonitor() {
        finished_.store(true);
        if (worker_.joinable()) {
            worker_.join();
        }
    }

private:
    void request_stop(const char* reason) {
        std::printf("MIRRORME_RECEIVER_STOP_REQUESTED reason=%s\n", reason);
        stop_uxplay();
    }

    void watch(HANDLE input) {
        std::string command;
        bool oversized = false;
        while (!finished_.load()) {
            DWORD available = 0;
            if (!PeekNamedPipe(input, nullptr, 0, nullptr, &available, nullptr)) {
                if (GetLastError() != ERROR_BROKEN_PIPE) {
                    std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: stdin pipe failed (Windows error %lu)\n", GetLastError());
                }
                request_stop("stdin-eof");
                return;
            }
            if (!available) {
                Sleep(50);
                continue;
            }
            char buffer[256];
            DWORD count = 0;
            if (!ReadFile(input, buffer, std::min<DWORD>(available, sizeof(buffer)), &count, nullptr) || !count) {
                request_stop("stdin-eof");
                return;
            }
            for (DWORD i = 0; i < count; ++i) {
                const char character = buffer[i];
                if (character == '\n') {
                    if (!oversized && command == "stop") {
                        request_stop("stdin-command");
                        return;
                    }
                    command.clear();
                    oversized = false;
                } else if (character != '\r' && !oversized) {
                    if (command.size() < 32) {
                        command += character;
                    } else {
                        oversized = true;
                    }
                }
            }
        }
    }

    std::atomic<bool> finished_{false};
    std::thread worker_;
};

} // namespace

int wmain(int argc, wchar_t* wide_argv[]) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    SetConsoleOutputCP(CP_UTF8);
    try {
        std::vector<std::string> arguments;
        arguments.reserve(argc);
        for (int i = 0; i < argc; ++i) {
            arguments.push_back(utf8(wide_argv[i]));
        }
        if (argc == 2 && arguments[1] == "--version") {
            std::printf("MirrorMe receiver %s; UxPlay 1.73.6; libuxplay %s\n", RECEIVER_VERSION, UXPLAY_COMMIT);
            return 0;
        }
        const auto directory = executable_directory();
        configure_runtime(directory);
        if (argc == 2 && arguments[1] == "--self-test") {
            return self_test(directory);
        }
        if (argc == 2 && (arguments[1] == "--media-self-test" ||
                          arguments[1] == "--media-self-test-window" ||
                          arguments[1] == "--media-self-test-software" ||
                          arguments[1] == "--media-self-test-invalid")) {
            return run_media_probe(arguments[1] == "--media-self-test-window",
                                   arguments[1] == "--media-self-test-software",
                                   arguments[1] == "--media-self-test-invalid");
        }

        std::vector<char*> argv;
        argv.reserve(arguments.size() + 1);
        for (auto& argument : arguments) {
            argv.push_back(argument.data());
        }
        argv.push_back(nullptr);
        InputMonitor input;
        const int result = start_uxplay(argc, argv.data());
        if (result) {
            std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: UxPlay exited with status %d\n", result);
        } else {
            std::puts("MIRRORME_RECEIVER_STOPPED");
        }
        return result;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "MIRRORME_RECEIVER_ERROR: %s\n", error.what());
        return 1;
    }
}
