#!/bin/bash
set -euo pipefail
ARCH="${1:-aarch64}"
SRC="${SOURCE_DIR:-.}"
echo "=== wiliwili ${ARCH} build (arch=${ARCH}, src=${SRC}) ==="
cd "$SRC"

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
  # === GPU/mesa GL 栈（libGL/libGLX/libGLdispatch/libEGL/libgbm）打包策略：部分 revert ===
  #   实机 RockNIX（PX30 + Mali-G31 Bifrost，封闭 Mali DDK r52p0）的 /usr/lib/libGL.so.1 当前
  #   损坏（file too short：悬空符号链接或截断文件），故 libGL/libGLX/libGLdispatch 三件套仍由
  #   构建机镜像打包（自包含 Mesa GL 客户端栈），以满足 libmpv.so.1 与 libavdevice.so.58 对
  #   libGL.so.1 的硬链接；一旦委托系统，加载即报 "libGL.so.1: file too short" 崩溃。
  #
  #   但 libEGL.so* 与 libgbm.so* 必须【交还系统】（重新列入下方排除清单），原因：
  #   - no-image 根因：自打包的 Mesa libEGL/libgbm 经 LD_LIBRARY_PATH 优先遮蔽了设备系统 Mali
  #     DDK 提供的 libEGL/libgbm；Mesa EGL 无法在 Mali GPU 上创建渲染面 → 黑屏无图。
  #   - 实机对照样本 wiliwili160（/roms/ports/wiliwili160，纯系统 GL）GL 信息实证：
  #       GL Vendor: ARM / Renderer: Mali-G31 / GL ES 3.2 —— 证明系统 Mali 栈可正常出图。
  #   - 交还系统后，SDL2/EGL 显示面改用系统 Mali libEGL/libgbm 渲染 → 出图；
  #     而 libmpv/libavdevice 硬链接的 libGL 仍解析到打包的合法 Mesa libGL → 不触发损坏系统 libGL。
  #   - 硬链接校验（GL_HARDLINK_CHECK.md）：仅 libmpv.so.1 与 libavdevice.so.58 硬链接 libGL.so.1；
  #     libEGL/libgbm 仅被 libmpv.so.1 硬链接，交还系统后回退到有效 Mali 版本，无崩溃风险。
  #
  #   ⮕ 当前策略：libGL/libGLX/libGLdispatch 打包（避 file-too-short），libEGL/libgbm 交系统（修 no-image）。
  #     若日后固件修复系统 libGL，可再把 libGL 三件套也交还系统，彻底与 wiliwili160 对齐。
  #
  # ⚠ 目标固件系统库清单随固件升级需复核更新：每次 RockNIX 固件大版本升级后，应重新比对 /usr/lib，
  # 据此增删下方 SYS_LIST，避免把新版固件已提供的库误打包、或漏打包固件新缺失的库。
  case "$(basename "$1")" in
    # 排除清单（命中则 return 0 不打包，交给系统）：核心运行时库 + libwayland 全族 + 2026-07-20
    # RockNIX 实机审计的 90 个系统已有 soname（按 X11/xcb、SDL/GL/EGL/DRM、GLib/GTK/Pango/Cairo、
    # 声音/多媒体、samba/heimdal/ndr、压缩/加密/系统基础 分组，详见上方 is_core 注释）。
    libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libgcc_s.so*|\
    libstdc++.so*|ld-linux-*|linux-vdso.so*|libutil.so*|libresolv.so*|\
    libBrokenLocale.so*|libmvec.so*|libnsl.so*|libpcprofile.so*|\
    libgthread-2.0.so*|\
    libwayland-client.so*|libwayland-cursor.so*|libwayland-egl.so*|libwayland-server.so*|\
    libX11.so*|libXau.so*|libXcursor.so*|libXdmcp.so*|libXext.so*|libXfixes.so*|\
    libXi.so*|libXinerama.so*|libXrandr.so*|libXrender.so*|libXss.so*|libXxf86vm.so*|\
    libxcb.so*|libxcb-render.so*|libxcb-shape.so*|libxcb-shm.so*|libxcb-xfixes.so*|\
    libSDL2-2.0.so*|\
    libvdpau.so*|libdrm.so*|libdrm_*.so*|libEGL.so*|libgbm.so*|\
    libglib-2.0.so*|libgobject-2.0.so*|libgmodule-2.0.so*|libgio-2.0.so*|\
    libcairo.so*|libcairo-gobject.so*|libpango-1.0.so*|libpangocairo-1.0.so*|\
    libpangoft2-1.0.so*|libgdk_pixbuf-2.0.so*|libpixman-1.so*|libthai.so*|\
    libdatrie.so*|libharfbuzz.so*|\
    libasound.so*|libpulse.so*|libopenal.so*|libsndfile.so*|libspeex.so*|libogg.so*|\
    libvorbis.so*|libvorbisenc.so*|libvorbisfile.so*|libmpg123.so*|libwavpack.so*|\
    libsamba-errors.so*|libsamba-util.so*|libsmbclient.so*|libsmbconf.so*|\
    libwbclient.so*|libndr-krb5pac.so*|libndr-nbt.so*|libndr-standard.so*|\
    libtalloc.so*|libdcerpc-binding.so*|\
    libz.so*|libzstd.so*|libbz2.so*|liblzma.so*|libexpat.so*|libfreetype.so*|\
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

tar -czf "/workspace/wiliwili-linux-${ARCH}.tar.gz" -C dist .
echo "=== done: /workspace/wiliwili-linux-${ARCH}.tar.gz ==="
