#!/bin/bash
# wiliwili TrimUi / 吹米 PortMaster 启动器（扁平布局）
# 端口根目录直接含：wiliwili 二进制、libs.aarch64/（运行时库）、resources/、config.json、icon.png

# 1. 解析脚本真实绝对路径（处理软链接）
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# 2. 设置运行时库搜索路径：优先 libs.aarch64，同时兼容保留的 libs 目录
export LD_LIBRARY_PATH="$SCRIPT_DIR/libs.aarch64:$SCRIPT_DIR/libs:$LD_LIBRARY_PATH"

# 3. 切换到脚本所在目录（扁平布局，二进制就在同目录）
cd "$SCRIPT_DIR"

# 4. 记录运行日志，便于排错
> "$SCRIPT_DIR/log.txt" && exec > >(tee "$SCRIPT_DIR/log.txt") 2>&1

exec ./wiliwili
