// SPDX-License-Identifier: GPL-3.0-or-later
// Probe-only synthetic PCM producer. Never link this file into the receiver.
#include "../include/audio_decode.h"
#include <cstdio>
#include <vector>
struct mm_audio_decoder { std::vector<int16_t> pcm; };
extern "C" {
mm_audio_decoder *mm_audio_decoder_create(unsigned codec, unsigned, uint64_t, char *error, size_t capacity) {
    if (codec != 0x4d4d) {
        if (error && capacity) std::snprintf(error, capacity, "Test-only synthetic codec required.");
        return nullptr;
    }
    return new mm_audio_decoder;
}
int mm_audio_decoder_decode(mm_audio_decoder *decoder, const unsigned char *data, size_t length,
    mm_audio_frame *frame, char *, size_t) {
    if (!decoder || !data || length != 1 || data[0] != 42) return -1;
    decoder->pcm.assign(441 * 2, 0);
    *frame = {decoder->pcm.data(), 441, 44100, 2};
    return 0;
}
void mm_audio_decoder_flush(mm_audio_decoder *decoder) { if (decoder) decoder->pcm.clear(); }
void mm_audio_decoder_destroy(mm_audio_decoder *decoder) { delete decoder; }
}
