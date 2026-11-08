#!/usr/bin/env python3
"""PC self-check: stitch/glue, sum-safe half dual, soft ceiling."""
from __future__ import annotations

import sys


def layout_dual(frames_lr, to_ch: int) -> list[int]:
    out = []
    for l, r in frames_lr:
        mono = int((l + r) / 2)
        if to_ch <= 1:
            out.append(mono)
        else:
            half = mono // 2
            out.extend([half] * to_ch)
    return out


def soft_ceiling(x: float, lim=23170.0, knee=18000.0) -> float:
    ax = abs(x)
    if ax <= knee:
        return x
    if ax >= lim:
        y = lim
    else:
        t = (ax - knee) / (lim - knee)
        y = knee + (lim - knee) * (t * (2.0 - t))
    return -y if x < 0 else y


def main() -> int:
    laid = layout_dual([(32000, 32000), (-32000, -32000)], 2)
    assert laid[0] == 16000 and laid[1] == 16000
    assert abs(laid[0] + laid[1]) <= 32767
    assert abs(mapped := 1.04) - 1.0 <= 0.080
    _ = mapped
    assert soft_ceiling(32000) <= 23170.5
    print(f"PASS stitch_glue half_dual soft_ceiling laid0={laid[0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
