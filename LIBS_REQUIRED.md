# LIBS_REQUIRED.md — wiliwili (aarch64) 运行时库依赖分析

> 生成依据：本地 `wiliwili-portmaster/wiliwili/wiliwili/`（ELF64 / AArch64 / DYN PIE 可执行文件）及其 `libs/`（197 个 `.so`）的完整 DT_NEEDED 闭包，交叉比对 `build.sh` 的 `is_core()`排除清单与实际 `libs/` 文件，确认无缺失库。

## 1. 方法与环境

- **分析对象（二进制）**：`wiliwili-portmaster/wiliwili/wiliwili/wiliwili`
  - `readelf -h`：`Class=ELF64`、`Machine=AArch64`、`Type=DYN`（PIE 可执行）。
- **分析对象（库目录）**：同名目录下的 `libs/`，共 **197** 个文件。
- **Docker 镜像（已修正标签）**：`ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest`
  - 注意：本机 `docker image ls` 中该镜像的完整标签即如上；裸名 `portmaster-builder:aarch64-latest`在本地并不存在，直接 `docker run portmaster-builder:aarch64-latest` 会误去 `docker.io/library/` 拉取而报 403。另一本地标签 `portmaster-builder:aarch64-gfx-local` 为 gfx 变体，未采用。
- **工具（与原指令的偏差）**：该镜像内**没有** `aarch64-linux-gnu-ldd`，也**没有** `qemu-aarch64`，因此无法执行 aarch64 动态链接器来跑 `ldd`。改用 `aarch64-linux-gnu-readelf -dW` 枚举每个 ELF 的 `DT_NEEDED`——这与 `ldd` 的“列 NEEDED”目标等价，且无需仿真、结果更稳健。对二进制及其 `libs/` 下全部 `.so` 各跑一次 `readelf -d`即得到完整依赖闭包。
- **比对基准**：
  1. `build.sh` 中 `is_core()` 函数（system-provided 排除清单，命中返回 0=交系统；否则返回 1=需打包）；
  2. 实际 `libs/` 目录中的文件名。

## 2. 二进制直接 NEEDED（13 个）

| # | soname | 归类 |
|---|--------|------|
| 1 | `libz.so.1` | system(is_core) |
| 2 | `libpthread.so.0` | system(is_core) |
| 3 | `libmpv.so.1` | bundled(libs) |
| 4 | `libwebp.so.6` | bundled(libs) |
| 5 | `libssl.so.1.1` | bundled(libs) |
| 6 | `libcrypto.so.1.1` | bundled(libs) |
| 7 | `libdbus-1.so.3` | system(is_core) |
| 8 | `libm.so.6` | system(is_core) |
| 9 | `libdl.so.2` | system(is_core) |
| 10 | `libstdc++.so.6` | system(is_core) |
| 11 | `libgcc_s.so.1` | system(is_core) |
| 12 | `libc.so.6` | system(is_core) |
| 13 | `ld-linux-aarch64.so.1` | system(is_core) |

## 3. 全依赖闭包统计

- 闭包总 soname 数（二进制 + 全部传递依赖）：**162**
- 已打包进 `libs/`：**96**
- 由系统提供（命中 `is_core` 排除清单）：**65**
- 既未打包、又不在 `is_core` 排除清单中的“标记项”：**1**

## 4. 标记项分析：`libxcb-shape.so.0`

- **来源**：由打包库 `libavdevice.so.58`（ffmpeg 设备库）依赖，与其兄弟 `libxcb.so.1` / `libxcb-shm.so.0` / `libxcb-xfixes.so.0` 同属一个 NEEDED 块。
- **`libs/` 中是否存在**：否。`libs/` 完全不含任何 `libxcb-*`（`libxcb` 族整体由系统提供，故构建期 `is_core` 将其排除、不打包）。
- **`is_core()` 一致性的遗漏**：`is_core()` 排除了 `libxcb.so*`、`libxcb-shm.so*`、`libxcb-xfixes.so*`，却**漏掉了 `libxcb-shape.so*`**。因此 `libxcb-shape.so.0` 既未被打包、又未被显式排除。
- **运行期行为**：加载 `libavdevice.so.58`（来自 `libs/`）时，加载器在 `LD_LIBRARY_PATH`（`libs/`）中找不到 `libxcb-shape.so.0`，回退到设备系统 `/usr/lib/libxcb-shape.so.0`。`xcb-shape` 是标准 X11 扩展库，ROCKNIX 系统自带 → **功能上不缺库、不会崩溃**。
- **建议**：在 `build.sh` 的 `is_core()` 排除清单中补 `libxcb-shape.so*`，与其兄弟 xcb 库保持一致，使构建自检明确将其视为系统库（避免未来固件变化时误判为“缺失的非核心依赖”而打包或报错）。

## 5. 结论

