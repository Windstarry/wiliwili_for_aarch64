#!/bin/bash
# diag_segfault.sh — wiliwili aarch64 实机 SIGSEGV 一键诊断脚本
#
# 用途：辅助定位 commit fdb4988 / legacy(gl=disabled) 在 RockNIX+Mali 掌机上
#       “跨过 pre-main 构造期后，SDL2 视频子系统创建/GL 上下文阶段 SIGSEGV”
#       的真根因（领先假设 H2a 已用 SDL_VIDEODRIVER=kmsdrm 绕过 wayland 坏库，
#       新崩在 kmsdrm / SDL2 视频初始化阶段）。
#
# 安全约定：
#   - 仅 set -u（不做 set -e，避免 grep 无匹配等正常非零退出误杀流程）；
#   - 所有外部命令均做存在性判断，缺失不硬崩；
#   - 纯诊断，不修改任何文件，不进 PortMaster 打包 tar。
#
# 用法（在 wiliwili 二进制同级目录执行）：
#   bash diag_segfault.sh 2>&1 | tee diag_out.txt
# 然后把 diag_out.txt 全文贴回分析。

set -u

# --- 定位脚本与二进制目录（兼容扁平/嵌套两种布局，同 wiliwili.sh）---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/wiliwili/wiliwili" ]; then
  BIN_DIR="$SCRIPT_DIR/wiliwili"
else
  BIN_DIR="$SCRIPT_DIR"
fi
BIN="$BIN_DIR/wiliwili"

echo "=================================================="
echo " wiliwili 实机 SIGSEGV 诊断脚本"
echo " 脚本目录  : $SCRIPT_DIR"
echo " 二进制目录: $BIN_DIR"
echo " 二进制     : $BIN"
echo "=================================================="

# --- 复刻启动器的 LD_LIBRARY_PATH，确保能加载自打包 libs/ ---
export LD_LIBRARY_PATH="$BIN_DIR/libs:$BIN_DIR/libs.aarch64:$LD_LIBRARY_PATH"
cd "$BIN_DIR" || { echo "ERROR: 无法 cd 到 $BIN_DIR" >&2; exit 1; }

if [ ! -x "$BIN" ]; then
  echo "ERROR: 未找到可执行二进制 $BIN" >&2
  exit 1
fi

# ---------------------------------------------------------------
# 工具：带超时运行命令
#   优先用 timeout；缺失则手动后台运行 + 15s 后强杀。
#   返回：命令真实退出码（timeout/手动超时时为 124）。
# ---------------------------------------------------------------
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 "$@"
    return $?
  fi
  # 无 timeout：后台运行，15s 后强杀
  "$@" &
  local pid=$!
  local i=0
  while [ $i -lt 15 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid" 2>/dev/null
  return $?
}

# ---------------------------------------------------------------
# 工具：设置 SDL2 verbose 日志
#   SDL >= 2.0.4 支持 SDL_LOG_PRIORITY_* 环境变量（优先）；
#   更老版本退化为 SDL_VIDEO_LOGGING=1；二者同时设置也无害。
# ---------------------------------------------------------------
set_sdl_verbose() {
  unset SDL_LOG_PRIORITY_VIDEO SDL_LOG_PRIORITY_ERROR SDL_LOG_PRIORITY_ALL SDL_VIDEO_LOGGING 2>/dev/null
  local ver=""
  if command -v sdl2-config >/dev/null 2>&1; then
    ver="$(sdl2-config --version 2>/dev/null)"
  fi
  if [ -n "$ver" ] && [ "$(printf '%s\n%s\n' "$ver" "2.0.4" | sort -V | head -n1)" = "2.0.4" ]; then
    export SDL_LOG_PRIORITY_VIDEO=verbose
    export SDL_LOG_PRIORITY_ERROR=verbose
    export SDL_LOG_PRIORITY_ALL=verbose
  else
    export SDL_VIDEO_LOGGING=1
  fi
}

# ===============================================================
# 1) 开场快照
# ===============================================================
echo
echo "########## [1/4] 设备关键快照 ##########"

echo "--- 关键环境变量 ---"
for v in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR SDL_VIDEODRIVER SDL_AUDIODRIVER \
         SDL_VIDEO_DRIVER SDL_RENDER_DRIVER LD_LIBRARY_PATH; do
  if [ -n "${!v:-}" ]; then
    echo "  $v=${!v}"
  else
    echo "  $v=(未设置)"
  fi
done

echo "--- uname -a ---"
uname -a 2>&1

