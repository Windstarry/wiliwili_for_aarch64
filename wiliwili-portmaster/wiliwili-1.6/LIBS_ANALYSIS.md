# LIBS_ANALYSIS.md — wiliwili160 对照样本依赖分析

> 目的：分析实机可正常运行的 `wiliwili160`（来自设备 `/roms/ports/wiliwili160`）的二进制及其唯一自带库 `libmpv.so.2` 的 `DT_NEEDED`，反推我们 build “运行无图像”的编译/打包参数差异。
> 结论先行：**我们 build 把 5 个 Mesa GL 客户端库（libEGL/libGL/libGLX/libGLdispatch/libgbm）打进了 `libs/`，通过 `LD_LIBRARY_PATH` 优先遮蔽了设备本可工作的系统 Mali GL 栈，导致 SDL2 加载到无法驱动 Mali GPU 的 Mesa EGL → 无图像。** `wiliwili160` 一个 GL 库都不打、全走系统 Mali → 出图。这就是根因。

---

## 0. 环境与方法

- **Docker 镜像**：`ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest`（裸名 `portmaster-builder:...` 本地不存在，必须带 `ghcr.io/monkeyx-net/portmaster-build-templates/` 前缀，否则会误去 `docker.io/library/` 拉取而 403）。
- **工具**：镜像内无 `aarch64-linux-gnu-ldd`、无 `qemu-aarch64`，故用 `aarch64-linux-gnu-readelf -dW <elf> | grep -i needed` 枚举 `DT_NEEDED`（与 `ldd` 列 NEEDED 等价）。
- **分析对象**：
  - 二进制 `wiliwili-portmaster/wiliwili-1.6/wiliwili160/wiliwili`（13.7 MB，ELF64/AArch64/DYN PIE）
  - 唯一自带库 `wiliwili160/libs/libmpv.so.2`（2.6 MB）
  - 启动脚本 `wiliwili160.sh`：**只设 `LD_LIBRARY_PATH`，未设** `DISPLAY` / `EGL_PLATFORM` / `LIBGL_DRIVERS_PATH` / `MESA_DRIVERS_PATH`
- **对照基准**：我们 build 的数据来自已生成的 `LIBS_REQUIRED.md`（二进制直接 NEEDED 13 项；`libs/` 打包 96 soname 含 5 个 Mesa GL 客户端库；闭包 162 = 96 打包 + 65 系统 + 1 标记）。

---

## 1. wiliwili160 二进制直接 DT_NEEDED（10 项）

| # | soname | 备注 |
|---|--------|------|
| 1 | `libz.so.1` | 系统 |
| 2 | `libmpv.so.2` | **唯一自带**（打包） |
| 3 | `libcurl.so.4` | 系统 |
| 4 | `libssl.so.3` | 系统（OpenSSL 3.x） |
| 5 | `libcrypto.so.3` | 系统（OpenSSL 3.x） |
| 6 | `libasound.so.2` | 系统 |
| 7 | `libstdc++.so.6` | 系统 |
| 8 | `libm.so.6` | 系统 |
| 9 | `libgcc_s.so.1` | 系统 |
| 10 | `libc.so.6` | 系统 |

> 二进制本身**不含任何 GL/EGL/gbm 硬链接**，仅通过 `libmpv.so.2` 间接引用。

---

## 2. libmpv.so.2 直接 DT_NEEDED（24 项）

