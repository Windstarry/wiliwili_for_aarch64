#!/bin/bash
set -euo pipefail
ARCH="${1:-aarch64}"
SRC="${SOURCE_DIR:-.}"
echo "=== wiliwili ${ARCH} build (arch=${ARCH}, src=${SRC}) ==="
cd "$SRC"

# ---------------------------------------------------------------------------
# TrimUi TG5040 / PowerVR GE8300 交叉构建入口
#   - 默认 TARGET=rocknix：沿用下方原有 RockNIX (Mali-G31) 线性构建流程，逐字节不变。
#   - TARGET=tg5040：调用 build_tg5040（Allwinner A133P + PowerVR GE8300 路径）。
# 注意：build_tg5040 在 ubuntu-latest runner 直接运行（无 docker、无 /workspace 挂载），
# 其产物 tar 包以相对名 wiliwili-linux-${ARCH}.tar.gz 落到仓库根目录，供下方 Assemble 步骤解包。
# ---------------------------------------------------------------------------
RECIPE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# TrimUi TG5040 (Allwinner A133P + PowerVR GE8300) 交叉构建路径
# 背景：目标机 TinaLinux + PowerVR GE8300，厂商 SDL2 的 mali 视频后端与 PowerVR
# EGL/WSEGL 不兼容，运行期早期 SIGSEGV。本路径改用随仓库附的 SDL2-2.26.1.GE8300
# （PowerVR 适配），经官方 trimui SDK sysroot 交叉编译，产出不依赖厂商 mali SDL2 的 wiliwili。
# 构建机：ubuntu-latest (x86_64) —— Linaro 工具链为 x86-host 二进制，可在 x86 CI 直接运行。
# 参考：https://github.com/dragonflylee/trimui-port (Makefile.tg5040 / port.yaml)
# ---------------------------------------------------------------------------
build_tg5040() {
  local TRIMUI="/opt/trimui"
  local SYSROOT="$TRIMUI/sysroot"
  local PREFIX="$SYSROOT/usr"
  local TMPDIR; TMPDIR="$(mktemp -d)"
  local WILIWILI_SRC="$SRC"          # wiliwili 源码（由 build.yml clone 至 SOURCE_DIR）
  local REPO_ROOT; REPO_ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"

  echo "=== [tg5040] TrimUi TG5040 / PowerVR GE8300 交叉构建 ==="

  # 0) 安装交叉构建主机侧工具（Linaro 工具链自身从官方 release 下载）
  apt-get update
  apt-get install -y --no-install-recommends \
    meson ninja-build cmake pkg-config wget ca-certificates xz-utils \
    bzip2 patch python3

  # 1) 下载并解包官方 trimui SDK（工具链 + sysroot，含 PowerVR GE8300 头文件/库）
  #    https://github.com/trimui/toolchain_sdk_smartpro/releases/tag/20231018
  rm -rf "$TRIMUI"
  mkdir -p "$TRIMUI"
  wget -q "https://github.com/trimui/toolchain_sdk_smartpro/releases/download/20231018/aarch64-linux-gnu-7.5.0-linaro.tgz" -O "$TMPDIR/linaro.tgz"
  tar zxf "$TMPDIR/linaro.tgz" -C "$TRIMUI" --strip-components=1
  mv "$TRIMUI/aarch64-linux-gnu/libc" "$SYSROOT"
  wget -q "https://github.com/trimui/toolchain_sdk_smartpro/releases/download/20231018/SDK_usr_tg5040_a133p.tgz" -O "$TMPDIR/sdk.tgz"
  tar zxf "$TMPDIR/sdk.tgz" -C "$SYSROOT"

  # 2) 依赖源码（curl/libwebp/harfbuzz/fribidi/libass/libdrm/v4l-utils/ffmpeg/mpv）
  wget -qO- https://curl.se/download/curl-8.14.1.tar.xz | tar Jxf - -C "$TMPDIR"
  wget -qO- https://github.com/webmproject/libwebp/archive/v1.4.0.tar.gz | tar zxf - -C "$TMPDIR"
  wget -qO- https://github.com/harfbuzz/harfbuzz/releases/download/7.3.0/harfbuzz-7.3.0.tar.xz | tar Jxf - -C "$TMPDIR"
  wget -qO- https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz | tar Jxf - -C "$TMPDIR"
  wget -qO- https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.xz | tar Jxf - -C "$TMPDIR"
  wget -qO- https://dri.freedesktop.org/libdrm/libdrm-2.4.120.tar.xz | tar Jxf - -C "$TMPDIR"
  wget -qO- https://linuxtv.org/downloads/v4l-utils/v4l-utils-1.24.1.tar.bz2 | tar jxf - -C "$TMPDIR"
  wget -qO- https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz | tar Jxf - -C "$TMPDIR"
  wget -qO- https://github.com/mpv-player/mpv/archive/v0.36.0.tar.gz | tar zxf - -C "$TMPDIR"
  patch -d "$TMPDIR/ffmpeg-6.1.1" -Nbp1 -i "$RECIPE_DIR/patches/ffmpeg-v4l2-request.patch"
  patch -d "$TMPDIR/mpv-0.36.0" -Nbp1 -i "$RECIPE_DIR/patches/mpv-v4l2-request.patch"

  export PATH="$SYSROOT/bin:$TRIMUI/bin:$PATH"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export LD_LIBRARY_PATH="$PREFIX/lib"

  # 3) SDL2 — PowerVR GE8300 适配版（仓库随附 SDL2-2.26.1.GE8300.tgz）
  tar zxf "$RECIPE_DIR/SDL2-2.26.1.GE8300.tgz" -C "$TMPDIR"
  ( cd "$TMPDIR/SDL2-2.26.1" && \
    ./configure --host=aarch64-linux-gnu --prefix=/usr --with-sysroot="$SYSROOT" \
      --disable-video-wayland --disable-pulseaudio && \
    make -j"$(nproc)" && make DESTDIR="$SYSROOT" install )

  # 4) curl（静态）
  cmake -B "$TMPDIR/build/curl" -G Ninja -S "$TMPDIR/curl-8.14.1" \
    -DCMAKE_TOOLCHAIN_FILE="$RECIPE_DIR/trimui.cmake" \
    -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DCURL_USE_OPENSSL=ON \
    -DCURL_CA_BUNDLE=resources/cacert.pem -DHTTP_ONLY=ON \
    -DCURL_DISABLE_PROGRESS_METER=ON -DBUILD_CURL_EXE=OFF \
    -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF -DBUILD_LIBCURL_DOCS=OFF \
    -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
    -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBPSL=OFF
  cmake --build "$TMPDIR/build/curl"
  DESTDIR="$SYSROOT" cmake --install "$TMPDIR/build/curl"

  # 5) libwebp（静态）
  cmake -B "$TMPDIR/build/libwebp" -G Ninja -S "$TMPDIR/libwebp-1.4.0" \
    -DCMAKE_TOOLCHAIN_FILE="$RECIPE_DIR/trimui.cmake" \
    -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF \
    -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_LIBWEBPMUX=OFF
  cmake --build "$TMPDIR/build/libwebp"
  DESTDIR="$SYSROOT" cmake --install "$TMPDIR/build/libwebp"

  # 6) harfbuzz / fribidi / libass（字幕链）
  meson setup "$TMPDIR/build/harfbuzz" "$TMPDIR/harfbuzz-7.3.0" --cross-file="$RECIPE_DIR/trimui.ini" \
    -Dfreetype=enabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
    -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Ddoc_tests=false -Dutilities=disabled
  meson compile -C "$TMPDIR/build/harfbuzz"
  meson install -C "$TMPDIR/build/harfbuzz" --destdir="$SYSROOT"

  meson setup "$TMPDIR/build/fribidi" "$TMPDIR/fribidi-1.0.16" --cross-file="$RECIPE_DIR/trimui.ini" \
    -Dbin=false -Ddocs=false -Dtests=false
  meson compile -C "$TMPDIR/build/fribidi"
  meson install -C "$TMPDIR/build/fribidi" --destdir="$SYSROOT"

  meson setup "$TMPDIR/build/libass" "$TMPDIR/libass-0.17.4" --cross-file="$RECIPE_DIR/trimui.ini"
  meson compile -C "$TMPDIR/build/libass"
  meson install -C "$TMPDIR/build/libass" --destdir="$SYSROOT"

  # 7) libdrm（VPU 解码依赖，静态）
  meson setup "$TMPDIR/build/libdrm" "$TMPDIR/libdrm-2.4.120" --cross-file="$RECIPE_DIR/trimui.ini" \
    --default-library=static -Dcairo-tests=disabled -Dtests=false
  meson compile -C "$TMPDIR/build/libdrm"
  meson install -C "$TMPDIR/build/libdrm" --destdir="$SYSROOT"

  # 8) ffmpeg 6.1.1（静态 + VPU 硬件解码 v4l2_m2m/request）
  mkdir -p "$TMPDIR/build/ffmpeg"
  ( cd "$TMPDIR/build/ffmpeg" && \
    "$TMPDIR/ffmpeg-6.1.1/configure" --prefix=/usr --disable-shared --enable-static \
      --enable-cross-compile --cross-prefix=aarch64-linux-gnu- --pkg-config=pkg-config \
      --arch=aarch64 --cpu=cortex-a53 --target-os=linux --enable-pic --enable-neon \
      --extra-cflags="-I$TMPDIR/v4l-utils-1.24.1/include -I$RECIPE_DIR/include -I$PREFIX/include" \
      --extra-ldflags="-L$PREFIX/lib" --sysroot="$SYSROOT" \
      --disable-runtime-cpudetect --disable-programs --disable-debug --disable-avdevice \
      --enable-nonfree --enable-openssl --disable-doc --enable-zlib --enable-libass \
      --enable-libdrm --enable-libv4l2 --enable-v4l2_m2m --enable-libudev --enable-v4l2-request \
      --disable-protocols --enable-protocol=file,http,tcp,udp,hls,https,tls,httpproxy \
      --disable-filters --enable-filter=hflip,vflip,transpose \
      --disable-muxers --disable-encoders --enable-encoder=png )
  make -C "$TMPDIR/build/ffmpeg" -j"$(nproc)"
  make -C "$TMPDIR/build/ffmpeg" DESTDIR="$SYSROOT" install

  # 9) mpv 0.36（静态 libmpv + VPU）
  meson setup "$TMPDIR/build/mpv" "$TMPDIR/mpv-0.36.0" --cross-file="$RECIPE_DIR/trimui.ini" \
    --default-library=static -Dlibmpv=true -Dcplayer=false -Dtests=false \
    -Dlua=disabled -Dlibarchive=disabled -Dsdl2=enabled -Dv4l2request=enabled
  meson compile -C "$TMPDIR/build/mpv"
  meson install -C "$TMPDIR/build/mpv" --destdir="$SYSROOT"

  # 10) wiliwili
  cmake -B "$TMPDIR/build/wiliwili" -G Ninja -S "$WILIWILI_SRC" \
    -DCMAKE_TOOLCHAIN_FILE="$RECIPE_DIR/trimui.cmake" \
    -DCMAKE_MODULE_PATH="$RECIPE_DIR/cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPLATFORM_DESKTOP=ON \
    -DCMAKE_CXX_FLAGS="-DTRIMUI" \
    -DUSE_SYSTEM_CURL=ON \
    -DUSE_SYSTEM_SDL2=ON \
    -DMPV_NO_FB=ON \
    -DUSE_SDL2=ON \
    -DUSE_GLES3=ON
  cmake --build "$TMPDIR/build/wiliwili"

  # 11) 收集产物 + 打包运行时依赖
  mkdir -p dist/libs
  cp "$TMPDIR/build/wiliwili/wiliwili" dist/wiliwili
  strip dist/wiliwili || true
  cp -r "$WILIWILI_SRC/resources" dist/resources

  # 仅打包随附的 libSDL2（GE8300 版，遮蔽厂商 mali SDL2）；PowerVR EGL/GLES 交还设备 DDK
  is_core_tg5040() {
    case "$(basename "$1")" in
      libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libgcc_s.so*|\
      libstdc++.so*|ld-linux-*|linux-vdso.so*|libutil.so*|libresolv.so*|\
      libBrokenLocale.so*|libmvec.so*|libnsl.so*|libpcprofile.so*|\
      libEGL.so*|libGLESv2.so*|libGLESv1_CM.so*|libgbm.so*|\
      libsrv_um.so*|libpvrNULL_WSEGL.so*|libPVR*.so*|libIMG*.so*|\
      libasound.so*|libz.so*|libexpat.so*|libfreetype.so*|\
      libglib-2.0.so*|libgobject-2.0.so*|libgmodule-2.0.so*|\
      libpng16.so*|libjpeg.so*|libharfbuzz.so*|libfribidi.so*|\
      libass.so*|libfontconfig.so*) return 0 ;;
      *) return 1 ;;
    esac
  }
  local DEST="dist/libs"
  stage_lib_tg5040() {
    local src="$1" soname; soname="$(basename "$src")"
    is_core_tg5040 "$soname" && return 0
    [ -e "$DEST/$soname" ] && return 0
    cp -L "$src" "$DEST/$soname" 2>/dev/null || { echo "WARN: 无法拷贝 $src" >&2; return 1; }
    return 0
  }
  scan_deps_tg5040() {
    local obj="$1" soname target
    while IFS= read -r line; do
      soname="$(printf '%s' "$line" | awk '{print $1}')"
      target="$(printf '%s' "$line" | awk '{print $3}')"
      [ -z "$soname" ] && continue
      [ "$soname" = "linux-vdso.so.1" ] && continue
      is_core_tg5040 "$soname" && continue
      [ -z "$target" ] && target="$(ldconfig -p 2>/dev/null | awk -v s="$soname" '$1==s {print $NF; exit}')"
      [ -z "$target" ] && for d in "$SYSROOT/usr/lib" "$SYSROOT/lib"; do
        [ -e "$d/$soname" ] && { target="$d/$soname"; break; }
      done
      [ -z "$target" ] && { echo "WARN: 无法定位 $soname" >&2; continue; }
      stage_lib_tg5040 "$target"
    done < <(ldd "$obj" 2>/dev/null)
  }
  stage_lib_tg5040 "$SYSROOT/usr/lib/libSDL2-2.0.so.0"
  scan_deps_tg5040 "dist/wiliwili"
  scan_deps_tg5040 "$DEST/libSDL2-2.0.so.0"

  cd "$REPO_ROOT"
  tar -czf "wiliwili-linux-${ARCH}.tar.gz" -C "$SRC/dist" .
  echo "=== done: wiliwili-linux-${ARCH}.tar.gz ==="
}

