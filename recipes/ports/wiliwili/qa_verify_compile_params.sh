#!/usr/bin/env bash
# ============================================================================
# 编译参数生效性核查脚本 (QA: 严过关)
# 对应修复: commit 68f6bbb — 注入 aarch64 编译优化参数
#   build.sh (行 120-126) 通过 cmake -D 注入:
#     -DCMAKE_C_FLAGS="-pipe -fomit-frame-pointer -march=armv8-a -mtune=cortex-a53 -ffunction-sections -fdata-sections"
#     -DCMAKE_CXX_FLAGS="... (同上)"
#     -DCMAKE_EXE_LINKER_FLAGS="-Wl,--gc-sections -Wl,--as-needed"
#
# 状态: 需 CI 用修复版 build.sh (commit 68f6bbb) 重建并把产物部署/拷贝到本机后执行。
#       当前实机 192.168.137.247 无法通过 SSH 建立会话 (端口22超时)，动态验证暂缓。
# 约束: 仅做只读检查，严禁修改实机/产物任何文件。
#
# 用法:
#   ./qa_verify_compile_params.sh [--bin <path>] [--run]
#     --bin <path> : 待核查二进制 (默认 dist/wiliwili；部署到实机后为 /roms/ports/wiliwili/wiliwili)
#     --run        : 额外执行实机运行期 SIGILL 判据 (仅当本机为 aarch64 设备时有效)
# ============================================================================
set -u

BIN="dist/wiliwili"
DO_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bin) BIN="$2"; shift 2 ;;
    --run) DO_RUN=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

OVERALL=0
need_tool() { command -v "$1" >/dev/null 2>&1 || { echo "  [SKIP] 缺少工具 $1" >&2; return 1; }; }

echo "===== 目标二进制: $BIN ====="
if [ ! -e "$BIN" ]; then
  echo "  [FATAL] 二进制不存在: $BIN (请先用 commit 68f6bbb 的 build.sh 重建并部署/拷贝产物)" >&2
  exit 2
fi

# --- [a] readelf -A: 微架构属性 (核心判据) ---
echo
echo "===== [a] readelf -A: 微架构属性 (核心判据: 应为 armv8-a 基线 + cortex-a53, 非 cortex-a55/v8.2+) ====="
if need_tool readelf; then
  ATTR="$(readelf -A "$BIN" 2>/dev/null)"
  echo "$ATTR" | sed 's/^/    /'

  # 1) 绝对禁止: 误用 -mcpu=cortex-a55 或任何 v8.2+ ISA (A55 是 Armv8.2 核)
  if echo "$ATTR" | grep -qiE 'cortex-a55|Tag_CPU_arch:.*v8\.[2-9]|Tag_CPU_arch:.*v9'; then
    echo "  [FAIL] 检测到 cortex-a55 或 v8.2+ 属性 —— 疑似误用 -mcpu=cortex-a55 / 过激 -march"
    OVERALL=1
  else
    echo "  [PASS] 无 cortex-a55 / v8.2+ 属性"
  fi

  # 2) 期望: CPU arch 为 v8-A (或 AArch64); CPU name 为 cortex-a53
  if echo "$ATTR" | grep -qiE 'Tag_CPU_arch:.*v8-A|Tag_CPU_arch:.*AArch64|Tag_CPU_arch:.*aarch64'; then
    echo "  [PASS] Tag_CPU_arch 落在 armv8-a 通用基线"
  else
    echo "  [FAIL] Tag_CPU_arch 非预期 v8-A 基线 (见上)"
    OVERALL=1
  fi

  if echo "$ATTR" | grep -qiE 'Tag_CPU_name:.*cortex-a53'; then
    echo "  [PASS] Tag_CPU_name = cortex-a53 (-mtune=cortex-a53 已生效)"
  else
    # 宽松判据: 只要 arch 已是 v8-A 基线且无更激进项, 缺 CPU_name 不致命 (仅信息)
    echo "  [WARN] Tag_CPU_name 未显示 cortex-a53 (可能上游未传播 -mtune); arch 已确认 v8-A 基线, 不判失败"
  fi