| # | soname | 归类 |
|---|--------|------|
| 1 | `libass.so.9` | 系统 |
| 2 | `libavcodec.so.60` | 系统（ffmpeg 6.x） |
| 3 | `libavfilter.so.9` | 系统（ffmpeg 6.x） |
| 4 | `libavformat.so.60` | 系统（ffmpeg 6.x） |
| 5 | `libavutil.so.58` | 系统（ffmpeg 6.x） |
| 6 | `libswresample.so.4` | 系统（ffmpeg 6.x） |
| 7 | `libswscale.so.7` | 系统（ffmpeg 6.x） |
| 8 | `liblcms2.so.2` | 系统 |
| 9 | `libarchive.so.13` | 系统 |
| 10 | `libavdevice.so.60` | 系统（ffmpeg 6.x） |
| 11 | `libm.so.6` | 系统 |
| 12 | `libluajit-5.1.so.2` | 系统 |
| 13 | `libSDL2-2.0.so.0` | 系统（**关键：SDL2 由系统提供**） |
| 14 | `libz.so.1` | 系统 |
| 15 | `libasound.so.2` | 系统 |
| 16 | `libpipewire-0.3.so.0` | 系统 |
| 17 | `libpulse.so.0` | 系统 |
| 18 | `libdrm.so.2` | 系统 |
| 19 | `libjpeg.so.8` | 系统 |
| 20 | `libplacebo.so.342` | 系统 |
| 21 | `libwayland-client.so.0` | 系统 |
| 22 | `libwayland-cursor.so.0` | 系统 |
| 23 | `libxkbcommon.so.0` | 系统 |
| 24 | `libc.so.6` | 系统 |

> `libmpv.so.2` 同样**不含任何 GL/EGL/gbm 硬链接**。它只链接 `libSDL2`、`libplacebo`、`libwayland-client`、`libdrm`、ffmpeg6 等——这些库在运行时再由 SDL2 去 `dlopen` 系统的 GL 栈。

---

## 3. wiliwili160 是否依赖 `libGL.so.1`？→ 链接层面**完全不依赖**

- **二进制 `DT_NEEDED`**：无 `libGL` / `libEGL` / `libgbm` / `libGLESv2` / `libvulkan`。
- **`libmpv.so.2` `DT_NEEDED`**：同上，均无任何 GL/Mesa 客户端库。
- 二进制 `.rodata` 里出现的 `libGL.so.1` / `libEGL.so.1` / `libGLESv2.so.2` / `libgbm.so.1` / `libvulkan.so.1` / `libwayland-egl.so.1` / `libGLES_CM.so.1` / `libGLESv1_CM.so.1` 全部是 **SDL2 运行时 `dlopen` 候选列表**（SDL2 的 video/EGL 后端会按序尝试 `dlopen` 这些系统库来选最佳渲染后端）。即 GL/EGL 由 SDL2 在**运行时向系统动态加载**，而非链接期绑定。
- 结论：wiliwili160 **不碰 `libGL` 的链接**，主要走 **EGL / GBM / Wayland / Vulkan**（均经 SDL2 动态加载系统库）。它并不要求一个“硬链接的 `libGL.so.1`”。

---

## 4. GL/Mesa 相关 soname 在 NEEDED 中的出现统计

| 位置 | libGL.so.1 | libEGL.so.1 | libgbm.so.1 | libGLESv2.so.2 | libvulkan.so.1 |
|------|-----------|-------------|-------------|----------------|----------------|
| 二进制 `DT_NEEDED` | 0 | 0 | 0 | 0 | 0 |
| `libmpv.so.2` `DT_NEEDED` | 0 | 0 | 0 | 0 | 0 |
| 二进制 `strings`（SDL2 dlopen 候选） | ✔ | ✔ | ✔ | ✔ | ✔ |

- **硬链接（DT_NEEDED）出现次数：0**。GL/Mesa 库仅以 SDL2 的 `dlopen` 候选字符串形式存在于二进制中。
- **对照我们 build**：`libs/` 显式打包了 `libEGL.so.1` / `libGL.so.1` / `libGLX.so.0` / `libGLdispatch.so.0` / `libgbm.so.1`（外加 `libOpenCL.so.1`、`libva-*.so.2` 等）——这是两套 build **最根本的分歧点**。

---

## 5. 两套 build 的“GL 后端选型 / 打包策略”差异，及能否解释“我们无图、160 有图”

### 5.1 GL/EGL 由谁提供（核心差异）

