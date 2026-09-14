// SPDX-License-Identifier: GPL-3.0-or-later
#include <winsock2.h>
#include <windows.h>
#include <aclapi.h>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <openssl/pem.h>
#include "include/mirrorme.h"
#include "include/media.h"
#include "raop.h"

extern "C" void mm_dnssd_set_stop_event(dnssd_t *, HANDLE);
extern "C" int mm_dnssd_close(dnssd_t *);
extern "C" void mm_protocol_disconnect(raop_t *, uint64_t);
static thread_local DWORD identity_error = ERROR_SUCCESS;
static thread_local const char *identity_operation = "initialization";
static int reject_key_password(char *, int, int, void *) { return 0; }

// A random persisted identity replaces upstream's permissive key-file fallback.
// Keys never pass through event messages, stdout, or deterministic device hashes.
extern "C" EVP_PKEY *mm_protocol_load_identity(const char *path) {
    identity_error = ERROR_SUCCESS;
    identity_operation = "initialization";
    if (!OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, nullptr)) {
        identity_error = ERROR_INVALID_DATA;
        return nullptr;
    }
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
    if (!count) { identity_error = GetLastError(); return nullptr; }
    std::wstring filename(count, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, filename.data(), count);
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) { identity_error = GetLastError(); return nullptr; }
    DWORD bytes = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
    std::vector<unsigned char> storage(bytes);
    if (!GetTokenInformation(token, TokenUser, storage.data(), bytes, &bytes)) {
        identity_error = GetLastError(); CloseHandle(token); return nullptr;
    }
    CloseHandle(token);
    auto *user = reinterpret_cast<TOKEN_USER *>(storage.data());
    EXPLICIT_ACCESSW access{};
    access.grfAccessPermissions = FILE_ALL_ACCESS;
    access.grfAccessMode = SET_ACCESS;
    access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    access.Trustee.TrusteeType = TRUSTEE_IS_USER;
    access.Trustee.ptstrName = static_cast<LPWSTR>(user->User.Sid);
    PACL acl = nullptr;
    identity_error = SetEntriesInAclW(1, &access, nullptr, &acl);
    if (identity_error != ERROR_SUCCESS) return nullptr;
    SECURITY_DESCRIPTOR descriptor{};
    InitializeSecurityDescriptor(&descriptor, SECURITY_DESCRIPTOR_REVISION);
    SetSecurityDescriptorDacl(&descriptor, TRUE, acl, FALSE);
    SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), &descriptor, FALSE};
    identity_operation = "file access";
    HANDLE file = CreateFileW(filename.c_str(), GENERIC_READ | GENERIC_WRITE,
        0, &attributes, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    bool created = GetLastError() != ERROR_ALREADY_EXISTS;
    if (file == INVALID_HANDLE_VALUE) { identity_error = GetLastError(); LocalFree(acl); return nullptr; }
    BY_HANDLE_FILE_INFORMATION info{};
    bool valid_file = GetFileInformationByHandle(file, &info) &&
        !(info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY));
    if (!valid_file) identity_error = ERROR_INVALID_DATA;
    identity_operation = "private permissions";
    LocalFree(acl);
    // New files receive the private DACL atomically at creation. Existing keys
    // are checked, never silently chmodded or regenerated when inaccessible.
    PSECURITY_DESCRIPTOR actual_descriptor = nullptr;
    PACL actual_acl = nullptr;
    DWORD acl_error = GetSecurityInfo(file, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
        nullptr, nullptr, &actual_acl, nullptr, &actual_descriptor);
    bool private_acl = !acl_error && actual_acl;
    unsigned char system_sid[SECURITY_MAX_SID_SIZE]{}, admin_sid[SECURITY_MAX_SID_SIZE]{};
    DWORD system_size = sizeof(system_sid), admin_size = sizeof(admin_sid);
    CreateWellKnownSid(WinLocalSystemSid, nullptr, system_sid, &system_size);
    CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr, admin_sid, &admin_size);
    for (DWORD i = 0; private_acl && i < actual_acl->AceCount; ++i) {
        void *entry = nullptr;
        if (!GetAce(actual_acl, i, &entry)) { private_acl = false; break; }
        auto *header = static_cast<ACE_HEADER *>(entry);
        if (header->AceType == ACCESS_ALLOWED_ACE_TYPE) {
            auto *allowed = static_cast<ACCESS_ALLOWED_ACE *>(entry);
            if ((allowed->Mask & (FILE_READ_DATA | GENERIC_READ | GENERIC_ALL)) &&
                !EqualSid(&allowed->SidStart, user->User.Sid) &&
                !EqualSid(&allowed->SidStart, system_sid) &&
                !EqualSid(&allowed->SidStart, admin_sid)) private_acl = false;
        } else if (header->AceType != ACCESS_DENIED_ACE_TYPE) {
            private_acl = false;
        }
    }
    if (actual_descriptor) LocalFree(actual_descriptor);
    if (!private_acl) { identity_error = acl_error ? acl_error : ERROR_ACCESS_DENIED; valid_file = false; }
    if (valid_file) identity_operation = created ? "key creation" : "key validation";
    EVP_PKEY *key = nullptr;
    if (valid_file && !created) {
        LARGE_INTEGER size{};
        if (GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= 16384) {
            std::vector<char> data(static_cast<size_t>(size.QuadPart));
            DWORD read = 0;
            if (ReadFile(file, data.data(), static_cast<DWORD>(data.size()), &read, nullptr) && read == data.size()) {
                BIO *bio = BIO_new_mem_buf(data.data(), static_cast<int>(data.size()));
                if (bio) {
                    key = PEM_read_bio_PrivateKey(bio, nullptr, reject_key_password, nullptr);
                    BIO_free(bio);
                }
            }
            SecureZeroMemory(data.data(), data.size());
        }
        if (key && EVP_PKEY_id(key) != EVP_PKEY_ED25519) { EVP_PKEY_free(key); key = nullptr; }
    } else if (valid_file) {
        EVP_PKEY_CTX *context = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, nullptr);
        if (context) {
            if (EVP_PKEY_keygen_init(context) <= 0 || EVP_PKEY_keygen(context, &key) <= 0)
                key = nullptr;
            EVP_PKEY_CTX_free(context);
        }
        BIO *bio = BIO_new(BIO_s_mem());
        bool saved = false;
        if (bio && key && PEM_write_bio_PrivateKey(bio, key, nullptr, nullptr, 0, nullptr, nullptr)) {
            char *data = nullptr;
            long length = BIO_get_mem_data(bio, &data);
            DWORD written = 0;
            saved = length > 0 && length <= 16384 &&
                WriteFile(file, data, static_cast<DWORD>(length), &written, nullptr) &&
                written == static_cast<DWORD>(length) && FlushFileBuffers(file);
            if (data && length > 0) SecureZeroMemory(data, static_cast<size_t>(length));
        }
        if (bio) BIO_free(bio);
        if (!saved) { identity_error = GetLastError(); EVP_PKEY_free(key); key = nullptr; }
    }
    CloseHandle(file);
    if (!key && created) DeleteFileW(filename.c_str());
    if (!key && !identity_error) identity_error = ERROR_INVALID_DATA;
    return key;
}

