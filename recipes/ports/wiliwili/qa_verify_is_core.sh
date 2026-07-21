#!/usr/bin/env bash
# 独立逻辑校验脚本 (QA: 严过关)
# 不依赖工程师临时脚本，自行从 build.sh 抽取 is_core() 后调用验证。
set -u

BUILD_SH="$(cd "$(dirname "$0")" && pwd)/build.sh"
[ -f "$BUILD_SH" ] || { echo "FATAL: 找不到 build.sh" >&2; exit 2; }

# --- 独立抽取 is_core() 函数定义 (从首行 "is_core() {" 到首个独立 "}" 行) ---
TMP_CORE="$(mktemp /tmp/qa_is_core.XXXXXX.sh)"
awk '/^is_core\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$BUILD_SH" > "$TMP_CORE"

# source 进当前 shell
# shellcheck disable=SC1090
. "$TMP_CORE"
if ! command -v is_core >/dev/null 2>&1; then
  echo "FATAL: is_core 抽取失败" >&2; rm -f "$TMP_CORE"; exit 2
fi

# --- 测试用例: "soname|期望返回值(0=不打包交系统 / 1=打包)" ---
# 注意: is_core 内部对入参做 basename，这里直接用 soname 名本身调用即可
# 2026-07-21 更新: 与 build.sh 当前策略对齐 ——
#   1) 纯系统 GL 路线: libGL/libGLX/libGLdispatch/libEGL/libgbm 全部交系统 (return 0)；
#      (原脚本曾按"自打包 Mesa GL"旧策略期望 return 1，已随 build.sh 改为纯系统 GL 而修正)
#   2) libbz2/liblzma/libzstd 缺失修复: 已从排除清单移除，改为自包含打包 (return 1)；
#   3) 负向对照 libz.so.1 仍交系统 (return 0)，证明仅 compression 子集被改、zlib 未误伤。
declare -a CASES=(
  # 纯系统 GL 路线 (当前 build.sh 策略): Mesa GL 栈全部交还系统
  "libGL.so.1|0"          # 纯系统 GL: 交系统(return 0)
  "libGLX.so.0|0"
  "libGLdispatch.so.0|0"
  "libEGL.so.1|0"
  "libgbm.so.1|0"
  # libbz2/liblzma/libzstd 缺失修复: 改为自包含打包(return 1)
  "libbz2.so.1.0|1"       # 核心修复: libbz2 必须打包
  "liblzma.so.5|1"        # 同族修复: liblzma 必须打包
  "libzstd.so.1|1"        # 同族修复: libzstd 必须打包
  "libmpv.so.1|1"         # mpv -> 应打包(return 1)
  "libz.so.1|0"           # 负向对照: zlib 仍交系统(修复未误伤)
  "libX11.so.6|0"         # 对照组 -> 不打包(return 0)
  "libSDL2-2.0.so.0|0"
  "libwayland-client.so.0|0"
  "libdrm.so.2|0"
  "libxkbcommon.so.0|0"
)

PASS=0; FAIL=0
echo "================ 独立逻辑校验 is_core() ================"
for c in "${CASES[@]}"; do
  soname="${c%|*}"; expected="${c#*|}"
  is_core "$soname"; actual=$?
  if [ "$actual" -eq "$expected" ]; then
    verdict="PASS"; PASS=$((PASS+1))
  else
    verdict="FAIL"; FAIL=$((FAIL+1))
  fi
  printf "  %-26s is_core -> %s (期望 %s)  [%s]\n" "$soname" "$actual" "$expected" "$verdict"
done
echo "-------------------------------------------------------"
echo "通过: $PASS   失败: $FAIL"
rm -f "$TMP_CORE"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