# === TARGET 路由分发 ===
TARGET="${TARGET:-rocknix}"
if [ "$TARGET" = "tg5040" ]; then
  build_tg5040
  exit 0
fi

# 修复容器挂载导致的 git "dubious ownership"（宿主 uid ≠ 容器内 git 用户 uid）
# 主仓库及可能的 submodule 工作树均由宿主 runner uid 拥有，挂载进容器后
# 容器内 git 用户（多为 root）uid 与之不同，首次 git 操作即报此错。
# CI 为一次性构建容器，使用通配接受所有目录，避免主仓库或 submodule 各自再报。
git config --global --add safe.directory '*'

# 0) 切换到指定源码版本（无条件；默认分支已是目标时是 no-op，不报错）
REF="${WILIWILI_REF:-master}"
git -C "$SRC" checkout "$REF"
git -C "$SRC" submodule update --init --recursive

# 1) 安装构建依赖（镜像已含 webp/gl/egl/openssl/zlib，仅需补 mpv + x11 + sdl2 dev）
apt-get update
apt-get install -y --no-install-recommends \
  libmpv-dev libwebp-dev libssl-dev zlib1g-dev \
  libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libcurl4-openssl-dev pkg-config \
  libsdl2-dev
# libsdl2-dev: SDL2 窗口后端必需。本机 Mali-G31 仅 GLES-only，GLFW 默认请求
#   桌面 OpenGL 上下文 -> 建窗口失败（glfw: Failed to create window，进程 abort）；
#   改用 -DUSE_SDL2=ON 后端后，SDL2 在 Mali 上经 EGL→系统 Mali libEGL/libgbm 正常
#   出图（同实机样本 wiliwili160 的 SDL2 后端实证，GL: Mali-G31 / ES 3.2）。
# patchelf 作为双保险（可选，缺失不致命）
apt-get install -y --no-install-recommends patchelf || true

