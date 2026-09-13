// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <gst/gst.h>

#ifdef __cplusplus
extern "C" {
#endif
guint mirrorme_watch_video(GstElement *pipeline, gboolean require_window);
guint64 mirrorme_rendered_frames(GstElement *pipeline, gboolean include_test_sink);
#ifdef __cplusplus
}
#endif