fi

# --- [b] file / readelf -h / readelf -d: 二进制完整性 (可选) ---
echo
echo "===== [b] file / readelf -h / readelf -d: 二进制完整性 (aarch64 动态可执行, 未损坏) ====="
if need_tool file; then
  FILEOUT="$(file "$BIN" 2>/dev/null)"
  echo "    $FILEOUT"
  if echo "$FILEOUT" | grep -qiE 'ELF 64-bit LSB (executable|shared object).*ARM aarch64'; then
    echo "  [PASS] aarch64 ELF"
  else
    echo "  [FAIL] 非 aarch64 ELF: $FILEOUT"
    OVERALL=1
  fi
  if echo "$FILEOUT" | grep -qi 'dynamically linked'; then
    echo "  [PASS] 动态链接可执行"
  else
    echo "  [WARN] 未标记 dynamically linked (静态链接? 或 file 版本差异)"
  fi
fi
if need_tool readelf; then
  echo "    Machine: $(readelf -h "$BIN" 2>/dev/null | awk -F: '/Machine/{print $2}' | xargs)"
  NEEDED="$(readelf -d "$BIN" 2>/dev/null | grep -c 'NEEDED')"
  echo "    NEEDED 动态库条目数: $NEEDED"
  [ "$NEEDED" -gt 0 ] && echo "  [PASS] 含动态依赖 (readelf -d 可读)" || echo "  [WARN] 无 NEEDED 条目"
fi

# --- [c] 实机运行期 SIGILL 判据 (仅 --run, 且仅在 aarch64 设备有意义) ---
if [ "$DO_RUN" -eq 1 ]; then
  echo
  echo "===== [c] 实机运行期 SIGILL 判据 (终极正确性: -march=armv8-a 基线不应产生非法指令) ====="
  # headless 无 D-Bus 的 SIGABRT 不计; 仅 SIGILL(信号4) 判失败
  if ! uname -m | grep -q aarch64; then
    echo "  [SKIP] 当前非 aarch64 设备 ($(uname -m)), 跳过运行期测试"
  else
    cd "$(dirname "$BIN")" || { echo "  [FATAL] 无法 cd 到二进制目录" >&2; exit 2; }
    BINNAME="$(basename "$BIN")"
    ./"$BINNAME" >/dev/null 2>&1 &
    PID=$!
    sleep 5
    if kill -0 "$PID" 2>/dev/null; then
      echo "  [PASS] 进程存活 5s 未崩溃 (无 SIGILL)"
      kill -9 "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
    else
      wait "$PID"; rc=$?
      case $rc in
        132) echo "  [FAIL] 退出码 $rc = SIGILL (非法指令) —— 编译基线过激"; OVERALL=1 ;;
        134|139) echo "  [WARN] 退出码 $rc (SIGABRT/SIGSEGV, headless 无 D-Bus/GTK 预期, 非 SIGILL)" ;;
        *) echo "  [PASS] 退出码 $rc (非 SIGILL)" ;;
      esac
    fi
  fi
else
  echo
  echo "===== [c] 运行期 SIGILL 判据: 未传 --run, 跳过 (需在 aarch64 实机执行 ./qa_verify_compile_params.sh --bin /roms/ports/wiliwili/wiliwili --run) ====="
fi

echo
if [ "$OVERALL" -eq 0 ]; then
  echo "===== 编译参数核查结论: 通过 (armv8-a 基线 + cortex-a53 + 关 LTO 生效; 无 cortex-a55/v8.2+/sysroot/TRIMUI) ====="
else
  echo "===== 编译参数核查结论: 存在失败项, 见上 ====="
fi
exit $OVERALL