struct mm_receiver {
    mm_receiver_config config{};
    std::string name, device_id, key_path;
    char address[6]{};
    mm_event_callback callback = nullptr;
    void *context = nullptr;
    HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE finished = CreateEventW(nullptr, TRUE, TRUE, nullptr);
    std::atomic<bool> started{false};
    std::atomic<uint64_t> disconnect{0};
    std::mutex state_mutex, media_mutex;
    uint64_t session_id = 0;
    uint64_t last_session_id = 0;
    ULONGLONG last_activity = 0;
    bool accepting = false, first_video = false, paused = false;
    mm_media *media = nullptr;
    raop_t *protocol = nullptr;
    dnssd_t *discovery = nullptr;
    ~mm_receiver() {
        if (stop) CloseHandle(stop);
        if (finished) CloseHandle(finished);
    }
    bool stopping() const { return WaitForSingleObject(stop, 0) == WAIT_OBJECT_0; }
    void emit(int kind, const char *message) {
        if (callback) callback(context, kind, message);
    }
};

namespace {
void error_text(char *error, size_t capacity, const char *text) {
    if (error && capacity) std::snprintf(error, capacity, "%s", text);
}
void ignored(void *) {}
void discard_log(void *, int, const char *) {}

void request_disconnect(mm_receiver *receiver) {
    std::lock_guard<std::mutex> lock(receiver->state_mutex);
    receiver->accepting = false;
    if (receiver->session_id) receiver->disconnect.store(receiver->session_id);
}

void media_event(void *context, int kind, const char *message) {
    auto *receiver = static_cast<mm_receiver *>(context);
    if (kind == MM_EVENT_SESSION_ENDED) {
        // This callback only requests teardown. The HTTP owner joins producers,
        // after which the identity-scoped protocol hook resets the media queues.
        request_disconnect(receiver);
        return;
    }
    if (receiver->stopping()) return;
    if (kind == MM_EVENT_VIDEO_RECEIVED) {
        std::lock_guard<std::mutex> lock(receiver->state_mutex);
        if (!receiver->accepting || receiver->paused || receiver->first_video) return;
        receiver->first_video = true;
    }
    if (kind == MM_EVENT_STREAMING) {
        std::lock_guard<std::mutex> lock(receiver->state_mutex);
        if (!receiver->accepting || receiver->paused || !receiver->first_video) return;
    }
    if (kind == MM_EVENT_ERROR) {
        receiver->emit(kind, "Native media playback failed. Check Windows media support.");
        request_disconnect(receiver);
    } else if (kind == MM_EVENT_VIDEO_RECEIVED) {
        receiver->emit(kind, "Mirroring video accepted.");
    } else if (kind == MM_EVENT_STREAMING) {
        receiver->emit(kind, "Video is being presented.");
    } else if (kind == MM_EVENT_NOTICE) {
        // Internal media messages contain no sender-supplied strings.
        char bounded[257]{};
        if (message) std::snprintf(bounded, sizeof(bounded), "%.256s", message);
        receiver->emit(kind, bounded);
    }
}

void audio_process(void *context, raop_ntp_t *, audio_decode_struct *data) {
    auto *receiver = static_cast<mm_receiver *>(context);
    if (!receiver->config.audio_enabled || receiver->stopping() || !data ||
        !data->data || data->data_len <= 0 || data->data_len > 1024 * 1024) return;
    {
        std::lock_guard<std::mutex> lock(receiver->state_mutex);
        if (!receiver->accepting) return;
        receiver->last_activity = GetTickCount64();
    }
    mm_media_push_audio(receiver->media, data->data, data->data_len, data->ntp_time_local);
}

void video_process(void *context, raop_ntp_t *, video_decode_struct *data) {
    auto *receiver = static_cast<mm_receiver *>(context);
    if (receiver->stopping() || !data || !data->data || data->data_len <= 0 ||
        data->data_len > 8 * 1024 * 1024) return;
    {
        std::lock_guard<std::mutex> lock(receiver->state_mutex);
        if (!receiver->accepting) return;
        receiver->last_activity = GetTickCount64();
    }
    // Media owns the copy. The timestamp is already local UNIX nanoseconds.
    mm_media_push_video(receiver->media, data->data, data->data_len, data->ntp_time_local);
}

int video_codec(void *context, video_codec_t codec) {
    auto *receiver = static_cast<mm_receiver *>(context);
    if (receiver->stopping()) return -1;
    if ((codec != VIDEO_CODEC_H264 && codec != VIDEO_CODEC_H265) ||
        (codec == VIDEO_CODEC_H265 && !receiver->config.allow_h265)) {
        receiver->emit(MM_EVENT_ERROR, "The sender selected a video codec that this receiver has not enabled.");
        return -1;
    }
    mm_media_flush_video(receiver->media);
    if (mm_media_set_video_codec(receiver->media, codec == VIDEO_CODEC_H265) < 0) {
        receiver->emit(MM_EVENT_ERROR, "Windows cannot decode the negotiated video codec. Disable optional HEVC or check Windows media support.");
        return -1;
    }
    return 0;
}
void pause_video(void *context) {
    auto *receiver = static_cast<mm_receiver *>(context);
    {
        std::lock_guard<std::mutex> lock(receiver->state_mutex);
        if (!receiver->accepting || receiver->paused || receiver->stopping()) return;
        receiver->paused = true;
        receiver->first_video = false;
    }
    mm_media_pause(receiver->media, 1);
    receiver->emit(MM_EVENT_PAUSED, "The iPhone paused its video stream.");
}
void resume_video(void *context) {
    auto *receiver = static_cast<mm_receiver *>(context);
    {
        std::lock_guard<std::mutex> lock(receiver->state_mutex);
        if (!receiver->accepting || !receiver->paused || receiver->stopping()) return;
        receiver->paused = false;
    }
    mm_media_pause(receiver->media, 0);
}
void flush_audio(void *context) { mm_media_flush_audio(static_cast<mm_receiver *>(context)->media); }
void flush_video(void *context) { mm_media_flush_video(static_cast<mm_receiver *>(context)->media); }
void set_volume(void *context, float volume) {
    if (std::isfinite(volume)) mm_media_set_volume(static_cast<mm_receiver *>(context)->media, volume);
}
double client_volume(void *) { return 0.0; }
void audio_format(void *context, unsigned char *codec, unsigned short *samples, bool *, bool *, uint64_t *format) {
    auto *receiver = static_cast<mm_receiver *>(context);
    if (!receiver->config.audio_enabled || !codec || !samples || !format) return;
    if (mm_media_configure_audio(receiver->media, *codec, *samples, *format) < 0)
        receiver->emit(MM_EVENT_NOTICE, "The sender's audio format is unavailable; mirroring video remains enabled.");
}
void feedback(void *context) {
    auto *receiver = static_cast<mm_receiver *>(context);
    std::lock_guard<std::mutex> lock(receiver->state_mutex);
    if (receiver->accepting) receiver->last_activity = GetTickCount64();
}
void conn_reset(void *, int) {}
void video_reset(void *context, reset_type_t reason) {
    // NOHOLD teardown is performed synchronously by the HTTP owner. Other reset
    // callbacks lack session identity and must not terminate a newer session.
    if (reason == RESET_TYPE_HLS_SHUTDOWN || reason == RESET_TYPE_HLS_EOS ||
        reason == RESET_TYPE_ON_VIDEO_PLAY)
        static_cast<mm_receiver *>(context)->emit(MM_EVENT_NOTICE, "Remote URL playback is not supported.");
}
void teardown(void *, bool *audio, bool *video) {
    if (audio) *audio = true;
    if (video) *video = true;
}
void metadata(void *, const void *, int) {}
void remote_control(void *, const char *, const char *) {}
void progress(void *, uint32_t *, uint32_t *, uint32_t *) {}
void video_size(void *, float *, float *, float *, float *) {}
void mirror_running(void *, bool) {}
void client_request(void *context, char *, char *, char *, bool *admit) {
    if (admit) *admit = !static_cast<mm_receiver *>(context)->stopping();
}
void display_pin(void *context, char *) {
    static_cast<mm_receiver *>(context)->emit(MM_EVENT_NOTICE, "Enter the configured PIN on your Apple device.");
}
void register_client(void *, const char *, const char *, const char *) {}
bool check_client(void *, const char *) { return false; }
void unsupported_play(void *context, const char *, float) {
    static_cast<mm_receiver *>(context)->emit(MM_EVENT_NOTICE, "Remote URL playback is not supported.");
}
void unsupported_position(void *, float) {}
void playback_info(void *, playback_info_t *info) { if (info) *info = {}; }
float playlist_remove(void *) { return 0; }

raop_callbacks_t callbacks(mm_receiver *receiver) {
    raop_callbacks_t c{};
    c.cls = receiver;
    c.audio_process = audio_process; c.video_process = video_process;
    c.video_pause = pause_video; c.video_resume = resume_video;
    c.conn_feedback = feedback; c.conn_reset = conn_reset; c.video_reset = video_reset;
    c.conn_init = ignored; c.conn_destroy = ignored; c.conn_teardown = teardown;
    c.audio_flush = flush_audio; c.video_flush = flush_video;
    c.audio_set_client_volume = client_volume; c.audio_set_volume = set_volume;
    c.audio_set_metadata = metadata; c.audio_set_coverart = metadata;
    c.audio_stop_coverart_rendering = ignored; c.audio_remote_control_id = remote_control;
    c.audio_set_progress = progress; c.audio_get_format = audio_format;
    c.video_report_size = video_size; c.mirror_video_running = mirror_running;
    c.report_client_request = client_request; c.display_pin = display_pin;
    c.register_client = register_client; c.check_register = check_client;
    // passwd being nonnull enables a different digest-password protocol branch.
    // PIN pairing intentionally uses the upstream use_pin branch instead.
    c.passwd = nullptr;
    c.export_dacp = remote_control; c.video_set_codec = video_codec;
    c.on_video_play = unsupported_play; c.on_video_scrub = unsupported_position;
    c.on_video_rate = unsupported_position; c.on_video_stop = ignored;
    c.on_video_acquire_playback_info = playback_info; c.on_video_playlist_remove = playlist_remove;
    return c;
}
}

