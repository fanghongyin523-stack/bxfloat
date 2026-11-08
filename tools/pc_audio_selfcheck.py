#!/usr/bin/env python3
"""PC self-check for Douyin mic inject (no iOS device).

Covers failclosed silence pad, stereo L=R half layout (sum-safe),
and mild -1.5dBFS ceiling.
"""
from __future__ import annotations

import math
import sys


def layout_half_dual(frames_lr: list[tuple[int, int]], to_ch: int) -> list[int]:
    out: list[int] = []
    for l, r in frames_lr:
        mono = int((l + r) / 2)
        if to_ch <= 1:
            out.append(mono)
        else:
            half = mono // 2
            out.append(half)
            for _ in range(1, to_ch):
                out.append(half)
    return out


def peak_ceiling(samples: list[int], lim: int = 27500) -> list[int]:
    out = []
    for x in samples:
        if x > lim:
            out.append(lim)
        elif x < -lim:
            out.append(-lim)
        else:
            out.append(x)
    return out


def silence_pad(have: int, need: int) -> list[int]:
    """Underrun tail must be zeros (failclosed), never hold last sample."""
    assert have < need
    return [0] * (need - have)


def main() -> int:
    hot = [(32000, 32000), (30000, 31000), (-32000, -32000)]
    laid = layout_half_dual(hot, 2)
    assert laid == [16000, 16000, 15250, 15250, -16000, -16000], laid

    for i in range(0, len(laid), 2):
        summed = laid[i] + laid[i + 1]
        assert abs(summed) <= 32767, f"sum clip {summed}"

    # Old full L=R would overflow on naive sum
    assert abs(32000 + 32000) > 32767

    capped = peak_ceiling([32000, -32000, 1000])
    assert capped == [27500, -27500, 1000], capped

    pad = silence_pad(100, 128)
    assert pad == [0] * 28
    assert all(v == 0 for v in pad), "hold-pad forbidden"

    n = 4410
    x = [math.sin(2 * math.pi * 440 * i / 44100) * 16000 for i in range(n)]
    assert len(x) == n

    print(
        "PASS failclosed_silence half_dual_sum_safe "
        f"ceiling={max(abs(v) for v in capped)} laid0={laid[0]}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
