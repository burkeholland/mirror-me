// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mm_audio_decoder mm_audio_decoder;
typedef struct mm_audio_frame {
    const int16_t *samples;
    size_t frames;
    unsigned int sample_rate;
    unsigned int channels;
} mm_audio_frame;

mm_audio_decoder *mm_audio_decoder_create(unsigned int codec, unsigned int samples_per_packet,
    uint64_t audio_format, char *error, size_t error_capacity);
int mm_audio_decoder_decode(mm_audio_decoder *decoder, const unsigned char *data, size_t length,
    mm_audio_frame *frame, char *error, size_t error_capacity);
void mm_audio_decoder_flush(mm_audio_decoder *decoder);
void mm_audio_decoder_destroy(mm_audio_decoder *decoder);

#ifdef __cplusplus
}
#endif
