# wiliwili for PortMaster (aarch64)

本文件夹提供一套 **GitHub Actions 自动编译 wiliwili aarch64 二进制并打包成 PortMaster 安装包** 的构建文件。

> 适用对象：wiliwili（跨平台 Bilibili 客户端，C++17，依赖 mpv / webp / GLFW / OpenGL）。
> 目标平台：PortMaster 掌机（aarch64，运行时由掌机自带的 Mesa / Panfrost 提供 GLES / EGL）。

## 目录结构

```
wiliwili_for_aarch64/
├── .github/
│   └── workflows/
│       └── build.yml                # GitHub Actions 工作流
├── recipes/
│   └── ports/
│       └── wiliwili/
│           ├── build.sh             # 容器内编译脚本（apt 装 mpv + 编译 + 打包 .so）
│           ├── wiliwili.sh          # PortMaster 启动器
│           ├── recipe.json          # PortMaster 构建配方元数据
│           └── port.json            # PortMaster 端口元数据
└── README.md                        # 本说明
```

## 构建原理

- 仅编译 aarch64，使用原生 ARM runner `ubuntu-24.04-arm`，通过 `docker run` 拉起已发布的
  `ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest` 镜像（**零 QEMU 仿真**）。
- 子模块随源码由 CI 在 runner 上 `git clone --recursive` 一并拉取（默认 `xfangfang/wiliwili` 仓库的 `master` 分支及其子模块）；若指定的 `WILIWILI_REF` 非 `master`，CI 会先 checkout 该版本再 `submodule update --init --recursive`，随后整份源码挂载进容器编译。
- 容器内仅 `apt-get install -y libmpv-dev`（0.32），镜像内已具备 webp / gl / egl / openssl / zlib / gcc / cmake。
- 图形后端保持默认 OpenGL / GLFW；掌机侧由 Mesa / Panfrost 落地 GLES / EGL，编译端无需额外开关。

## 使用方式

本仓库现已**自包含**：它只含 CI 构建文件（`.github/` 与 `recipes/`），**不含 wiliwili 源码**。
工作流在运行时由 CI 自动 clone 官方 wiliwili 源码（含子模块）到 `src/`，再挂载进容器编译打包，
因此**无需再把 `.github/` 与 `recipes/` 合并进 wiliwili 源码仓**即可跑。

- **手动触发**：在本仓库 Actions 页面点击 `Build wiliwili (aarch64)` 工作流的 `Run workflow`（即 `workflow_dispatch`）。
- **自动发布**：推送 `v*` 形式的 tag（例如 `v1.0.0`）时，工作流会自动编译并发布 Release。

### 指定源码仓库与版本

默认会拉取 `xfangfang/wiliwili@master`。若想换成你自己的 fork、或指定某个 tag / commit，有两种方式：

1. **（推荐）通过仓库 Variables 覆盖**：在本仓库 `Settings → Secrets and variables → Actions → Variables` 中新建：
   - `WILIWILI_REPO`：源码仓库地址（例如 `https://github.com/<your-name>/wiliwili.git`）。
   - `WILIWILI_REF`：分支 / tag / commit（例如 `v1.4.0` 或 `a1b2c3d`；默认 `master`）。
2. **直接编辑 `build.yml`**：修改顶层 `env` 中的 `WILIWILI_REPO` / `WILIWILI_REF`。

> 注意：当 `WILIWILI_REF` 非 `master` 时，CI 会先 checkout 该版本，再 `submodule update --init --recursive` 重新拉取子模块。

## 触发方式

- **手动触发**：在仓库 Actions 页面点击 `Build wiliwili (aarch64)` 工作流的 `Run workflow`（即 `workflow_dispatch`）。
- **自动发布**：推送 `v*` 形式的 tag（例如 `v1.0.0`）时，工作流会自动编译并发布 Release。

## 产物

工作流分三个 job 串联执行：

| Job | 产物 | 说明 |
| --- | --- | --- |
| `build` | `wiliwili-linux-aarch64.tar.gz` | 编译出的 aarch64 二进制 + `resources/` + `libs.aarch64/`（自带运行时 .so，已排除 glibc 核心库） |
| `package` | `wiliwili.zip` | PortMaster 端口包：含 wiliwili 二进制 + resources + libs.aarch64 + `port.json` + `wiliwili.sh` |
| `release` | Release 附件 | 仅当推送 `v*` tag 时，将 `wiliwili.zip` 发布到 GitHub Release |

`wiliwili.zip` 内部布局约定为：

```
wiliwili/
├── wiliwili            # 二进制
├── resources/          # 资源
├── libs.aarch64/       # 运行时 .so
├── port.json           # 端口元数据
└── wiliwili.sh         # 启动器（已 chmod +x）
```

## 前提条件

- 仓库需开启 GitHub Actions。
- 公开仓库默认可用 `ubuntu-24.04-arm` 原生 ARM runner；私有仓库可能需付费计划，否则需回退到
  `ubuntu-latest` + `docker/setup-qemu-action` 做 ARM 仿真（速度明显更慢）。

## 已知风险与注意点

1. **mpv 版本**：容器内 `apt install libmpv-dev` 给出的是 **mpv 0.32**。wiliwili 官方 Switch 构建使用 mpv 0.36。
   若编译报错缺少 `mpv_render_*` 等新 API，需要改用自建 Dockerfile 安装 mpv 0.36（可基于该镜像二次构建）。
   运行时真正依赖的是 **目标掌机自己的 libmpv**，因此打包进 `libs.aarch64` 的 .so 仅供参考/兜底。
2. **port.json 字段**：`port.json` 的字段（title / desc / exec / image / category / method / author）需按
   目标 PortMaster 版本规范核对；不同 PortMaster 版本字段可能略有差异。
3. **图标文件**：`port.json` 引用的 `wiliwili.png` 图标已包含在仓库
   `recipes/ports/wiliwili/wiliwili.png`，CI 打包时会自动拷入端口根目录
   `ports/wiliwili/wiliwili.png`（与 `port.json` 同级），无需另行提供。
4. **GLFW 由子模块内置（无需系统 `libglfw3-dev`）**：wiliwili 默认 `USE_SYSTEM_GLFW=OFF`
   （见仓库 `CMakeLists.txt` 第 45 行），桌面版使用的是 **borealis 子模块内置的修改版 GLFW**
   （源码来自 `library/borealis/library/lib/extern/glfw`，即 `xfangfang/glfw` fork）。
   该子模块会随源码在 CI 中经 `git clone --recursive` 一并拉取，编译时由 borealis 的
   toolchain 从源码构建。因此 `build.sh` 的 `apt-get install` **不需要** `libglfw3-dev`；
   已安装的 `libx11-dev / libxrandr-dev / libxinerama-dev / libxcursor-dev / libxi-dev` 以及
   `libgl1-mesa-dev / libegl1-mesa-dev / libgles2-mesa-dev` 已足够让内置 GLFW 完成编译。
   仅当你显式 `-DUSE_SYSTEM_GLFW=ON` 时才需改为安装系统 `libglfw3-dev`（官方不推荐）。

## 校验

构建文件已做基本校验：

- `build.sh` / `wiliwili.sh` 通过 `bash -n` 语法检查。
- `recipe.json` / `port.json` 为合法 JSON。