| 维度 | wiliwili160（能出图） | 我们 build（无图像） |
|------|----------------------|---------------------|
| 自带 GL/EGL 库 | **0 个** | **5 个 Mesa 客户端库**（libEGL/libGL/libGLX/libGLdispatch/libgbm） |
| SDL2 来源 | 系统 `libSDL2-2.0.so.0` | 系统（未打包 SDL2） |
| SDL2 `dlopen("libEGL.so.1")` 解析到 | **系统 Mali DDK** 的 libEGL（设备 GL 由封闭 Mali r52p0 提供） | **我们打包的 Mesa** libEGL（`LD_LIBRARY_PATH=libs:...` 优先） |
| 渲染结果 | Mali 硬件/合成器正常出图 | Mesa EGL 无法驱动 Mali（无 panfrost、无 `renderD128`、仅 `card0`，需 `kms_swrast` 而该软驱动多半缺失）→ EGL 建面/渲染失败 → **无图像** |

### 5.2 这能否解释差异？→ **能，且完整解释**

- 不是 DRI 驱动路径问题，所以 commit `9e040d4`（设 `LIBGL_DRIVERS_PATH=/usr/lib/dri`）无效：问题不在“Mesa 去哪找 DRI 驱动”，而在“**Mesa EGL 本身就无法在这块 Mali GPU 上渲染**”。只要 SDL2 加载到的是我们打包的 Mesa libEGL，就注定无图。
- `wiliwili160` 恰好是反证：它一个 GL 库都不打、`LD_LIBRARY_PATH` 不设任何 GL/Mesa 变量，SDL2 自然 `dlopen` 到系统 Mali libEGL/libGLESv2/libgbm → 出图。证明“**走系统 Mali GL 栈 = 出图**”。
- 因此根因是 **build/packaging 把 Mesa GL 客户端库打进 `libs/`，遮蔽了设备可用的系统 Mali GL 栈**。

### 5.3 次级差异（与无图无直接关系，但说明“我们过度打包”）

- **ffmpeg / mpv 版本**：
  - 我们：旧 `libmpv.so.1`（mpv 0.x）+ ffmpeg 4.x（`libav*.so.58/.57/.56/.55/.3/.5`），全部打包。
  - 160：新 `libmpv.so.2`（mpv 新版）+ ffmpeg 6.x（`libav*.so.60/.9/.58/.4/.7`），全部走系统。
  - 说明设备系统**本来就具备可用的 mpv/ffmpeg/SDL2/wayland/GL**；我们当初大包特包，是 build 时误判系统缺库，并连带把 Mesa GL 也打了进来。
- **OpenSSL**：160 用 3.x（系统），我们打包 1.1（版本错配，与无图无关）。

---

## 6. 对之前 no-image 假设（H1–H4）的修正

- **H3（自打包 Mesa 遮蔽原生 Mali GL 栈）：已确认**，并有了对照实证（wiliwili160）。
- **H1（系统缺 `kms_swrast_dri.so`）：降级为次要**——160 完全不用 Mesa、也不设 `LIBGL_DRIVERS_PATH` 却能出图，说明“缺 kms_swrast”不是主因；主因是强制 Mesa EGL 无法用 Mali。H1 仅在“坚持用 Mesa”的假设下才相关，而正确方向是“不用 Mesa GL”。
- **H2（EGL platform 错配）：可能叠加但非根因**——即便走 Mali，也可能需要 `EGL_PLATFORM=gbm`；但根因是 GL 库被替换，先修根因再视情况补 platform。
- **H4（gbm 后端缺失）：对 Mali 路径不适用**——Mali DDK 自带 gbm 后端。

---

## 7. 下一步建议（只读分析，未改任何源码/脚本；待 lead 批准后再落地）

**核心修复方向：停止把 Mesa GL 客户端库打进 `libs/`，改由系统（Mali DDK）提供 GL/EGL/GBM**，与 wiliwili160 完全一致。