echo "--- /proc/fb ---"
if [ -e /proc/fb ]; then
  cat /proc/fb
else
  echo "  (无 /proc/fb)"
fi

echo "--- /dev/dri ---"
if [ -d /dev/dri ]; then
  ls -l /dev/dri 2>&1
else
  echo "  (无 /dev/dri 目录)"
fi

echo "--- sdl2-config --version ---"
if command -v sdl2-config >/dev/null 2>&1; then
  sdl2-config --version
else
  echo "  (sdl2-config 不存在)"
fi

# ===============================================================
# 2) 三个 SDL 视频后端探针
# ===============================================================
echo
echo "########## [2/4] SDL 视频后端探针 (wayland / kmsdrm / x11) ##########"

run_probe() {
  local backend="${1:-}"
  echo
  echo "=== 探针后端: $backend ==="
  export SDL_VIDEODRIVER="$backend"
  set_sdl_verbose

  local out
  out="$(run_with_timeout "$BIN" 2>&1)"
  local rc=$?

  local desc
  case "$rc" in
    139) desc="SIGSEGV (信号 11, 退出码 139)" ;;
    134) desc="abort / SIGABRT (退出码 134)" ;;
    124) desc="超时 (timeout, 退出码 124)" ;;
    0)   desc="成功退出 (退出码 0)" ;;
    *)   desc="其它退出码 ($rc)" ;;
  esac

  local banner="否"
  echo "$out" | grep -qE 'wiliwili |Using platform SDL' && banner="是"
  local failinit="否"
  echo "$out" | grep -q 'sdl: failed to initialize' && failinit="是"

  echo "  退出码                       : $desc"
  echo "  打印版本横幅                 : $banner"
  echo "  出现 'sdl: failed to initialize' : $failinit"
  echo "  --- 该后端 wiliwili 输出尾部 (last 25 lines) ---"
  echo "$out" | tail -n 25 | sed 's/^/    /'
}

for backend in wayland kmsdrm x11; do
  run_probe "$backend"
done

# ===============================================================
# 3) gdb 活体回溯（kmsdrm 后端）
# ===============================================================
echo
echo "########## [3/4] gdb 活体回溯 (kmsdrm 后端) ##########"
if command -v gdb >/dev/null 2>&1; then
  echo "(检测到 gdb，运行 kmsdrm 后端抓取 SIGSEGV 栈)"
  export SDL_VIDEODRIVER=kmsdrm
  set_sdl_verbose
  gdb -batch -ex run -ex bt --args "$BIN" 2>&1 | tail -n 60
else
  echo "(未检测到 gdb)"
  if command -v catchsegv >/dev/null 2>&1; then
    echo "  提示: 可安装 gdb，或试 catchsegv:"
    echo "    catchsegv env SDL_VIDEODRIVER=kmsdrm $BIN"
  fi
  if command -v addr2line >/dev/null 2>&1; then
    echo "  提示: addr2line 可用，可配合 dmesg 的 ip 偏移定位（但本机 core_pattern=|/bin/false 无 core，活体 gdb 才是主路径）。"
  fi
  echo "  提示: 设备 core_pattern=|/bin/false 已禁用 core dump，请尽量在设备上安装 gdb 以拿到活体回溯。"
fi

# ===============================================================
# 4) ldd 快照
# ===============================================================
echo
echo "########## [4/4] ldd 快照 ##########"
echo "--- glibc 版本 (ldd --version) ---"
ldd --version 2>&1 | head -n 2

echo "--- ldd ./wiliwili (not found) ---"
ldd "$BIN" 2>&1 | grep -i 'not found' || echo "  (无 not found)"

echo "--- ldd libs/libmpv.so.* (not found) ---"
found_mpv=0
for f in "$BIN_DIR"/libs/libmpv.so.*; do
  [ -e "$f" ] || continue
  found_mpv=1
  echo "  $f:"
  ldd "$f" 2>&1 | grep -i 'not found' || echo "    (无 not found)"
done
[ "$found_mpv" -eq 0 ] && echo "  (未发现 libmpv.so.* ，跳过)"

# ===============================================================
# 结尾：请用户贴回 + 金标准对照要求
# ===============================================================
echo
echo "=================================================="
echo " 诊断完成。请将【以上完整输出】贴回分析。"
echo " 金标准对照要求：请同时贴出同机 wiliwili160 的"
echo "   wiliwili.sh 全文（它实机可出图，其 env 设置是"
echo "   我们修复的金标准参考）。"
echo "=================================================="