# === Optional: build mpv 0.36 + ffmpeg 6 from source ===
# 仅当 BUILD_MPV_FROM_SRC 非空且为真（非空、非 0、非 false）时，才从源码构建
# ffmpeg 6.x + mpv 0.36.0 并安装到 /usr/local，覆盖 apt 提供的 libmpv-dev 0.32。
# 默认（BUILD_MPV_FROM_SRC 为空）完全跳过此块，沿用 apt 的 libmpv-dev 0.32 + ffmpeg 4.2，
# 行为与改动前字节级一致（默认 CI 路径不受影响）。
# 开启后 ffmpeg 配置见下方 --enable-* 完整列表（含用户实机验证参数 + 本仓库必需的 --enable-pic /
# --disable-doc --disable-programs），mpv 仍按 meson 段构建；二者均安装至 /usr/local 隔离。
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
    libfreetype6-dev libopenjp2-7-dev libmp3lame-dev libvorbis-dev libvpx-dev \
    libplacebo-dev libass-dev libsdl2-dev \
    libegl-dev libgles2-mesa-dev || true
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
         --enable-gpl --enable-nonfree \
         --enable-libfreetype --enable-libopenjpeg \
         --enable-libmp3lame --enable-libvorbis --enable-libvpx \
         --enable-libx264 --enable-libx265 \
         --enable-postproc --enable-small --enable-openssl --enable-pthreads --enable-zlib \
         --disable-opengl \
         --disable-doc --disable-programs 2>/dev/null; then
      echo "WARN: ffmpeg 完整 configure 失败，回退到最简 --enable-shared 配置"
      ./configure --prefix=/usr/local --enable-shared --enable-pic \
        --disable-opengl \
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

  # 确保 meson >= 0.62（镜像自带 0.53.2 过旧，mpv 0.36 的 meson.build 要求 >= 0.62.0；且需 <1.0 以兼容 mpv 0.36 的 boolean libmpv 选项）
  if ! command -v meson >/dev/null 2>&1 || \
     [ "$(printf '%s\n%s\n' "$(meson --version 2>/dev/null)" "0.62.0" | sort -V | head -n1)" != "0.62.0" ]; then
    echo "=== [optional] 升级 meson/ninja 到 >=0.62（镜像自带过旧）==="
    pip3 install --user --upgrade "meson>=0.63,<1.0" ninja 2>/dev/null \
      || python3 -m pip install --user --upgrade "meson>=0.63,<1.0" ninja 2>/dev/null \
      || pip3 install --upgrade "meson>=0.63,<1.0" ninja
    export PATH="$(python3 -m site --user-base)/bin:$PATH"
    if ! command -v meson >/dev/null 2>&1 || \
       [ "$(printf '%s\n%s\n' "$(meson --version 2>/dev/null)" "0.62.0" | sort -V | head -n1)" != "0.62.0" ]; then
      echo "ERROR: meson 升级失败（可能缺网/缺 pip），mpv 0.36 需 >=0.62.0，当前仍 $(meson --version 2>/dev/null || echo 缺失)。" >&2
      exit 1
    fi
  fi

  echo "=== [optional] 克隆 mpv ${MPV_TAG} ==="
  git clone --depth 1 --branch "$MPV_TAG" https://github.com/mpv-player/mpv.git "$WORK/mpv"
  pushd "$WORK/mpv" >/dev/null
    # 纯系统 GL 路线（修正）：mpv 必须以 GL 渲染后端构建，wiliwili 才能经 libmpv 渲染 API
    #（mpv_render_context_create + MPV_RENDER_PARAM_OPENGL_INIT_PARAMS）把自身 GLES 上下文
    #（borealis/SDL2 经系统 Mali EGL 创建）交给 mpv 做解码+着色器渲染。
    # - gl=enabled + plain-gl=enabled：启用 mpv GPU 渲染器（vo=gpu）与 libmpv 渲染 API；plain-gl
    #   不拉桌面 libGL（仅启用渲染器特性），避免 NEEDED 桌面 libGL.so.1/libGLX.so/libGLdispatch.so。
    #   gl=disabled 会令 mpv_render_context_create 失败并抛 std::logic_error("failed to initialize
    #   mpv GL context") → abort（即退出设置时崩溃）。
    # - 刻意 egl=disabled：不启用 mpv 自带 EGL 上下文后端。wiliwili 经 libmpv 渲染 API 把自身
    #   GLES 上下文交给 mpv 渲染，mpv 用宿主机提供的上下文即可；启用 egl 会让 mpv 硬链 libEGL
    #   → 传递依赖 libGLdispatch.so.0，破坏纯系统 GL 路线并在 Mali 上运行期加载失败。
    # - x11=disabled / wayland=disabled / drm=disabled：关闭 GLX/桌面 GL 上下文后端（避免 libGL
    #   硬链），libmpv 只经 EGL 链系统 Mali libEGL，纯系统 GL 路线不变，is_core 末尾校验仍应通过。
    # - caca=disabled：去 libcaca/ncurses 依赖。
    # MPV_VIDEO_BACKEND 开关：默认 gl（启用 mpv GPU 渲染器 vo=gpu + libmpv 渲染 API，
    # 经 plain-gl 仅开渲染器特性、不拉桌面 libGL）；设 legacy 退回旧 gl=disabled（会崩，勿默认）。
    # 注意：刻意【不】启用 mpv 自带 egl 上下文后端（egl=disabled）——wiliwili 经渲染 API 把自身
    # GLES 上下文交给 mpv，mpv 用宿主机提供的上下文即可，无需 mpv 自建 EGL；启用 egl 会让 mpv
    # 硬链 libEGL→传递依赖 libGLdispatch.so.0，既破坏纯系统 GL 路线、又会在 Mali（无 GLVND
    # libGLdispatch）上运行期加载失败。故 egl=disabled 是正确且安全的选择。
    MPV_VIDEO_BACKEND="${MPV_VIDEO_BACKEND:-gl}"
    if [ "$MPV_VIDEO_BACKEND" = "gl" ]; then
      MPV_GL_OPTS="-Dgl=enabled -Dplain-gl=enabled -Dx11=disabled -Dwayland=disabled -Dcaca=disabled -Ddrm=disabled"
    else
      MPV_GL_OPTS="-Dgl=disabled -Dcaca=disabled"
    fi
    meson setup build \
      --prefix=/usr/local \
      -Dbuildtype=release \
      -Ddefault_library=shared \
      -Dlibmpv=true \
      -Dgpl=true \
      -Dlua=disabled \
      -Djavascript=disabled \
      -Diconv=disabled \
      $MPV_GL_OPTS \
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