extern "C" void mm_protocol_session(void *context, uint64_t id, int state) {
    auto *receiver = static_cast<mm_receiver *>(context);
    bool ended = false, began = false;
    {
        std::lock_guard<std::mutex> lock(receiver->state_mutex);
        if (state == 1 && id > receiver->last_session_id && !receiver->stopping()) {
            receiver->session_id = id;
            receiver->last_session_id = id;
            receiver->accepting = true;
            receiver->first_video = false;
            receiver->paused = false;
            receiver->last_activity = GetTickCount64();
            began = true;
        } else if (state == 2 && receiver->session_id == id) {
            receiver->accepting = false;
            receiver->disconnect.store(id);
        } else if (state == 3 && receiver->session_id == id) {
            receiver->session_id = 0;
            receiver->accepting = false;
            receiver->first_video = false;
            receiver->paused = false;
            ended = true;
        }
    }
    if (began) receiver->emit(MM_EVENT_CONNECTING, "Mirroring session negotiated.");
    if (ended) {
        // The copied RAOP connection destructor invokes state 3 after joining
        // every RTP/NTP producer, including naturally-exited mirror threads.
        mm_media_reset(receiver->media);
        if (!receiver->stopping()) receiver->emit(MM_EVENT_SESSION_ENDED, "Mirroring session ended.");
    }
}

