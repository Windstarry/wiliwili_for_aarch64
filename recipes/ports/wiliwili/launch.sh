#!/bin/bash
# wiliwili PortMaster 启动器
# 兼容两种目录布局：
#   - 扁平（CI 产物）：脚本同目录直接含 wiliwili 二进制与 libs/ 或 libs.aarch64/
#   - 嵌套（手动解包）：wiliwili/ 子目录内含二进制与 libs.aarch64/
# 同时兼容 libs 与 libs.aarch64 命名，对 libmpv.so.* 版本无关。

# 1. 解析脚本真实绝对路径（处理软链接）
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# 2. 定位二进制所在目录（扁平或嵌套）
if [ -x "$SCRIPT_DIR/wiliwili/wiliwili" ]; then
  BIN_DIR="$SCRIPT_DIR/wiliwili"
else
  BIN_DIR="$SCRIPT_DIR"
fi

# 3. 设置运行时库搜索路径（libs 与 libs.aarch64 都尝试，对 libmpv 版本无关）
export LD_LIBRARY_PATH="$BIN_DIR/libs:$BIN_DIR/libs.aarch64:$LD_LIBRARY_PATH"

# 4. 切换到二进制目录
cd "$BIN_DIR"

# 5. 记录运行日志，便于排错
> "$BIN_DIR/log.txt" && exec > >(tee "$BIN_DIR/log.txt") 2>&1

./wiliwili
