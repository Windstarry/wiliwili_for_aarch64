#!/bin/bash
# ============================================================================
#  实机验证脚本 —— wiliwili libwayland 符号缺失修复 (undefined symbol: wl_proxy_marshal_flags)
#
#  ⚠️ 需 CI 重建部署后执行 ⚠️
#  本脚本用于实机验证修复是否生效。当前（2026-07-20 09:44 部署）实机仍是旧产物，
#  直接运行仍会复现 bug；必须先由 CI 用修复后的 build.sh 重新构建并部署到
#  $DEPLOY_DIR（默认 /roms/ports/wiliwili）后再执行本脚本。
#
#  用法:
#    ./verify_libwayland_fix.sh [DEPLOY_DIR]
#  例如:
#    ./verify_libwayland_fix.sh /roms/ports/wiliwili
#
#  退出码: 0 = 全部通过（修复生效）；非 0 = 仍有问题（参照逐项输出排查）
# ============================================================================
set -uo pipefail

DEPLOY_DIR="${1:-/roms/ports/wiliwili}"
PASS=0
FAIL=0

green() { printf '\033[32m[PASS]\033[0m %s\n' "$1"; }
red()   { printf '\033[31m[FAIL]\033[0m %s\n' "$1"; }
info()  { printf '\033[36m[INFO]\033[0m %s\n' "$1"; }

if [ ! -d "$DEPLOY_DIR" ]; then
  echo "ERROR: 部署目录不存在: $DEPLOY_DIR" >&2
  exit 2
fi
cd "$DEPLOY_DIR" || exit 2

info "部署目录: $DEPLOY_DIR"
info "当前时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------------------
# 检查 1: libs/ 中不应再出现 libwayland 全族（client/cursor/egl/server）
# 这是修复的直接产物证据：is_core 将其标记为不打包。
# 注意: libva-wayland.so.* 是不同库，修复的 glob 不会匹配它，允许存在。
# ---------------------------------------------------------------------------
info "=== 检查 1: libs/ 不应再含 libwayland-{client,cursor,egl,server}.so* ==="
bundled_wayland=$(ls libs/ 2>/dev/null | grep -E '^libwayland-(client|cursor|egl|server)\.so' || true)
if [ -z "$bundled_wayland" ]; then
  green "libs/ 中未发现 libwayland 全族（client/cursor/egl/server）"
  PASS=$((PASS+1))
else
  red "libs/ 中仍存在应被排除的 libwayland 库:"
  printf '        %s\n' "$bundled_wayland"
  FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 检查 2: 系统 libwayland-client 必须存在且含 wl_proxy_marshal_flags 符号
# （运行期回退目标；实机应自带 1.20+）
# ---------------------------------------------------------------------------
info "=== 检查 2: 系统 libwayland-client 应含 wl_proxy_marshal_flags 符号 ==="
sys_client=$(ls /usr/lib/libwayland-client.so.0 /usr/lib/aarch64-linux-gnu/libwayland-client.so.0 2>/dev/null | head -n1)
if [ -z "$sys_client" ]; then
  red "系统未找到 libwayland-client.so.0（修复依赖实机系统提供，缺失将致命）"
  FAIL=$((FAIL+1))
else
  if nm -D "$sys_client" 2>/dev/null | grep -qi wl_proxy_marshal_flags \
     || strings "$sys_client" 2>/dev/null | grep -q wl_proxy_marshal_flags; then
    green "系统 libwayland-client ($sys_client) 含 wl_proxy_marshal_flags 符号"
    PASS=$((PASS+1))
  else
    red "系统 libwayland-client ($sys_client) 缺少 wl_proxy_marshal_flags（系统版本过旧，修复无法生效）"
    FAIL=$((FAIL+1))
  fi
fi

# ---------------------------------------------------------------------------
# 检查 3: 模拟启动器（LD_LIBRARY_PATH=./libs）运行 wiliwili，
#          不应再报 "symbol lookup error: ... wl_proxy_marshal_flags"。
#          注意: 若无显示服务/会话总线，进程可能因 D-Bus 断言提前退出（SIGABRT），
#          这属于环境问题，不视为符号缺失 bug；仅当错误信息含关键词才判 FAIL。
# ---------------------------------------------------------------------------
info "=== 检查 3: 运行 wiliwili 不应再报 wl_proxy_marshal_flags 符号错误 ==="
err_out=$(LD_LIBRARY_PATH=./libs timeout 20 ./wiliwili 2>&1 | grep -iE 'symbol lookup error|undefined symbol: wl_proxy_marshal_flags' || true)
if [ -z "$err_out" ]; then
  green "未捕获 wl_proxy_marshal_flags 符号查找错误"
  PASS=$((PASS+1))
else
  red "仍出现符号查找错误:"
  printf '        %s\n' "$err_out"
  FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# 检查 4: LD_DEBUG 跟踪实际加载路径 —— libwayland-client 应来自系统 /usr/lib，
#          而非 ./libs/libwayland-client.so.0。
# ---------------------------------------------------------------------------
info "=== 检查 4: LD_DEBUG 确认 libwayland-client 来自系统目录（非 libs/）==="
load_path=$(LD_LIBRARY_PATH=./libs LD_DEBUG=libs timeout 10 ./wiliwili 2>&1 \
              | grep -E "trying file=.*libwayland-client\.so" | head -n1 || true)
if [ -z "$load_path" ]; then
  info "(未能捕获 libwayland-client 加载路径——可能进程在加载前已退出；可人工执行检查 5 命令确认)"
  # 不计入 FAIL：路径捕获失败不等于修复失败
elif echo "$load_path" | grep -qE "trying file=\./libs/libwayland-client\.so"; then
  red "libwayland-client 仍从 libs/ 加载（修复未生效）: $load_path"
  FAIL=$((FAIL+1))
else
  green "libwayland-client 来自系统目录（非 libs/）: $load_path"
  PASS=$((PASS+1))
fi

# ---------------------------------------------------------------------------
# 检查 5（人工辅助命令，打印出来供手动核对）:
#   直接观察 libwayland-client / libdecor 的实际解析来源。
# ---------------------------------------------------------------------------
info "=== 检查 5（人工核对命令，可选手动执行）==="
info "  LD_LIBRARY_PATH=./libs LD_DEBUG=libs ./wiliwili 2>&1 | grep -iE 'libwayland-client|libdecor'"
info "  预期: libwayland-client.so.0 解析到 /usr/lib/libwayland-client.so.0（系统 1.23.x）"

# ---------------------------------------------------------------------------
echo
info "汇总: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  green "全部关键检查通过 —— libwayland 修复在实机生效 ✅"
  exit 0
else
  red "存在失败项 —— 修复在实机未完全生效，请参照上方输出排查 ❌"
  exit 1
fi