# === 防御性补丁：修复 fmt v12 对 null const char* 抛 format_error 崩溃 ===
# 根因：borealis 的 SDLVideoContext 构造时通过 Logger::info 打印 GL 信息：
#   Logger::info("sdl: GL Vendor: {}",   (const char*)glGetString(GL_VENDOR));
#   Logger::info("sdl: GL Renderer: {}", (const char*)glGetString(GL_RENDERER));
#   Logger::info("sdl: GL Version: {}",  (const char*)glGetString(GL_VERSION));
# 这三处把 glGetString(...) 的返回值（const char*）直接喂给 fmt::format。
# 本机 RockNIX + Mali-G31（闭源 DDK）+ 自打包 Mesa libGL 的环境下，GL 上下文未必按
# 桌面 OpenGL 3.2 CORE 路径正常建立，glGetString 可能返回 NULL。fmt 自 v9 起对 null
# const char* 抛 format_error("string pointer is null") 并 abort；旧版 wiliwili160 用
# 旧 fmt（容忍 null、打印 "(null)"）故不崩，yoga 构建链 fmt v12 更严格 -> 命中此崩溃
# （与上游 issue #570 崩溃轨迹一致：SDLVideoContext->Logger::info->Logger::log->format_error）。
# 修复：对三处 glGetString 调用加 null 守卫（`x ? x : ""`），NULL 时降级为空串，规避 fmt
# 抛异常；glGetString 返回有效串时行为完全不变。必须在 checkout/submodule 之后、cmake 之前注入。
SDL_VID_SRC="$(find "$SRC/library/borealis" -path '*/platforms/sdl/sdl_video.cpp' 2>/dev/null | head -n1)"
if [ -n "$SDL_VID_SRC" ]; then
  echo "=== [patch] fmt null 守卫：定位 sdl_video.cpp -> $SDL_VID_SRC ==="
  if ! grep -q 'glGetString(GL_VENDOR) ?' "$SDL_VID_SRC"; then
    sed -i -E 's@\(const char\*\)glGetString\(GL_(VENDOR|RENDERER|VERSION)\)@& ? & : ""@' "$SDL_VID_SRC"
    echo "=== [patch] 已为 GL Vendor/Renderer/Version 三处 glGetString 调用加 null 守卫 ==="
  else
    echo "=== [patch] sdl_video.cpp 已含 null 守卫，跳过（幂等）==="
  fi
