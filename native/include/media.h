// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "mirrorme.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mm_media mm_media;

mm_media *mm_media_create(const mm_receiver_config *config,
    mm_event_callback callback, void *context, char *error, size_t error_capacity);
// Codec/configure/push operations return zero on success, negative on failure.
// Accepted packets may buffer; only STREAMING confirms presented video.
int mm_media_set_video_codec(mm_media *media, int hevc);
int mm_media_push_video(mm_media *media, const unsigned char *data, size_t length, uint64_t local_timestamp_ns);
int mm_media_configure_audio(mm_media *media, unsigned int codec, unsigned int samples_per_packet, uint64_t audio_format);
int mm_media_push_audio(mm_media *media, const unsigned char *data, size_t length, uint64_t local_timestamp_ns);
void mm_media_set_volume(mm_media *media, float decibels);
void mm_media_pause(mm_media *media, int paused);
void mm_media_flush_audio(mm_media *media);
void mm_media_flush_video(mm_media *media);
void mm_media_reset(mm_media *media);
void mm_media_show_window(mm_media *media);
uint64_t mm_media_rendered_frames(mm_media *media);
void mm_media_destroy(mm_media *media);

#ifdef __cplusplus
}
#endif
