# PACKAGING_NOTES.md — wiliwili (aarch64) 打包方式说明

> 适用范围：本仓库的 wiliwili aarch64 PortMaster 移植。记录**维护版（当前 CI 构建）**的打包流程，
> 以及历史手工版 **wiliwili153** 的打包形态与二者差异。
> 关联文档：`LIBS_REQUIRED.md`（运行时库依赖闭包分析）。

## 1. 概述

- wiliwili：跨平台 Bilibili 客户端，aarch64 移植，通过 **PortMaster** 分发到 ROCKNIX 等设备。
- 存在两种打包形态：
  - **维护版（当前）**：由 `recipes/ports/wiliwili/` 下的 `build.sh` + `recipe.json` + `port.json` + `wiliwili.sh` 定义，CI 构建产出 `wiliwili-linux-aarch64.tar.gz`。
  - **历史手工版 wiliwili153**：本地 `wiliwili-portmaster/wiliwili153版/`，早期手工打包，布局与维护版不同（见 §4）。

## 2. 维护版打包流程（build.sh）

1. **源码**：wiliwili 上游仓库（默认分支 `master`，可用 `WILIWILI_REF` 指定），含 submodule，`git submodule update --init --recursive`。
2. **构建镜像**：`portmaster-builder:aarch64-latest`（自带 `aarch64-linux-gnu` 工具链，不引用外部 SDK/sysroot）。
   - 编译参数（兼容多机型，避免 SIGILL）：`-march=armv8-a -mtune=cortex-a53`，关闭 LTO。
   - CMake：`PLATFORM_DESKTOP=ON`、`Release`、`-Wl,--gc-sections -Wl,--as-needed`。
3. **可选 mpv 源码构建**：仅当 `BUILD_MPV_FROM_SRC` 为真时，从源码构建 ffmpeg 6 + mpv 0.36 覆盖 apt 的 mpv 0.32；默认跳过（沿用 apt 0.32 + ffmpeg 4.2）。
4. **产物收集**：`cp build/wiliwili dist/wiliwili`、`strip`、`cp -r resources dist/resources`。
5. **依赖收集（核心策略）**：`is_core()` **反转版“系统已有库”排除清单**——
   - 命中排除清单（系统已提供，约 90+ soname：核心运行时、libwayland 全族、X11/xcb、SDL2、DRM、GLib/GTK/Pango/Cairo、声音、samba/heimdal、压缩/加密/系统基础、xkbcommon 等）→ **交系统，不打包**。
   - 其余（固件确实缺失、必须自带，约 192 个：libmpv + ffmpeg 全套 libav*/libpostproc/libsw*、samba/heimdal/krb5、OpenSSL1.1、libffi、libpcre 等）→ **打包进 `libs/`**。
   - **Mesa GL 栈特例**：系统 `/usr/lib/libGL.so.1` 在实机 ROCKNIX 上**损坏**（`file too short`），故维护版**自带** `libGL/libGLX/libGLdispatch/libEGL/libgbm`；真正的 GL 实现（`libEGL_mesa.so.0`/`libGLX_mesa.so.0` + 系统较新 `libdrm`）仍由系统提供。
   - 递归 `ldd` 收集传递依赖进 `dist/libs`，并对每个非核心 NEEDED 做“已在 `libs/` 或交系统”的**构建自检**，缺非核心库则拒绝产出残包。
6. **rpath 双保险**：`patchelf --set-rpath '$ORIGIN/libs' dist/wiliwili`（无 patchelf 时退回 `LD_LIBRARY_PATH` 方案）。
7. **产出**：`tar -czf /workspace/wiliwili-linux-aarch64.tar.gz -C dist .`。
8. **PortMaster 元数据**：
   - `port.json`：`title=wiliwili`、`exec=wiliwili.sh`、`method=aarch64`、`category=Utilities`、`author=Windstarry`。
   - `recipe.json`：`name=wiliwili.zip`、`date_updated=2026-07-19`。

## 3. 维护版启动器（wiliwili.sh）

