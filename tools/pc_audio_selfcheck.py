#!/usr/bin/env python3
"""PC self-check for inject headroom / ceiling (no iOS device)."""
from __future__ import annotations

import math
import sys


def peak_ceiling(samples: list[float], lim: float = 13000.0, knee: float = 9000.0) -> list[float]:
    out = []
    for x in samples:
        ax = abs(x)
        if ax <= knee:
            out.append(x)
            continue
        if ax >= lim:
            y = lim
        else:
            t = (ax - knee) / (lim - knee)
            y = knee + (lim - knee) * (t * (2.0 - t))
        out.append(-y if x < 0 else y)
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
    # Hot sine that would clip at full scale
    n = 48000
    hot = [math.sin(2 * math.pi * 440 * i / n) * 32000 for i in range(n)]
    capped = peak_ceiling(hot)
    pk = max(abs(v) for v in capped)
    assert pk <= 13000.5, f"ceiling fail pk={pk}"
    # Float write clamp mirror
    floats = [max(-0.40, min(0.40, v / 32768.0)) for v in capped]
    fpk = max(abs(v) for v in floats)
    assert fpk <= 0.401, f"float clamp fail {fpk}"
    # Resample 48k->44.1k should not explode
    r = catmull_resample(capped, 48000, 44100)
    rpk = max(abs(v) for v in r)
    assert rpk < 20000, f"resample explode {rpk}"
    print(f"PASS ceiling_pk={pk:.1f} float_pk={fpk:.3f} resample_pk={rpk:.1f} out_n={len(r)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
