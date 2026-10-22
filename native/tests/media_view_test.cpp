// SPDX-License-Identifier: GPL-3.0-or-later
#include <cstdio>
#include "../media_view.h"
using namespace mmview;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); ++failures; } } while (0)

int main() {
    // Phone 1170x2532 in a 600x800 area.
    auto fit = compute(Mode::Fit, 1170, 2532, 600, 800);
    CHECK(fit.dstH == 800 && fit.dstW < 600 && fit.srcW == 1170 && fit.srcH == 2532);
    CHECK(fit.dstX == (600 - fit.dstW) / 2 && fit.dstY == 0);

    auto fill = compute(Mode::Fill, 1170, 2532, 600, 800);
    CHECK(fill.dstW == 600 && fill.dstH == 800 && fill.srcW == 1170 && fill.srcH < 2532);
    CHECK(fill.srcY == (2532 - fill.srcH) / 2);

    auto actual = compute(Mode::Actual, 1170, 2532, 600, 800);
    CHECK(actual.dstW == 600 && actual.dstH == 800 && actual.srcW == 600 && actual.srcH == 800);
    CHECK(actual.srcX == 285 && actual.srcY == 866);

    auto small = compute(Mode::Actual, 300, 400, 600, 800);
    CHECK(small.dstW == 300 && small.dstX == 150 && small.dstY == 200 && small.srcW == 300);

    auto dbl = compute(Mode::Double, 300, 400, 700, 900);
    CHECK(dbl.dstW == 600 && dbl.dstH == 800 && dbl.srcW == 300);

    auto integer = compute(Mode::Integer, 300, 400, 700, 900);
    CHECK(integer.scale == 2.0 && integer.dstW == 600);
    auto integerSmall = compute(Mode::Integer, 1170, 2532, 600, 800);
    CHECK(integerSmall.scale < 1.0 && integerSmall.dstH == 800);

    auto empty = compute(Mode::Fit, 0, 10, 10, 10);
    CHECK(empty.dstW == 0);
    auto tiny = compute(Mode::Fit, 100, 100, 1, 1);
    CHECK(tiny.dstW == 1 && tiny.dstH == 1);

    if (!failures) std::printf("ok\n");
    return failures ? 1 : 0;
}
