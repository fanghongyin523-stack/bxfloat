#!/bin/bash
# 下载 monsoir/FFmpeg-iOS 预编译包，整理成 Vendor/FFmpeg/{include,lib} 供注入 dylib 静态链接。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/BXFloatMVP/Vendor/FFmpeg"
VER="${FFMPEG_IOS_VER:-v1.0.2}"
BASE="https://github.com/monsoir/FFmpeg-iOS/releases/download/${VER}"
LIBS=(avutil avcodec avformat swscale swresample)

rm -rf "$OUT"
mkdir -p "$OUT/include" "$OUT/lib" "$OUT/_tmp"
cd "$OUT/_tmp"

for lib in "${LIBS[@]}"; do
  echo ">> fetch $lib"
  curl -fsSL -o "${lib}.zip" "${BASE}/${lib}.zip"
  rm -rf "${lib}_x"
  mkdir -p "${lib}_x"
  unzip -q "${lib}.zip" -d "${lib}_x"
  # 优先 ios-arm64 静态库
  AFILE="$(find "${lib}_x" -path '*ios-arm64*' -name '*.a' | head -n 1 || true)"
  if [[ -z "${AFILE}" ]]; then
    AFILE="$(find "${lib}_x" -name "lib${lib}.a" | head -n 1 || true)"
  fi
  if [[ -z "${AFILE}" ]]; then
    echo "ERROR: no static lib for $lib" >&2
    find "${lib}_x" -maxdepth 4 -type f | head -n 50 >&2
    exit 1
  fi
  cp -f "$AFILE" "$OUT/lib/lib${lib}.a"
  # headers
  HDIR="$(find "${lib}_x" -type d -name 'Headers' | head -n 1 || true)"
  if [[ -n "${HDIR}" ]]; then
    mkdir -p "$OUT/include/lib${lib}"
    # monsoir 可能是 Headers/libavcodec/*.h 或 Headers/*.h
    if [[ -d "${HDIR}/lib${lib}" ]]; then
      cp -R "${HDIR}/lib${lib}/." "$OUT/include/lib${lib}/"
    else
      cp -R "${HDIR}/." "$OUT/include/lib${lib}/" 2>/dev/null || cp -R "${HDIR}/." "$OUT/include/"
    fi
  fi
done

# 若头文件在 include/libavcodec 下已就位，再保证 libavutil 等能被 #include "libavutil/..." 找到
if [[ ! -d "$OUT/include/libavutil" ]]; then
  # 有的包把头直接铺在 Headers 根
  find "$OUT/_tmp" -type d -name 'libavutil' | head -n 1 | while read -r d; do
    mkdir -p "$OUT/include/libavutil"
    cp -R "$d/." "$OUT/include/libavutil/"
  done
fi

# 统一：若存在 include/avcodec 而无 libavcodec，做一层包装
for lib in "${LIBS[@]}"; do
  if [[ ! -d "$OUT/include/lib${lib}" ]]; then
    ALT="$(find "$OUT/_tmp" -type d -name "lib${lib}" | head -n 1 || true)"
    if [[ -n "$ALT" ]]; then
      mkdir -p "$OUT/include/lib${lib}"
      cp -R "$ALT/." "$OUT/include/lib${lib}/"
    fi
  fi
done

echo ">> FFmpeg vendor ready:"
ls -lh "$OUT/lib"
ls "$OUT/include" | head
test -f "$OUT/lib/libavformat.a"
test -f "$OUT/lib/libavcodec.a"
test -f "$OUT/lib/libavutil.a"
test -f "$OUT/lib/libswscale.a"
# 至少一个头
test -d "$OUT/include/libavformat" -o -f "$OUT/include/libavformat/avformat.h"

# 写标记给 xcode
cat > "$OUT/ffmpeg.xcconfig" <<EOF
BXFLOAT_FFMPEG_ROOT = \$(SRCROOT)/Vendor/FFmpeg
HEADER_SEARCH_PATHS = \$(inherited) \$(BXFLOAT_FFMPEG_ROOT)/include
LIBRARY_SEARCH_PATHS = \$(inherited) \$(BXFLOAT_FFMPEG_ROOT)/lib
OTHER_LDFLAGS = \$(inherited) -lavcodec -lavformat -lavutil -lswscale -lswresample -lbz2 -lz -liconv -lc++
GCC_PREPROCESSOR_DEFINITIONS = \$(inherited) BXFLOAT_HAS_FFMPEG=1
SWIFT_ACTIVE_COMPILATION_CONDITIONS = \$(inherited) BXFLOAT_FFMPEG
EOF

rm -rf "$OUT/_tmp"
echo "OK"
