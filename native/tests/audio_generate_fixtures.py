#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate original tones, codec packets and provenance; never used in production."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build" / "native-audio"
OUT = ROOT / "native" / "tests" / "audio_fixtures"
ENCODER = json.loads((ROOT / "native" / "audio-dependencies.json").read_text())["testFixtureEncoder"]
XAAC_COMMIT = ENCODER["commit"]
XAAC_SHA = ENCODER["sourceSha256"]
XAAC_URL = ENCODER["sourceUrl"]
COMMANDS = []


def run(*args, capture=False):
    args = [str(arg) for arg in args]
    COMMANDS.append(args)
    return subprocess.run(args, check=True, stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None).stdout


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hexdump(text):
    return bytes.fromhex("".join(line.split(":", 1)[1].strip().split("  ", 1)[0].replace(" ", "")
                                for line in text.splitlines() if ":" in line))


def pack(name, ct, spp, rate, channels, bit, cookie, packets):
    target = OUT / (name + ".mma")
    with target.open("wb") as output:
        output.write(struct.pack("<8sIIIIQQII", b"MMAUDIO1", ct, spp, rate, channels,
                                 1 << bit, sum(frames for _, frames in packets),
                                 len(cookie), len(packets)))
        output.write(cookie)
        for packet, frames in packets:
            output.write(struct.pack("<II", len(packet), frames))
            output.write(packet)
    return {"file": target.name, "sha256": sha(target), "codec": ct, "sampleRate": rate,
            "channels": channels, "samplesPerPacket": spp, "audioFormat": 1 << bit,
            "decodedFrames": sum(frames for _, frames in packets), "packets": len(packets),
            "cookieHex": cookie.hex()}


def tone(ffmpeg, name, rate=44100, channels=2, frames=13230, bits=16):
    wav = BUILD / (name + ".wav")
    expression = "0.25*sin(2*PI*997*t)"
    if channels == 2:
        expression += "|0.25*sin(2*PI*1499*t)"
    run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
        f"aevalsrc={expression}:s={rate}:d=1", "-af", f"atrim=end_sample={frames}",
        "-c:a", f"pcm_s{bits}le", wav)
    return wav


def container_fixture(ffmpeg, ffprobe, name, ct, spp, rate, bits, bit, frames):
    wav = tone(ffmpeg, name, rate=rate, frames=frames, bits=bits)
    encoded = BUILD / (name + ".m4a")
    options = ["-c:a", "alac"] if ct == 2 else ["-c:a", "aac", "-profile:a", "aac_low", "-b:a", "192k"]
    run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", wav, *options, encoded)
    info = json.loads(run(ffprobe, "-v", "error", "-show_packets", "-show_streams", "-show_data",
                          "-of", "json", encoded, capture=True))
    stream = info["streams"][0]
    cookie = hexdump(stream["extradata"])
    if ct == 2:
        assert len(cookie) == 36 and cookie[4:8] == b"alac"
        assert cookie[17] == bits and cookie[21] == 2
        assert int.from_bytes(cookie[32:36], "big") == rate
    else:
        assert cookie[:2] == (b"\x12\x10" if rate == 44100 else b"\x11\x90")
    packets = [(hexdump(p["data"]), int(p["duration"]) if ct == 2 else spp)
               for p in info["packets"]]
    assert all(len(packet) == int(p["size"]) for (packet, _), p in zip(packets, info["packets"]))
    result = pack(name, ct, spp, rate, 2, bit, cookie, packets)
    if ct == 2:
        reference = OUT / (name + ".s16le")
        run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", wav,
            "-c:a", "pcm_s16le", "-f", "s16le", reference)
        result["referenceSha256"] = sha(reference)
    else:
        # Re-wrap actual LC access units in ADTS for a separate framing test.
        adts = BUILD / (name + ".aac")
        run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", encoded, "-c:a", "copy",
            "-f", "adts", adts)
        raw = adts.read_bytes()
        framed = []
        offset = 0
        while offset < len(raw):
            length = ((raw[offset + 3] & 3) << 11) | (raw[offset + 4] << 3) | (raw[offset + 5] >> 5)
            assert length >= 7 and offset + length <= len(raw)
            framed.append((raw[offset:offset + length], spp))
            offset += length
        assert [p[7:] for p, _ in framed] == [p for p, _ in packets]
        result["adts"] = pack(name + "-adts", ct, spp, rate, 2, bit, cookie[:2], framed)
    result["sourceContainerSha256"] = sha(encoded)
    return result


