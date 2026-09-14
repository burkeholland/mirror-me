// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum mm_event_kind {
    MM_EVENT_READY = 1,
    MM_EVENT_CONNECTING = 2,
    MM_EVENT_VIDEO_RECEIVED = 3,
    MM_EVENT_STREAMING = 4,
    MM_EVENT_SESSION_ENDED = 5,
    MM_EVENT_ERROR = 6,
    MM_EVENT_NOTICE = 7,
    MM_EVENT_PAUSED = 8
};

// Message is diagnostic text, not a sender name or lifecycle identifier.
typedef void (*mm_event_callback)(void *context, int kind, const char *message);

typedef struct mm_receiver_config {
    const char *name;
    const char *device_id;
    const char *key_path;
    // The app resolves automatic settings to 1920x1080 at 60 FPS.
    unsigned int width;
    unsigned int height;
    unsigned int max_fps;
    unsigned int idle_timeout_seconds;
    unsigned int pin;
    int require_pin;
    int prefer_newest;
    int hardware_decode;
    int allow_h265;
    int audio_enabled;
} mm_receiver_config;

typedef struct mm_receiver mm_receiver;

mm_receiver *mm_receiver_create(const mm_receiver_config *config,
    mm_event_callback callback, void *context, char *error, size_t error_capacity);
int mm_receiver_run(mm_receiver *receiver);
void mm_receiver_request_stop(mm_receiver *receiver);
void mm_receiver_show_video(mm_receiver *receiver);
void mm_receiver_destroy(mm_receiver *receiver);

#ifdef __cplusplus
}
#endif
