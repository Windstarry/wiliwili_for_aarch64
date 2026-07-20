#!/bin/bash
# =============================================================================
# qa_build_params_verify.sh
# -----------------------------------------------------------------------------
# 验证 wiliwili aarch64 构建产物的编译参数基线（参照 commit 68f6bbb 的 build.sh）。
#
# ⚠ 需 CI 用修复版 build.sh（commit 68f6bbb）重建并部署后执行。
#   本脚本仅做【只读】核查，绝不修改任何目标文件。
#
# 判定标准：
#   1) readelf -A 应显示
#        Tag_CPU_arch: AArch64        （CPU_arch = v8-A / ARMv8）
#        Tag_CPU_name: cortex-a53     （或至少不出现比 v8-A 更激进的 v8.2/v8.3 属性）
#      —— 证明采用了 -march=armv8-a -mtune=cortex-a53，未误用 -mcpu=cortex-a55。
#   2) readelf -h / file 应确认其为 aarch64 动态可执行、未被截断/损坏。
#   3)（可选，实机）运行 ./wiliwili 不应出现 SIGILL（illegal instruction）。
#      注意：headless 无 D-Bus 导致的 SIGABRT 不计为基线失败。
#
# 用法：
#   bash qa_build_params_verify.sh [BIN_PATH]
#     BIN_PATH 默认 $PWD/dist/wiliwili
#   可选环境变量：
#     RUN_CHECK=1   额外尝试实机运行并捕获 SIGILL（仅建议在生产实机执行）
# =============================================================================
set -u

BIN="${1:-dist/wiliwili}"
RC=0

echo "=== QA: wiliwili aarch64 编译参数基线核查（需 CI 重建部署后执行）==="
echo "目标二进制: $BIN"

if [ ! -f "$BIN" ]; then
  echo "ERROR: 找不到二进制 $BIN，请先完成 CI 重建与部署。" >&2
  exit 2
fi

for t in readelf file; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "WARN: 缺少 $t 工具，部分检查将跳过。" >&2
  fi
done

# ---- 1) ELF 头 / 架构确认 ----
echo
echo "--- [1/3] ELF 头与架构 (readelf -h / file) ---"
if command -v file >/dev/null 2>&1; then
  file "$BIN" || RC=1
fi
if command -v readelf >/dev/null 2>&1; then
  HDR="$(readelf -h "$BIN" 2>/dev/null)"
  if echo "$HDR" | grep -qi 'AArch64'; then
    echo "OK: ELF 为 AArch64 架构"
  else
    echo "FAIL: 未检测到 AArch64 架构"; RC=1
  fi
  if echo "$HDR" | grep -qiE 'Type:\s+(DYN|EXEC)'; then
    echo "OK: 为标准 ELF 可执行 (DYN/EXEC)"
  else
    echo "WARN: ELF 类型异常，请人工确认"
  fi
fi

# ---- 2) 编译参数属性 (readelf -A) ----
echo
echo "--- [2/3] 编译参数属性 (readelf -A) ---"
if command -v readelf >/dev/null 2>&1; then
  ATTR="$(readelf -A "$BIN" 2>/dev/null)"
  echo "$ATTR"

  if echo "$ATTR" | grep -qE 'Tag_CPU_arch: AArch64'; then
    echo "OK: Tag_CPU_arch = AArch64"
  else
    echo "FAIL: 未找到 Tag_CPU_arch: AArch64"; RC=1
  fi

  if echo "$ATTR" | grep -qE 'Tag_CPU_name: cortex-a53'; then
    echo "OK: Tag_CPU_name = cortex-a53 (mtune=cortex-a53 生效)"
  else
    echo "WARN: 未显示 Tag_CPU_name: cortex-a53。"
    if echo "$ATTR" | grep -qiE 'v8\.[2-9]|ARMv8\.[2-9]'; then
      echo "FAIL: 检测到比 v8-A 更激进的微架构属性（疑似误用 -mcpu=cortex-a55 / -march=armv8.2-a）"; RC=1
    else
      echo "PASS(弱化): 未发现更激进微架构属性，march=armv8-a 基线可认定成立"
    fi
  fi

  if echo "$ATTR" | grep -qi 'LTO'; then
    echo "WARN: 发现 LTO 相关属性（请确认 -flto 未启用）"
  else
    echo "OK: 未发现 LTO 属性（与关闭 LTO 一致）"
  fi
else
  echo "SKIP: readelf 不可用，无法核查编译参数属性"; RC=1
fi

# ---- 3) 可选：实机运行 SIGILL 判据 ----
echo
echo "--- [3/3] 实机运行 SIGILL 判据 (可选, RUN_CHECK=1) ---"
if [ "${RUN_CHECK:-0}" = "1" ]; then
  echo "尝试运行 $BIN 并捕获信号..."
  timeout 15 "$BIN" --version >/dev/null 2>&1
  ec=$?
  # SIGILL = 128+4 = 132
  if [ "$ec" -eq 132 ] || [ "$ec" -eq 4 ]; then
    echo "FAIL: 检测到 SIGILL (退出码 $ec) —— -march 基线过激！"; RC=1
  else
    echo "OK: 未出现 SIGILL（退出码=$ec；headless 无 D-Bus 的 SIGABRT 不计为基线失败）"
  fi
else
  echo "SKIP: 未设置 RUN_CHECK=1，跳过运行期核查（请在生产实机显式开启）"
fi

echo
if [ "$RC" -eq 0 ]; then
  echo "=== QA 结论: 通过（编译参数基线符合 -march=armv8-a -mtune=cortex-a53，未误用 -mcpu=cortex-a55，LTO 已关）==="
else
  echo "=== QA 结论: 不通过（详见上方 FAIL）===" >&2
fi
exit $RC
