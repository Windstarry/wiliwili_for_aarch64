#!/usr/bin/env bash
# ============================================================================
# qa_verify_libbz2_fix.sh — 回归测试: libbz2 / liblzma / libzstd 缺失修复
# ----------------------------------------------------------------------------
# 对应 bug:   software-bugfix-libbz2-missing
#   现象: 目标 RockNIX 固件未必提供 libbz2 / liblzma / libzstd；源码构建的
#         ffmpeg 6 默认自动链接 bzlib / xz / zstd，运行期加载器若在其
#         LD_LIBRARY_PATH(libs/) 与系统 /usr/lib 都找不到对应 .so，会报:
#           "error while loading shared libraries: libbz2.so.1:
#            cannot open shared object file"
#         -> 程序无法启动 (无图像 / 不启动)。
#   修复: 在 recipes/ports/wiliwili/build.sh 的 is_core() 排除清单中移除
#         libbz2 / liblzma / libzstd，使三者随 libs/ 自包含打包
#         (is_core 命中排除清单返回 0=交系统，未命中返回 1=打包；移除后
#          三者返回 1，被正确 stage 进 dist/libs)。
#
# 本脚本只做【只读】逻辑回归 (不需要 aarch64 容器 / 实机即可运行):
#   1) 从 build.sh 独立抽取 is_core() 函数定义 (与 qa_verify_is_core.sh 同源手法)；
#   2) 断言 libbz2 / liblzma / libzstd 必须被判定为「打包」(return 1)；
#   3) 负向对照: libz.so.1 (zlib) 仍判定为「系统提供」(return 0)，
#      证明修复只动了 compression 子集、未误伤 zlib；
#   4) (可选) --libs-dir <path> 指向已构建的 libs/ 时，额外断言该目录下存在
#       libbz2.so.* / liblzma.so.* / libzstd.so.* 实体文件；未提供则跳过。
#
# 退出码: 0 = 全部通过; 2 = 环境错误(找不到 build.sh / 抽取失败); 1 = 有断言失败。
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SH="${BUILD_SH:-$SCRIPT_DIR/build.sh}"
LIBS_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --build-sh) BUILD_SH="$2"; shift 2 ;;
    --libs-dir) LIBS_DIR="$2"; shift 2 ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "WARN: 忽略未知参数: $1" >&2; shift ;;
  esac
done

[ -f "$BUILD_SH" ] || { echo "FATAL: 找不到 build.sh ($BUILD_SH)" >&2; exit 2; }

# --- 独立抽取 is_core() (从首行 "is_core() {" 到首个独立 "}" 行) ---
TMP_CORE="$(mktemp /tmp/qa_libbz2.XXXXXX.sh)"
awk '/^is_core\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$BUILD_SH" > "$TMP_CORE"
# shellcheck disable=SC1090
. "$TMP_CORE"
if ! command -v is_core >/dev/null 2>&1; then
  echo "FATAL: 从 build.sh 抽取 is_core() 失败" >&2
  rm -f "$TMP_CORE"
  exit 2
fi

# 测试表: "soname|期望(0=系统/1=打包)|说明"
declare -a CASES=(
  "libbz2.so.1.0|1|核心修复: libbz2 必须自包含打包"
  "liblzma.so.5|1|同族修复: liblzma 必须打包"
  "libzstd.so.1|1|同族修复: libzstd 必须打包"
  "libz.so.1|0|负向对照: zlib 仍交系统(未被误改)"
  "libmpv.so.1|1|回归保护: libmpv 仍打包"
  "libX11.so.6|0|回归保护: X11 仍交系统"
)

PASS=0; FAIL=0; FAILS=()
echo "================ 回归校验: libbz2/liblzma/libzstd 缺失修复 ================"
for c in "${CASES[@]}"; do
  soname="${c%|*}"
  rest="${c#*|}"; expected="${rest%|*}"; desc="${rest#*|}"
  is_core "$soname"; actual=$?
  if [ "$actual" -eq "$expected" ]; then
    printf '  [PASS] %-20s is_core -> %s (期望 %s)  %s\n' "$soname" "$actual" "$expected" "$desc"
    PASS=$((PASS+1))
  else
    printf '  [FAIL] %-20s is_core -> %s (期望 %s)  %s\n' "$soname" "$actual" "$expected" "$desc"
    FAIL=$((FAIL+1)); FAILS+=("$soname")
  fi
done

# --- 可选: 已构建 libs/ 目录实体存在性校验 ---
if [ -n "$LIBS_DIR" ]; then
  echo "-------------------------------------------------------"
  echo "可选校验: 已构建 libs/ 目录 ($LIBS_DIR)"
  if [ -d "$LIBS_DIR" ]; then
    for base in libbz2 liblzma libzstd; do
      if ls "$LIBS_DIR"/${base}.so.* >/dev/null 2>&1; then
        printf '  [PASS] %s 实体存在于 libs/ (%s)\n' "$base" \
               "$(ls "$LIBS_DIR"/${base}.so.* 2>/dev/null | head -1)"
        PASS=$((PASS+1))
      else
        printf '  [FAIL] %s 未在 libs/ 中找到实体文件\n' "$base"
        FAIL=$((FAIL+1)); FAILS+=("$base(libs)")
      fi
    done
  else
    printf '  [SKIP] libs 目录不存在 (%s)，跳过实体校验\n' "$LIBS_DIR"
  fi
fi

echo "-------------------------------------------------------"
echo "通过: $PASS   失败: $FAIL"
rm -f "$TMP_CORE"
if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAIL (缺失/误判: ${FAILS[*]})" >&2
  exit 1
fi
echo "RESULT: PASS"
exit 0