else
  echo "WARN: 未找到 sdl_video.cpp，跳过 fmt null 守卫补丁（不影响其余构建步骤）"
fi

# === 防御性补丁：Mali-G31 GLES-only 强制走 GLES 上下文（修复 SIGSEGV）===
# 根因：borealis 在 PLATFORM_DESKTOP Linux SDL2 构建下，默认走桌面 OpenGL CORE
# profile（sdl_video.cpp 的 #else 分支：SDL_GL_CONTEXT_PROFILE_CORE + GL 3.2）。
# Mali-G31 是 GLES-only，建出坏上下文 -> glGetString 返回 NULL（实机三行 GL 日志
# 全空）-> 首个真实 GL 调用 NULL fnptr -> SIGSEGV。对照样本 wiliwili160 同机能出图
# （GL Version=OpenGL ES 3.2），是因为它走了 GLES profile 路径。
# 修复：borealis 的 commonOption.cmake 声明了 USE_GLES3 选项，但桌面分支未
# add_definitions，故 USE_GLES3 宏从未定义、永远走 CORE 分支。给 borealis target
# 追加 PUBLIC -DUSE_GLES3，让 sdl_video.cpp 走 USE_GLES3 分支
# （SDL_GL_CONTEXT_PROFILE_ES + GLES3 nanovg 实现），与 wiliwili160 行为一致；
# PUBLIC 使 wiliwili 也继承该宏。borealis 的 PS4 分支硬编码 -DUSE_GLES2 用同一
# bundled glad，证明 glad 支持 GLES，故 GLES3 可用。
BRLS_CMAKE="$(find "$SRC/library/borealis" -path '*/library/CMakeLists.txt' 2>/dev/null | head -n1)"
if [ -n "$BRLS_CMAKE" ]; then
  echo "=== [patch] USE_GLES3：定位 borealis library/CMakeLists.txt -> $BRLS_CMAKE ==="
  if ! grep -qF 'target_compile_options(borealis PUBLIC -DUSE_GLES3)' "$BRLS_CMAKE"; then
    printf '\ntarget_compile_options(borealis PUBLIC -DUSE_GLES3) # [wiliwili-aarch64] Mali GLES-only: force ES context\n' >> "$BRLS_CMAKE"
    echo "=== [patch] 已向 borealis 追加 PUBLIC -DUSE_GLES3 ==="
  else
    echo "=== [patch] borealis 已含 USE_GLES3，跳过（幂等）==="
  fi
else
  echo "WARN: 未找到 borealis library/CMakeLists.txt，跳过 USE_GLES3 补丁（不影响其余构建步骤）"
fi

