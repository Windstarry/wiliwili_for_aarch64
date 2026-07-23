# wiliwili for PortMaster (aarch64)

本仓库提供一套 **GitHub Actions 自动编译 wiliwili aarch64 二进制并打包成 PortMaster 安装包** 的构建文件，支持两种掌机固件的构建与打包。

> 适用对象：wiliwili（跨平台 Bilibili 客户端，C++17，依赖 mpv / webp / GLFW / OpenGL）。
> 目标平台：PortMaster 掌机（aarch64，运行时由掌机自带的 Mesa / Panfrost 或厂商 GLES 提供 GLES / EGL）。

## 支持的固件目标

| target | 固件 / 芯片 | 运行器 | 构建方式 | 端口布局 |
| --- | --- | --- | --- | --- |
| `rocknix` | RockNIX / Mali-G31 | `ubuntu-24.04-arm` | Docker 镜像内编译（WILIWILI_REF=`yoga` + 自建 mpv） | PortMaster 嵌套布局 |
| `tg5040` | TrimUi TG5040 / Allwinner A133P + PowerVR GE8300 | `ubuntu-latest` | 原生交叉编译（Linaro 工具链 + TrimUi SDK sysroot） | TrimUi 原生扁平布局 |

- **RockNIX 路径**：纯系统 GLES，mpv 以 HOST-CONTEXT 渲染，`plain-gl` 启用 + `egl` 关闭，libplacebo 剥离 GLVND `libGLdispatch`。
- **TrimUi 路径**：钉死源码版本 `WILIWILI_REF_TG5040=88e5876bea9502d06f46a8656e3530684d3aaf7d`，自带 `SDL2-2.26.1.GE8300` 与厂商字体 `trimui.ttf`，同为 GLES-only、无 GLVND。

## 目录结构

```
wiliwili_for_aarch64/
├── .github/
│   └── workflows/
│       └── build.yml                # GitHub Actions 工作流（含 target / release_tag 输入）
├── recipes/
│   └── ports/
│       └── wiliwili/
│           ├── build.sh             # 编译脚本：TARGET=rocknix(默认)/tg5040 双路径
│           ├── wiliwili.sh          # RockNIX (PortMaster 嵌套) 启动器
│           ├── port.json            # RockNIX 端口元数据
│           ├── wiliwili.png         # RockNIX 端口图标
│           ├── config.json          # TrimUi 扁平端口元数据
│           ├── launch.sh            # TrimUi 扁平端口启动器
│           ├── icon.png             # TrimUi 扁平端口图标
│           ├── trimui.ttf           # TrimUi 厂商字体（字体替换）
│           ├── trimui.cmake / trimui.ini  # TrimUi 交叉编译工具链配置
│           ├── SDL2-2.26.1.GE8300.tgz    # TrimUi 自带 SDL2（PowerVR GE8300）
│           ├── cmake/ include/ patches/  # 构建依赖与补丁
│           ├── recipe.json          # PortMaster 构建配方元数据
│           └── qa_*.sh / verify_*.sh / diag_segfault.sh  # 校验 / 诊断辅助脚本
└── README.md                        # 本说明
```

## 构建原理

- 仓库**自包含**：仅含 CI 构建文件（`.github/` 与 `recipes/`），**不含 wiliwili 源码**。工作流运行时由 CI 自动 clone 官方源码（含子模块）到 `src/`，再编译打包。
- 单一分支 `main`，通过 `workflow_dispatch` 的 `target` 输入选择构建目标；`strategy.matrix` 为两个固件各起一个 job 实例（不同 runner），各自 clone / 编译 / 打包，互不影响目录。
- **RockNIX（嵌套布局）**：`ubuntu-24.04-arm` 原生 ARM runner，`docker run` 拉起 `ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest`，设 `WILIWILI_REF=yoga`、`BUILD_MPV_FROM_SRC=on`。
- **TrimUi TG5040（扁平布局）**：`ubuntu-latest` runner，`sudo env TARGET=tg5040 bash build.sh aarch64` 走 Linaro 交叉工具链 + TrimUi SDK sysroot，`WILIWILI_REF_TG5040` 钉死源码版本。
- 子模块随源码由 CI 在 runner 上 `git clone --recursive` 一并拉取；CI 会无条件按目标版本 checkout 并 `submodule update --init --recursive`。
- 图形后端保持默认 OpenGL / GLFW；掌机侧由厂商 GLES 落地，编译端无需额外开关。

## 触发方式

- **手动触发**：在仓库 **Actions → `Build wiliwili (aarch64)` → Run workflow**（即 `workflow_dispatch`）。输入项：
  - `target`：`both`（默认，两固件都构建）/ `rocknix` / `tg5040`。
  - `release_tag`：留空 → 发布覆盖式 `nightly` prerelease；填 `v1.0.0` 这类 → 发布同名正式 Release。
- **重要**：`on:` 仅 `workflow_dispatch`，**没有** push 自动触发。每次构建都必须用顶部 **Run workflow** 按钮全新触发（勿用失败任务的 Re-run，否则复用旧 SHA、不拾取新提交）。

### 指定源码仓库与版本

默认拉取 `Windstarry/wiliwili@yoga`。覆盖方式：