- 解析脚本绝对路径（处理软链接），兼容**扁平 / 嵌套**两种目录布局，兼容 `libs` 与 `libs.aarch64` 命名。
- 设置运行时库搜索路径：`LD_LIBRARY_PATH="$BIN_DIR/libs:$BIN_DIR/libs.aarch64:$LD_LIBRARY_PATH"`。
- **DRI 驱动（本次无图像 Bug 的修复点）**：
  ```bash
  export LIBGL_DRIVERS_PATH="/usr/lib/dri"
  export MESA_DRIVERS_PATH="/usr/lib/dri"
  ```
  使自打包 Mesa 客户端栈指向系统 DRI 驱动（`rockchip_dri` / `panfrost_dri` / `kms_swrast_dri` / `swrast_dri` 等），
  否则 EGL 报 “No EGL drivers found” / “failed to create dri2 screen” → 无渲染面 → 无图像。
- `cd "$BIN_DIR"`；日志重定向 `exec >> "$BIN_DIR/log" 2>&1`；`exec ./"wiliwili" "$@"`。

## 4. wiliwili153 历史手工版打包（wiliwili153版/）

目录布局：
```
wiliwili153版/
├── wiliwili153版.sh            # 启动器
└── wiliwili/
    ├── wiliwili                # 二进制
    ├── lib/                    # 注意：lib/ 而非 libs/
    ├── resources/
    ├── .cache/  .config/       # 运行时配置（随包携带）
```

启动器 `wiliwili153版.sh` 要点：
```sh
#!/bin/sh
progdir=`dirname "$0"`
GAMEDIR="/roms/ports/wiliwili"          # 硬编码目标路径
if [ -f "$GAMEDIR/wiliwili" ]; then
  cd $GAMEDIR
  DBUS_FATAL_WARNINGS=0 HOME=./ LD_LIBRARY_PATH="lib:$LD_LIBRARY_PATH" \
    SDL_GAMECONTROLLERCONFIG_FILE="<gamecontrollerdb>" ./wiliwili
fi
```
- 库目录名为 **`lib/`**（维护版为 `libs/`）。
- 设 `HOME=./` 实现**便携配置**（配置写入端口目录）；维护版用 `exec >> log` 记录日志。
- 设 `SDL_GAMECONTROLLERCONFIG_FILE` 指向手柄映射数据库（设备 `/storage/.config/SDL-GameControllerDB/` 或 `/opt/inttools/`）。
- **不含** `LIBGL_DRIVERS_PATH` / `MESA_DRIVERS_PATH` → 依赖系统 Mesa/DRI。在系统 `libGL.so.1` 损坏的设备上会失败；维护版改用“自带 Mesa + 显式 DRI 路径”修复。
- 硬编码 `GAMEDIR`；维护版动态解析脚本路径以兼容多布局。
- 纯 `LD_LIBRARY_PATH`，无 `patchelf`/`rpath`。

**适用场景**：早期/手工打包，适合系统 GL 完好的环境；维护版是针对“实机无图像”Bug 的演进形态。

## 5. 分发与安装

- PortMaster 端口以 zip / tar.gz 形式分发（仓库内 `wiliwili.zip` / `wiliwili-portmaster.zip` 为打包产物样例）。
- 安装到设备 `/roms/ports/wiliwili`，由 PortMaster 调用 `wiliwili.sh` 启动。
- **行尾注意（与 CRLF 修复关联）**：端口脚本必须以 **LF** 行尾入库（仓库已新增 `.gitattributes`：`*.sh text eol=lf`），
  否则 Windows `core.autocrlf=true` 在 `git checkout` 时把 LF 转 CRLF，导致 Linux 设备 `bash` 拒绝执行（无图像/不启动）。
  若以**预打包 zip** 分发，zip 须从含 `.gitattributes` 的仓库重新生成，否则 zip 内仍可能带 CRLF。

## 6. 备注

- 大体积二进制 / `libs/` 暂**不入库**（待确认），分析所用工件取自本地 `wiliwili-portmaster/wiliwili/wiliwili/`。
- 依赖闭包与缺失库核对见 `LIBS_REQUIRED.md`；当前唯一标记项 `libxcb-shape.so.0`（由系统提供）不影响实机可用性，建议补入 `is_core()` 排除清单。
