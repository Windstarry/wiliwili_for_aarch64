# GL_HARDLINK_CHECK.md — 我们“无图 build”快照：打包库是否硬链接 libGL/EGL/gbm

> 目的：决定“把 5 个 Mesa GL 客户端库从打包改回系统库（revert 2baf746）”是否安全。核心风险：若我们打包的库硬链接 `libGL.so.1`，移除打包的 Mesa libGL 后，加载器会回退到设备损坏的系统 `libGL.so.1`（file too short）→ 启动崩溃（BugFix #5 的坑）。
> 结论先行：**全量 revert 2baf746 不安全；只把 `libEGL.so.1` + `libgbm.so.1` 改回系统库（保留 `libGL.so.1`/`libGLX.so.0`/`libGLdispatch.so.0` 打包）才是安全修复。**

---

## 1. 方法与对象

- **Docker 镜像**：`ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest`
- **工具**：`aarch64-linux-gnu-readelf -dW <lib> | grep -i needed`（镜像内无 `aarch64-linux-gnu-ldd` / `qemu-aarch64`）
- **对象**：本地快照 `wiliwili-portmaster/wiliwili/wiliwili/libs/`（96+ 个 `.so`，含我们“无图 build”打进来的 5 个 Mesa GL 客户端库）
- **判定**：对 libs/ 下每个 `*.so*`，列出其 `DT_NEEDED`，并判定是否命中 `libGL.so*` / `libGLX*` / `libGLdispatch*` / `libEGL.so*` / `libgbm.so*` / `libGLESv2.so*` / `libGLESv1*`。区分“硬链接 DT_NEEDED（危险）”与“仅二进制 .rodata 里的 SDL2 dlopen 候选字符串（无害，wiliwili160 就是这种）”。

---

## 2. 全量扫描：哪些打包库硬链接 GL/EGL/gbm

逐库扫描全部 `.so`，**仅以下命中 GL/EGL/gbm 硬链接**：

| 库 | DT_NEEDED 中的 GL/EGL/gbm | 性质 |
|----|--------------------------|------|
| `libEGL.so.1` | `libGLdispatch.so.0` | Mesa 内部依赖 |
| `libGL.so.1` | `libGLdispatch.so.0`, `libGLX.so.0` | Mesa 内部依赖 |
| `libGLX.so.0` | `libGLdispatch.so.0` | Mesa 内部依赖 |
| **`libavdevice.so.58`** | **`libGL.so.1`** | ⚠ 业务库硬链接 libGL |
| **`libmpv.so.1`** | **`libEGL.so.1`, `libgbm.so.1`, `libGL.so.1`** | ⚠ 业务库硬链接全部三者 |

> 其余所有打包库（`libva.so.2` / `libva-drm.so.2` / `libva-wayland.so.2` / `libva-x11.so.2`、`libavcodec.so.58` / `libavutil.so.56` / `libavformat.so.58` / `libavfilter.so.7`、`libswscale.so.5` / `libswresample.so.3`、`libOpenCL.so.1`、以及全部 samba/kerb/flite/x264 等）均 **clean（无 GL/EGL/gbm 硬链接）**。

---

## 3. 关键判定（直接回答 lead 的问题）

- **谁硬链接 `libGL.so.1`？** → 我们打包的 **`libmpv.so.1`** 和 **`libavdevice.so.58`**（两个都是打包库）。
- **谁硬链接 `libEGL.so.1`？** → 仅 **`libmpv.so.1`**（外加 `libEGL` 自身依赖 `libGLdispatch`）。
- **谁硬链接 `libgbm.so.1`？** → 仅 **`libmpv.so.1`**。
- `libva-*` 与 ffmpeg 核心库（avcodec / avutil / avformat / avfilter）**均不**硬链接 GL/EGL/gbm。
- libs/ 中**不含** `libSDL2-2.0.so.0`（系统提供，与 wiliwili160 一致）、不含 `libplacebo` / `libvulkan` / `libGLX_mesa` / `libEGL_mesa`。

---

## 4. 移除打包 Mesa GL 是否安全？→ 全量 revert 不安全；部分 revert 安全

