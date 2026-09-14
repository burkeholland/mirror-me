// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

enum class ProbeTiming { disabled, buffered_behind, buffered_ahead, on_time };
int run_media_probe(bool window, bool software, bool broken, ProbeTiming timing);
