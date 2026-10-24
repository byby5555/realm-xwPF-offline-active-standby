#!/bin/bash
# 连通性探测测试：nc 缺失时必须能回退到 bash /dev/tcp
# 用法: bash tests/test_connectivity.sh
# 不需要 root，不修改真实 /etc/realm

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 期望 [$3] 实际 [$2]"; fi; }

TMPF="$(mktemp -d)"
trap 'rm -rf "$TMPF"' EXIT

echo "=============================================="
echo "A. lib/health.sh 内的 check_connectivity（唯一真源）"
echo "=============================================="
awk '/^check_connectivity\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$REPO/lib/health.sh" > "$TMPF/cc_fn.sh"
if grep -q "dev/tcp" "$TMPF/cc_fn.sh"; then ok "lib/health.sh 含 /dev/tcp 回退"; else bad "lib/health.sh 缺 /dev/tcp 回退"; fi
# shellcheck disable=SC1091
source "$TMPF/cc_fn.sh"

if command -v nc >/dev/null 2>&1; then echo "  (本机有 nc: $(command -v nc))"; else echo "  (本机无 nc → 走 /dev/tcp 回退分支)"; fi

# 起一个本地监听端口
python -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',18080)); s.listen(8)
time.sleep(25)
" &
PY_PID=$!
sleep 1.5

check_connectivity "127.0.0.1" "18080" 2
check "可达端口 → 成功" "$?" "0"

check_connectivity "127.0.0.1" "18081" 2
check "关闭端口 → 失败" "$?" "1"

START=$(date +%s)
check_connectivity "10.255.255.1" "18080" 2
RC=$?
END=$(date +%s)
check "不可达 IP → 失败" "$RC" "1"
if [ $((END-START)) -le 6 ]; then ok "超时受控 ($((END-START))s)"; else bad "超时失控 ($((END-START))s)"; fi

kill $PY_PID 2>/dev/null
wait $PY_PID 2>/dev/null

echo "=============================================="
echo "B. 生成的 health_check.sh 里的 check_connectivity（独立副本）"
echo "=============================================="
awk "/health_check_script_body\(\) \{/{f=1} f&&/cat << 'EOF'/{g=1;next} g&&/^EOF\$/{exit} g{print}" \
    "$REPO/lib/health.sh" > "$TMPF/hc_script.sh"
if [ -s "$TMPF/hc_script.sh" ]; then
    if grep -q "dev/tcp" "$TMPF/hc_script.sh"; then ok "health_check.sh 含 /dev/tcp 回退"; else bad "health_check.sh 缺 /dev/tcp 回退"; fi
    awk '/^check_connectivity\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TMPF/hc_script.sh" > "$TMPF/cc_fn2.sh"
    # shellcheck disable=SC1091
    source "$TMPF/cc_fn2.sh"
    python -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',18082)); s.listen(8)
time.sleep(15)
" &
    PY2=$!
    sleep 1.5
    check_connectivity "127.0.0.1" "18082" 2
    check "health_check.sh 版本 → 可达端口成功" "$?" "0"
    check_connectivity "127.0.0.1" "18083" 2
    check "health_check.sh 版本 → 关闭端口失败" "$?" "1"
    kill $PY2 2>/dev/null; wait $PY2 2>/dev/null
else
    bad "未能提取 health_check.sh 内容"
fi

echo "=============================================="
echo "C. 两份探测实现保持一致（防止改了一处忘了另一处）"
echo "=============================================="
if [ -s "$TMPF/cc_fn.sh" ] && [ -s "$TMPF/cc_fn2.sh" ]; then
    # 归一化：去掉注释与空行后比较
    norm_a=$(grep -v '^\s*#' "$TMPF/cc_fn.sh" | grep -v '^\s*$')
    norm_b=$(grep -v '^\s*#' "$TMPF/cc_fn2.sh" | grep -v '^\s*$')
    if [ "$norm_a" = "$norm_b" ]; then ok "lib/health.sh 与 health_check.sh 的探测实现一致"; else bad "两份探测实现已漂移"; fi
else
    bad "缺少可比对的实现"
fi

echo "=============================================="
echo "结果: PASS=$PASS FAIL=$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ]