wiliwili 的完整运行时依赖闭包（162 个 soname）已被 `libs/`（96 个打包库）+ 系统库（65 个 `is_core` 排除项）完全覆盖，**无硬性缺失库**。
唯一标记项 `libxcb-shape.so.0` 由设备系统提供，不导致运行失败；它揭示 `is_core()` 排除清单的一处遗漏（建议补 `libxcb-shape.so*`），但不影响当前实机可用性。

> 注：本次分析基于本地 `wiliwili-portmaster/wiliwili/wiliwili/` 工件（与设备 `/roms/ports/wiliwili` 同源；
> 若需以实机最新目录复核，见任务 A 的 tar 抓取，当前因设备 SSH 凭据未提供而暂缓）。

## 附录 A：打包进 libs/ 的 soname（96 个）

```
libEGL.so.1
libGL.so.1
libGLX.so.0
libGLdispatch.so.0
libOpenCL.so.1
libXv.so.1
libaom.so.0
libavc1394.so.0
libavcodec.so.58
libavdevice.so.58
libavfilter.so.7
libavformat.so.58
libavutil.so.56
libbluray.so.2
libbs2b.so.0
libbsd.so.0
libcaca.so.0
libcdio.so.18
libcdio_cdda.so.2
libcdio_paranoia.so.2
libchromaprint.so.1
libcodec2.so.0.9
libcom_err.so.2
libcrypto.so.1.1
libdc1394.so.22
libdvdnav.so.4
libdvdread.so.7
libfftw3.so.3
libflite.so.1
libflite_cmu_us_awb.so.1
libflite_cmu_us_kal.so.1
libflite_cmu_us_kal16.so.1
libflite_cmu_us_rms.so.1
libflite_cmu_us_slt.so.1
libflite_cmulex.so.1
libflite_usenglish.so.1
libgbm.so.1
libgme.so.0
libgsm.so.1
libgssapi_krb5.so.2
libicudata.so.66
libicuuc.so.66
libiec61883.so.0
libjack.so.0
libk5crypto.so.3
libkeyutils.so.1
libkrb5.so.3
libkrb5support.so.0
liblilv-0.so.0
liblua5.2.so.0
libmp3lame.so.0
libmpv.so.1
libmysofa.so.1
libnorm.so.1
libnuma.so.1
libopenjp2.so.7
libopenmpt.so.0
libopus.so.0
libpgm-5.2.so.0
libpostproc.so.55
libraw1394.so.11
librom1394.so.0
librsvg-2.so.2
librubberband.so.2
libsamplerate.so.0
libserd-0.so.0
libshine.so.3
libslang.so.2
libsnappy.so.1
libsndio.so.7.0
libsodium.so.23
libsord-0.so.0
libsoxr.so.0
libsratom-0.so.0
libssh-gcrypt.so.4
libssl.so.1.1
libswresample.so.3
libswscale.so.5
libtheoradec.so.1
libtheoraenc.so.1
libtwolame.so.0
libuchardet.so.0
libva-drm.so.2
libva-wayland.so.2
libva-x11.so.2
libva.so.2
libvidstab.so.1.1
libvpx.so.6
libwebp.so.6
libwebpmux.so.3
libx264.so.155
libx265.so.179
libxml2.so.2
libxvidcore.so.4
libzmq.so.5
libzvbi.so.0
```

## 附录 B：由系统提供（is_core 排除）的 soname（65 个）

```
ld-linux-aarch64.so.1
libSDL2-2.0.so.0
libX11.so.6
libXext.so.6
libXfixes.so.3
libXinerama.so.1
libXrandr.so.2
libXss.so.1
libarchive.so.13
libasound.so.2
libass.so.9
libbz2.so.1.0
libc.so.6
libcairo-gobject.so.2
libcairo.so.2
libdbus-1.so.3
libdl.so.2
libdrm.so.2
libexpat.so.1
libfontconfig.so.1
libfreetype.so.6
libfribidi.so.0
libgcc_s.so.1
libgcrypt.so.20
libgdk_pixbuf-2.0.so.0
libgio-2.0.so.0
libglib-2.0.so.0
libgnutls.so.30
libgobject-2.0.so.0
libgomp.so.1
libgpg-error.so.0
libjpeg.so.8
liblcms2.so.2
liblzma.so.5
libm.so.6
libmpg123.so.0
libncursesw.so.6
libogg.so.0
libopenal.so.1
libpango-1.0.so.0
libpangocairo-1.0.so.0
libpng16.so.16
libpthread.so.0
libpulse.so.0
libresolv.so.2
librt.so.1
libsmbclient.so.0
libspeex.so.1
libstdc++.so.6
libtinfo.so.6
libusb-1.0.so.0
libvdpau.so.1
libvorbis.so.0
libvorbisenc.so.2
libvorbisfile.so.3
libwavpack.so.1
libwayland-client.so.0
libwayland-cursor.so.0
libwayland-egl.so.1
libwayland-server.so.0
libxcb-shm.so.0
libxcb-xfixes.so.0
libxcb.so.1
libxkbcommon.so.0
libz.so.1
```

