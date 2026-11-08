#!/usr/bin/env python3
"""PC self-check for Douyin mic inject layout (no iOS device).

Regression covered:
- Stereo AU must not emit L=R full-scale (Douyin often sums L+R w/o /2 → 0dBFS rail).
- Mono-on-left layout: L=downmix, R=0 so sum ≈ source level.
- 1:1 path when rates match (no per-callback SRC).
"""
from __future__ import annotations

import math
import sys


def layout_mono_on_left(frames_lr: list[tuple[int, int]], to_ch: int) -> list[int]:
    out: list[int] = []
    for l, r in frames_lr:
        mono = int((l + r) / 2)
        if to_ch <= 1:
            out.append(mono)
        else:
            out.append(mono)
            for _ in range(1, to_ch):
                out.append(0)
    return out


def catmull_resample(x: list[float], src: int, dst: int) -> list[float]:
    if src == dst or not x:
        return list(x)
    n = len(x)
    out_n = max(1, int(round(n * dst / src)))
    last = n - 1

    def at(i: int) -> float:
        return x[min(max(i, 0), last)]

    out = []
    for i in range(out_n):
        pos = i * src / dst
        i1 = int(math.floor(pos))
        t = pos - i1
        y0, y1, y2, y3 = at(i1 - 1), at(i1), at(i1 + 1), at(i1 + 2)
        a0 = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
        a1 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
        a2 = -0.5 * y0 + 0.5 * y2
        a3 = y1
        out.append(((a0 * t + a1) * t + a2) * t + a3)
    return out


def main() -> int:
    # Hot correlated stereo (OBS desktop often L≈R near full scale)
    hot = [(32000, 32000), (30000, 31000), (-32000, -32000)]
    laid = layout_mono_on_left(hot, 2)
    assert laid == [32000, 0, 30500, 0, -32000, 0], laid

    # Douyin-style naive sum must stay within int16 full scale
    for i in range(0, len(laid), 2):
        summed = laid[i] + laid[i + 1]
        assert abs(summed) <= 32767, f"sum clip {summed}"

    # Old bug: L=R=full → sum overflows
    old_sum = 32000 + 32000
    assert abs(old_sum) > 32767

    # Rate-matched path keeps length (no SRC)
    n = 4410
    x = [math.sin(2 * math.pi * 440 * i / 44100) * 16000 for i in range(n)]
    same = catmull_resample(x, 44100, 44100)
    assert len(same) == n

    r = catmull_resample(x, 48000, 44100)
    assert abs(len(r) - int(round(n * 44100 / 48000))) <= 1
    assert max(abs(v) for v in r) < 25000

    print(
        "PASS mono_on_left sum_safe "
        f"laid0={laid[0]} laid1={laid[1]} resample_n={len(r)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
