#!/bin/bash
set -euo pipefail
ARCH="${1:-aarch64}"
SRC="${SOURCE_DIR:-.}"
echo "=== wiliwili ${ARCH} build (arch=${ARCH}, src=${SRC}) ==="
cd "$SRC"

# 0) 切换到指定源码版本（无条件；默认分支已是目标时是 no-op，不报错）
REF="${WILIWILI_REF:-master}"
git -C "$SRC" checkout "$REF"
git -C "$SRC" submodule update --init --recursive

# 1) 安装构建依赖（镜像已含 webp/gl/egl/openssl/zlib，仅需补 mpv + x11 dev）
apt-get update
apt-get install -y --no-install-recommends \
  libmpv-dev libwebp-dev libssl-dev zlib1g-dev \
  libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libcurl4-openssl-dev pkg-config
# patchelf 作为双保险（可选，缺失不致命）
apt-get install -y --no-install-recommends patchelf || true

# === Optional: build mpv 0.36 + ffmpeg 6 from source ===
# 仅当 BUILD_MPV_FROM_SRC 非空且为真（非空、非 0、非 false）时，才从源码构建
# ffmpeg 6.x + mpv 0.36.0 并安装到 /usr/local，覆盖 apt 提供的 libmpv-dev 0.32。
# 默认（BUILD_MPV_FROM_SRC 为空）完全跳过此块，沿用 apt 的 libmpv-dev 0.32 + ffmpeg 4.2，
# 行为与改动前字节级一致（默认 CI 路径不受影响）。
BUILD_MPV_FROM_SRC="${BUILD_MPV_FROM_SRC:-}"
_is_truthy() {
  case "${1,,}" in
    ''|0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}
if _is_truthy "$BUILD_MPV_FROM_SRC"; then
  echo "=== [optional] BUILD_MPV_FROM_SRC=${BUILD_MPV_FROM_SRC}: 从源码构建 ffmpeg 6 + mpv 0.36 ==="

  # 0) 安装源码构建所需工具（镜像通常已含 gcc 9.4；补缺即可，缺失不致命）
  apt-get install -y --no-install-recommends \
    python3 python3-pip meson ninja-build pkg-config git ca-certificates \
    libplacebo-dev libass-dev libsdl2-dev || true
  # 编解码必需/可选的外部库（缺失则 ffmpeg 回退到最简配置）
  apt-get install -y --no-install-recommends libx264-dev libx265-dev || true

  WORK="$(mktemp -d)"
  FFMPEG_TAG="${FFMPEG_TAG:-n6.1}"
  MPV_TAG="${MPV_TAG:-v0.36.0}"

  # 1) 构建并安装 ffmpeg 6.x（固定 tag，可复现；优先启用 x264/x265，失败则回退最简）
  echo "=== [optional] 克隆 ffmpeg ${FFMPEG_TAG} ==="
  git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$WORK/ffmpeg"
  pushd "$WORK/ffmpeg" >/dev/null
    if ! ./configure --prefix=/usr/local --enable-shared --enable-pic \
         --enable-gpl --enable-libx264 --enable-libx265 \
         --disable-doc --disable-programs 2>/dev/null; then
      echo "WARN: ffmpeg 带 x264/x265 的 configure 失败，回退到最简 --enable-shared 配置"
      ./configure --prefix=/usr/local --enable-shared --enable-pic \
        --disable-doc --disable-programs \
        || { echo "ERROR: ffmpeg configure 失败，请检查构建依赖。" >&2; exit 1; }
    fi
    make -j"$(nproc)" \
      || { echo "ERROR: ffmpeg 编译失败。" >&2; exit 1; }
    make install \
      || { echo "ERROR: ffmpeg 安装失败。" >&2; exit 1; }
  popd >/dev/null
  ldconfig

  # 2) 构建并安装 mpv 0.36（依赖上一步安装的 ffmpeg；通过 PKG_CONFIG_PATH 发现）
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  echo "=== [optional] 克隆 mpv ${MPV_TAG} ==="
  git clone --depth 1 --branch "$MPV_TAG" https://github.com/mpv-player/mpv.git "$WORK/mpv"
  pushd "$WORK/mpv" >/dev/null
    meson setup build \
      --prefix=/usr/local \
      -Dbuildtype=release \
      -Ddefault_library=shared \
      -Dlibmpv=enabled \
      -Dlibmpv-shared=true \
      -Dgpl=true \
      -Dlua=disabled \
      -Djavascript=disabled \
      -Diconv=disabled \
      || { echo "ERROR: mpv meson setup 失败，请检查 libass/libplacebo 等依赖。" >&2; exit 1; }
    meson compile -C build -j"$(nproc)" \
      || { echo "ERROR: mpv 编译失败。" >&2; exit 1; }
    meson install -C build \
      || { echo "ERROR: mpv 安装失败。" >&2; exit 1; }
  popd >/dev/null
  ldconfig

  # 3) 移除 apt 安装的旧 libmpv-dev（避免 cmake 误链 0.32 头文件/库）；失败不致命
  apt-get remove -y --purge libmpv-dev libmpv2 2>/dev/null || true

  # 4) 确保后续 cmake 优先使用 /usr/local 中的 mpv 0.36
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

  # 5) 校验：源码构建的 libmpv 必须可被 ldconfig 发现，否则后续打包会失败
  if ! ldconfig -p 2>/dev/null | awk '$1 ~ /^libmpv\.so\./ {found=1} END{exit !found}'; then
    echo "ERROR: 源码构建后 ldconfig 未找到 libmpv.so.*，构建环境异常。" >&2
    exit 1
  fi

  rm -rf "$WORK"
  echo "=== [optional] mpv 0.36 + ffmpeg 6 源码构建完成（libmpv 已安装至 /usr/local）==="
