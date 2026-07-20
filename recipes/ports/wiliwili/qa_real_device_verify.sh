#!/usr/bin/env bash
# ============================================================================
# 实机动态验证脚本 (QA: 严过关)
# 状态: 需 CI 用修复版 build.sh (commit 2baf746) 重建并把新产物部署到实机
#       /roms/ports/wiliwili 后，方可在实机执行本脚本。
# 当前实机 192.168.137.247 离线/SSH 超时，本脚本尚未运行，动态证伪暂缓。
# 严禁在本脚本内修改实机任何文件，仅做只读检查。
# ============================================================================
set -u

PORT_DIR="/roms/ports/wiliwili"
cd "$PORT_DIR" || { echo "FATAL: 无法 cd $PORT_DIR (产物是否已部署?)" >&2; exit 2; }

GL_LIBS='libGL\.so|libGLX|libGLdispatch|libEGL|libgbm'
OVERALL=0

echo "===== [a] 启动期不应再报 libGL file too short ====="
# 注意: headless 无 D-Bus 会话会 SIGABRT，那非本 bug；判定以"无 libGL file too short"为准
OUT="$(./wiliwili 2>&1 & PID=$!; sleep 4; kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null)"
if printf '%s' "$OUT" | grep -qiE 'libGL\.so\.1: file too short|error while loading shared libraries'; then
  echo "  [FAIL] 仍报 file too short / 加载失败:"
  printf '%s\n' "$OUT" | grep -iE 'file too short|error while loading' | head
  OVERALL=1
else
  echo "  [PASS] 无 libGL file too short / 无 error while loading shared libraries"
fi

echo "===== [b] LD_DEBUG 确认 5 个 GL 库从 ./libs/ 加载 (自包含生效) ====="
DBG="$(LD_DEBUG=libs ./wiliwili 2>&1 & PID=$!; sleep 3; kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null)"
# 取每个 GL soname 的"首次找到"路径
ok_b=0; need=0
for pat in libGL.so.1 libGLX.so.0 libGLdispatch.so.0 libEGL.so.1 libgbm.so.1; do
  need=$((need+1))
  line="$(printf '%s' "$DBG" | grep -E "file=.*${pat}" | head -1)"
  if printf '%s' "$line" | grep -qE "from.*\./libs/|${PORT_DIR}/libs/"; then
    echo "  [PASS] $pat 从 libs/ 加载: $(printf '%s' "$line" | grep -oE 'from[^]]*' | head -1)"
    ok_b=$((ok_b+1))
  else
    echo "  [WARN] $pat 未从 ./libs/ 解析: ${line:-<未出现>}"
  fi
done
[ "$ok_b" -eq "$need" ] || OVERALL=1

echo "===== [c] 部署 libs/ 应包含这 5 个 GL 库 (证明已打包) ====="
present="$(ls "$PORT_DIR/libs/" 2>/dev/null | grep -iE '^libGL\.so|^libGLX|^libGLdispatch|^libEGL\.so|^libgbm' | sort)"
echo "  已打包 GL 库:"
echo "$present" | sed 's/^/    /'
need_c=0
for pat in '^libGL\.so' '^libGLX' '^libGLdispatch' '^libEGL\.so' '^libgbm'; do
  need_c=$((need_c+1))
  printf '%s\n' "$present" | grep -qE "$pat" || { echo "  [FAIL] 缺失匹配 $pat 的库"; OVERALL=1; }
done
[ "$OVERALL" -eq 0 ] && echo "===== 实机验证结论: 全部通过 (自包含 GL 栈生效) =====" \
                     || echo "===== 实机验证结论: 存在失败项，见上 ====="
exit $OVERALL
