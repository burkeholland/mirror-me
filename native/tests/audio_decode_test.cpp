// SPDX-License-Identifier: GPL-3.0-or-later
#include "audio_decode.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

namespace {
unsigned assertions = 0;
void require(bool condition, const char *message) {
    ++assertions;
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}

struct Packet {
    std::vector<unsigned char> data;
    unsigned frames;
};
struct Fixture {
    unsigned codec, spp, rate, channels;
    uint64_t format, frames;
    std::vector<unsigned char> cookie;
    std::vector<Packet> packets;
};

std::vector<unsigned char> bytes(const std::string &path) {
    std::ifstream input(path, std::ios::binary);
    require(input.good(), ("Open fixture " + path).c_str());
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

Fixture load(const std::string &path) {
    auto data = bytes(path);
    size_t offset = 0;
    auto integer = [&](unsigned width) {
        require(width <= 8 && offset + width <= data.size(), "Complete fixture metadata");
        uint64_t value = 0;
        for (unsigned i = 0; i < width; ++i) value |= uint64_t(data[offset++]) << (8 * i);
        return value;
    };
    require(data.size() > 48 && std::memcmp(data.data(), "MMAUDIO1", 8) == 0, "Fixture magic");
    offset += 8;
    Fixture fixture{};
    fixture.codec = static_cast<unsigned>(integer(4));
    fixture.spp = static_cast<unsigned>(integer(4));
    fixture.rate = static_cast<unsigned>(integer(4));
    fixture.channels = static_cast<unsigned>(integer(4));
    fixture.format = integer(8);
    fixture.frames = integer(8);
    size_t cookie_length = integer(4), count = integer(4);
    require(cookie_length < 128 && offset + cookie_length <= data.size() && count < 1024, "Bounded fixture");
    fixture.cookie.assign(data.begin() + offset, data.begin() + offset + cookie_length);
    offset += cookie_length;
    for (size_t i = 0; i < count; ++i) {
        const size_t length = integer(4);
        const unsigned frames = static_cast<unsigned>(integer(4));
        require(length <= 65536 && offset + length <= data.size(), "Complete codec packet");
        fixture.packets.push_back({{data.begin() + offset, data.begin() + offset + length}, frames});
        offset += length;
    }
    require(offset == data.size(), "Fixture preserves every encoded byte");
    return fixture;
}

std::vector<int16_t> decode(mm_audio_decoder *decoder, const Fixture &fixture) {
    std::vector<int16_t> samples;
    char error[256];
    for (const auto &packet : fixture.packets) {
        mm_audio_frame frame{};
        int result = mm_audio_decoder_decode(decoder, packet.data.data(), packet.data.size(), &frame, error, sizeof(error));
        if (result) std::fprintf(stderr, "ct=%u packet=%zu: %s\n", fixture.codec, samples.size(), error);
        require(result == 0 && error[0] == '\0', "Decode actual codec access unit");
        require(frame.frames == packet.frames, "Exact frame count per packet");
        require(frame.sample_rate == fixture.rate && frame.channels == fixture.channels, "Actual sample rate and channels");
        require(frame.samples != nullptr, "Samples point to retained output");
        samples.insert(samples.end(), frame.samples, frame.samples + frame.frames * frame.channels);
        require(std::equal(frame.samples, frame.samples + frame.frames * frame.channels,
                           samples.end() - frame.frames * frame.channels), "Output lifetime until next decoder operation");
    }
    require(samples.size() == fixture.frames * fixture.channels, "Exact total decoded sample count");
    return samples;
}

double tone_energy(const std::vector<int16_t> &samples, unsigned channels, unsigned channel,
                   unsigned rate, double frequency, size_t start, size_t end) {
    double sine = 0, cosine = 0, energy = 0;
    constexpr double pi = 3.14159265358979323846;
    for (size_t i = start; i < end; ++i) {
        const double sample = samples[i * channels + channel];
        const double phase = 2 * pi * frequency * i / rate;
        sine += sample * std::sin(phase);
        cosine += sample * std::cos(phase);
        energy += sample * sample;
    }
    if (!energy) return 0;
    return 2 * (sine * sine + cosine * cosine) / ((end - start) * energy);
}

void tones(const std::vector<int16_t> &samples, const Fixture &fixture) {
    size_t start = 0, end = samples.size() / fixture.channels;
    if (fixture.codec == 4 || fixture.codec == 8) {
        start = 2048;
        end -= 1024;
    }
    require(end > start, "Sufficient steady-state tone samples");
    for (unsigned channel = 0; channel < fixture.channels; ++channel) {
        const double expected = channel == 0 ? 997 : 1499;
        const double ratio = tone_energy(samples, fixture.channels, channel, fixture.rate, expected, start, end);
        const double unwanted = tone_energy(samples, fixture.channels, channel, fixture.rate, 3000, start, end);
        if (ratio <= 0.8) std::fprintf(stderr, "Tone energy ct=%u ch=%u: %.6f\n", fixture.codec, channel, ratio);
        require(ratio > 0.8 && unwanted < 0.03, "Decoded expected independent channel tones, not invented PCM/noise");
        double rms = 0;
        for (size_t i = start; i < end; ++i) {
            double sample = samples[i * fixture.channels + channel];
            rms += sample * sample;
        }
        rms = std::sqrt(rms / (end - start));
        require(rms > 3500 && rms < 8000, "Decoded nonzero tone at expected amplitude");
    }
}

void invalid_packet(mm_audio_decoder *decoder, const unsigned char *data, size_t length) {
    mm_audio_decoder_flush(decoder);
    mm_audio_frame frame{reinterpret_cast<const int16_t *>(1), 99, 99, 99};
    char error[256] = {};
    const int result = mm_audio_decoder_decode(decoder, data, length, &frame, error, sizeof(error));
    if (!result || !error[0]) std::fprintf(stderr, "Invalid length=%zu result=%d frames=%zu error=%s\n",
                                          length, result, frame.frames, error);
    require(result != 0 && error[0], "Invalid packet returns explicit error text");
    require(frame.frames == 0 && frame.samples == nullptr, "Invalid packet never returns invented PCM");
}

void exercise(const std::string &directory, const char *name) {
    const auto fixture = load(directory + "\\" + name + ".mma");
    if (fixture.codec == 8) {
        require(fixture.cookie.size() == 4 && fixture.cookie[0] == 0xf8, "Fixture really is AAC-ELD AOT39");
        const unsigned object_type = 32 + ((fixture.cookie[0] & 7) << 3) + (fixture.cookie[1] >> 5);
        require(object_type == 39, "ELD fixture is not AAC-LC");
    }
    char error[256];
    auto *decoder = mm_audio_decoder_create(fixture.codec, fixture.spp, fixture.format, error, sizeof(error));
    if (!decoder) std::fprintf(stderr, "Create: %s\n", error);
    require(decoder != nullptr, "Create supported static codec");
    auto samples = decode(decoder, fixture);
    tones(samples, fixture);
    if (fixture.codec == 2) {
        const auto reference = bytes(directory + "\\" + name + ".s16le");
        require(reference.size() == samples.size() * sizeof(int16_t), "ALAC reference sample count");
        require(std::memcmp(samples.data(), reference.data(), reference.size()) == 0, "ALAC lossless samples match original PCM");
    }
    for (unsigned i = 0; i < 3; ++i) {
        mm_audio_decoder_flush(decoder);
        require(samples == decode(decoder, fixture), "Flush fully clears overlap/history and buffered codec state");
    }
    const auto &packet = fixture.packets.front().data;
    invalid_packet(decoder, nullptr, packet.size());
    invalid_packet(decoder, packet.data(), 0);
    invalid_packet(decoder, packet.data(), 65537);
    invalid_packet(decoder, packet.data(), 1);
    invalid_packet(decoder, packet.data(), packet.size() / 2);
    const unsigned char malformed[16] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                                         0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    invalid_packet(decoder, malformed, sizeof(malformed));
    if (fixture.codec == 2) {
        auto trailing = packet;
        trailing.insert(trailing.end(), 16, 0xff);
        invalid_packet(decoder, trailing.data(), trailing.size());
    }
    if (std::strstr(name, "-adts")) {
        auto doubled = packet;
        doubled.insert(doubled.end(), packet.begin(), packet.end());
        invalid_packet(decoder, doubled.data(), doubled.size());
        auto mismatch = packet;
        mismatch[2] ^= 4;
        invalid_packet(decoder, mismatch.data(), mismatch.size());
    }
    mm_audio_decoder_flush(decoder);
    require(samples == decode(decoder, fixture), "Decoder recovers after rejected malformed/truncated/oversized packets");
    mm_audio_decoder_destroy(decoder);
    std::printf("PASS %s: %zu packets, %llu frames at %u Hz / %u channels\n", name,
                fixture.packets.size(), static_cast<unsigned long long>(fixture.frames), fixture.rate, fixture.channels);
}

void configuration_tests() {
    char error[256];
    auto bad = [&](unsigned codec, unsigned spp, uint64_t format) {
        auto *decoder = mm_audio_decoder_create(codec, spp, format, error, sizeof(error));
        require(!decoder && error[0], "Unsupported configuration is explicit");
    };
    bad(0, 352, 0); bad(3, 352, 0); bad(16, 352, 0); bad(2, 4097, 0);
    bad(8, 460, 0); bad(8, 1024, 0); bad(4, 480, 0);
    bad(2, 352, uint64_t(1) << 24); bad(2, 352, uint64_t(3) << 18);
    bad(8, 480, uint64_t(1) << 63); bad(8, 480, uint64_t(1) << 28);
    for (unsigned codec : {1u, 2u, 4u, 8u}) {
        for (unsigned i = 0; i < 16; ++i) {
            auto *decoder = mm_audio_decoder_create(codec, 0, 0, error, sizeof(error));
            require(decoder != nullptr, "Legacy zero-format/default-SPP configuration");
            mm_audio_decoder_flush(decoder);
            mm_audio_decoder_flush(decoder);
            mm_audio_decoder_destroy(decoder);
        }
    }
    for (unsigned bit : {24u, 25u, 26u, 27u, 31u, 32u}) {
        for (unsigned spp : {480u, 512u}) {
            auto *decoder = mm_audio_decoder_create(8, spp, uint64_t(1) << bit, error, sizeof(error));
            if (!decoder) std::fprintf(stderr, "ELD config: %s\n", error);
            require(decoder != nullptr, "AAC-ELD correct rate/channel/480-or-512 AudioSpecificConfig accepted");
            mm_audio_decoder_destroy(decoder);
        }
    }
    for (unsigned bit : {22u, 23u}) {
        auto *decoder = mm_audio_decoder_create(4, 960, uint64_t(1) << bit, error, sizeof(error));
        require(decoder != nullptr, "AAC-LC short-frame configuration accepted");
        require(mm_audio_decoder_decode(decoder, nullptr, 0, nullptr, error, sizeof(error)) != 0 && error[0],
                "Missing output frame returns an explicit error");
        mm_audio_decoder_destroy(decoder);
    }
    mm_audio_decoder_flush(nullptr);
    mm_audio_decoder_destroy(nullptr);
    mm_audio_frame frame{};
    require(mm_audio_decoder_decode(nullptr, nullptr, 0, &frame, error, sizeof(error)) != 0, "Null decoder error");
    char tiny = 'x';
    require(!mm_audio_decoder_create(99, 0, 0, &tiny, 1) && tiny == '\0', "One-byte error buffer is terminated");
    require(!mm_audio_decoder_create(99, 0, 0, nullptr, 999), "Null error buffer is safe");
}

void pcm_tests() {
    char error[256];
    for (unsigned bit = 2; bit <= 17; ++bit) {
        const bool wide = bit == 12 || bit == 13 || bit == 16 || bit == 17;
        const unsigned channels = (bit % 2) ? 2 : 1;
        const unsigned low_rates[] = {8000, 16000, 24000, 32000};
        const unsigned rate = bit < 10 ? low_rates[(bit - 2) / 2] : bit < 14 ? 44100 : 48000;
        auto *decoder = mm_audio_decoder_create(1, 352, uint64_t(1) << bit, error, sizeof(error));
        require(decoder != nullptr, "PCM rate/channel/depth configuration");
        std::vector<unsigned char> packet;
        std::vector<int16_t> expected;
        for (unsigned i = 0; i < 16 * channels; ++i) {
            const int16_t sample = (i % 2) ? static_cast<int16_t>(32767 - i) : static_cast<int16_t>(-32768 + i);
            expected.push_back(sample);
            if (wide) packet.push_back(0x7f);
            packet.push_back(static_cast<unsigned char>(sample & 255));
            packet.push_back(static_cast<unsigned char>((static_cast<uint16_t>(sample) >> 8) & 255));
        }
        mm_audio_frame frame{};
        require(mm_audio_decoder_decode(decoder, packet.data(), packet.size(), &frame, error, sizeof(error)) == 0, "PCM decode");
        require(frame.frames == 16 && frame.channels == channels && frame.sample_rate == rate, "PCM exact frame/channel/rate");
        require(std::equal(expected.begin(), expected.end(), frame.samples), "PCM signed16 output endian/depth conversion");
        invalid_packet(decoder, packet.data(), packet.size() - 1);
        invalid_packet(decoder, packet.data(), 353 * channels * (wide ? 3 : 2));
        mm_audio_decoder_destroy(decoder);
    }
}
}

int main(int argc, char **argv) {
    require(argc == 2, "Supply audio_fixtures directory");
    configuration_tests();
    pcm_tests();
    for (const auto *name : {"alac-44100-16-352", "alac-48000-24", "aac-lc-44100", "aac-lc-48000",
                             "aac-lc-44100-adts", "aac-lc-48000-adts", "aac-eld-44100-480", "aac-eld-48000-512"})
        exercise(argv[1], name);
    // Independent decoder construction may occur on different connection threads.
    // Do not mutate the test assertion counter from worker threads.
    auto create_destroy = [] {
        for (unsigned i = 0; i < 16; ++i) {
            char error[256];
            auto *decoder = mm_audio_decoder_create(8, 480, uint64_t(1) << 24, error, sizeof(error));
            if (!decoder) std::abort();
            mm_audio_decoder_destroy(decoder);
        }
    };
    std::thread first(create_destroy), second(create_destroy);
    first.join();
    second.join();
    std::printf("PASS %u assertions; ALAC, AAC-LC, real AAC-ELD, PCM, limits, lifecycle and flush\n", assertions);
    return 0;
}