else
  echo "=== [optional] BUILD_MPV_FROM_SRC 未设置/为假，跳过源码构建（沿用 apt libmpv-dev 0.32）==="
fi

# 2) 配置 + 编译
cmake -B build -DPLATFORM_DESKTOP=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --target wiliwili -j"$(nproc)"

# 3) 收集产物
mkdir -p dist/libs
cp build/wiliwili dist/wiliwili
strip dist/wiliwili || true
cp -r resources dist/resources

# 4) 递归收集 wiliwili 及其全部传递依赖（ROBUST）
DEST="dist/libs"
mkdir -p "$DEST"

is_core() {
  case "$(basename "$1")" in
    libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libgcc_s.so*|\
    libstdc++.so*|ld-linux-*|linux-vdso.so*|libutil.so*|libresolv.so*|\
    libBrokenLocale.so*|libmvec.so*|libnsl.so*|libpcprofile.so*) return 0 ;;
    *) return 1 ;;
  esac
}

stage_lib() {
  local src="$1"
  local soname; soname="$(basename "$src")"
  is_core "$soname" && return 0
  if [ ! -e "$DEST/$soname" ]; then
    cp -L "$src" "$DEST/$soname" 2>/dev/null || { echo "WARN: 无法拷贝 $src" >&2; return 1; }
  fi
  if [ "${SEEN[$soname]:-0}" != "1" ]; then
    SEEN[$soname]=1
    QUEUE+=("$DEST/$soname")
  fi
  return 0
}

scan_deps() {
  local obj="$1"
  local soname target
  while IFS= read -r line; do
    soname="$(printf '%s' "$line" | awk '{print $1}')"
    target="$(printf '%s' "$line" | awk '{print $3}')"
    [ -z "$soname" ] && continue
    [ "$soname" = "linux-vdso.so.1" ] && continue
    is_core "$soname" && continue
    if [ -z "$target" ] || [ "$target" = "not" ]; then
      target="$(command -v ldconfig >/dev/null && ldconfig -p 2>/dev/null | awk -v s="$soname" '$1==s {print $NF; exit}')"
      [ -z "$target" ] && for d in /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu /usr/lib /lib; do
        [ -e "$d/$soname" ] && { target="$d/$soname"; break; }
      done
    fi
    [ -z "$target" ] && { echo "WARN: 无法定位 $soname" >&2; continue; }
    stage_lib "$target"
  done < <(ldd "$obj" 2>/dev/null)
}

declare -A SEEN=()
QUEUE=()
scan_deps "build/wiliwili"

# 显式兜底：确保 libmpv（版本无关，匹配 libmpv.so.*）一定被打包（即使 ldd 偶发漏报）
has_mpv=0
for f in "$DEST"/libmpv.so.*; do
  [ -e "$f" ] && { has_mpv=1; break; }
done
if [ "$has_mpv" -eq 0 ]; then
  # 版本无关定位：优先 ldconfig -p，再回退目录扫描，匹配 libmpv.so.*
  mpv="$(command -v ldconfig >/dev/null && ldconfig -p 2>/dev/null | awk '$1 ~ /^libmpv\.so\./ {print $NF; exit}')"
  [ -z "$mpv" ] && for d in /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu /usr/lib /lib; do
    f="$(ls "$d"/libmpv.so.* 2>/dev/null | head -n1)"
    [ -n "$f" ] && { mpv="$f"; break; }
  done
  if [ -n "$mpv" ]; then
    stage_lib "$mpv"
  else
    echo "ERROR: 构建机上找不到 libmpv，无法打包运行时依赖。" >&2
    exit 1
  fi
fi

while [ ${#QUEUE[@]} -gt 0 ]; do
  cur="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
  scan_deps "$cur"
done

if command -v patchelf >/dev/null 2>&1; then
  patchelf --set-rpath '$ORIGIN/libs' dist/wiliwili 2>/dev/null \
    && echo "=== patchelf: 已为 dist/wiliwili 设置 rpath=\$ORIGIN/libs ===" \
    || echo "WARN: patchelf 设置 rpath 失败（不影响 LD_LIBRARY_PATH 方案）"
else
  echo "=== 未安装 patchelf，依赖 wiliwili.sh 的 LD_LIBRARY_PATH ==="
fi

echo "=== 校验：确认所有非核心 NEEDED 库都已打包进 $DEST ==="
MISSING=()
while IFS= read -r soname; do
  [ -z "$soname" ] && continue
  [ "$soname" = "linux-vdso.so.1" ] && continue
  is_core "$soname" && continue
  [ -e "$DEST/$soname" ] && continue
  MISSING+=("$soname")
done < <(ldd dist/wiliwili 2>/dev/null | awk '{print $1}')

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: 以下非核心依赖未被打包，拒绝产出残包：" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  exit 1
fi
echo "=== OK: $DEST 已包含 wiliwili 所需的全部非核心运行时库 ==="

tar -czf "/workspace/wiliwili-linux-${ARCH}.tar.gz" -C dist .
echo "=== done: /workspace/wiliwili-linux-${ARCH}.tar.gz ==="