1. **（推荐）Variables 覆盖**：`Settings → Secrets and variables → Actions → Variables` 新建 `WILIWILI_REPO` / `WILIWILI_REF`（rocknix）或 `WILIWILI_REF_TG5040`（tg5040）。
2. **直接编辑 `build.yml`**：修改顶层 `env`。

> 注意：CI 会无条件按目标 REF checkout 并递归更新子模块（无论 master / yoga / tag / commit 都精确生效）。

## 产物

工作流分两个 job：

| Job | 固件 | 产物 | 说明 |
| --- | --- | --- | --- |
| `build` | rocknix | `wiliwili-rocknix.zip` | PortMaster 嵌套端口包（内层 `wiliwili/` 含二进制 + resources + libs + port.json + wiliwili.sh + wiliwili.png） |
| `build` | tg5040 | `wiliwili-tg5040.zip` | TrimUi 原生扁平端口包（根含 `wiliwili` 二进制 + resources + libs.aarch64 + libs + config.json + icon.png + launch.sh） |
| `release` | 二者 | GitHub Release 附件 | 仅 `workflow_dispatch` 触发；按 `release_tag` 发布 nightly 或正式版 |

### 端口包内部布局

**RockNIX（嵌套）`wiliwili-rocknix.zip`：**

```
wiliwili/                      # 端口根（PortMaster 识别）
└── wiliwili/                  # 内层目录
    ├── wiliwili              # 二进制
    ├── resources/            # 资源
    ├── libs/                 # 运行时 .so（libmpv 及全部传递依赖，已排除 glibc 核心库）
    ├── port.json             # 端口元数据
    ├── wiliwili.sh           # 启动器（已 chmod +x）
    └── wiliwili.png          # 图标
```

**TrimUi TG5040（扁平）`wiliwili-tg5040.zip`：**

```
wiliwili/                      # 端口根（TrimUi 扁平布局，端口根直接含内容）
├── wiliwili                  # 二进制
├── resources/                # 资源
├── libs.aarch64/             # PowerVR GE8300 运行时 .so（主）
├── libs/                     # libs.aarch64 的副本，兼容个别固件
├── config.json               # 扁平端口元数据（label/icon/launch/description）
├── icon.png                  # 图标
└── launch.sh                 # 启动器（已 chmod +x）
```

> RockNIX 与 TrimUi 的 **`libs/`** 均自带完整运行时（libmpv 及全部传递依赖），启动器通过 `LD_LIBRARY_PATH` 指向它，不依赖掌机系统库。

## 前提条件

- 仓库需开启 GitHub Actions。
- RockNIX job 使用公开仓库默认可用的 `ubuntu-24.04-arm` 原生 ARM runner；TrimUi job 使用 `ubuntu-latest`（x86）原生交叉编译，无需 QEMU。

## 已知风险与注意点

1. **mpv 版本**：RockNIX 路径 `BUILD_MPV_FROM_SRC=on` 在容器内自建 mpv；若编译报缺少 `mpv_render_*` 等新 API，需核对 mpv 版本。CI 会把 libmpv 及其全部传递依赖打包进 `libs/`，启动器 `wiliwili.sh` / `launch.sh` 通过 `LD_LIBRARY_PATH` 指向它。依赖收集对 `libmpv.so.*` 版本无关。
2. **port.json / config.json 字段**：需按目标 PortMaster / TrimUi 版本规范核对；不同版本字段可能略有差异。
3. **图标文件**：RockNIX 用 `recipes/ports/wiliwili/wiliwili.png`（嵌套布局 `wiliwili/wiliwili.png`）；TrimUi 用 `recipes/ports/wiliwili/icon.png`（扁平布局 `wiliwili/icon.png`）。CI 打包时自动拷入对应端口根目录，无需另行提供。
4. **GLFW 由子模块内置（无需系统 `libglfw3-dev`）**：wiliwili 默认 `USE_SYSTEM_GLFW=OFF`，桌面版使用 borealis 子模块内置的修改版 GLFW。该子模块随源码在 CI 中 `git clone --recursive` 一并拉取，编译时由 borealis toolchain 从源码构建。
5. **双固件 CI 表达式陷阱**：`matrix` 仅能在 **step 级 `if`** 中使用，**不能**写在 job 级 `if`（解析时 matrix 尚未定义，报 `Unrecognized named-value: 'matrix'`）。Upload 步骤用 `github.event.inputs.target == 'both' || github.event.inputs.target == matrix.target`；Clone / Build / Assemble 直接用 `matrix.target == 'X'`（若写成 `both || ...` 会让同 job 内另一固件也跑 clone，撞 `src` 目录导致 `destination path 'src' already exists`）。

## 校验

构建文件已做基本校验：

- `build.sh` / `wiliwili.sh` / `launch.sh` 通过 `bash -n` 语法检查。
- `recipe.json` / `port.json` / `config.json` 为合法 JSON。
- CI 产物经逻辑回归校验（YAML 合法、双布局模拟、release 撞名修复、启动器可执行）。
- 注意：`pyyaml` 仅校验 YAML 语法，**不校验** GitHub Actions 表达式上下文语义（如 `matrix` 作用域）；表达式错误需 `actionlint` 或真实 CI 运行才能暴露。
