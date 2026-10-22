// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cmath>

// Pure view-layout math for the mirror window. No platform dependencies so it
// can be unit tested anywhere.
namespace mmview {

enum class Mode { Fit = 0, Fill, Actual, Double, Integer };
constexpr int modeCount = 5;

inline const wchar_t *modeLabel(Mode mode) {
    switch (mode) {
    case Mode::Fit: return L"Fit";
    case Mode::Fill: return L"Fill";
    case Mode::Actual: return L"100%";
    case Mode::Double: return L"200%";
    case Mode::Integer: return L"Pixel-perfect";
    }
    return L"Fit";
}

struct Layout {
    int srcX = 0, srcY = 0, srcW = 0, srcH = 0;
    int dstX = 0, dstY = 0, dstW = 0, dstH = 0;
    double scale = 1.0;
};

// Maps a frame onto an area of the given size. When the scaled picture is larger
// than the area it is centre-cropped, so src/dst always describe a visible region.
inline Layout compute(Mode mode, int frameW, int frameH, int areaW, int areaH) {
    Layout out;
    if (frameW <= 0 || frameH <= 0 || areaW <= 0 || areaH <= 0) return out;
    const double fit = std::min(double(areaW) / frameW, double(areaH) / frameH);
    const double cover = std::max(double(areaW) / frameW, double(areaH) / frameH);
    double scale = fit;
    switch (mode) {
    case Mode::Fit: scale = fit; break;
    case Mode::Fill: scale = cover; break;
    case Mode::Actual: scale = 1.0; break;
    case Mode::Double: scale = 2.0; break;
    case Mode::Integer: scale = fit >= 1.0 ? std::floor(fit) : fit; break;
    }
    out.scale = scale;
    const int scaledW = std::max(1, int(std::lround(frameW * scale)));
    const int scaledH = std::max(1, int(std::lround(frameH * scale)));
    out.dstW = std::min(scaledW, areaW);
    out.dstH = std::min(scaledH, areaH);
    out.dstX = (areaW - out.dstW) / 2;
    out.dstY = (areaH - out.dstH) / 2;
    out.srcW = scaledW <= areaW ? frameW : std::max(1, std::min(frameW, int(std::lround(out.dstW / scale))));
    out.srcH = scaledH <= areaH ? frameH : std::max(1, std::min(frameH, int(std::lround(out.dstH / scale))));
    out.srcX = (frameW - out.srcW) / 2;
    out.srcY = (frameH - out.srcH) / 2;
    return out;
}

}
