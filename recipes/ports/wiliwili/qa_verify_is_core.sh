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
declare -a CASES=(
  "libGL.so.1|1"          # 5 个 mesa GL 栈 -> 应打包(return 1)
  "libGLX.so.0|1"
  "libGLdispatch.so.0|1"
  "libEGL.so.1|1"
  "libgbm.so.1|1"
  "libmpv.so.1|1"         # mpv -> 应打包(return 1)
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