def eld_encoder():
    archive = BUILD / "libxaac-6c771f2.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(XAAC_URL, archive)
    assert sha(archive) == XAAC_SHA, "libxaac source archive SHA-256 mismatch"
    source = BUILD / f"libxaac-{XAAC_COMMIT}"
    if source.exists():
        shutil.rmtree(source)
    with tarfile.open(archive) as tar:
        tar.extractall(BUILD, filter="data")
    patch = ROOT / "native" / "tests" / "audio_eld_core.patch"
    patch_hash = hashlib.sha256(patch.read_bytes().replace(b"\r\n", b"\n")).hexdigest()
    assert patch_hash == ENCODER["patchSha256"], "Test encoder patch SHA-256 mismatch"
    target = source / "encoder" / "ixheaace_api.c"
    if "(AOT_AAC_ELD == pstr_input_config->aot)) {" in target.read_text():
        run("git", "-C", source, "apply", "--ignore-space-change", "--check", patch)
        run("git", "-C", source, "apply", "--ignore-space-change", patch)
    compiler = Path(r"C:\Strawberry\c\bin")
    build = BUILD / "xaac-build"
    run(compiler / "cmake.exe", "-S", source, "-B", build, "-G", "Ninja",
        f"-DCMAKE_C_COMPILER={compiler / 'gcc.exe'}", f"-DCMAKE_CXX_COMPILER={compiler / 'g++.exe'}",
        f"-DCMAKE_MAKE_PROGRAM={compiler / 'ninja.exe'}", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD64=ON")
    run(compiler / "cmake.exe", "--build", build, "--target", "xaacenc", "--parallel", "6")
    shutil.copyfile(source / "LICENSE", OUT / "LIBXAAC-LICENSE.txt")
    return build / "xaacenc.exe"


def eld_fixture(ffmpeg, encoder, name, spp, rate, bit):
    wav = tone(ffmpeg, name, rate=rate, frames=spp * 32)
    encoded = BUILD / (name + ".es")
    run(encoder, f"-ifile:{wav}", f"-ofile:{encoded}", "-aot:39", f"-framesize:{spp}",
        "-br:192000", "-adts:0", "-mps:0", "-esbr:0")
    entries = [line.split(":") for line in encoded.with_suffix(".txt").read_text().splitlines()]
    metadata = {key: int(value) for key, value in entries if key != "-ia_mp4_stsz_size"}
    sizes = [int(value) for key, value in entries if key == "-ia_mp4_stsz_size"]
    raw = encoded.read_bytes()
    offset = metadata["-dec_info_init"]
    cookie = raw[:offset]
    expected = {
        (44100, 480): bytes.fromhex("f8e85000"),
        (48000, 512): bytes.fromhex("f8e64000"),
    }[(rate, spp)]
    assert cookie == expected, f"Not AirPlay-compatible ELD ASC: {cookie.hex()} != {expected.hex()}"
    assert metadata["-media_time_scale"] == rate
    packets = []
    for size in sizes:
        packets.append((raw[offset:offset + size], spp))
        assert len(packets[-1][0]) == size
        offset += size
    assert offset == len(raw)
    return pack(name, 8, spp, rate, 2, bit, cookie, packets)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--ffprobe", default=shutil.which("ffprobe"))
    args = parser.parse_args()
    assert args.ffmpeg and args.ffprobe, "Install/provide a local FFmpeg/ffprobe for fixture generation only"
    BUILD.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    scratch = BUILD / "scratch"
    scratch.mkdir(exist_ok=True)
    os.environ["TEMP"] = os.environ["TMP"] = str(scratch)
    results = [
        container_fixture(args.ffmpeg, args.ffprobe, "alac-44100-16-352", 2, 352, 44100, 16, 18, 352),
        container_fixture(args.ffmpeg, args.ffprobe, "alac-48000-24", 2, 4096, 48000, 24, 21, 12288),
        container_fixture(args.ffmpeg, args.ffprobe, "aac-lc-44100", 4, 1024, 44100, 16, 22, 12288),
        container_fixture(args.ffmpeg, args.ffprobe, "aac-lc-48000", 4, 1024, 48000, 16, 23, 12288),
    ]
    encoder = eld_encoder()
    results.extend([
        eld_fixture(args.ffmpeg, encoder, "aac-eld-44100-480", 480, 44100, 24),
        eld_fixture(args.ffmpeg, encoder, "aac-eld-48000-512", 512, 48000, 25),
    ])
    provenance = {
        "license": "CC0-1.0 (original generated tones; not copied media)",
        "ffmpegVersion": run(args.ffmpeg, "-version", capture=True).decode().splitlines()[0],
        "eldEncoder": {"project": "ittiam-systems/libxaac", "license": "Apache-2.0",
                       "commit": XAAC_COMMIT, "sourceUrl": XAAC_URL, "sourceSha256": XAAC_SHA,
                       "patch": "native/tests/audio_eld_core.patch",
                       "patchSha256": sha(ROOT / "native" / "tests" / "audio_eld_core.patch")},
        "fixtures": results,
        "commands": COMMANDS,
    }
    (OUT / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    print(f"Generated and source-verified {len(results)} original ALAC/AAC-LC/AAC-ELD fixtures")


if __name__ == "__main__":
    main()
