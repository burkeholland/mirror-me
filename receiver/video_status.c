// SPDX-License-Identifier: GPL-3.0-or-later
#include "video_status.h"
#include "video_window.h"
#include <gst/base/gstbasesink.h>
#include <gst/video/gstvideosink.h>

typedef struct {
    GstElement *pipeline;
    gboolean reported;
    gboolean require_window;
    guint window_ticks;
} video_watch;

guint64 mirrorme_rendered_frames(GstElement *pipeline, gboolean include_test_sink) {
    guint64 frames = 0;
    GstIterator *iterator = gst_bin_iterate_recurse(GST_BIN(pipeline));
    GValue value = G_VALUE_INIT;
    gboolean done = FALSE;
    while (!done) {
        switch (gst_iterator_next(iterator, &value)) {
        case GST_ITERATOR_OK: {
            GstElement *element = g_value_get_object(&value);
            if (GST_IS_BASE_SINK(element) && (include_test_sink || GST_IS_VIDEO_SINK(element))) {
                GstStructure *stats = NULL;
                guint64 rendered = 0;
                g_object_get(element, "stats", &stats, NULL);
                if (stats) {
                    if (gst_structure_get_uint64(stats, "rendered", &rendered)) {
                        frames = MAX(frames, rendered);
                    }
                    gst_structure_free(stats);
                }
            }
            g_value_reset(&value);
            break;
        }
        case GST_ITERATOR_RESYNC:
            frames = 0;
            gst_iterator_resync(iterator);
            break;
        default:
            done = TRUE;
            break;
        }
    }
    if (G_VALUE_TYPE(&value)) g_value_unset(&value);
    gst_iterator_free(iterator);
    return frames;
}

static gboolean poll_video(gpointer data) {
    video_watch *watch = data;
    if (watch->require_window && (!watch->reported || ++watch->window_ticks % 10 == 0)) {
        mirrorme_brand_video_windows();
    }
    if (!watch->reported && mirrorme_rendered_frames(watch->pipeline, FALSE) > 0) {
        watch->reported = TRUE;
        g_print("MIRRORME_STREAMING\n");
    } else if (!watch->reported && watch->require_window &&
               mirrorme_rendered_frames(watch->pipeline, TRUE) > 0) {
        watch->reported = TRUE;
        g_print("MIRRORME_RECEIVER_ERROR: Windows could not open a video output. Check your display driver and try software decoding in Picture & sound.\n");
    }
    return G_SOURCE_CONTINUE;
}

static void free_watch(gpointer data) {
    video_watch *watch = data;
    gst_object_unref(watch->pipeline);
    g_free(watch);
}

guint mirrorme_watch_video(GstElement *pipeline, gboolean require_window) {
    video_watch *watch = g_new0(video_watch, 1);
    watch->require_window = require_window;
    // The watch owns a pipeline reference, never a renderer pointer. GLib
    // releases it after any active callback, including concurrent teardown.
    watch->pipeline = gst_object_ref(pipeline);
    return g_timeout_add_full(G_PRIORITY_DEFAULT, 100, poll_video, watch, free_watch);
}