extern "C" mm_receiver *mm_receiver_create(const mm_receiver_config *config,
    mm_event_callback callback, void *context, char *error, size_t capacity) {
    error_text(error, capacity, "");
    if (!config || !config->name || !config->device_id || !config->key_path ||
        !*config->name || !*config->key_path ||
        ((config->width == 0) != (config->height == 0)) ||
        (config->width && (config->width < 64 || config->width > 8192)) ||
        (config->height && (config->height < 64 || config->height > 8192)) ||
        config->max_fps > 120 || config->idle_timeout_seconds > 86400 ||
        (config->require_pin && config->pin > 9999)) {
        error_text(error, capacity, "Invalid receiver configuration.");
        return nullptr;
    }
    if (std::strlen(config->name) > 50) {
        error_text(error, capacity, "Receiver name exceeds 50 UTF-8 bytes, the RAOP discovery label budget.");
        return nullptr;
    }
    try {
        auto receiver = std::make_unique<mm_receiver>();
        if (!receiver->stop || !receiver->finished) {
            error_text(error, capacity, "Windows could not create receiver synchronization handles.");
            return nullptr;
        }
        if (std::strlen(config->device_id) != 17) {
            error_text(error, capacity, "Device identity must be a six-byte colon-separated address.");
            return nullptr;
        }
        for (int i = 0; i < 6; ++i) {
            char token[] = {config->device_id[i * 3], config->device_id[i * 3 + 1], 0};
            char *end = nullptr;
            long value = std::strtol(token, &end, 16);
            if (!std::isxdigit(static_cast<unsigned char>(token[0])) ||
                !std::isxdigit(static_cast<unsigned char>(token[1])) ||
                !end || *end || (i < 5 && config->device_id[i * 3 + 2] != ':')) {
                error_text(error, capacity, "Invalid stable device identity.");
                return nullptr;
            }
            receiver->address[i] = static_cast<char>(value);
        }
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, config->name, -1, nullptr, 0)) {
            error_text(error, capacity, "Receiver name must be valid UTF-8.");
            return nullptr;
        }
        for (const unsigned char *p = reinterpret_cast<const unsigned char *>(config->name); *p; ++p) {
            if (*p < 32 || *p == 127) {
                error_text(error, capacity, "Receiver name cannot contain control characters.");
                return nullptr;
            }
        }
        receiver->name = config->name; receiver->device_id = config->device_id; receiver->key_path = config->key_path;
        receiver->config = *config;
        if (!receiver->config.width) {
            receiver->config.width = 1920;
            receiver->config.height = 1080;
        }
        if (!receiver->config.max_fps) receiver->config.max_fps = 60;
        receiver->config.name = receiver->name.c_str();
        receiver->config.device_id = receiver->device_id.c_str();
        receiver->config.key_path = receiver->key_path.c_str();
        receiver->callback = callback; receiver->context = context;
        return receiver.release();
    } catch (...) {
        error_text(error, capacity, "Not enough memory to create the receiver.");
        return nullptr;
    }
}

