// SPDX-License-Identifier: GPL-3.0-or-later
// AirPlay cookies/ASC follow the attributed UxPlay renderer; see AUDIO-NOTICES.txt.
#include "audio_decode.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
}

namespace {
constexpr size_t max_packet_bytes = 65536;
constexpr unsigned max_packet_frames = 4096;
constexpr unsigned max_channels = 2;

struct Format {
    unsigned codec;
    unsigned rate;
    unsigned bits;
    unsigned channels;
};

// Indices are the negotiated AirPlay audioFormat bit positions, not codec IDs.
constexpr Format formats[] = {
    {0, 0, 0, 0}, {0, 0, 0, 0},
    {1, 8000, 16, 1}, {1, 8000, 16, 2},
    {1, 16000, 16, 1}, {1, 16000, 16, 2},
    {1, 24000, 16, 1}, {1, 24000, 16, 2},
    {1, 32000, 16, 1}, {1, 32000, 16, 2},
    {1, 44100, 16, 1}, {1, 44100, 16, 2},
    {1, 44100, 24, 1}, {1, 44100, 24, 2},
    {1, 48000, 16, 1}, {1, 48000, 16, 2},
    {1, 48000, 24, 1}, {1, 48000, 24, 2},
    {2, 44100, 16, 2}, {2, 44100, 24, 2},
    {2, 48000, 16, 2}, {2, 48000, 24, 2},
    {4, 44100, 16, 2}, {4, 48000, 16, 2},
    {8, 44100, 16, 2}, {8, 48000, 16, 2},
    {8, 16000, 16, 1}, {8, 24000, 16, 1},
    {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0},
    {8, 44100, 16, 1}, {8, 48000, 16, 1}
};

int fail(char *error, size_t capacity, const char *format, ...) {
    if (error && capacity) {
        va_list arguments;
        va_start(arguments, format);
        std::vsnprintf(error, capacity, format, arguments);
        va_end(arguments);
        error[capacity - 1] = '\0';
    }
    return -1;
}

int codec_error(char *error, size_t capacity, const char *operation, int code) {
    char detail[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(code, detail, sizeof(detail));
    return fail(error, capacity, "%s: %s (%d)", operation, detail, code);
}

void big32(unsigned char *data, unsigned value) {
    for (unsigned i = 0; i < 4; ++i) data[i] = static_cast<unsigned char>(value >> (24 - i * 8));
}

struct Bits {
    unsigned char data[8] = {};
    unsigned count = 0;
    void put(unsigned value, unsigned width) {
        for (unsigned i = width; i; --i, ++count)
            data[count / 8] |= ((value >> (i - 1)) & 1) << (7 - count % 8);
    }
};

unsigned frequency_index(unsigned rate) {
    switch (rate) {
    case 48000: return 3;
    case 44100: return 4;
    case 32000: return 5;
    case 24000: return 6;
    case 16000: return 8;
    default: return 15;
    }
}
}

struct mm_audio_decoder {
    const AVCodec *implementation;
    AVCodecContext *context;
    AVPacket *packet;
    AVFrame *decoded;
    int16_t *samples;
    Format format;
    unsigned samples_per_packet;
};

namespace {
int bounded_buffer(AVCodecContext *context, AVFrame *frame, int flags) {
    const auto *decoder = static_cast<const mm_audio_decoder *>(context->opaque);
    // FFmpeg's AAC decoder reserves 2048 samples even for LC/ELD, then sets the
    // actual 1024/960/512/480 count. Validate the final output separately.
    const unsigned allocation_frames = decoder->format.codec == 4 || decoder->format.codec == 8
        ? 2048 : decoder->samples_per_packet;
    if (frame->nb_samples <= 0 || frame->nb_samples > static_cast<int>(allocation_frames) ||
        frame->ch_layout.nb_channels != static_cast<int>(decoder->format.channels))
        return AVERROR_INVALIDDATA;
    return avcodec_default_get_buffer2(context, frame, flags);
}

int set_config(mm_audio_decoder *decoder) {
    unsigned char cookie[36] = {0, 0, 0, 36, 'a', 'l', 'a', 'c'};
    Bits asc;
    const unsigned char *data = nullptr;
    size_t length = 0;
    const auto &format = decoder->format;
    if (format.codec == 2) {
        big32(cookie + 12, decoder->samples_per_packet);
        cookie[17] = static_cast<unsigned char>(format.bits);
        cookie[18] = 40;
        cookie[19] = 10;
        cookie[20] = 14;
        cookie[21] = static_cast<unsigned char>(format.channels);
        cookie[23] = 255;
        big32(cookie + 32, format.rate);
        data = cookie;
        length = sizeof(cookie);
    } else if (format.codec == 4 || format.codec == 8) {
        if (format.codec == 8) {
            asc.put(31, 5);
            asc.put(39 - 32, 6); // Escaped MPEG-4 AOT 39: ER AAC ELD, not LC/ADTS.
        } else {
            asc.put(2, 5);
        }
        asc.put(frequency_index(format.rate), 4);
        asc.put(format.channels, 4);
        if (format.codec == 8) {
            asc.put(decoder->samples_per_packet == 480, 1);
            asc.put(0, 3); // No section/scalefactor/spectral resilience.
            asc.put(0, 1); // AirPlay ELD has no low-delay SBR.
            asc.put(0, 4); // ELDEXT_TERM.
            asc.put(0, 2); // epConfig.
        } else {
            asc.put(decoder->samples_per_packet == 960, 1);
            asc.put(0, 2); // dependsOnCoreCoder and extensionFlag.
        }
        data = asc.data;
        length = (asc.count + 7) / 8;
    }
    if (length) {
        decoder->context->extradata = static_cast<uint8_t *>(av_mallocz(length + AV_INPUT_BUFFER_PADDING_SIZE));
        if (!decoder->context->extradata) return AVERROR(ENOMEM);
        std::memcpy(decoder->context->extradata, data, length);
        decoder->context->extradata_size = static_cast<int>(length);
    }
    return 0;
}

int open_context(mm_audio_decoder *decoder) {
    const auto &format = decoder->format;
    auto *context = avcodec_alloc_context3(decoder->implementation);
    if (!context) return AVERROR(ENOMEM);
    decoder->context = context;
    context->sample_rate = static_cast<int>(format.rate);
    av_channel_layout_default(&context->ch_layout, static_cast<int>(format.channels));
    context->bits_per_raw_sample = static_cast<int>(format.bits);
    context->thread_count = 1;
    context->thread_type = 0;
    context->err_recognition = AV_EF_CAREFUL | AV_EF_EXPLODE | AV_EF_BITSTREAM | AV_EF_BUFFER;
    context->max_samples = max_packet_frames * format.channels;
    context->get_buffer2 = bounded_buffer;
    context->opaque = decoder;
    int result = set_config(decoder);
    if (result >= 0) result = avcodec_open2(context, decoder->implementation, nullptr);
    if (result < 0) avcodec_free_context(&decoder->context);
    return result;
}

int copy_samples(mm_audio_decoder *decoder, size_t offset, char *error, size_t capacity) {
    const auto *frame = decoder->decoded;
    const auto sample_format = static_cast<AVSampleFormat>(frame->format);
    const bool planar = av_sample_fmt_is_planar(sample_format) != 0;
    const auto packed = av_get_packed_sample_fmt(sample_format);
    if (packed != AV_SAMPLE_FMT_S16 && packed != AV_SAMPLE_FMT_S32 && packed != AV_SAMPLE_FMT_FLT)
        return fail(error, capacity, "Unsupported decoded sample format %d", frame->format);
    for (int i = 0; i < frame->nb_samples; ++i) {
        for (unsigned channel = 0; channel < decoder->format.channels; ++channel) {
            const auto *plane = frame->extended_data[planar ? channel : 0];
            const size_t index = planar ? static_cast<size_t>(i) : i * decoder->format.channels + channel;
            int value = 0;
            if (packed == AV_SAMPLE_FMT_S16) {
                value = reinterpret_cast<const int16_t *>(plane)[index];
            } else if (packed == AV_SAMPLE_FMT_S32) {
                // FFmpeg uses left-aligned S32 for 24-bit ALAC/PCM.
                const int32_t sample = reinterpret_cast<const int32_t *>(plane)[index];
                value = static_cast<int>(std::floor(static_cast<double>(sample) / 65536.0));
            } else {
                const float sample = reinterpret_cast<const float *>(plane)[index];
                if (!std::isfinite(sample))
                    return fail(error, capacity, "Decoder produced a non-finite audio sample");
                if (sample >= 1.0f) value = 32767;
                else if (sample <= -1.0f) value = -32768;
                else value = static_cast<int>(std::lround(sample * 32768.0f));
                if (value > 32767) value = 32767;
            }
            decoder->samples[(offset + i) * decoder->format.channels + channel] = static_cast<int16_t>(value);
        }
    }
    return 0;
}

int validate_packet(mm_audio_decoder *decoder, const unsigned char *&data, size_t &length,
                    char *error, size_t capacity) {
    if (!data || !length) return fail(error, capacity, "Empty audio packet (flush uses mm_audio_decoder_flush)");
    if (length > max_packet_bytes) return fail(error, capacity, "Audio packet exceeds 65536-byte limit");
    if (decoder->format.codec == 1) {
        const unsigned alignment = decoder->format.channels * (decoder->format.bits / 8);
        if (length % alignment)
            return fail(error, capacity, "PCM packet is truncated: incomplete interleaved sample");
        if (length / alignment > decoder->samples_per_packet)
            return fail(error, capacity, "PCM packet exceeds negotiated samples_per_packet");
    }
    if (decoder->format.codec == 2 && length < 3)
        return fail(error, capacity, "Truncated ALAC packet");
    if (decoder->format.codec == 8 && length < 2)
        return fail(error, capacity, "Truncated AAC-ELD access unit");
    // Accept either one raw LC access unit or exactly one validated ADTS frame.
    // ELD is always raw and must never acquire an invented ADTS (LC) header.
    if (decoder->format.codec == 4 && length >= 2 && data[0] == 0xff && (data[1] & 0xf0) == 0xf0) {
        if (length < 7) return fail(error, capacity, "Truncated AAC ADTS header");
        const unsigned header = (data[1] & 1) ? 7 : 9;
        const unsigned bytes = ((data[3] & 3) << 11) | (data[4] << 3) | (data[5] >> 5);
        const unsigned channels = ((data[2] & 1) << 2) | (data[3] >> 6);
        if ((data[1] & 6) || (data[2] >> 6) != 1 ||
            ((data[2] >> 2) & 15) != frequency_index(decoder->format.rate) ||
            channels != decoder->format.channels || decoder->samples_per_packet != 1024)
            return fail(error, capacity, "ADTS configuration does not match negotiated AAC-LC format");
        if ((data[6] & 3) || bytes != length || length <= header)
            return fail(error, capacity, "ADTS packet must contain exactly one complete AAC-LC access unit");
        // Without a verified CRC, accepting a protected frame would silently ignore corruption.
        if (header != 7) return fail(error, capacity, "CRC-protected ADTS is not supported; supply a verified raw access unit");
        data += header;
        length -= header;
    }
    return 0;
}
}

extern "C" mm_audio_decoder *mm_audio_decoder_create(unsigned codec, unsigned samples_per_packet,
    uint64_t audio_format, char *error, size_t error_capacity) {
    if (error && error_capacity) error[0] = '\0';
    if (codec != 1 && codec != 2 && codec != 4 && codec != 8) {
        fail(error, error_capacity, "Unsupported AirPlay audio codec ct=%u (supported: 1, 2, 4, 8)", codec);
        return nullptr;
    }
    Format format{codec, 44100, 16, 2};
    if (audio_format) {
        if (audio_format & (audio_format - 1)) {
            fail(error, error_capacity, "audio_format must select one negotiated format, not a capability mask");
            return nullptr;
        }
        unsigned bit = 0;
        for (uint64_t value = audio_format; value > 1; value >>= 1) ++bit;
        if (bit >= sizeof(formats) / sizeof(formats[0]) || formats[bit].codec != codec) {
            fail(error, error_capacity, "Unsupported audio_format bit %u for codec ct=%u", bit, codec);
            return nullptr;
        }
        format = formats[bit];
    }
    if (!samples_per_packet) samples_per_packet = codec == 8 ? 480 : codec == 4 ? 1024 : 352;
    if (samples_per_packet > max_packet_frames ||
        (codec == 8 && samples_per_packet != 480 && samples_per_packet != 512) ||
        (codec == 4 && samples_per_packet != 960 && samples_per_packet != 1024)) {
        fail(error, error_capacity, "Unsupported samples_per_packet=%u for ct=%u (limit 4096)", samples_per_packet, codec);
        return nullptr;
    }
    const AVCodecID id = codec == 2 ? AV_CODEC_ID_ALAC :
        codec == 1 ? (format.bits == 24 ? AV_CODEC_ID_PCM_S24LE : AV_CODEC_ID_PCM_S16LE) : AV_CODEC_ID_AAC;
    const AVCodec *implementation = avcodec_find_decoder(id);
    if (!implementation) {
        fail(error, error_capacity, "Required static decoder for ct=%u is absent from this build", codec);
        return nullptr;
    }
    auto *decoder = static_cast<mm_audio_decoder *>(av_mallocz(sizeof(mm_audio_decoder)));
    if (!decoder) {
        fail(error, error_capacity, "Unable to allocate audio decoder");
        return nullptr;
    }
    decoder->format = format;
    decoder->samples_per_packet = samples_per_packet;
    decoder->implementation = implementation;
    decoder->packet = av_packet_alloc();
    decoder->decoded = av_frame_alloc();
    decoder->samples = static_cast<int16_t *>(av_malloc_array(max_packet_frames * max_channels, sizeof(int16_t)));
    if (!decoder->packet || !decoder->decoded || !decoder->samples) {
        fail(error, error_capacity, "Unable to allocate bounded audio decoder buffers");
        mm_audio_decoder_destroy(decoder);
        return nullptr;
    }
    const int result = open_context(decoder);
    if (result < 0) {
        codec_error(error, error_capacity, "Opening static audio codec configuration", result);
        mm_audio_decoder_destroy(decoder);
        return nullptr;
    }
    return decoder;
}

extern "C" int mm_audio_decoder_decode(mm_audio_decoder *decoder, const unsigned char *data, size_t length,
    mm_audio_frame *frame, char *error, size_t error_capacity) {
    if (error && error_capacity) error[0] = '\0';
    if (frame) *frame = {};
    if (!decoder || !frame) return fail(error, error_capacity, "Audio decoder and output frame are required");
    if (validate_packet(decoder, data, length, error, error_capacity)) return -1;
    if (!decoder->context) {
        const int opened = open_context(decoder);
        if (opened < 0) return codec_error(error, error_capacity, "Reopening flushed audio codec", opened);
    }
    av_packet_unref(decoder->packet);
    int result = av_new_packet(decoder->packet, static_cast<int>(length));
    if (result < 0) return codec_error(error, error_capacity, "Allocating padded audio packet", result);
    // av_new_packet supplies AV_INPUT_BUFFER_PADDING_SIZE zero bytes past packet->size.
    std::memcpy(decoder->packet->data, data, length);
    result = avcodec_send_packet(decoder->context, decoder->packet);
    av_packet_unref(decoder->packet);
    if (result < 0) {
        mm_audio_decoder_flush(decoder);
        return codec_error(error, error_capacity, "Decoding audio access unit", result);
    }
    size_t frames = 0;
    for (;;) {
        result = avcodec_receive_frame(decoder->context, decoder->decoded);
        if (result == AVERROR(EAGAIN)) break;
        if (result < 0) {
            mm_audio_decoder_flush(decoder);
            return codec_error(error, error_capacity, "Receiving decoded audio", result);
        }
        const auto *decoded = decoder->decoded;
        if (decoded->nb_samples <= 0 || decoded->sample_rate != static_cast<int>(decoder->format.rate) ||
            decoded->ch_layout.nb_channels != static_cast<int>(decoder->format.channels) ||
            frames + decoded->nb_samples > decoder->samples_per_packet ||
            decoded->decode_error_flags || (decoded->flags & AV_FRAME_FLAG_CORRUPT)) {
            mm_audio_decoder_flush(decoder);
            return fail(error, error_capacity, "Corrupt audio frame or decoded format/frame count violates negotiation");
        }
        const unsigned count = static_cast<unsigned>(decoded->nb_samples);
        result = copy_samples(decoder, frames, error, error_capacity);
        av_frame_unref(decoder->decoded);
        if (result) {
            mm_audio_decoder_flush(decoder);
            return result;
        }
        frames += count;
    }
    if (!frames && !(decoder->context->codec->capabilities & AV_CODEC_CAP_DELAY)) {
        mm_audio_decoder_flush(decoder);
        return fail(error, error_capacity, "Audio access unit contained no decodable frame");
    }
    frame->samples = frames ? decoder->samples : nullptr;
    frame->frames = frames;
    frame->sample_rate = decoder->format.rate;
    frame->channels = decoder->format.channels;
    return 0;
}

extern "C" void mm_audio_decoder_flush(mm_audio_decoder *decoder) {
    if (!decoder) return;
    // AAC's avcodec_flush_buffers retains PNS/configuration state. Reopen lazily
    // so flush fully resets the stream, and allocation failures can be reported
    // by decode rather than swallowed by this void C API.
    avcodec_free_context(&decoder->context);
    av_packet_unref(decoder->packet);
    av_frame_unref(decoder->decoded);
}

extern "C" void mm_audio_decoder_destroy(mm_audio_decoder *decoder) {
    if (!decoder) return;
    avcodec_free_context(&decoder->context);
    av_packet_free(&decoder->packet);
    av_frame_free(&decoder->decoded);
    av_free(decoder->samples);
    av_free(decoder);
}