### ❌ 全量 revert 2baf746（把 5 个 Mesa GL 客户端库全部改回系统库）：**不安全**
- 原因：`libmpv.so.1` 与 `libavdevice.so.58` 都硬链接 `libGL.so.1`。一旦打包的 Mesa `libGL` 被移除，加载器在 `LD_LIBRARY_PATH`（libs/）找不到 `libGL.so.1`，回退到系统 `/usr/lib/libGL.so.1`——已知 **file too short 损坏** → **启动即加载失败崩溃**（正是 BugFix #5 要避的坑）。

### ✅ 部分 revert（安全、推荐）：只把 `libEGL.so.1` 与 `libgbm.so.1` 改回系统库，保留 `libGL.so.1` + `libGLX.so.0` + `libGLdispatch.so.0` 打包
- `libEGL.so.1` / `libgbm.so.1` 改走系统 Mali DDK（设备 Mali 提供**可用**的 libEGL/libgbm）→ SDL2/EGL 表面由 Mali 渲染 → **修复 no-image 根因**（之前打包的 Mesa libEGL 遮蔽了 Mali，Mesa 无法在 Mali 上渲染）。
- `libGL.so.1`（+ `libGLX.so.0` + `libGLdispatch.so.0`）仍打包（Mesa GL 客户端栈）→ `libmpv` / `libavdevice` 的硬链接 `libGL` 解析到**有效的打包 Mesa libGL**，不触发损坏的系统 libGL → **不崩溃**。
- `libmpv` 硬链接的 `libEGL` / `libgbm` 此刻回退到系统 Mali（有效）→ 正常。

> 一句话：**保留 Mesa 的 `libGL/libGLX/libGLdispatch`（喂 mpv/libavdevice 的硬链接，避开损坏系统 libGL），移除 Mesa 的 `libEGL/libgbm`（让 SDL2 用系统 Mali 出图）。** 这样既不出崩溃，又能出图。

---

## 5. 修复建议（待 lead 批准后再改 build.sh；此处仅只读分析）

在 `build.sh` 的 `is_core()` / 打包逻辑中：
1. 将 `libEGL.so.1`、`libgbm.so.1` 从“强制打包”改为“系统库（`is_core` 排除）”。
2. 保持 `libGL.so.1`、`libGLX.so.0`、`libGLdispatch.so.0` **打包**（Mesa GL 客户端栈，供给 mpv/libavdevice 的硬链接）。
3. `libOpenCL.so.1`（clean，无 GL 硬链接）与 `libva-*` 维持现状。
4. **不要整段 revert 2baf746**；只回退 EGL / gbm 两项。

---

## 6. 更干净的长期方案（非本次最小修复）

wiliwili160 的 `libmpv.so.2` **不硬链接** `libGL`/`libEGL`/`libgbm`（全走 SDL2 运行时 `dlopen` 系统 Mali）。若我们重构 `libmpv` 链接（去掉对 `libGL` 的硬链接，改由 SDL2 `dlopen`），则整套 Mesa GL 客户端库都可不再打包，彻底与 160 对齐。但这是构建 / CI 改动，非快速打包 revert，留作后续。

---

## 附录 A：libmpv.so.1 的 GL 相关 NEEDED（节选）
```
libEGL.so.1      ← 硬链接
libgbm.so.1      ← 硬链接
libGL.so.1       ← 硬链接
```
（其余为 libav*/libSDL2/libX11/libwayland*/libva*/libdrm 等，完整见 `_named_full.txt`）

## 附录 B：libavdevice.so.58 的 GL 相关 NEEDED（节选）
```
libGL.so.1       ← 硬链接
```
（其余为 libav*/libxcb*/libcdio/jack/libSDL2/libopenal 等）

## 附录 C：libva-* / ffmpeg 核心库（clean 证据）
- `libva.so.2` / `libva-drm.so.2` / `libva-wayland.so.2` / `libva-x11.so.2`：仅依赖 libva/drm/wayland-client/X11 等，**无 GL**。
- `libavcodec.so.58` / `libavutil.so.56` / `libavformat.so.58` / `libavfilter.so.7`：**无 GL/EGL/gbm**（仅 `libOpenCL.so.1` 被 avutil/avfilter 链接，非 GL）。

---

*生成：software-engineer / 仅只读分析，未改动任何源码或脚本。原始扫描见同目录 `_gl_check.txt`（全量硬链接扫描）与 `_named_full.txt`（命名库完整 NEEDED）。*