extern "C" int mm_receiver_run(mm_receiver *receiver) {
    if (!receiver || receiver->started.exchange(true)) return -1;
    ResetEvent(receiver->finished);
    int status = 0;
    try {
        do {
            if (receiver->stopping()) break;
            char error[256]{};
            mm_media *media = mm_media_create(&receiver->config, media_event, receiver, error, sizeof(error));
            {
                std::lock_guard<std::mutex> lock(receiver->media_mutex);
                receiver->media = media;
            }
            if (!receiver->media) {
                error[sizeof(error) - 1] = '\0';
                receiver->emit(MM_EVENT_ERROR, *error ? error : "Windows media initialization failed.");
                status = -1; break;
            }
            auto c = callbacks(receiver);
            receiver->protocol = raop_init(&c);
            if (!receiver->protocol) {
                receiver->emit(MM_EVENT_ERROR, "The native protocol host could not initialize.");
                status = -1; break;
            }
            raop_set_log_callback(receiver->protocol, discard_log, nullptr);
            raop_set_log_level(receiver->protocol, -1);
            if (raop_init2(receiver->protocol, receiver->config.prefer_newest,
                           receiver->device_id.c_str(), receiver->key_path.c_str()) < 0) {
                char message[200];
                std::snprintf(message, sizeof(message),
                    "Pairing identity %s failed (code %u). Check the private key directory.",
                    identity_operation, static_cast<unsigned>(identity_error));
                receiver->emit(MM_EVENT_ERROR, message);
                status = -1; break;
            }
            raop_set_plist(receiver->protocol, "width", receiver->config.width);
            raop_set_plist(receiver->protocol, "height", receiver->config.height);
            raop_set_plist(receiver->protocol, "maxFPS", receiver->config.max_fps);
            raop_set_plist(receiver->protocol, "refreshRate", receiver->config.max_fps);
            raop_set_plist(receiver->protocol, "hls", 0);
            if (receiver->config.require_pin)
                raop_set_plist(receiver->protocol, "pin", 10000 + receiver->config.pin);
            int dns_error = 0;
            receiver->discovery = dnssd_init(receiver->name.c_str(), static_cast<int>(receiver->name.size()),
                                             receiver->address, 6, &dns_error, receiver->config.require_pin ? 1 : 0);
            if (!receiver->discovery) {
                receiver->emit(MM_EVENT_ERROR, "Windows discovery could not allocate service records.");
                status = -1; break;
            }
            mm_dnssd_set_stop_event(receiver->discovery, receiver->stop);
            // No URL playback, photo playback, FairPlay video/HLS, or rotation.
            for (int bit : {0, 1, 2, 3, 4, 5, 8, 13})
                dnssd_set_airplay_features(receiver->discovery, bit, 0);
            dnssd_set_airplay_features(receiver->discovery, 7, 1);
            dnssd_set_airplay_features(receiver->discovery, 9, receiver->config.audio_enabled ? 1 : 0);
            dnssd_set_airplay_features(receiver->discovery, 42, receiver->config.allow_h265 ? 1 : 0);
            raop_set_dnssd(receiver->protocol, receiver->discovery);
            unsigned short port = 0;
            if (raop_start_httpd(receiver->protocol, &port) < 0 || !port) {
                receiver->emit(MM_EVENT_ERROR, "The mirroring TCP listener could not start.");
                status = -1; break;
            }
            raop_set_port(receiver->protocol, port);
            dns_error = dnssd_register_raop(receiver->discovery, port);
            if (!dns_error && !receiver->stopping())
                dns_error = dnssd_register_airplay(receiver->discovery, port);
            if (receiver->stopping()) break;
            if (dns_error) {
                char bounded[240];
                std::snprintf(bounded, sizeof(bounded),
                    "Windows DNS-SD registration failed (code %u). Check an active private network, Windows DNS Client, and multicast firewall access.",
                    static_cast<unsigned>(dns_error));
                receiver->emit(MM_EVENT_ERROR, bounded);
                status = -1; break;
            }
            if (!raop_is_running(receiver->protocol)) {
                receiver->emit(MM_EVENT_ERROR, "The mirroring listener stopped before discovery completed.");
                status = -1; break;
            }
            receiver->emit(MM_EVENT_READY, "Windows registered both mirroring services.");
            while (WaitForSingleObject(receiver->stop, 50) == WAIT_TIMEOUT) {
                uint64_t id = receiver->disconnect.exchange(0);
                if (id) mm_protocol_disconnect(receiver->protocol, id);
                {
                    std::lock_guard<std::mutex> lock(receiver->state_mutex);
                    if (receiver->accepting && receiver->config.idle_timeout_seconds &&
                        GetTickCount64() - receiver->last_activity >= uint64_t(receiver->config.idle_timeout_seconds) * 1000) {
                        receiver->accepting = false;
                        mm_protocol_disconnect(receiver->protocol, receiver->session_id);
                    }
                }
                if (!raop_is_running(receiver->protocol)) {
                    receiver->emit(MM_EVENT_ERROR, "The mirroring listener stopped unexpectedly.");
                    status = -1; break;
                }
            }
        } while (false);
    } catch (...) {
        receiver->emit(MM_EVENT_ERROR, "The receiver could not allocate a required native resource.");
        status = -1;
    }
    SetEvent(receiver->stop);
    if (receiver->protocol) {
        raop_destroy(receiver->protocol);
        receiver->protocol = nullptr;
    }
    if (receiver->discovery) {
        int close_error = mm_dnssd_close(receiver->discovery);
        if (close_error) {
            char message[160];
            std::snprintf(message, sizeof(message),
                "Windows discovery cleanup failed (code %u). The worker will exit to release its registration.",
                static_cast<unsigned>(close_error));
            receiver->emit(MM_EVENT_ERROR, message);
            status = -1;
        }
        dnssd_destroy(receiver->discovery);
        receiver->discovery = nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(receiver->media_mutex);
        if (receiver->media) mm_media_destroy(receiver->media);
        receiver->media = nullptr;
    }
    SetEvent(receiver->finished);
    return status;
}

extern "C" void mm_receiver_request_stop(mm_receiver *receiver) {
    if (receiver) SetEvent(receiver->stop);
}
extern "C" void mm_receiver_show_video(mm_receiver *receiver) {
    if (!receiver || receiver->stopping()) return;
    std::lock_guard<std::mutex> lock(receiver->media_mutex);
    if (receiver->media) mm_media_show_window(receiver->media);
}
extern "C" void mm_receiver_destroy(mm_receiver *receiver) {
    if (!receiver) return;
    mm_receiver_request_stop(receiver);
    WaitForSingleObject(receiver->finished, INFINITE);
    delete receiver;
}
