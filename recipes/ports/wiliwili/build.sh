#!/bin/bash
set -euo pipefail
ARCH="${1:-aarch64}"
echo "=== wiliwili aarch64 build (arch=${ARCH}) ==="

# 1) 安装构建依赖（镜像已含 webp/gl/egl/openssl/zlib，仅需补 mpv + x11 dev）
apt-get update
apt-get install -y --no-install-recommends \
  libmpv-dev libwebp-dev libssl-dev zlib1g-dev \
  libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libcurl4-openssl-dev pkg-config

# 2) 配置 + 编译
cmake -B build -DPLATFORM_DESKTOP=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --target wiliwili -j"$(nproc)"

# 3) 收集产物
mkdir -p dist/libs.${ARCH}
cp build/wiliwili dist/wiliwili
strip dist/wiliwili || true
cp -r resources dist/resources

# 4) 打包 wiliwili 依赖的 .so（排除 glibc 核心库），使 port 自带运行时
DEST="dist/libs.${ARCH}"
while read -r _ _ lib _; do
  [ -z "$lib" ] && continue
  case "$lib" in
    /lib/*|/usr/lib/*) ;;
    *) continue ;;
  esac
  base="$(basename "$lib")"
  case "$base" in
    libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libgcc_s.so*|libstdc++.so*|ld-linux-*) continue ;;
  esac
  cp -L -n "$lib" "$DEST/" 2>/dev/null || true
done < <(ldd build/wiliwili)

# 5) 打包
tar -czf "/workspace/wiliwili-linux-${ARCH}.tar.gz" -C dist .
echo "=== done: /workspace/wiliwili-linux-${ARCH}.tar.gz ==="