# 2) 配置 + 编译
# === 窗口后端：GLFW -> SDL2（修复 Mali-G31 上建窗口失败）===
#   根因：wiliwili 桌面默认 GLFW 后端（-DPLATFORM_DESKTOP=ON）会请求【桌面 OpenGL】
#   上下文；而本机 RockNIX + Mali-G31 Bifrost（闭源 DDK r52p0）是【GLES-only】设备，
#   Mali 无法提供桌面 GL -> GLFW 建上下文/窗口失败 -> 进程抛 std::logic_error
#   "glfw: Failed to create window" 直接 abort（用户 log.txt 实证；旧版仅黑屏，现已升级为崩溃）。
#   对照样本 wiliwili160（同设备完整出图、干净退出）使用【SDL2 后端】，其运行时打印
#   "Using platform SDL"，且 GL 信息同为 Mali-G31 / OpenGL ES 3.2（ARM），证明 SDL2 后端
#   能在 Mali GLES 上正常出图、GLFW 不能。
#   故在保留 -DPLATFORM_DESKTOP=ON 的同时追加 -DUSE_SDL2=ON 切到 SDL2 窗口后端：
#   SDL2 在本机自动选择 Wayland/X11，经 EGL 走系统 Mali libEGL/libgbm 渲染 -> 出图；
#   SDL2 后端与现有 GL 打包策略（libGL 三件套自打包、libEGL/libgbm 交还系统）完全契合。
#   注：USE_SDL2 为 wiliwili 既有选项（上游文档确认；当前 WILIWILI_REF=yoga 分支支持），
#   仅需在容器里能 find_package(SDL2) 找到头文件/库（已在上一步 apt 安装 libsdl2-dev）。
# aarch64 优化参数：沿用 PortMaster 镜像自带 aarch64-linux-gnu 工具链，不引用任何外部 SDK/sysroot。
# 借鉴 dragonflylee/trimui-port 的微架构基线（Cortex-A53）：以 -march=armv8-a 通用 ISA 为底线
# （A53/A55/A72 全兼容，绝不 SIGILL），-mtune=cortex-a53 仅做指令调度调优（不改 ISA）。
# 多机型混合分发，故不用 -mcpu=cortex-a55（避免老 A53 设备非法指令崩溃）。LTO 关闭（轻量安全）。
# 通过 cmake 命令行 -DCMAKE_C_FLAGS/-DCMAKE_CXX_FLAGS 注入（cmake 标准全局传参方式；wiliwili 为常规 CMake 项目、以追加式书写 CMAKE_CXX_FLAGS，本注入稳定生效，且高于 CXXFLAGS 环境变量优先级）。
cmake -B build \
  -DPLATFORM_DESKTOP=ON \
  -DUSE_SDL2=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-pipe -fomit-frame-pointer -march=armv8-a -mtune=cortex-a53 -ffunction-sections -fdata-sections" \
  -DCMAKE_CXX_FLAGS="-pipe -fomit-frame-pointer -march=armv8-a -mtune=cortex-a53 -ffunction-sections -fdata-sections" \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--gc-sections -Wl,--as-needed"
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
  # === 打包策略：反转版（白名单式"系统已有库"排除，而非逐个排除库族）===
  # 本清单基于 2026-07-20 RockNIX 实机审计（逐库比对 /usr/lib）整理：
  #   - 实机系统已有的库（共 90 个 soname，见下方 SYS_LIST）-> 交给系统，不打包；
  #   - 其余（固件缺失、必须自带的库，约 192 个，典型为 libmpv.so.1 + ffmpeg 全套
  #     libav*/libpostproc/libswscale/libswresample/libavutil/libavcodec/libavformat/
  #     libavfilter/libavdevice/libavresample、samba/heimdal/krb5 可选依赖、OpenSSL1.1
  #     libssl.so.1.1/libcrypto.so.1.1、libffi.so.7、libpcre/libpcre2 等）-> 打包进 libs/。
  # 根因（为什么必须这么做）：构建机镜像(portmaster-builder:aarch64-latest)自带的底层库普遍
  # 较旧；若把系统已有的库也打进 libs/，运行期 LD_LIBRARY_PATH 会优先加载这些旧库而非实机系统
  # 较新的库，导致实机上层组件解析到旧版符号而报 undefined symbol（如 wl_proxy_marshal_flags、
  # g_once_init_enter_pointer、drmGetDeviceFromDevId 等连锁缺失）。
  # 改为"只打包固件确实缺失的库"后，libs/ 不会再出现任何系统已有库，从源头消除了旧库覆盖新
  # 系统库的错配；运行期这些库自然由 LD_LIBRARY_PATH 回退到实机系统库。
  #
  # 核心运行时库（libc/libm/libpthread/libdl/librt/libgcc_s/libstdc++/ld-linux/linux-vdso/
  # libutil/libresolv 等）始终排除，依赖目标固件系统提供（不在下方 90 个 SYS soname 内，如
  # libstdc++ 当前未被打包故未出现在审计清单，但必须继续排除）。
  #
  # 注：libwayland 全族、libgthread-2.0、libxkbcommon-x11、libxkbregistry 同样交给系统
  # （实机系统自带 libwayland-client 1.23 等），虽未列入下方 90 个 SYS soname（因它们早先已被
  # 排除、不出现在部署 libs/ 中，故审计比对无从命中），但系统确已有之，仍需显式排除，否则会
  # 重新引入 wl_proxy_marshal_flags 等缺失；libxkbcommon.so.0 本身已进 SYS_LIST。
  #
  # === GPU/mesa GL 栈（libGL/libGLX/libGLdispatch/libEGL/libgbm）打包策略：纯系统 GL 路线 ===
  #   目标：运行时 GL/EGL 全部来自系统 Mali DDK，libs/ 中【不再打包任何 Mesa GL 栈】，
  #   且打包集合里【没有任何库 DT_NEEDED 桌面 libGL】（否则加载即触发 H1 预 main 挂起）。
  #   实现方式（对齐实机对照样本 wiliwili160 的纯系统 GL 路线）：
  #   - 开启 BUILD_MPV_FROM_SRC，从源码构建 mpv 0.36 + ffmpeg 6，并：
  #       · mpv meson: 默认 MPV_VIDEO_BACKEND=gl ⇒
  #           -Dgl=enabled -Dplain-gl=enabled -Dx11=disabled -Dwayland=disabled -Dcaca=disabled -Ddrm=disabled
  #           （刻意 egl=disabled：不启用 mpv 自带 EGL 上下文后端）
  #           - gl=enabled + plain-gl=enabled：启用 mpv GPU 渲染器（vo=gpu）与 libmpv 渲染 API
  #             （mpv_render_context）；plain-gl 仅开渲染器特性、不拉桌面 libGL。wiliwili 经渲染 API
  #             把自身 EGL/GLES（系统 Mali）上下文交给 mpv 做解码+着色器渲染，正依赖此 GL 渲染后端；
  #             gl=disabled 会令 mpv_render_context_create 失败并抛 std::logic_error → abort（即退出设置时崩溃）。
  #           - egl=disabled（关键）：mpv 用 wiliwili 提供的上下文即可，无需自建 EGL 后端；若启用 egl
  #             会让 mpv 硬链 libEGL→传递依赖 libGLdispatch.so.0，破坏纯系统 GL 路线、并在 Mali（无 GLVND
#             libGLdispatch）上运行期加载失败；x11/wayland/drm=disabled 关闭 GLX/桌面 GL 上下文后端，
#             libmpv 不会 NEEDED 桌面 libGL/libGLX（Mali GLES-only 无其提供方）；但【注意】libplacebo
#             的 GLVND 链接仍可能使 libGLdispatch.so.0 残留于 DT_NEEDED——见下方"GLVND / libplacebo
#             泄漏与 patchelf 剥离"补遗，构建后将以 patchelf 剥离，守卫仍会通过。
  #           - caca=disabled：移除 libcaca.so.0 及其 libncursesw/libtinfo 依赖。
  #           - caca=disabled：移除 libcaca.so.0（及其 libncursesw/libtinfo 依赖），消除那三行
  #             "no version information available" 版本警告，并排除 H2（libcaca 构造期崩溃）。
  #       · ffmpeg configure: --disable-opengl，去掉 libavdevice.so 对桌面 libGL 的链接。
  #   - 因此 libmpv.so / libavdevice.so 均不再 NEEDED libGL，下方排除清单可安全把
  #     libGL/libGLX/libGLdispatch 也交还系统（与 libEGL/libgbm 一致），libs/ 中不再含任何 Mesa GL。
  #
  #   历史（已废弃的旧策略，留作对照）：此前因系统 /usr/lib/libGL.so.1 损坏（file too short），
  #   曾把 libGL 三件套自打包以避崩溃；但自打包 Mesa libGL 经 LD_LIBRARY_PATH 优先遮蔽系统 Mali
  #   libEGL/libgbm 会黑屏（no-image），交还 libEGL/libgbm 后 libGL 仍由 Mesa 提供 -> 触发 H1 预
  #   main 挂起。现改为"源码构建 EGL-only mpv/ffmpeg + 完全不打包 Mesa GL"，从根上消除该错配。
  #
  #   ⮕ 当前策略：libGL/libGLX/libGLdispatch/libEGL/libgbm 全部交还系统（纯系统 Mali GL/EGL）；
  #     Mesa GL 栈不再进入 libs/。若 BUILD_MPV_FROM_SRC 关闭（回退 apt libmpv-dev 0.32），则
