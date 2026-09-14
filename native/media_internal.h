// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "include/media.h"

// Lifecycle/clock contract (the public declarations are owned by the host):
// - int media operations return 0 on acceptance/success, -1 on rejection/error.
// - Incoming times are already-mapped local UNIX nanoseconds, or 0 for "now".
//   Media converts local wall time to a shared bounded monotonic timeline only.
// - Lifecycle callbacks are serialized on the owned media worker. A destroy
//   from a callback requests
//   stop; the owner must call destroy again after the callback to join/reclaim.
// - The owner stops external packet producers before the final destroy call.
// - Off-callback mm_media_reset waits for the worker to flush both decoders.
//   Stop old producers, reset without holding host callback locks, then announce
//   the replacement session. A callback/window-thread reset is request-only.
// - Pause/resume are idempotent presentation fences. They hide paused video and
//   preserve encoded reference pictures; resumed P-frames do not require IDR.

// Test-only diagnostics, deliberately excluded from the production C ABI.
#ifdef MM_MEDIA_TESTING
struct mm_media_test_stats {
    uintptr_t window;
    size_t video_packets, audio_packets, video_bytes, audio_bytes;
    uint64_t rendered, audio_submitted, clock_resets, dropped;
    uint64_t converted, skipped_conversion, output_allocations, receive_to_paint_ns;
    float volume;
    unsigned presented_width, presented_height;
};
extern "C" void mm_media_test_snapshot(mm_media *, mm_media_test_stats *);
extern "C" int mm_media_test_video_layout(unsigned, unsigned, long, size_t);
#endif
