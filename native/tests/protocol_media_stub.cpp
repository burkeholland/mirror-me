// SPDX-License-Identifier: GPL-3.0-or-later
// Linked ONLY by MM_PROTOCOL_ONLY tests, never into a production receiver archive.
#include "media.h"
#include <new>
struct mm_media {};
extern "C" {
mm_media *mm_media_create(const mm_receiver_config *, mm_event_callback, void *, char *, size_t) { return new (std::nothrow) mm_media; }
int mm_media_set_video_codec(mm_media *, int) { return 0; }
int mm_media_push_video(mm_media *, const unsigned char *, size_t, uint64_t) { return 0; }
int mm_media_configure_audio(mm_media *, unsigned int, unsigned int, uint64_t) { return 0; }
int mm_media_push_audio(mm_media *, const unsigned char *, size_t, uint64_t) { return 0; }
void mm_media_set_volume(mm_media *, float) {}
void mm_media_pause(mm_media *, int) {}
void mm_media_flush_audio(mm_media *) {}
void mm_media_flush_video(mm_media *) {}
void mm_media_reset(mm_media *) {}
void mm_media_show_window(mm_media *) {}
uint64_t mm_media_rendered_frames(mm_media *) { return 0; }
void mm_media_destroy(mm_media *media) { delete media; }
}