#     libmpv 仍会硬链 libGL -> 下方 MISSING 校验会拒绝产出残包（fail loud，不静默出图异常）。
#
#   ⚠ 关键补遗（GLVND / libplacebo 泄漏与 patchelf 剥离，2026 构建修正）：
#   - (a) egl=disabled【单独】并不足以消除 libGLdispatch 泄漏：mpv 的 -Degl=disabled 只关闭 mpv
#     【自身】的 EGL 上下文后端，并不会移除 libplacebo（vo=gpu 渲染后端）在 GLVND 构建机上的 GL 后端
#     链接（libEGL.so.1 / libGLESv2.so.2 → 传递依赖 libGLdispatch.so.0）。故即便 egl=disabled，
#     libmpv.so / wiliwili 的 DT_NEEDED 仍可能残留 libGLdispatch.so.0（即 CI 当前失败根因）。
#   - (b) 因此构建后追加 patchelf 后处理：对 DT_NEEDED 含 libGLdispatch.so.0 的 dist 对象执行
#     `patchelf --remove-needed libGLdispatch.so.0` 将其剥离。之所以安全：wiliwili 以【HOST-CONTEXT】
#     模式经 libmpv 渲染 API（mpv_render_context_create + MPV_RENDER_PARAM_OPENGL_INIT_PARAMS）把自身
#     Mali GLES 上下文交给 mpv 渲染，mpv 不调用 GLVND 调度桩（eglGetDisplay/eglCreateContext 等），
#     这些符号若在运行期被引用会解析到设备 Mali 的 libEGL/libGLESv2（同名 soname、非 GLVND、无
#     libGLdispatch）。剥离后下方"纯系统 GL 路线"守卫即可通过，且不改变运行期 GL 来源。
#   - (c) 注意 libGL.so.1 / libGLX.so.0 仍被下方"纯系统 GL 路线"守卫【拒绝】（Mali GLES-only 无其
#     提供方）；本剥离仅针对 libGLdispatch.so.0。若 libGL/libGLX 意外泄漏，守卫照常 fail loud，
#     不会被误剥离放行。
#
  # ⚠ 目标固件系统库清单随固件升级需复核更新：每次 RockNIX 固件大版本升级后，应重新比对 /usr/lib，
  # 据此增删下方 SYS_LIST，避免把新版固件已提供的库误打包、或漏打包固件新缺失的库。
  case "$(basename "$1")" in
    # 排除清单（命中则 return 0 不打包，交给系统）：核心运行时库 + libwayland 全族 + 2026-07-20
    # RockNIX 实机审计的 90 个系统已有 soname（按 X11/xcb、SDL/GL/EGL/DRM、GLib/GTK/Pango/Cairo、
    # 声音/多媒体、samba/heimdal/ndr、压缩/加密/系统基础 分组，详见上方 is_core 注释）。
    # 注意：libbz2/liblzma/libzstd 已从排除清单移除并改为打包——源码构建的 ffmpeg 6 默认自动链接
    # 这三者（bzlib/xz/zstd），而目标 RockNIX 固件未必提供，2026-07-20 审计的"系统已有"假设在此
    # 不成立；改为自包含打包，避免运行时 'cannot open shared object file: libbz2.so.1' 类缺库错误。
    libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libgcc_s.so*|\
    libstdc++.so*|ld-linux-*|linux-vdso.so*|libutil.so*|libresolv.so*|\
    libBrokenLocale.so*|libmvec.so*|libnsl.so*|libpcprofile.so*|\
    libgthread-2.0.so*|\
    libwayland-client.so*|libwayland-cursor.so*|libwayland-egl.so*|libwayland-server.so*|\
    libX11.so*|libXau.so*|libXcursor.so*|libXdmcp.so*|libXext.so*|libXfixes.so*|\
    libXi.so*|libXinerama.so*|libXrandr.so*|libXrender.so*|libXss.so*|libXxf86vm.so*|\
    libxcb.so*|libxcb-render.so*|libxcb-shape.so*|libxcb-shm.so*|libxcb-xfixes.so*|\
    libSDL2-2.0.so*|\
    libvdpau.so*|libdrm.so*|libdrm_*.so*|libEGL.so*|libgbm.so*|libGL.so*|libGLX.so*|libGLdispatch.so*|\
    libglib-2.0.so*|libgobject-2.0.so*|libgmodule-2.0.so*|libgio-2.0.so*|\
    libcairo.so*|libcairo-gobject.so*|libpango-1.0.so*|libpangocairo-1.0.so*|\
    libpangoft2-1.0.so*|libgdk_pixbuf-2.0.so*|libpixman-1.so*|libthai.so*|\
    libdatrie.so*|libharfbuzz.so*|\
    libasound.so*|libpulse.so*|libopenal.so*|libsndfile.so*|libspeex.so*|libogg.so*|\
    libvorbis.so*|libvorbisenc.so*|libvorbisfile.so*|libmpg123.so*|libwavpack.so*|\
    libsamba-errors.so*|libsamba-util.so*|libsmbclient.so*|libsmbconf.so*|\
    libwbclient.so*|libndr-krb5pac.so*|libndr-nbt.so*|libndr-standard.so*|\
    libtalloc.so*|libdcerpc-binding.so*|\
    libz.so*|libexpat.so*|libfreetype.so*|\
    libfontconfig.so*|libpng16.so*|libjpeg.so*|liblcms2.so*|libgcrypt.so*|\
    libgpg-error.so*|libgmp.so*|libgnutls.so*|libidn2.so*|libsqlite3.so*|\
    libsystemd.so*|libudev.so*|libusb-1.0.so*|libdbus-1.so*|libblkid.so*|\
    libmount.so*|libuuid.so*|libarchive.so*|libass.so*|libfribidi.so*|\
    libgomp.so*|libtinfo.so*|libncursesw.so*|libxkbcommon.so*|\
    libxkbcommon-x11.so*|libxkbregistry.so*) return 0 ;;
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