1. **主修复（高置信、最小改动）**：在 `build.sh` 的 `is_core()`/打包逻辑中，将以下库从“强制打包”改为“视为系统库（排除打包）”：
   `libEGL.so.1`、`libGL.so.1`、`libGLX.so.0`、`libGLdispatch.so.0`、`libgbm.so.1`（以及 `libgallium.so`、`libOSMesa.so.8` 若也在打包清单）。
   让 SDL2 在实机 `dlopen` 到系统 Mali libEGL。应用/业务库（`libmpv`、`ffmpeg` 等）保持现状打包，避免连带改动。

2. **⚠ 必做前置校验（防止改出启动崩溃）**：确认我们打包的 `libmpv.so.1` / `ffmpeg` / `libva-*.so.2` 等是否**硬链接** `libGL.so.1`。
   - 若存在硬链接：移除打包的 Mesa `libGL` 后，加载器会回退到“系统 `/usr/lib/libGL.so.1`（已知 `file too short` 损坏）”→ 可能启动即加载失败崩溃。
   - 校验命令（对本地/设备上的我们 `libs/` 各 `.so`）：`aarch64-linux-gnu-readelf -dW <lib> | grep -i needed | grep -i libGL`。
   - 若存在硬链接：需同时让该库也走系统（设备具备兼容版本时），或重构我们的 mpv/SDL 链接系统库（对齐 160）；最干净是让我们的二进制/mpv 也像 160 那样仅经 SDL2 `dlopen` GL、不硬链接 `libGL`。
   - 当前本地**无我们的 build 工件**（盘上只有 `wiliwili-1.6` 参考样本），此项需在设备 tar（任务 A）或 CI 产物上复核。

3. **低风险附带优化（可选）**：参考 160，把 `ffmpeg`/`mpv` 也改为走系统（设备已具备 ffmpeg6/mpv/SDL2），可大幅缩减 `libs/` 体积。但**最小改动 = 仅修 GL 遮蔽**，其余打包库暂保留。

4. **修复后复核**：用 `wiliwili-diag.sh` 在实机跑一次，预期 SDL2 加载系统 Mali libEGL、出图；对比 `DIAG_EGL_PLATFORM=gbm` 与 `DIAG_SOFTWARE=1` 两次运行确认（诊断脚本保持本地未跟踪、不提交）。

5. **回溯 build.sh 初衷**：当初“系统 `libGL.so.1` 损坏 → 打 Mesa”的假设被 160 证伪——设备渲染路径（SDL2→EGL/GLES via Mali）根本不需要硬链接的 `libGL.so.1`，损坏的 `libGL` 是干扰项。应据此调整 `is_core` 策略，避免再误打包 Mesa GL。

---

## 附录 A：原始 readelf 输出摘要（完整见同目录 `_readelf_out.txt`）

**二进制 NEEDED（10）**：libz.so.1, libmpv.so.2, libcurl.so.4, libssl.so.3, libcrypto.so.3, libasound.so.2, libstdc++.so.6, libm.so.6, libgcc_s.so.1, libc.so.6

**libmpv.so.2 NEEDED（24）**：libass.so.9, libavcodec.so.60, libavfilter.so.9, libavformat.so.60, libavutil.so.58, libswresample.so.4, libswscale.so.7, liblcms2.so.2, libarchive.so.13, libavdevice.so.60, libm.so.6, libluajit-5.1.so.2, libSDL2-2.0.so.0, libz.so.1, libasound.so.2, libpipewire-0.3.so.0, libpulse.so.0, libdrm.so.2, libjpeg.so.8, libplacebo.so.342, libwayland-client.so.0, libwayland-cursor.so.0, libxkbcommon.so.0, libc.so.6

**二进制 strings 中的 GL/Mesa/Mali/dlopen 候选**：libEGL.so.1, libGL.so.1, libGLES_CM.so.1, libGLESv1_CM.so.1, libGLESv2.so.2, libgbm.so.1, libvulkan.so.1, libwayland-client.so.0, libwayland-cursor.so.0, libwayland-egl.so.1（均为 SDL2 动态加载探针，非硬链接）

---

*生成：software-engineer / 仅只读分析，未改动任何源码或脚本。*