# === patchelf 后处理：剥离 libGLdispatch.so.0（GLVND 调度库）===
# 背景（为什么必须这一步）：即便 mpv 用 -Degl=disabled 关闭了【自身】的 EGL 上下文后端，
# libplacebo（vo=gpu 的着色器/渲染后端）在构建机（Debian mesa GLVND 环境）上仍会把其 GL 后端
# 链到 GLVND 的 libEGL.so.1 / libGLESv2.so.2，而这两者【传递依赖】libGLdispatch.so.0。
# 因此 dist/libmpv.so.2（连带 dist/wiliwili）的 DT_NEEDED 里仍会残留 libGLdispatch.so.0，
# 触发下方"纯系统 GL 路线"的 ldd 校验失败（即 CI 当前失败点）。
# 为什么【剥离安全】（HOST-CONTEXT 模式）：wiliwili 经 libmpv 渲染 API
#（mpv_render_context_create + MPV_RENDER_PARAM_OPENGL_INIT_PARAMS）把自身 Mali GLES 上下文 +
# get_proc_address 回调交给 mpv 渲染；mpv 在 host-context 模式下【不会】调用 GLVND 调度桩
#（eglGetDisplay / eglCreateContext 等），这些符号即便被引用也会在运行期解析到设备 Mali 的
# libEGL/libGLESv2（同名 soname、非 GLVND、无 libGLdispatch）。这与对照样本 wiliwili160 的
# "纯系统 GL"行为一致，故移除 libGLdispatch NEEDED 在目标机上安全。
# 注意：libGL.so.1 / libGLX.so.0 仍被下方"纯系统 GL 路线"守卫拒绝（Mali GLES-only 无其提供方），
# 本循环只针对 libGLdispatch.so.0；若将来出现 libGL/libGLX 泄漏，守卫会照常 fail loud。
if command -v patchelf >/dev/null 2>&1; then
  for obj in dist/wiliwili dist/libs/*.so*; do
    [ -e "$obj" ] || continue
    # 仅当该对象【直接】DT_NEEDED libGLdispatch.so.0 时才剥离（patchelf --print-needed 取直接依赖），
    # 避免对仅经系统 libEGL 传递依赖的对象误报/误剥。
    if patchelf --print-needed "$obj" 2>/dev/null | grep -Eq 'libGLdispatch\.so'; then
      if patchelf --remove-needed libGLdispatch.so.0 "$obj" 2>/dev/null; then
        echo "=== patchelf: 已从 $obj 剥离 libGLdispatch.so.0（GLVND 调度，运行期由 Mali 提供）==="
      else
        echo "WARN: patchelf 剥离 $obj 的 libGLdispatch.so.0 失败（不中止构建，下方守卫将持续拦截）" >&2
      fi
    fi
  done
else
  echo "WARN: 未安装 patchelf，跳过 libGLdispatch.so.0 剥离（纯系统 GL 路线守卫可能失败）" >&2
fi

# 纯系统 GL 路线强制校验：dist 内任何对象（主程序 + 全部 libs/*.so*）都不得【直接】DT_NEEDED 桌面
# libGL/libGLX/libGLdispatch。任一命中即拒绝产出（fail loud），确保 H1 根因（自带 Mesa libGL
# 预 main 挂起）不会随残包流出。CI 默认 BUILD_MPV_FROM_SRC=on，此步即团队要求的 GL 依赖验证。
# 注意：本校验检查【直接 NEEDED】（readelf -d），而非 ldd 的【传递闭包】。libGLdispatch 常经系统
# GLVND libEGL.so.1【传递】依赖引入——这在构建机上存在，但目标机 Mali 的 libEGL 为非 GLVND、
# 无 libGLdispatch（HOST-CONTEXT 模式下 mpv 不经 GLVND 调度桩，符号运行期由 Mali libEGL/libGLESv2
# 提供），故传递依赖是构建机假象、运行期不存在，不应判失败。仅当某 dist 对象【直接】链入被禁库才拒绝。
echo "=== 校验：纯系统 GL 路线 —— dist 内任何对象不得直接 DT_NEEDED 桌面 libGL ==="
GL_BAD=0
for obj in dist/wiliwili dist/libs/*.so*; do
  [ -e "$obj" ] || continue
  # 直接 NEEDED 检查（readelf -d）：仅本对象自身 DT_NEEDED 的被禁库才拒绝；经系统 GLVND libEGL 的
  # 传递 libGLdispatch 依赖不计入（目标机 libEGL 非 GLVND、无 libGLdispatch）。
  if readelf -d "$obj" 2>/dev/null | grep -Eq 'NEEDED.+libGL\.so|NEEDED.+libGLX\.so|NEEDED.+libGLdispatch\.so'; then
    echo "ERROR: $obj 直接 DT_NEEDED 桌面 libGL（违反纯系统 GL 路线）：" >&2
    readelf -d "$obj" 2>/dev/null | grep -E 'NEEDED.+libGL\.so|NEEDED.+libGLX\.so|NEEDED.+libGLdispatch\.so' >&2
    GL_BAD=1
  fi
done
if [ "$GL_BAD" -ne 0 ]; then
  echo "ERROR: 存在桌面 libGL 直接依赖，拒绝产出。请确认 mpv GL 渲染后端经 plain-gl 启用（gl=enabled plain-gl=enabled，egl=disabled 避免硬链 libEGL）、x11=disabled（GL 走渲染器而非 GLX）且 ffmpeg --disable-opengl 已生效；libGLdispatch 仅允许经系统 libEGL 的【传递】依赖（目标机非 GLVND、运行期无 libGLdispatch）。" >&2
  exit 1
fi
echo "=== OK: dist 内无任何对象直接 DT_NEEDED 桌面 libGL（纯系统 GL 路线校验通过）==="

tar -czf "/workspace/wiliwili-linux-${ARCH}.tar.gz" -C dist .
echo "=== done: /workspace/wiliwili-linux-${ARCH}.tar.gz ==="
